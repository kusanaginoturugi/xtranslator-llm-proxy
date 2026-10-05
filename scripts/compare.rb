#!/usr/bin/env ruby
# bench.sh の BENCH_OUT で保存した JSONL を、原文ごとに並べた Markdown にする。
# usage: scripts/compare.rb A.jsonl B.jsonl ... > comparison.md
require "json"

runs = ARGV.map { |path| File.readlines(path).map { |line| JSON.parse(line) } }
abort "usage: #{$0} A.jsonl B.jsonl ..." if runs.empty?

runs.first.each_index do |i|
  puts "## #{i + 1}", "", "> #{runs.first[i]["source"]}", ""
  runs.each { |run| puts "- `#{run[i]["label"]}`: #{run[i]["translation"].to_s.gsub("\n", " / ")}" }
  puts
end
