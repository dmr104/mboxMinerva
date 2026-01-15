#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# mbox_pre-parser.rb - Parse mbox archives into JSONL for ML training pipelines
# =============================================================================
#
# SYNOPSIS
#   ruby mbox_pre-parser.rb input.mbox [OPTIONS]
#
# DESCRIPTION
#   Parses a standard Unix mbox file and emits structured JSONL records suitable
#   for downstream splitting (splitter.rb) and LoRA fine-tuning. Each email is
#   assigned a collision-proof internal_id (SHA256 of Message-ID + body hash),
#   threaded via References/In-Reply-To headers, and tagged with a cohort_id.
#
#   The script applies several quality filters:
#     - Drops emails exceeding 16,000 characters (avoids LoRA truncation at 8k tokens)
#     - Drops emails containing binary data or Base64-encoded attachments
#     - Strips quoted reply blocks ("> " prefixed lines, "On ... wrote:" headers)
#     - Deduplicates by internal_id (exact content match)
#     - Logs Message-ID collisions (same ID, different content) for human triage
#
# OUTPUT FORMAT
#   Default: Sharded JSONL files in emails/part-NNNNN.jsonl
#   With --output FILE: Single JSON array file
#
#   Each record contains:
#     {
#       "internal_id":          "sha256-hex",      # Primary key (collision-proof)
#       "original_message_id":  "<abc@example>",   # Raw Message-ID for threading lookups
#       "thread_id":            "<root@example>",  # Thread root ID or synthetic hash
#       "cohort_id":            "2025-01",         # YYYY-MM cohort stamp
#       "email_message":        "cleaned body..."  # Processed email body (quotes stripped)
#     }
#
# OPTIONS
#   -o, --output FILE        Write single JSON file instead of sharded JSONL
#   --output-dir DIR         Output directory for shards (default: emails/)
#   --cohort YYYY-MM         Override cohort_id for all messages
#   --shard-size N           Messages per shard file (default: 1000)
#   --triage-file PATH       Path for Message-ID collision log (default: collisions.log)
#   -f, --force              Overwrite existing JSON/JSONL files in output directory
#   -y, --yes                Skip confirmation prompts for destructive operations
#   -h, --help               Show this help message
#
# EXAMPLES
#   # Basic usage with default sharding
#   ruby mbox_pre-parser.rb archive.mbox --output-dir emails/
#
#   # Single file output with explicit cohort
#   ruby mbox_pre-parser.rb archive.mbox --output emails.json --cohort 2025-01
#
#   # Force overwrite with custom triage log
#   ruby mbox_pre-parser.rb archive.mbox --output-dir emails/ --force --yes \
#        --triage-file /var/log/mbox_collisions.log
#
# =============================================================================

require 'json'
require 'digest/sha256'
require 'mail'
require 'optparse'
require 'date'
require 'charlock_holmes'
require 'fileutils'

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Character limit for LoRA training compatibility (~4k tokens at 4 chars/token)
# Sized for 8k context LoRA adapters to avoid truncation
MAX_CHAR_LIMIT = 16_000

# Patterns indicating binary or encoded binary content
BINARY_INDICATORS = [
  /^Content-Transfer-Encoding:\s*base64/im,
  /^Content-Type:\s*application\//im,
  /^Content-Type:\s*image\//im,
  /^Content-Type:\s*audio\//im,
  /^Content-Type:\s*video\//im,
  /\x00/,  # Null bytes
  /^begin [0-7]{3} /m,  # uuencoded content
].freeze

# Pattern for "On <date> <person> wrote:" quote headers
QUOTE_ATTRIBUTION_PATTERN = /^On\s+.{10,80}\s+wrote:\s*$/i

# -----------------------------------------------------------------------------
# Mbox Parsing
# -----------------------------------------------------------------------------

def parse_mbox(mbox_path)
  messages = []
  current_message = []
  in_message = false

  File.open(mbox_path, 'rb') do |file|
    file.each_line do |line|
      # mbox separator: lines starting with "From " (not "From:")
      if line.start_with?('From ') && !line.start_with?('From:')
        if in_message && !current_message.empty?
          messages << current_message.join
          current_message = []
        end
        in_message = true
      else
        current_message << line if in_message
      end
    end
    # Capture final message
    if in_message && !current_message.empty?
      messages << current_message.join
    end
  end
  messages
end

# -----------------------------------------------------------------------------
# Message-ID Handling
# -----------------------------------------------------------------------------

def extract_message_id(raw_email)
  begin
    mail = Mail.new(raw_email)
    msg_id = mail.message_id
    if msg_id.nil? || msg_id.empty?
      # Synthesize ID from content hash when header is missing
      hash = Digest::SHA256.hexdigest(raw_email)[0..15]
      msg_id = "synthetic-#{hash}@generated"
    end
    msg_id
  rescue => e
    hash = Digest::SHA256.hexdigest(raw_email)[0..15]
    "synthetic-#{hash}@generated"
  end
end

# -----------------------------------------------------------------------------
# Threading
# -----------------------------------------------------------------------------

def normalize_subject(subject)
  return "" if subject.nil? || subject.empty?
  # Strip Re:, Fwd:, Fw:, Aw: prefixes recursively
  subject.gsub(/^\s*(re|fwd?|aw):\s*/i, '').strip.downcase
end

def derive_thread_id(mail, message_id)
  begin
    # Priority 1: First Reference (thread root)
    if mail.references && !mail.references.empty?
      return mail.references.first.to_s.strip
    end

    # Priority 2: In-Reply-To header
    if mail.in_reply_to && !mail.in_reply_to.empty?
      in_reply = mail.in_reply_to.is_a?(Array) ? mail.in_reply_to.first : mail.in_reply_to
      return in_reply.to_s.strip
    end

    # Priority 3: Normalized subject hash (groups related subjects)
    subject = mail.subject
    if subject && !subject.empty?
      normalized = normalize_subject(subject)
      return "subject-#{Digest::SHA256.hexdigest(normalized)[0..15]}" unless normalized.empty?
    end

    # Fallback: Message starts its own thread
    message_id
  rescue => e
    message_id
  end
end

# -----------------------------------------------------------------------------
# Cohort Stamping
# -----------------------------------------------------------------------------

def stamp_cohort_id(mail, mbox_path, override_cohort)
  return override_cohort if override_cohort

  begin
    return mail.date.strftime('%Y-%m') if mail.date
  rescue => e
    # Fall through to mtime
  end

  File.mtime(mbox_path).strftime('%Y-%m')
end

# -----------------------------------------------------------------------------
# Charset Detection & Transcoding
# -----------------------------------------------------------------------------

# Extracts charset from Content-Type header, returns nil if not found
def extract_charset(mail, part = nil)
  begin
    if part
      return part.charset if part.charset && !part.charset.empty?
    else
      return mail.charset if mail.charset && !mail.charset.empty?
    end
  rescue => e
    # Fall through to nil
  end
  nil
end

# Detects charset using charlock_holmes when Content-Type charset is missing
def detect_charset(raw_bytes)
  detection = CharlockHolmes::EncodingDetector.detect(raw_bytes)
  detection[:encoding] if detection && detection[:encoding]
rescue => e
  nil
end

# Transcodes body to UTF-8 with charset detection and fallback
# Priority: (1) explicit charset, (2) charlock_holmes detection, (3) safe replace
def transcode_to_utf8(body_bytes, explicit_charset = nil)
  return "" if body_bytes.nil? || body_bytes.empty?
  
  # Ensure we're working with raw bytes
  body_bytes = body_bytes.dup.force_encoding('ASCII-8BIT')
  
  # Try explicit charset first
  charset = explicit_charset
  
  # Auto-detect if no explicit charset
  charset ||= detect_charset(body_bytes)
  
  # Fallback to UTF-8 assumption
  charset ||= 'UTF-8'
  
  # Transcode with safe fallback for any remaining invalid sequences
  body_bytes.force_encoding(charset).encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError => e
  # Nuclear fallback: force ASCII-8BIT interpretation with replacement
  body_bytes.force_encoding('ASCII-8BIT').encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
end

# -----------------------------------------------------------------------------
# Content Filtering
# -----------------------------------------------------------------------------

def contains_binary?(raw_email)
  BINARY_INDICATORS.any? { |pattern| raw_email.match?(pattern) }
end

def strip_quoted_blocks(body)
  return "" if body.nil?

  lines = body.lines
  cleaned_lines = []
  skip_next_blank = false

  lines.each do |line|
    # Skip "On ... wrote:" attribution lines
    if line.match?(QUOTE_ATTRIBUTION_PATTERN)
      skip_next_blank = true
      next
    end

    # Skip quoted lines (starting with >)
    if line.start_with?('>')
      skip_next_blank = true
      next
    end

    # Skip blank line immediately after quote block
    if skip_next_blank && line.strip.empty?
      skip_next_blank = false
      next
    end

    skip_next_blank = false
    # Trim trailing whitespace only, preserve leading whitespace
    cleaned_lines << line.rstrip
  end

  cleaned_lines.join("\n")
end

def extract_and_clean_body(mail, raw_email)
  begin
    body = if mail.multipart?
            # For multipart, prefer text/plain part with proper charset handling
            text_part = mail.parts.find { |p| p.content_type&.start_with?('text/plain') }
            if text_part
              charset = extract_charset(mail, text_part)
              transcode_to_utf8(text_part.decoded, charset)
            else
              first_part = mail.parts.first
              charset = extract_charset(mail, first_part) if first_part
              transcode_to_utf8(first_part&.decoded, charset)
            end
          else
          charset = extract_charset(mail)
          transcode_to_utf8(mail.body.decoded, charset)
          end

    strip_quoted_blocks(body || "")
  rescue => e
    # Fallback: strip headers and clean raw content with auto-detection
    header_end = raw_email.index("\n\n") || raw_email.index("\r\n\r\n")
    body = header_end ? raw_email[(header_end + 2)..-1] : raw_email
    strip_quoted_blocks(transcode_to_utf8(body || ""))
  end
end

def exceeds_size_limit?(text)
  text.size > MAX_CHAR_LIMIT
end

# -----------------------------------------------------------------------------
# Internal ID Generation
# -----------------------------------------------------------------------------

def generate_internal_id(message_id, body_text)
  body_hash = Digest::SHA256.hexdigest(body_text)
  Digest::SHA256.hexdigest("#{message_id}#{body_hash}")
end

# -----------------------------------------------------------------------------
# Collision Tracking
# -----------------------------------------------------------------------------

class CollisionTracker
  def initialize(triage_file_path)
    @triage_file_path = triage_file_path
    @seen_internal_ids = {}      # internal_id => true (for exact dedup)
    @message_id_index = {}       # message_id => first internal_id seen
    @collisions = []
  end

  # Returns :new, :duplicate, or :collision
  def check(message_id, internal_id, raw_email_preview)
    # Check for exact duplicate (same internal_id)
    if @seen_internal_ids.key?(internal_id)
      return :duplicate
    end

    # Check for Message-ID collision (same message_id, different internal_id)
    if @message_id_index.key?(message_id)
      first_internal_id = @message_id_index[message_id]
      if first_internal_id != internal_id
        @collisions << {
          message_id: message_id,
          first_internal_id: first_internal_id,
          new_internal_id: internal_id,
          preview: raw_email_preview[0..500]
        }
        # Still record this as seen and return :collision (we keep it, but log it)
        @seen_internal_ids[internal_id] = true
        return :collision
      end
    end

    # New unique message
    @seen_internal_ids[internal_id] = true
    @message_id_index[message_id] = internal_id
    :new
  end

  def write_triage_log
    return if @collisions.empty?

    File.open(@triage_file_path, 'w') do |f|
      f.puts "# Message-ID Collision Triage Log"
      f.puts "# Generated: #{Time.now.utc.iso8601}"
      f.puts "# Collisions: #{@collisions.size}"
      f.puts "#"
      f.puts "# These messages share a Message-ID but have different content."
      f.puts "# Both versions are preserved in the output with unique internal_ids."
      f.puts "# Review manually to determine if one should be excluded."
      f.puts ""

      @collisions.each_with_index do |c, i|
        f.puts "=" * 78
        f.puts "COLLISION ##{i + 1}"
        f.puts "Message-ID:       #{c[:message_id]}"
        f.puts "First internal_id:  #{c[:first_internal_id]}"
        f.puts "New internal_id:    #{c[:new_internal_id]}"
        f.puts "Preview:"
        f.puts c[:preview].gsub(/^/, '  ')
        f.puts ""
      end
    end
    @collisions.size
  end

  def collision_count
    @collisions.size
  end
end

# -----------------------------------------------------------------------------
# File Management
# -----------------------------------------------------------------------------

def find_existing_json_files(output_dir)
  return [] unless Dir.exist?(output_dir)
  Dir.glob(File.join(output_dir, "*.{json,jsonl}"))
end

def delete_json_files!(output_dir)
  json_files = find_existing_json_files(output_dir)
  json_files.each { |f| File.delete(f) }
  json_files.size
end

def resolve_output_dir(options)
  if options[:output]
    File.dirname(File.expand_path(options[:output]))
  else
    options[:output_dir]
  end
end

# -----------------------------------------------------------------------------
# Option Parsing
# -----------------------------------------------------------------------------

options = {
  shard_size: 1000,
  output_dir: 'emails',
  output_dir_explicit: false,
  output_explicit: false,
  triage_file: 'collisions.log',
  force: false,
  yes: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby mbox_pre-parser.rb input.mbox [OPTIONS]"
  opts.separator ""
  opts.separator "Parse mbox archives into JSONL for ML training pipelines."
  opts.separator "See header comments for full documentation."
  opts.separator ""
  opts.separator "Options:"

  opts.on("-o", "--output FILE", "Write single JSON file (overrides sharding)") do |o|
    options[:output] = o
    options[:output_explicit] = true
  end

  opts.on("--output-dir DIR", "Output directory for shards (default: emails/)") do |d|
    options[:output_dir] = d
    options[:output_dir_explicit] = true
  end

  opts.on("--cohort COHORT", "Override cohort_id (YYYY-MM format)") do |c|
    options[:cohort] = c
  end

  opts.on("--shard-size N", Integer, "Messages per shard (default: 1000)") do |s|
    options[:shard_size] = s
  end

  opts.on("--triage-file PATH", "Path for collision log (default: collisions.log)") do |t|
    options[:triage_file] = t
  end

  opts.on("-f", "--force", "Overwrite existing JSON/JSONL files") do
    options[:force] = true
  end

  opts.on("-y", "--yes", "Skip confirmation prompts") do
    options[:yes] = true
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

# -----------------------------------------------------------------------------
# Input Validation
# -----------------------------------------------------------------------------

if ARGV.empty?
  puts "Error: No input mbox file specified"
  puts "Usage: ruby mbox_pre-parser.rb input.mbox [OPTIONS]"
  exit 1
end

mbox_path = ARGV[0]
unless File.exist?(mbox_path)
  puts "Error: File not found: #{mbox_path}"
  exit 1
end

# -----------------------------------------------------------------------------
# Safety Checks for Output Directory
# -----------------------------------------------------------------------------

target_dir = resolve_output_dir(options)
existing_json_files = find_existing_json_files(target_dir)

if existing_json_files.any?
  unless options[:force]
    puts "Error: Output directory '#{target_dir}' contains #{existing_json_files.size} existing JSON/JSONL file(s):"
    existing_json_files.first(5).each { |f| puts "  - #{File.basename(f)}" }
    puts "  ... and #{existing_json_files.size - 5} more" if existing_json_files.size > 5
    puts "Use --force to delete them and proceed."
    exit 1
  end

  unless options[:output_explicit] || options[:output_dir_explicit]
    puts "Error: When using --force, you must explicitly specify --output or --output-dir."
    puts "This prevents accidental deletion of files in the default directory."
    exit 1
  end

  unless options[:yes]
    puts "Warning: #{existing_json_files.size} JSON/JSONL file(s) will be deleted from '#{target_dir}':"
    existing_json_files.first(10).each { |f| puts "  - #{File.basename(f)}" }
    puts "  ... and #{existing_json_files.size - 10} more" if existing_json_files.size > 10
    print "Proceed? [y/N] "
    response = STDIN.gets.chomp.downcase
    unless response == 'y' || response == 'yes'
      puts "Aborted."
      exit 0
    end
  end

  deleted_count = delete_json_files!(target_dir)
  puts "Deleted #{deleted_count} existing JSON/JSONL file(s)."
end

# -----------------------------------------------------------------------------
# Main Processing
# -----------------------------------------------------------------------------

puts "Parsing mbox: #{mbox_path}"
raw_messages = parse_mbox(mbox_path)
puts "Found #{raw_messages.size} raw messages"

# Initialize tracking
stats = {
  binary_skipped: 0,
  oversized_skipped: 0,
  duplicate_skipped: 0,
  collision_kept: 0,
  processed: 0
}

collision_tracker = CollisionTracker.new(options[:triage_file])
json_output = []

raw_messages.each_with_index do |raw_email, idx|
  # Filter: Binary content
  if contains_binary?(raw_email)
    stats[:binary_skipped] += 1
    next
  end

  begin
    mail = Mail.new(raw_email)
  rescue => e
    # If we can't parse at all, skip
    stats[:binary_skipped] += 1
    next
  end

  # Extract and clean body
  cleaned_body = extract_and_clean_body(mail, raw_email)

  # Filter: Size limit (post-cleaning)
  if exceeds_size_limit?(cleaned_body)
    stats[:oversized_skipped] += 1
    next
  end

  # Extract identifiers
  message_id = extract_message_id(raw_email)
  internal_id = generate_internal_id(message_id, cleaned_body)

  # Check for duplicates and collisions
  status = collision_tracker.check(message_id, internal_id, raw_email)

  case status
  when :duplicate
    stats[:duplicate_skipped] += 1
    next
  when :collision
    stats[:collision_kept] += 1
    # Continue processing - we keep collisions but log them
  end

  # Derive threading and cohort
  thread_id = derive_thread_id(mail, message_id)
  cohort_id = stamp_cohort_id(mail, mbox_path, options[:cohort])

  json_output << {
    "internal_id" => internal_id,
    "original_message_id" => message_id,
    "thread_id" => thread_id,
    "cohort_id" => cohort_id,
    "email_message" => cleaned_body
  }

  stats[:processed] += 1
end

# -----------------------------------------------------------------------------
# Write Output
# -----------------------------------------------------------------------------

if options[:output]
  # Single-file JSON mode
  output_dir = File.dirname(File.expand_path(options[:output]))
  FileUtils.mkdir_p(output_dir) unless output_dir == '.'

  File.open(options[:output], 'w') do |f|
    f.write(JSON.pretty_generate(json_output))
  end
  puts "Output written to: #{options[:output]} (single file)"
else
  # Sharded JSONL mode
  output_dir = options[:output_dir]
  FileUtils.mkdir_p(output_dir)

  shard_size = options[:shard_size]
  shard_count = [(json_output.size.to_f / shard_size).ceil, 1].max

  if json_output.empty?
    puts "Warning: No messages to write (all filtered out)."
  else
    json_output.each_slice(shard_size).with_index(1) do |shard, index|
      shard_file = File.join(output_dir, "part-%05d.jsonl" % index)
      File.open(shard_file, 'w') do |f|
        shard.each { |record| f.puts JSON.generate(record) }
      end
      puts "  Written shard #{index}/#{shard_count}: #{shard_file} (#{shard.size} messages)"
    end
    puts "Output written to: #{output_dir}/ (#{shard_count} shards)"
  end
end

# Write collision triage log if any collisions detected
collisions_logged = collision_tracker.write_triage_log
if collisions_logged && collisions_logged > 0
  puts "Collision triage log written to: #{options[:triage_file]} (#{collisions_logged} collisions)"
end

# -----------------------------------------------------------------------------
# Summary Statistics
# -----------------------------------------------------------------------------

puts ""
puts "=== Processing Summary ==="
puts "Total parsed:       #{raw_messages.size}"
puts "Binary skipped:     #{stats[:binary_skipped]}"
puts "Oversized skipped:  #{stats[:oversized_skipped]} (>#{MAX_CHAR_LIMIT} chars)"
puts "Duplicates skipped: #{stats[:duplicate_skipped]} (exact internal_id match)"
puts "Collisions kept:    #{stats[:collision_kept]} (same Message-ID, different content)"
puts "Messages output:    #{stats[:processed]}"

if json_output.any?
  thread_counts = json_output.group_by { |m| m["thread_id"] }.transform_values(&:size)
  puts ""
  puts "Unique threads:  #{thread_counts.size}"
  puts "Largest thread:  #{thread_counts.values.max} messages"

  cohort_counts = json_output.group_by { |m| m["cohort_id"] }.transform_values(&:size)
  puts "Cohorts:         #{cohort_counts.keys.sort.join(', ')}"

  puts ""
  if options[:output]
    puts "Ready for: ruby splitter.rb -i #{options[:output]} -o splits/ --pin YYYY-MM"
  else
    puts "Ready for: ruby splitter.rb -i #{options[:output_dir]}/ -o splits/ --pin YYYY-MM"
  end
end