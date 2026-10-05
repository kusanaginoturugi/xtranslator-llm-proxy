#!/usr/bin/env ruby
# frozen_string_literal: true

# xTranslator の UserDictionaries/*.sst を書き出す。
#   --format jsonl: プロキシ用の辞書スナップショット（全件、優先順、同じ原文は先勝ち）
#   --format tsv:   用語っぽい短いエントリだけの TSV（確認・他ツール用）

require "fileutils"
require "json"
require "optparse"
require_relative "lib/sst"

options = {
  game: "SkyrimSE",
  source: "english",
  dest: "japanese",
  root: File.expand_path("~/.local/bin/_xTranslator"),
  format: "tsv",
  output: nil,
  max_chars: 80,
  min_chars: 4,
  all: false
}

DEFAULT_OUTPUT = {
  "tsv" => "/tmp/xtranslator-glossary.tsv",
  "jsonl" => File.expand_path("~/.local/share/xtranslator-llm-proxy/dictionary.jsonl")
}.freeze

OptionParser.new do |o|
  o.banner = "Usage: #{$PROGRAM_NAME} [options]"
  o.on("--root PATH", "xTranslator directory") { |v| options[:root] = v }
  o.on("--game NAME", "Game folder, default: SkyrimSE") { |v| options[:game] = v }
  o.on("--source LANG", "Source language, default: english") { |v| options[:source] = v }
  o.on("--dest LANG", "Destination language, default: japanese") { |v| options[:dest] = v }
  o.on("--format FORMAT", DEFAULT_OUTPUT.keys, "tsv (default) or jsonl") { |v| options[:format] = v }
  o.on("-o", "--output PATH", "Output path, default: #{DEFAULT_OUTPUT.map { |k, v| "#{k}: #{v}" }.join(', ')}") { |v| options[:output] = v }
  o.on("--max-chars N", Integer, "tsv: max source length, default: 80") { |v| options[:max_chars] = v }
  o.on("--min-chars N", Integer, "tsv: min source length, default: 4") { |v| options[:min_chars] = v }
  o.on("--all", "tsv: include sentence-like entries too") { options[:all] = true }
end.parse!

options[:output] ||= DEFAULT_OUTPUT.fetch(options[:format])

def valid_pair?(source, target)
  !source.empty? && !target.empty? && source != target && target != "-"
end

def usable_entry?(source, target, options)
  return false unless valid_pair?(source, target)
  return false if source.length < options[:min_chars] || source.length > options[:max_chars]
  return true if options[:all]

  return false if source.match?(/[\r\n]/)
  return false if source.count(" ") > 6
  return false if source.match?(/[.!?。！？]$/)
  return false if source == source.downcase

  true
end

# 途中で読まれても壊れたファイルが見えないよう、同じディレクトリに書いてから rename する
def write_atomically(path)
  FileUtils.mkdir_p(File.dirname(path))
  tmp = "#{path}.tmp#{Process.pid}"
  File.open(tmp, "w:utf-8") { |file| yield file }
  File.rename(tmp, path)
ensure
  File.unlink(tmp) if tmp && File.exist?(tmp)
end

files = SST.files(root: options[:root], game: options[:game], source: options[:source], dest: options[:dest])
abort "no SST files under #{File.join(options[:root], 'UserDictionaries', options[:game])}" if files.empty?

seen = {}
rows = []

files.each do |path|
  name = File.basename(path)
  SST.each_pair(path) do |source, target|
    if options[:format] == "jsonl"
      next unless valid_pair?(source, target)
      next if seen.key?(source)

      seen[source] = true
    else
      next unless usable_entry?(source, target, options)
      next if seen.key?(source.downcase)

      seen[source.downcase] = true
    end
    rows << [source, target, name]
  end
rescue => e
  warn "skip #{path}: #{e.message}"
end

write_atomically(options[:output]) do |file|
  if options[:format] == "jsonl"
    rows.each { |source, target, name| file.puts JSON.dump(source: source, target: target, file: name) }
  else
    rows.sort_by { |source, _target, _name| [source.downcase.length, source.downcase] }.each do |source, target, _name|
      file.puts [source, target].join("\t")
    end
  end
end

warn "wrote #{rows.length} entries from #{files.length} SST files to #{options[:output]}"
