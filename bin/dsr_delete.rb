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
  dry_run: false,
  reason: 'GDPR Art. 17 - Right to erasure'
}

OptionParser.new do |opts|
  opts.banner = 'Usage: bin/dsr_delete --email user@example.com [options]'

  opts.on('--email EMAIL', 'Email to delete') { |v| options[:email] = v }
  opts.on('--threads ID1,ID2', 'Delete specific thread IDs') { |v| options[:threads] = v.split(',') }
  opts.on('--manifest PATH', 'Manifest path') { |v| options[:manifest] = v }
  opts.on('--vault-dir DIR', 'Vault directory') { |v| options[:vault_dir] = v }
  opts.on('--seed SEED', Integer, 'Vault seed') { |v| options[:seed] = v }
  opts.on('--dry-run', 'Preview without writing tombstones') { options[:dry_run] = true }
  opts.on('--reason REASON', 'Deletion reason') { |v| options[:reason] = v }
end.parse!

# Enforce git-crypt before vault lookup
VaultGuard.ensure_unlocked!(vault_dir: options[:vault_dir])

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

puts "#{options[:dry_run] ? '[DRY RUN]' : '[LIVE]'} Deleting #{thread_ids.size} thread(s):"
thread_ids.each do |tid|
  if options[:dry_run]
    puts "  Would tombstone: #{tid}"
  else
    path = DSRHelpers.tombstone_thread(
      tid,
      manifest_path: options[:manifest],
      reason: options[:reason]
    )
    puts "  Tombstoned: #{tid} → #{path}"
  end
end

puts "\nNext steps:" unless options[:dry_run]
puts '  1. Retrain with --respect-tombstones=true'
puts '  2. git add data/tombstones/ && git commit'
