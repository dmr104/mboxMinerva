#!/usr/bin/env ruby
#
# PII Scrubber CLI
# =================
#
# A production-ready CLI for deterministic PII pseudonymization (Emails/IPs)
# using GPG-encrypted vault storage. It processes JSONL files from an input
# directory and writes sanitized versions to an output directory.
#
# Usage:
#   bin/pii_scrubber.rb --input-dir data/in --output-dir data/out --vault-dir secrets/vault --salt "mysecret" --passphrase "changeit"
#
# Options:
#   -i, --input-dir DIR      Directory containing raw .jsonl files to scrub (Required)
#   -o, --output-dir DIR     Directory where scrubbed .jsonl files will be written (Required)
#   -v, --vault-dir DIR      Directory storing GPG-encrypted mapping files (default: ./crypt)
#   -s, --salt STRING        Deterministic salt for pseudonymization (env: PII_SALT)
#   -p, --passphrase STRING  GPG passphrase for symmetric encryption (default mode) (env: GPG_PASSPHRASE)
#   -r, --recipient EMAIL    GPG recipient email for asymmetric encryption (overrides passphrase)
#   -h, --help               Show this help message
#
# Environment Variables:
#   PII_SALT                 Alternative to --salt
#   GPG_PASSPHRASE           Alternative to --passphrase
#   GPG_RECIPIENT            Alternative to --recipient
#
# Examples:
#   1. Symmetric (Shared Secret) - Good for CI/CD default:
#      bin/pii_scrubber.rb -i ./raw -o ./clean -s "salty" -p "gpg-secret"
#
#   2. Asymmetric (Public Key) - Good for writing to a vault only readable by admins:
#      bin/pii_scrubber.rb -i ./raw -o ./clean -s "salty" -r "admin@example.com"
#

require 'optparse'
require 'fileutils'
require 'json'
require_relative '../lib/pii_scrubber'

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: bin/pii_scrubber.rb [options]"

  opts.on("-i", "--input-dir DIR", "Input directory containing .jsonl files") do |d|
    options[:input_dir] = d
  end

  opts.on("-o", "--output-dir DIR", "Output directory for scrubbed files") do |d|
    options[:output_dir] = d
  end

  opts.on("-v", "--vault-dir DIR", "Directory for encrypted vault maps") do |d|
    options[:vault_dir] = d
  end

  opts.on("-s", "--salt STRING", "Deterministic salt string") do |s|
    options[:seed] = s
  end

  opts.on("-p", "--passphrase STRING", "GPG passphrase (symmetric)") do |p|
    options[:gpg_passphrase] = p
  end

  opts.on("-r", "--recipient EMAIL", "GPG recipient (asymmetric)") do |r|
    options[:gpg_recipient] = r
  end
end.parse!

# --- Validation ---

input_dir = options[:input_dir] || ENV['INPUT_DIR']
output_dir = options[:output_dir] || ENV['OUTPUT_DIR']
vault_dir = options[:vault_dir] || ENV['VAULT_DIR'] || './crypt'
seed = options[:seed] || ENV['PII_SALT']
passphrase = options[:gpg_passphrase] || ENV['GPG_PASSPHRASE']
recipient = options[:gpg_recipient] || ENV['GPG_RECIPIENT']

errors = []
errors << "Missing required argument: --input-dir" unless input_dir
errors << "Missing required argument: --output-dir" unless output_dir
errors << "Missing salt: provide --salt or PII_SALT env var" unless seed
errors << "Missing GPG auth: provide --passphrase or --recipient" unless passphrase || recipient

if errors.any?
  puts "Error(s):"
  errors.each { |e| puts "  - #{e}" }
  puts ""
  puts "Use --help for usage information."
  exit 1
end

unless Dir.exist?(input_dir)
  puts "Error: Input directory '#{input_dir}' does not exist."
  exit 1
end

# --- Initialization ---

begin
  scrubber = PIIScrubber.new(
    vault_dir: vault_dir,
    seed: seed,
    gpg_passphrase: passphrase,
    gpg_recipient: recipient
  )
rescue StandardError => e
  puts "Failed to initialize PII Scrubber: #{e.message}"
  exit 1
end

FileUtils.mkdir_p(output_dir)

puts "=== PII Scrubber CLI ==="
puts "Input Dir:  #{input_dir}"
puts "Output Dir: #{output_dir}"
puts "Vault Dir:  #{vault_dir}"
puts "Encryption: #{recipient ? "Asymmetric (PubKey)" : "Symmetric (Passphrase)"}"
puts "========================"

# --- Execution ---

files = Dir.glob(File.join(input_dir, '*.jsonl')).sort

if files.empty?
  puts "No *.jsonl files found in input directory."
  exit 0
end

files.each do |input_path|
  filename = File.basename(input_path)
  output_path = File.join(output_dir, filename)
  
  puts "Processing: #{filename}"
  
  # Process line-by-line to handle large files memory-efficiently
  File.open(output_path, 'w') do |out_f|
    File.foreach(input_path).with_index do |line, idx|
      next if line.strip.empty?
      
      begin
        json_row = JSON.parse(line)
        
        # Scrub the JSON object
        # NOTE: Assumes scrubber.scrub() recursively handles Hash/Array traversal.
        # If the library only handles strings, you must implement traversal here.
        scrubbed_row = scrubber.scrub(json_row)
        
        out_f.puts scrubbed_row.to_json
      rescue JSON::ParserError
        STDERR.puts "  [WARN] Skipping invalid JSON at line #{idx + 1} of #{filename}"
      rescue StandardError => e
        STDERR.puts "  [ERR] Failed to scrub line #{idx + 1} of #{filename}: #{e.message}"
      end
    end
  end
end

puts "Done. Scrubbed files are in #{output_dir}"