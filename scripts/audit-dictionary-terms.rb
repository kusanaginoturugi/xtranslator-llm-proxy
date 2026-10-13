#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

WORD_RE = /[[:alnum:]]+(?:['’][[:alnum:]]+)*/
MAX_TERM_WORDS = 6

options = {
  dictionary: File.expand_path("~/.local/share/xtranslator-llm-proxy/dictionary.jsonl"),
  glossary: File.expand_path("../xtranslator-glossary.local.tsv", __dir__),
  max_source_chars: 300,
  min_source_words: 7,
  min_occurrences: 3,
  limit: 50,
  term: nil,
  translation: nil
}

OptionParser.new do |parser|
  parser.banner = "Usage: #{$PROGRAM_NAME} [--term ENGLISH] [--translation JAPANESE] [options]"
  parser.on("--dictionary PATH", "JSONL dictionary") { |value| options[:dictionary] = File.expand_path(value) }
  parser.on("--glossary PATH", "manual TSV (default: repository glossary)") { |value| options[:glossary] = File.expand_path(value) }
  parser.on("--term ENGLISH", "inspect one English term") { |value| options[:term] = value }
  parser.on("--translation JAPANESE", "expected translation for --term") { |value| options[:translation] = value }
  parser.on("--max-source-chars N", Integer, "maximum sentence length (default: 300)") { |value| options[:max_source_chars] = value }
  parser.on("--min-source-words N", Integer, "minimum source words in automatic report (default: 7)") { |value| options[:min_source_words] = value }
  parser.on("--min-occurrences N", Integer, "minimum containing sentences (default: 3)") { |value| options[:min_occurrences] = value }
  parser.on("--limit N", Integer, "maximum reported terms or examples (default: 50)") { |value| options[:limit] = value }
end.parse!
abort "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
abort "--translation requires --term" if options[:translation] && !options[:term]
abort "limits must be positive" unless options.values_at(:max_source_chars, :min_source_words, :min_occurrences, :limit).all?(&:positive?)
abort "dictionary not found: #{options[:dictionary]}" unless File.file?(options[:dictionary])

def words(text) = text.to_s.tr("’", "'").scan(WORD_RE).map(&:downcase)
def term_key(text) = words(text).join(" ")
def one_line(text, max = 160) = text.to_s.gsub(/\s+/, " ")[0, max]

def candidate?(source, target)
  return false if source.empty? || target.empty? || source.length > 80 || target.length > 60
  return false unless target.match?(/[\p{Hiragana}\p{Katakana}\p{Han}]/)
  return false unless source.match?(/\A[[:alnum:]][[:alnum:]'’ -]*\z/)

  tokens = source.scan(WORD_RE)
  return false unless (2..MAX_TERM_WORDS).cover?(tokens.length)

  capitals = tokens.count { |word| word.match?(/\A[[:upper:]]/) }
  capitals >= 2
end

def each_row(path)
  File.foreach(path, chomp: true, encoding: "UTF-8") do |line|
    row = JSON.parse(line)
    source = row["source"].to_s
    target = row["target"].to_s
    yield source, target, row["file"].to_s unless source.empty? || target.empty?
  end
end

terms = {}
each_row(options[:dictionary]) do |source, target, file|
  next unless candidate?(source, target)

  terms[term_key(source)] ||= { source: source, target: target, file: file }
end

if File.file?(options[:glossary])
  File.foreach(options[:glossary], chomp: true, encoding: "UTF-8") do |line|
    next if line.empty? || line.start_with?("#")

    source, target = line.split("\t", 3)
    next unless source && target && candidate?(source, target)

    terms[term_key(source)] = { source: source, target: target, file: File.basename(options[:glossary]) }
  end
end

if options[:term]
  key = term_key(options[:term])
  abort "term has no words" if key.empty?
  if options[:translation]
    terms = { key => { source: options[:term], target: options[:translation], file: "--translation" } }
  else
    abort "term not found; pass --translation: #{options[:term]}" unless terms.key?(key)
    terms = { key => terms.fetch(key) }
  end
end

results = Hash.new { |hash, key| hash[key] = { matching: 0, missing: 0, examples: [] } }
each_row(options[:dictionary]) do |source, target, file|
  next if source.length > options[:max_source_chars]

  tokens = words(source)
  next if !options[:term] && tokens.length < options[:min_source_words]
  seen = {}
  tokens.each_index do |i|
    [MAX_TERM_WORDS, tokens.length - i].min.downto(1) do |length|
      key = tokens[i, length].join(" ")
      term = terms[key]
      next unless term && !seen[key] && term[:source].casecmp(source) != 0
      next unless source.match?(/(?<![[:alnum:]])#{Regexp.escape(term[:source])}(?![[:alnum:]])/)

      seen[key] = true
      result = results[key]
      if target.include?(term[:target])
        result[:matching] += 1
      else
        result[:missing] += 1
        result[:examples] << [source, target, file] if result[:examples].length < options[:limit]
      end
    end
  end
end

if options[:term]
  key = terms.keys.first
  term = terms.fetch(key)
  result = results[key]
  puts "#{term[:source]} = #{term[:target]} (#{term[:file]})"
  puts "訳語あり #{result[:matching]} 件 / 訳語なし #{result[:missing]} 件。訳語なしは要確認:"
  result[:examples].each do |source, target, file|
    puts "- [#{file}] #{one_line(source)}"
    puts "  #{one_line(target)}"
  end
else
  puts "訳語なし\t訳語あり\t英語用語\t基準訳\t原文例\t訳文例\t出典"
  ranked = results.filter_map do |key, result|
    next if result[:missing].zero? || result[:matching].zero?
    next if result[:matching] + result[:missing] < options[:min_occurrences]

    [key, result]
  end.sort_by { |key, result| [-result[:missing], -result[:matching], key] }
  ranked.first(options[:limit]).each do |key, result|
    term = terms.fetch(key)
    source, target, file = result[:examples].first
    puts [result[:missing], result[:matching], term[:source], term[:target],
          one_line(source, 100), one_line(target, 100), file].join("\t")
  end
end
