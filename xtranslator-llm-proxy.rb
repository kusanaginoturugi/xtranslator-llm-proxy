#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "socket"
require "time"
require "uri"
require_relative "lib/dictionary"

BRIEF_LOG = !!(ARGV.delete("--brief") || ARGV.delete("-b"))
DUMP_PATH = (i = ARGV.index("--dump")) ? ARGV.slice!(i, 2)[1] : ENV["XTRANSLATOR_DUMP"]

def env(key, default) = ENV.fetch("XTRANSLATOR_#{key}", default)

LISTEN_HOST = env("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = env("LISTEN_PORT", "8091").to_i
UPSTREAM = URI(env("UPSTREAM", "http://127.0.0.1:8080/v1/chat/completions"))
MODEL = env("MODEL", "gemma-4-12b-it-qat-imatrix")
SHORT_MODEL = env("SHORT_MODEL", "")
SHORT_MODEL_MAX_LINES = env("SHORT_MODEL_MAX_LINES", "2").to_i
SHORT_MODEL_MAX_CHARS = env("SHORT_MODEL_MAX_CHARS", "160").to_i
TEMPERATURE = env("TEMPERATURE", "0").to_f
UPSTREAM_TIMEOUT = env("UPSTREAM_TIMEOUT", "30").to_f
RETRIES = env("RETRIES", "1").to_i
# xTranslator (Delphi REST) は約 20 秒で接続を切る。この秒数に収まりそうなときだけ再試行する
CLIENT_BUDGET = env("CLIENT_BUDGET", "18").to_f
WARMUP = env("WARMUP", "1") != "0"

DICTIONARY_PATH = File.expand_path(env("DICTIONARY", "~/.local/share/xtranslator-llm-proxy/dictionary.jsonl"))
SESSION_PATH = env("SESSION", File.expand_path("~/.local/share/xtranslator-llm-proxy/session.jsonl"))
GAME_TITLE = env("GAME_TITLE", "The Elder Scrolls V: Skyrim")
GLOSSARY_PREPEND = env("GLOSSARY_PREPEND", File.join(__dir__, "xtranslator-glossary.local.tsv"))
GLOSSARY_LIMIT = env("GLOSSARY_LIMIT", "40").to_i
EXAMPLE_LIMIT = env("EXAMPLE_LIMIT", "3").to_i
SESSION_EXAMPLE_LIMIT = env("SESSION_EXAMPLE_LIMIT", "2").to_i
CACHE_PATH = env("CACHE", File.expand_path("~/.cache/xtranslator-llm-proxy/translations.jsonl"))
PROMPT_VERSION = "3"

DICTIONARY = Dictionary.new(
  snapshot: DICTIONARY_PATH,
  local_paths: GLOSSARY_PREPEND.split(":").map { |path| File.expand_path(path) },
  session: SESSION_PATH.empty? ? nil : File.expand_path(SESSION_PATH)
)

# ---- xTranslator request ----

def source_text_from(content)
  content.to_s.split(/\r?\n/, 2)[1].to_s
end

def user_message_from(payload)
  messages = payload["messages"]
  return nil unless messages.is_a?(Array)

  messages.find { |m| m.is_a?(Hash) && m["role"] == "user" && m["content"].is_a?(String) }
end

def model_for_source_text(source_text)
  return MODEL if SHORT_MODEL.empty?

  lines = source_text.to_s.split(/\r?\n/, -1)
  compact_text = source_text.to_s.gsub(/\s+/, "")
  return SHORT_MODEL if lines.length <= SHORT_MODEL_MAX_LINES && compact_text.length <= SHORT_MODEL_MAX_CHARS

  MODEL
end

def completion_response(content, model, finish_reason = "stop")
  JSON.dump(
    choices: [
      {
        finish_reason: finish_reason,
        index: 0,
        message: {
          role: "assistant",
          content: content
        }
      }
    ],
    object: "chat.completion",
    model: model
  )
end

# ---- cache ----

# 検証を通った LLM 訳だけを JSONL に追記して再利用する。
class TranslationCache
  def initialize(path)
    @path = path
    @entries = {}
    return if path.to_s.empty? || !File.file?(path)

    File.foreach(path, chomp: true) do |line|
      row = JSON.parse(line)
      @entries[row["key"]] = row["text"]
    rescue JSON::ParserError
      next
    end
  end

  def key(model, text) = [PROMPT_VERSION, model, text].join("\t")

  def [](model, text) = @entries[key(model, text)]

  def store(model, text, translated)
    return if @path.to_s.empty?

    k = key(model, text)
    @entries[k] = translated
    FileUtils.mkdir_p(File.dirname(@path))
    File.open(@path, "a") { |f| f.puts JSON.dump(key: k, text: translated) }
  end

  def size = @entries.size
end

CACHE = TranslationCache.new(CACHE_PATH)

# ---- prompt ----

def build_prompt(text, terms, examples, problems = [])
  sections = []
  sections << <<~RULES.chomp
    You are a professional English (en) to Japanese (ja) translator for the video game #{GAME_TITLE}.
    Your goal is to accurately convey the meaning and nuances of the original English text while adhering to Japanese grammar, vocabulary, and the style of the official Japanese localization.
    Produce only the Japanese translation, without any additional explanations or commentary.
    Keep exactly the same number of lines as the source text.
    Keep angle-bracket placeholders such as <mag>, <dur> and <Alias=Player> exactly as they are.
    For titles, spell names, effect names, item names, and noun phrases, output a Japanese noun phrase, not a full sentence.
  RULES

  unless terms.empty?
    sections << "Glossary. Always use these exact Japanese terms:\n" +
                terms.map { |t| "#{t[:source]} = #{t[:target]}" }.join("\n")
  end

  unless examples.empty?
    sections << "Reference translations of similar lines (official localization and earlier translations). Follow their wording:\n" +
                examples.map { |s, t| "English: #{s}\nJapanese: #{t}" }.join("\n\n")
  end

  unless problems.empty?
    sections << "Your previous translation had these problems. Fix them:\n" + problems.map { |p| "- #{p}" }.join("\n")
  end

  sections << "Please translate the following English text into Japanese:\n\n\n#{text}"
  sections.join("\n\n")
end

# ---- response cleanup (旧実装から継承) ----

def strip_model_markup(text)
  text
    .lines
    .reject { |line| line.match?(/\A\s*```/) }
    .reject { |line| line.include?("=>") }
    .join
    .gsub(/(?m)^\s*[-*•]\s+/, "")
    .gsub(/(?m)^\s*\d+[.)]\s+/, "")
    .gsub(/(?m)^\s*<\d+>\s+/, "")
    .gsub(/\*\*([^*\r\n]+)\*\*/, "\\1")
    .gsub(/__([^_\r\n]+)__/, "\\1")
    .gsub(/`([^`\r\n]+)`/, "\\1")
    .sub(/\A\s*(?:Japanese|日本語|翻訳|訳文)\s*[:：]\s*/, "")
    .sub(/\r?\n+\z/, "")
end

def angle_tags(text)
  text.to_s.scan(/<[^<>\r\n]+>/)
end

def strip_unseen_angle_tags(text, source_text)
  source_lines = source_text.to_s.split(/\r?\n/, -1)
  output_lines = text.to_s.split(/\r?\n/, -1)

  if source_lines.length == output_lines.length
    return output_lines.each_with_index.map do |line, index|
      allowed = angle_tags(source_lines[index]).uniq
      line.gsub(/<[^<>\r\n]+>/) { |tag| allowed.include?(tag) ? tag : "" }
    end.join("\n")
  end

  allowed = angle_tags(source_text).uniq
  text.gsub(/<[^<>\r\n]+>/) { |tag| allowed.include?(tag) ? tag : "" }
end

def enforce_source_line_count(text, source_text)
  source_lines = source_text.to_s.split(/\r?\n/, -1)
  output_lines = text.to_s.split(/\r?\n/, -1)
  return text if source_lines.length == output_lines.length

  compact_lines = output_lines.map(&:strip).reject(&:empty?)
  return compact_lines.join if source_lines.length == 1
  return compact_lines.join("\n") if source_lines.length == compact_lines.length

  text
end

def strip_added_terminal_periods(text, source_text)
  source_lines = source_text.to_s.split(/\r?\n/, -1)
  output_lines = text.to_s.split(/\r?\n/, -1)
  return text unless source_lines.length == output_lines.length

  output_lines.each_with_index.map do |line, index|
    source_line = source_lines[index].rstrip
    next line if source_line.match?(/[.。]\z/)

    line.sub(/[.。]\z/, "")
  end.join("\n")
end

def sanitize(content, source_text)
  content = strip_model_markup(content.to_s)
  content = strip_unseen_angle_tags(content, source_text)
  content = enforce_source_line_count(content, source_text)
  strip_added_terminal_periods(content, source_text)
end

# ---- validation ----

def normalize_ja(text) = text.to_s.gsub(/[\s・=＝]/, "")

def problems_in(output, source_text, terms)
  problems = []
  source_lines = source_text.split(/\r?\n/, -1).length
  output_lines = output.split(/\r?\n/, -1).length
  problems << "The source has #{source_lines} lines but the translation has #{output_lines} lines." if source_lines != output_lines

  missing_tags = angle_tags(source_text).tally.select { |tag, n| output.scan(tag).length < n }.keys
  problems << "Keep these placeholders: #{missing_tags.join(' ')}" unless missing_tags.empty?

  terms.each do |t|
    next if normalize_ja(output).include?(normalize_ja(t[:target]))

    problems << "Translate \"#{t[:source]}\" as \"#{t[:target]}\"."
  end

  # タグ (<...>) と本のページ区切りなど ([pagebreak]) の中の英字は数えない
  plain = output.gsub(/<[^<>]*>|\[[^\[\]]*\]/, "")
  if Dictionary.words(Dictionary.mask_tags(source_text)).length >= 3 &&
     plain.scan(/[A-Za-z]/).length > plain.gsub(/\s/, "").length / 2
    problems << "The text was not translated into Japanese."
  else
    # 訳文に混ざった小文字始まりのラテン文字の単語（"wielderに", "voluntadで"）。固有名詞は大文字なので対象外
    leaked = plain.scan(/(?<![\p{Latin}\d%])\p{Ll}[\p{Latin}']{2,}(?![\p{Latin}])/).uniq
    problems << "These words are not Japanese. Translate them: #{leaked.join(', ')}" unless leaked.empty?
  end

  problems
end

# ---- upstream ----

class UpstreamError < StandardError
  attr_reader :status, :body

  def initialize(status, body)
    @status = status
    @body = body
    super("upstream #{status}: #{body.to_s[0, 200]}")
  end
end

def upstream_chat(model, prompt, max_tokens)
  post = Net::HTTP::Post.new(UPSTREAM)
  post["Content-Type"] = "application/json"
  post["Accept"] = "application/json"
  post.body = JSON.dump(
    model: model,
    messages: [{ role: "user", content: prompt }],
    temperature: TEMPERATURE,
    max_tokens: max_tokens,
    stream: false
  )

  Net::HTTP.start(UPSTREAM.host, UPSTREAM.port) do |http|
    if UPSTREAM_TIMEOUT.positive?
      # 長文は生成に時間がかかるので、最悪 25 tok/s として read timeout を延ばす
      http.open_timeout = UPSTREAM_TIMEOUT
      http.read_timeout = UPSTREAM_TIMEOUT + max_tokens / 25.0
    end

    http.request(post)
  end
end

# LLM で訳す。問題があれば指摘付きで再試行し、問題の少ない方を採る。
# 戻り値: [訳文, 残った問題]
def translate_with_llm(model, text)
  terms = DICTIONARY.match_terms(text, limit: GLOSSARY_LIMIT)
  examples = DICTIONARY.similar_examples(text, limit: EXAMPLE_LIMIT, session_limit: SESSION_EXAMPLE_LIMIT)
  max_tokens = (text.length * 3).clamp(64, 8192)
  best = nil
  problems = []
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  (RETRIES + 1).times do |attempt|
    prompt = build_prompt(text, terms, examples, problems)
    log_verbose("---- upstream prompt #{model} (attempt #{attempt + 1}) ----", prompt)

    response = upstream_chat(model, prompt, max_tokens)
    raise UpstreamError.new(response.code.to_i, response.body) unless response.code.to_i == 200

    content = JSON.parse(response.body).dig("choices", 0, "message", "content").to_s
    output = sanitize(content, text)
    problems = problems_in(output, text, terms)
    log_verbose("---- llama.cpp output (attempt #{attempt + 1}) ----", content, "problems: #{problems.inspect}")

    best = [output, problems] if best.nil? || problems.length < best[1].length
    break if problems.empty?

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    if elapsed * (attempt + 2) / (attempt + 1) > CLIENT_BUDGET
      log_verbose("skip retry: #{elapsed.round(1)}s elapsed, budget #{CLIENT_BUDGET}s")
      break
    end
  end

  best
end

# 検証を通った訳を 1 行ずつ作業中辞書へ。以降の用語・例文・完全一致に使われる。
def remember_lines(text, output)
  sources = text.split("\n", -1)
  targets = output.split("\n", -1)
  return unless sources.length == targets.length

  sources.zip(targets).each { |source, target| DICTIONARY.remember(source, target) }
end

# 1 リクエスト分を訳す。戻り値: [訳文, ログ用ラベル]
def translate(source_text)
  DICTIONARY.refresh!

  whole = DICTIONARY.lookup(source_text)
  return [whole, "glossary"] if whole

  lines = source_text.split(/\r?\n/, -1)
  resolved = lines.map { |line| line.strip.empty? ? line : DICTIONARY.lookup(line) }
  pending = lines.each_index.reject { |i| resolved[i] }
  return [resolved.join("\n"), "glossary"] if pending.empty?

  model = model_for_source_text(source_text)
  partial = pending.length < lines.count { |line| !line.strip.empty? }
  text = partial ? pending.map { |i| lines[i] }.join("\n") : source_text

  if (cached = CACHE[model, text])
    output = cached
    label = "cache"
  else
    output, problems = translate_with_llm(model, text)
    # temperature 0 なので再実行しても同じ結果。問題が残っても保存し、xTranslator が
    # timeout で切った長文も次のリクエストで即返せるようにする
    CACHE.store(model, text, output)
    remember_lines(text, output) if problems.empty?
    label = problems.empty? ? model : "#{model} (#{problems.length} problems)"
  end

  return [output, label] unless partial

  translated = output.split(/\r?\n/, -1)
  if translated.length == pending.length
    pending.each_with_index { |line_index, i| resolved[line_index] = translated[i] }
    return [resolved.join("\n"), "glossary+#{label}"]
  end

  # 行数が合わなければ部分合成を諦めて全文を訳す
  output, = translate_with_llm(model, source_text)
  [output, model]
end

# ---- HTTP ----

def read_request(sock)
  head = +""
  head << sock.readpartial(1024) until head.include?("\r\n\r\n")
  header, rest = head.split("\r\n\r\n", 2)
  lines = header.lines.map(&:chomp)
  request_line = lines.shift
  headers = {}

  lines.each do |line|
    key, value = line.split(":", 2)
    headers[key.downcase] = value.to_s.strip if key
  end

  length = headers["content-length"].to_i
  body = rest.to_s
  body << sock.read(length - body.bytesize) while body.bytesize < length

  [request_line, headers, body.force_encoding(Encoding::UTF_8)]
end

def write_response(sock, status, body)
  reason = status == 200 ? "OK" : "Error"
  bytes = body.b
  sock.write "HTTP/1.1 #{status} #{reason}\r\n"
  sock.write "Content-Type: application/json; charset=utf-8\r\n"
  sock.write "Content-Length: #{bytes.bytesize}\r\n"
  sock.write "Connection: close\r\n"
  sock.write "\r\n"
  sock.write bytes
end

def client_disconnected?(error)
  error.is_a?(Errno::EPIPE) || error.is_a?(Errno::ECONNRESET) || error.is_a?(IOError)
end

def upstream_timeout_error?(error)
  error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout)
end

# ---- logging ----

def log_verbose(*lines)
  return if BRIEF_LOG

  lines.each { |line| warn line }
end

def brief_style(text, code)
  return text unless $stderr.tty?

  "\e[#{code}m#{text}\e[0m"
end

def log_brief_translation(source_text, translated, model)
  return unless BRIEF_LOG

  warn brief_style("モデル: #{model}", "1;35")
  warn brief_style("ソース", "1;32")
  warn source_text
  warn brief_style("訳文", "1;36")
  warn translated
  warn brief_style("────────────────", "2")
end

def dump_request(request_line, headers, body)
  return if DUMP_PATH.to_s.empty?

  File.open(DUMP_PATH, "a") do |f|
    f.puts JSON.dump(time: Time.now.iso8601, request_line: request_line, headers: headers, body: body)
  end
end

# ---- main ----

if WARMUP
  Thread.new do
    upstream_chat(MODEL, "Translate into Japanese: Hello", 4)
    warn "warmup: #{MODEL} loaded"
  rescue => e
    warn "warmup failed: #{e.class}: #{e.message}"
  end
end

server = TCPServer.new(LISTEN_HOST, LISTEN_PORT)
warn "listening on http://#{LISTEN_HOST}:#{LISTEN_PORT}/v1/chat/completions"
warn "upstream #{UPSTREAM} model=#{MODEL}#{SHORT_MODEL.empty? ? '' : " short=#{SHORT_MODEL}"}"
warn "dictionary #{DICTIONARY_PATH} memory=#{DICTIONARY.memory_size} terms=#{DICTIONARY.term_size} examples=#{DICTIONARY.example_size} session=#{DICTIONARY.session_size} cache=#{CACHE.size}"
warn "dump requests to #{DUMP_PATH}" unless DUMP_PATH.to_s.empty?

trap("INT") do
  warn "\nbye"
  exit
end

loop do
  sock = server.accept

  begin
    request_line, headers, body = read_request(sock)
    dump_request(request_line, headers, body)
    log_verbose("---- xTranslator request ----", request_line, headers.inspect, body)

    user_message = user_message_from(JSON.parse(body))
    raise "no user message in request" unless user_message

    # xTranslator は配列の各要素を \r\n でつないで送り、同じ改行で分割して受け取る。
    # 中では \n で扱い、返すときに元の改行へ戻す。
    raw_source = source_text_from(user_message["content"])
    eol = raw_source.include?("\r\n") ? "\r\n" : "\n"
    source_text = raw_source.gsub("\r\n", "\n")

    begin
      translated, label = translate(source_text)
    rescue => e
      raise unless upstream_timeout_error?(e)

      warn "upstream timeout (base #{UPSTREAM_TIMEOUT}s): #{model_for_source_text(source_text)}"
      log_brief_translation(source_text, source_text, "timeout")
      write_response(sock, 200, completion_response(raw_source, "timeout", "length"))
      next
    end

    log_brief_translation(source_text, translated, label)
    write_response(sock, 200, completion_response(translated.gsub(/\r?\n/, eol), label))
  rescue UpstreamError => e
    warn "proxy error: #{e.message}"
    begin
      write_response(sock, e.status, e.body.to_s)
    rescue => write_error
      raise write_error unless client_disconnected?(write_error)
    end
  rescue => e
    if client_disconnected?(e)
      warn "client disconnected: #{e.class}: #{e.message}"
      next
    end

    warn "proxy error: #{e.class}: #{e.message}"
    warn e.backtrace.first(5).join("\n")
    begin
      write_response(sock, 500, JSON.dump(error: e.message))
    rescue => write_error
      raise write_error unless client_disconnected?(write_error)

      warn "client disconnected while writing error response: #{write_error.class}: #{write_error.message}"
    end
  ensure
    sock.close
  end
end
