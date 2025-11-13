#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require_relative '../lib/dsr_helpers'
require_relative '../lib/vault_guard'

options = {
  email: nil,
  manifest: 'data/manifest.json',
  vault_dir: 'vault/',
  seed: 42,
  threads: nil,
  reverse: true
}

OptionParser.new do |opts|
  opts.banner = 'Usage: bin/dsr_export --email user@example.com [options]'

  opts.on('--email EMAIL', 'Email to export') { |v| options[:email] = v }
  opts.on('--threads ID1,ID2', 'Export specific thread IDs (comma-separated)') { |v| options[:threads] = v.split(',') }
  opts.on('--manifest PATH', 'Manifest path') { |v| options[:manifest] = v }
  opts.on('--vault-dir DIR', 'Vault directory') { |v| options[:vault_dir] = v }
  opts.on('--seed SEED', Integer, 'Vault seed') { |v| options[:seed] = v }
  opts.on('--[no-]reverse', 'Reverse pseudonyms (default: true)') { |v| options[:reverse] = v }
end.parse!

# Enforce git-crypt before any vault access
if options[:reverse]
  VaultGuard.ensure_unlocked!(vault_dir: options[:vault_dir])
end

thread_ids = if options[:threads]
               options[:threads]
             elsif options[:email]
               DSRHelpers.locate_email(
                 options[:email],
                 manifest_path: options[:manifest],
                 vault_dir: options[:vault_dir],
                 seed: options[:seed]
               )
             else
               abort 'Specify --email or --threads'
             end

if thread_ids.empty?
  puts 'No threads found for given email.'
  exit 0
end

puts "Exporting #{thread_ids.size} thread(s):"
thread_ids.each do |tid|
  export = DSRHelpers.export_thread(
    tid,
    manifest_path: options[:manifest],
    vault_dir: options[:vault_dir],
    seed: options[:seed],
    reverse: options[:reverse]
  )
  next unless export

  puts "\n=== Thread: #{tid} ==="
  puts export[:content]
  puts "(Reversed: #{export[:reversed]})"
end
