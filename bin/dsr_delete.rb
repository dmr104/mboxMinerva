#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'optparse'
require 'fileutils'
require_relative '../lib/dsr_helpers'

options = {
  subject: nil,
  manifest: 'manifest.jsonl',
  tombstone_path: 'vault/dsr_tombstones.jsonl',
  dry_run: false,
  threads: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: dsr_delete --subject EMAIL_OR_PSEUDONYM [options]"
  opts.on('-s', '--subject SUBJECT', 'Real email or pseudonym to delete') { |v| options[:subject] = v }
  opts.on('-m', '--manifest PATH', 'Path to manifest.jsonl (default: manifest.jsonl)') { |v| options[:manifest] = v }
  opts.on('-t', '--tombstone PATH', 'Tombstone file (default: vault/dsr_tombstones.jsonl)') { |v| options[:tombstone_path] = v }
  opts.on('-d', '--dry-run', 'Preview deletions without committing') { options[:dry_run] = true }
  opts.on('--threads', 'Delete entire threads containing subject') { options[:threads] = true }
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

# Load vault and existing tombstones
vault = DSRHelpers.load_vault
existing_tombstones = DSRHelpers.load_tombstones(options[:tombstone_path])

# Scan manifest
to_delete = []
thread_ids = Set.new

File.foreach(options[:manifest]) do |line|
  record = JSON.parse(line.strip)
  next if existing_tombstones.include?(record['message_id']) # already tombstoned

  if DSRHelpers.record_matches?(record, options[:subject], vault)
    to_delete << record
    thread_ids << record['thread_id'] if options[:threads]
  end
end

# Expand to full threads if requested
if options[:threads]
  thread_ids.each do |tid|
    members = DSRHelpers.collect_thread_members(options[:manifest], tid)
    to_delete.concat(members.reject { |r| to_delete.any? { |dr| dr['message_id'] == r['message_id'] } || existing_tombstones.include?(r['message_id']) })
  end
end

to_delete.uniq! { |r| r['message_id'] }

if to_delete.empty?
  puts "✓ No new records to delete for #{options[:subject]}"
  exit 0
end

puts "#{options[:dry_run] ? '[DRY RUN]' : ''} Found #{to_delete.size} record(s) to delete:"
to_delete.each { |r| puts "  - #{r['message_id']} (#{r['from']})" }

if options[:dry_run]
  puts "\nRe-run without --dry-run to commit deletions."
  exit 0
end

# Write tombstones
new_tombstones = to_delete.map do |r|
  {
    message_id: r['message_id'],
    subject: options[:subject],
    deleted_at: Time.now.utc.iso8601,
    reason: 'DSR deletion request'
  }
end

DSRHelpers.append_tombstones(new_tombstones, options[:tombstone_path])

puts "✓ Tombstoned #{new_tombstones.size} record(s) to #{options[:tombstone_path]}"
puts "  Update your dataloader to filter these message_ids at training time."