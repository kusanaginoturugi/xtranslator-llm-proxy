#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/sst"

options = {
  root: File.expand_path("~/.local/bin/_xTranslator"),
  game: "SkyrimSE",
  source: "english",
  dest: "japanese",
  limit: 50,
  term: nil,
  all: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: #{$PROGRAM_NAME} [--term ENGLISH] [options]"
  parser.on("--root PATH", "xTranslator directory") { |value| options[:root] = File.expand_path(value) }
  parser.on("--game NAME", "game folder (default: SkyrimSE)") { |value| options[:game] = value }
  parser.on("--source LANG", "source language (default: english)") { |value| options[:source] = value }
  parser.on("--dest LANG", "destination language (default: japanese)") { |value| options[:dest] = value }
  parser.on("--term ENGLISH", "inspect one exact source") { |value| options[:term] = value }
  parser.on("--all", "include sentences and generic text") { options[:all] = true }
  parser.on("--limit N", Integer, "maximum source groups (default: 50)") { |value| options[:limit] = value }
end.parse!
abort "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
abort "--limit must be positive" unless options[:limit].positive?

files = SST.files(**options.slice(:root, :game, :source, :dest))
abort "no active SST files" if files.empty?

entries = Hash.new { |hash, key| hash[key] = {} }
files.each do |path|
  name = File.basename(path)
  SST.each_pair(path) do |source, target|
    source = source.strip
    target = target.strip
    next if source.empty? || target.empty?
    next if options[:term] && source != options[:term]

    (entries[source][target] ||= []) << name
  end
end

if options[:term]
  variants = entries[options[:term]]
  abort "source not found: #{options[:term]}" if variants.empty?
  puts "#{options[:term]}: #{variants.length} 訳"
  variants.each do |target, names|
    puts "- #{target} [#{names.uniq.join(', ')}]"
  end
else
  puts "訳数\t原文\t訳文とSST（優先順）"
  entries.select do |source, variants|
    next false if variants.length < 2
    next true if options[:all]

    words = source.scan(/[[:alnum:]]+(?:['’][[:alnum:]]+)*/)
    (2..6).cover?(words.length) && source.match?(/\A[[:alnum:]][[:alnum:]'’ -]*\z/) &&
      words.count { |word| word.match?(/\A[[:upper:]]/) } >= 2
  end
    .sort_by { |source, variants| [-variants.length, source] }
    .first(options[:limit]).each do |source, variants|
      details = variants.map { |target, names| "#{target} [#{names.uniq.join(', ')}]" }.join(" / ")
      puts [variants.length, source.gsub(/\s+/, " "), details.gsub(/\s+/, " ")].join("\t")
    end
end
