#!/usr/bin/env ruby
# frozen_string_literal: true

# CLI entrypoint for PIIScrubber using pipelines.
#
# Usage:
#   bin/pii_scrubber < input.txt > scrubbed.txt
#   bin/pii_scrubber file1.txt file2.txt > scrubbed.txt
#   bin/pii_scrubber --vault-dir vault/ --seed 42 < input.txt
#
# Loads lib/pii_scrubber.rb and streams scrubbed text to stdout.
# Saves vault after processing completes.
#
# CLI wrapper for lib/pii_scrubber.rb with shard batch processing support.
#
# Modes:
#   1. Batch mode (--input-dir + --output-dir):
#        bin/pii_scrubber --vault-dir vault --seed 42 --input-dir emails/ --output-dir emails_scrubbed/
#      Finds all *.jsonl shards in input-dir, scrubs each through one shared vault,
#      writes to output-dir with same filename.
#
#   2. Single-file/stdin mode:
#        bin/pii_scrubber --vault-dir vault --seed 42 < input.txt > scrubbed.txt
#        bin/pii_scrubber --vault-dir vault --seed 42 file1.txt file2.txt > out.txt
#      Legacy mode for pipelines.
#
# Pseudonyms stay consistent across all shards when the same --vault-dir and --seed are used.

require 'optparse'
require 'fileutils'

# Load the library
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'pii_scrubber'

options = {
  vault_dir: nil,
  seed: 'mboxminerva-default-seed',
  input_dir: nil,
  output_dir: nil
}

parser = OptionParser.new do |opts|
  opts.banner = <<~BANNER
    Usage: pii_scrubber [options] [files...]
    
    Scrub PII (emails, IPs) from text using deterministic pseudonymization.
    
    Batch mode (shards):
      pii_scrubber --vault-dir vault --seed 42 --input-dir emails/ --output-dir emails_scrubbed/
    
    Single-file/stdin mode:
      cat input.txt | pii_scrubber --vault-dir vault --seed 42 > output.txt
      pii_scrubber --vault-dir vault --seed 42 file1.txt file2.txt > output.txt
  BANNER

  opts.on('--vault-dir PATH', 'Vault directory for encrypted pseudonym storage (required)') do |v|
    options[:vault_dir] = v
  end

  opts.on('--seed SEED', 'Deterministic seed for pseudonym generation (default: mboxminerva-default-seed)') do |s|
    options[:seed] = s
  end

  opts.on('--input-dir DIR', 'Input directory containing *.jsonl shards (batch mode)') do |d|
    options[:input_dir] = d
  end

  opts.on('--output-dir DIR', 'Output directory for scrubbed shards (batch mode)') do |d|
    options[:output_dir] = d
  end

  opts.on('-h', '--help', 'Show this help') do
    puts opts
    exit 0
  end
end

parser.parse!

# Validate required flags
unless options[:vault_dir]
  warn 'ERROR: --vault-dir is required'
  puts parser
  exit 1
end

# Initialize scrubber (one instance, shared vault across all files)
scrubber = PIIScrubber.new(vault_dir: options[:vault_dir], seed: options[:seed])

# Batch mode: process all shards in input-dir
if options[:input_dir] && options[:output_dir]
  unless Dir.exist?(options[:input_dir])
    warn "ERROR: Input directory does not exist: #{options[:input_dir]}"
    exit 1
  end

  FileUtils.mkdir_p(options[:output_dir])

  # Find all *.jsonl shards
  shards = Dir.glob(File.join(options[:input_dir], '*.jsonl')).sort

  if shards.empty?
    warn "WARNING: No *.jsonl shards found in #{options[:input_dir]}"
    exit 0
  end

  warn "Processing #{shards.size} shard(s) from #{options[:input_dir]} -> #{options[:output_dir]}"

  shards.each do |shard_path|
    basename = File.basename(shard_path)
    output_path = File.join(options[:output_dir], basename)

    warn "  #{basename} ..."

    File.open(shard_path, 'r') do |infile|
      File.open(output_path, 'w') do |outfile|
        infile.each_line do |line|
          scrubbed = scrubber.scrub_email(line)
          outfile.puts(scrubbed)
        end
      end
    end
  end

  # Save vault once after all shards
  scrubber.save_vault
  warn "Done. Vault saved to #{options[:vault_dir]}"

# Single-file/stdin mode
else
  if ARGV.empty?
    # stdin -> stdout
    STDIN.each_line do |line|
      puts scrubber.scrub_email(line)
    end
  else
    # file args -> stdout
    ARGV.each do |file|
      File.open(file, 'r') do |f|
        f.each_line do |line|
          puts scrubber.scrub_email(line)
        end
      end
    end
  end

  scrubber.save_vault
  warn "Vault saved to #{options[:vault_dir]}" if STDERR.tty?
end
