# frozen_string_literal: true

require "digest"
require "json"
require "set"

# 辞書スナップショット (JSONL) と手動 TSV から、翻訳メモリ・用語集・類似例文を引く。
# スナップショットは xtranslator_sst_glossary.rb --format jsonl が SST から書き出す。
# 元ファイルの mtime が変わったら refresh! で作り直す。
#
# 作業中辞書 (session): プロキシ自身の訳を 1 行ずつ貯め、優先度最低の層として使う。
# SST が保存されてスナップショットの中身が変わったら空にする（訳は SST 側に入ったとみなす）。
class Dictionary
  WORD_RE = /[[:alnum:]]+(?:['’][[:alnum:]]+)*/
  STOPWORDS = %w[
    the and for you your are was were with that this have has had not but from they them their
    what when where who will would can could should into out about there then than its his her
    she him our all any some one two just been being more most very also only over such
  ].to_set.freeze
  TERM_MIN_CHARS = 3
  TERM_MAX_CHARS = 80
  TERM_MAX_WORDS = 8
  EXAMPLE_MIN_CHARS = 20
  EXAMPLE_MAX_CHARS = 300
  EXAMPLE_MAX_DF = 400

  attr_reader :memory_size, :term_size, :example_size, :session_size

  def initialize(snapshot:, local_paths: [], session: nil)
    @snapshot = snapshot
    @local_paths = local_paths
    @session = session.to_s.empty? ? nil : session
    @signature = nil
    refresh!
  end

  def self.words(text)
    text.to_s.tr("’", "'").scan(WORD_RE).map(&:downcase)
  end

  def self.term_key(text) = words(text).join(" ")

  # <img src=...> や <font ...> の中身を照合対象から外す（位置は保つ）。
  def self.mask_tags(text) = text.to_s.gsub(/<[^<>]*>/) { |tag| " " * tag.length }

  # 手動 TSV が先（優先）、スナップショットが後
  def paths
    (@local_paths + [@snapshot]).select { |path| File.file?(path) }
  end

  # 元ファイルに変化があれば読み直す。読み直したら true。
  # 作業中辞書のファイルが外から消された場合も読み直す。
  def refresh!
    signature = paths.map { |path| [path, File.mtime(path).to_f, File.size(path)] }
    session_removed = @session && @session_size.to_i.positive? && !File.file?(@session)
    return false if signature == @signature && !session_removed

    warn "dictionary: snapshot not found: #{@snapshot}" unless File.file?(@snapshot)
    build(signature.map(&:first))
    reset_session_if_snapshot_changed
    load_session
    @signature = signature
    true
  end

  # プロキシの訳を作業中辞書に追加する。既に辞書にある原文は無視。追加したら true。
  def remember(source, target)
    return false unless @session
    return false if source.strip.empty? || target.strip.empty? || source == target
    return false unless target.match?(/[\p{Hiragana}\p{Katakana}\p{Han}]/)
    return false if @memory.key?(source)

    add(source, target, false, session: true)
    File.open(@session, "a") { |f| f.puts JSON.dump(source: source, target: target) }
    @session_size += 1
    true
  end

  # 1 行（または 1 エントリ全体）の確定訳。無ければ nil。
  def lookup(text)
    text = text.to_s
    return nil if text.strip.empty?

    found = @memory[text] || @memory_ci[text.downcase] || @memory_ci[text.strip.downcase]
    return found if found

    if (m = text.match(/\ASpell Tome: (.+)\z/))
      spell = lookup(m[1])
      return "呪文の書: #{spell}" if spell
    end

    nil
  end

  # 原文中に出てくる用語を左から最長一致で拾う。
  # 1 語の用語は、原文側で大文字始まり かつ 訳がカタカナを含む（固有名詞の音訳）ときだけ採用する。
  # パーク名などのタイトルケース ("Stand Your Ground") で "Your = あなたの" を拾わないため。
  def match_terms(text, limit: 40)
    text = Dictionary.mask_tags(text).tr("’", "'")
    tokens = []
    text.scan(WORD_RE) { tokens << [Regexp.last_match[0], Regexp.last_match.begin(0)] }
    lowered = tokens.map { |word, _| word.downcase }

    found = {}
    i = 0
    while i < tokens.length
      hit = nil
      [@max_term_words, tokens.length - i].min.downto(1) do |n|
        entry = @terms[lowered[i, n].join(" ")]
        next unless entry
        next if n == 1 && !entry[:local] && !(tokens[i][0].match?(/\A[[:upper:]]/) && entry[:target].match?(/\p{Katakana}/))
        # 2 語目以降は大文字小文字まで一致したときだけ（"an Imperial sword" を "Imperial Sword" にしない）
        next if n > 1 && !entry[:local] && tokens[i + 1, n - 1].map(&:first) != entry[:words].drop(1)
        # 全部小文字の句 ("pick up") は一般的な言い回しなので用語にしない
        next if n > 1 && !entry[:local] && tokens[i, n].none? { |word, _| word.match?(/\A[[:upper:]]/) }

        hit = [entry, n]
        break
      end

      if hit
        found[Dictionary.term_key(hit[0][:source])] ||= hit[0]
        i += hit[1]
      else
        i += 1
      end
    end

    found.values.first(limit)
  end

  # 原文と珍しい単語を多く共有する既訳を返す。文体と固有名詞の訳し方を揃える用。
  # 作業中辞書の例文は session_limit 件まで優先して入れる（同じ mod の直前の訳が一番近いため）。
  # 並びは 公式訳 → 作業中辞書（原文に近い位置）。
  def similar_examples(text, limit: 3, session_limit: 2, min_score: 6.0, with_similarity: false)
    return [] if limit <= 0 || text.to_s.length > EXAMPLE_MAX_CHARS * 2

    query = Dictionary.words(Dictionary.mask_tags(text)).reject { |w| w.length < 3 || STOPWORDS.include?(w) }.uniq
    scores = Hash.new(0.0)
    query.each do |word|
      ids = @postings[word]
      next if ids.nil? || ids.length > EXAMPLE_MAX_DF

      idf = Math.log(@examples.length.to_f / ids.length)
      ids.each { |id| scores[id] += idf }
    end

    text_key = text.to_s.strip.downcase
    ranked = scores
             .map { |id, score| [id, score / Math.sqrt(@example_lengths[id])] }
             .select { |_, score| score >= min_score / Math.sqrt(query.length.clamp(1, 16)) }
             .sort_by { |id, score| [-score, id] }
             .map(&:first)
             .reject { |id| @examples[id][0].strip.downcase == text_key }

    session = ranked.select { |id| @session_ids.include?(id) }.first([session_limit, limit].min)
    official = (ranked - session).first(limit - session.length)
    (official + session).map do |id|
      example = @examples[id]
      with_similarity ? [*example, Dictionary.text_similarity(text, example[0])] : example
    end
  end

  # 原文の編集距離から近似率を出す。候補選択には使わず、参考訳の目安だけにする。
  def self.text_similarity(left, right)
    left = left.to_s.downcase.strip.chars
    right = right.to_s.downcase.strip.chars
    return 100 if left == right
    return 0 if left.empty? || right.empty?

    previous = (0..right.length).to_a
    left.each_with_index do |char, i|
      current = [i + 1]
      right.each_with_index do |other, j|
        current << [current[j] + 1, previous[j + 1] + 1, previous[j] + (char == other ? 0 : 1)].min
      end
      previous = current
    end
    ((1.0 - previous[-1].to_f / [left.length, right.length].max) * 100).round
  end

  private

  def build(paths)
    @memory = {}
    @memory_ci = {}
    @terms = {}
    @examples = []
    @example_lengths = []
    @postings = {}
    @session_ids = Set.new
    @session_size = 0
    @max_term_words = 1

    paths.each do |path|
      local = path != @snapshot
      each_pair(path) { |source, target| add(source, target, local) }
    rescue => e
      warn "dictionary: skip #{path}: #{e.message}"
    end

    @memory_size = @memory.size
    @term_size = @terms.size
    @example_size = @examples.size
  end

  # スナップショットの中身が前回と違えば作業中辞書を空にする。
  # 中身のハッシュを "<session>.snapshot" に覚えておく（再起動時の書き出し直しでは消さない）。
  def reset_session_if_snapshot_changed
    return unless @session && File.file?(@snapshot)

    digest_path = "#{@session}.snapshot"
    digest = Digest::SHA256.file(@snapshot).hexdigest
    previous = File.read(digest_path).strip if File.file?(digest_path)

    if previous && previous != digest && File.file?(@session)
      File.delete(@session)
      warn "dictionary: session cleared (snapshot changed)"
    end
    File.write(digest_path, digest) unless previous == digest
  end

  def load_session
    return unless @session && File.file?(@session)

    File.foreach(@session, chomp: true, encoding: "utf-8") do |line|
      row = JSON.parse(line)
      source = row["source"].to_s
      next if @memory.key?(source)

      add(source, row["target"].to_s, false, session: true)
      @session_size += 1
    rescue JSON::ParserError
      next
    end
  end

  def each_pair(path)
    if path == @snapshot
      File.foreach(path, chomp: true, encoding: "utf-8") do |line|
        row = JSON.parse(line)
        yield row["source"].to_s, row["target"].to_s
      end
      return
    end

    File.readlines(path, chomp: true, encoding: "bom|utf-8").each do |line|
      next if line.strip.empty? || line.start_with?("#")

      source, target = line.split("\t", 3)
      yield source.to_s, target.to_s
    end
  end

  def add(source, target, local, session: false)
    return if source.empty? || target.empty? || target == "-" || source == target

    first = !@memory.key?(source)
    @memory[source] ||= target
    @memory_ci[source.downcase] ||= target
    # 作業中辞書の 1 語の用語は使わない（"Dragonbone = ドラゴンボーン" のような誤訳を広めないため）
    add_term(source, target, local) if local || (term_like?(source) && !(session && !source.include?(" ")))
    add_example(source, target, session) if first && example_like?(source, target)
  end

  def add_term(source, target, local)
    key = Dictionary.term_key(source)
    return if key.empty? || key.count(" ") >= TERM_MAX_WORDS

    words = source.tr("’", "'").scan(WORD_RE)
    @terms[key] ||= { source: source, target: target, local: local, words: words }
    @max_term_words = [@max_term_words, words.length].max
  end

  def add_example(source, target, session)
    id = @examples.length
    words = Dictionary.words(source).reject { |w| w.length < 3 || STOPWORDS.include?(w) }.uniq
    return if words.length < 3

    @examples << [source, target]
    @example_lengths << words.length
    @session_ids << id if session
    words.each { |word| (@postings[word] ||= []) << id }
  end

  # 旧 xtranslator_sst_glossary.rb の usable_entry? と同じ基準に加え、
  # "(Laughing.)" や "No. " のような記号・空白付きのセリフ断片を除く。
  def term_like?(source)
    return false if source.length < TERM_MIN_CHARS || source.length > TERM_MAX_CHARS
    return false if source != source.strip
    return false if source.match?(/[\r\n<>()\[\]!?.;"“”…*]/)
    return false if source.count(" ") > 6
    return false if source.match?(/[.!?。！？]\z/)
    return false if source == source.downcase

    true
  end

  def example_like?(source, target)
    return false if source.length < EXAMPLE_MIN_CHARS || source.length > EXAMPLE_MAX_CHARS
    return false if target.length > EXAMPLE_MAX_CHARS
    return false unless target.match?(/[\p{Hiragana}\p{Katakana}\p{Han}]/)

    source.include?(" ")
  end
end
