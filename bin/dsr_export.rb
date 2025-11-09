#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'fileutils'
require_relative '../lib/dsr_helpers'

options = {
  subject: nil,
  manifest: 'manifest.jsonl',
  output: 'dsr_export',
  threads: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: dsr_export --subject EMAIL_OR_PSEUDONYM [options]"
  opts.on('-s', '--subject SUBJECT', 'Real email or pseudonym to search') { |v| options[:subject] = v }
  opts.on('-m', '--manifest PATH', 'Path to manifest.jsonl (default: manifest.jsonl)') { |v| options[:manifest] = v }
  opts.on('-o', '--output DIR', 'Output directory (default: dsr_export)') { |v| options[:output] = v }
  opts.on('-t', '--threads', 'Export entire threads containing subject') { options[:threads] = true }
  opts.on('-h', '--help', 'Show this help') { puts opts; exit }
end.parse!

unless options[:subject]
  warn "Error: --subject is required"
  exit 1
end

unless File.exist?(options[:manifest])
  warn "Error: manifest not found at #{options[:manifest]}"
  exit 1
end

# Load vault and tombstones
vault = DSRHelpers.load_vault
tombstones = DSRHelpers.load_tombstones

# Scan manifest
matching_records = []
thread_ids = Set.new

File.foreach(options[:manifest]) do |line|
  record = JSON.parse(line.strip)
  next if tombstones.include?(record['message_id']) # skip deleted

  if DSRHelpers.record_matches?(record, options[:subject], vault)
    matching_records << record
    thread_ids << record['thread_id'] if options[:threads]
  end
end

# Expand to full threads if requested
if options[:threads]
  thread_ids.each do |tid|
    members = DSRHelpers.collect_thread_members(options[:manifest], tid)
    matching_records.concat(members.reject { |r| matching_records.any? { |mr| mr['message_id'] == r['message_id'] } })
  end
end

# Write output
FileUtils.mkdir_p(options[:output])
out_file = File.join(options[:output], "#{options[:subject].gsub(/[^a-z0-9_-]/i, '_')}.jsonl")
summary_file = File.join(options[:output], "summary.txt")

File.open(out_file, 'w') do |f|
  matching_records.uniq { |r| r['message_id'] }.each { |r| f.puts(r.to_json) }
end

File.open(summary_file, 'w') do |f|
  f.puts "DSR Export Report"
  f.puts "=================="
  f.puts "Subject: #{options[:subject]}"
  f.puts "Manifest: #{options[:manifest]}"
  f.puts "Export time: #{Time.now.utc.iso8601}"
  f.puts "Records found: #{matching_records.size}"
  f.puts "Threads: #{thread_ids.size}" if options[:threads]
  f.puts "Output: #{out_file}"
end

puts "✓ Exported #{matching_records.size} record(s) to #{out_file}"
puts "  Summary: #{summary_file}"