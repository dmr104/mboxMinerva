#!/usr/bin/env ruby
# mbox_pre-parser.rb - Convert mbox to JSON format compatible with splitter.rb
# Usage: ruby mbox_pre-parser.rb input.mbox [--output FILE] [--cohort YYYY-MM] [--shard-size N]
# Output: By default, writes sharded JSONL to emails/part-NNNNN.jsonl
#         With --output FILE, writes single JSON file
# Output: `[{"message_id": "...", "thread_id": "...", "cohort_id": "...", "email_message": "raw RFC 822..."}]`
#
# REQUIREMENTS:
#   gem install simhash2   # For fuzzy deduplication
#
# INPUT FILE:
#   Must be a SpamAssassin-processed mbox (containing X-Spam-* headers).
#   Messages with X-Spam-Flag: YES are automatically skipped.
#
# SAFETY:
#   Will not overwrite existing shard/JSON files without --force.
#   Use --force --yes to skip confirmation prompt.
#   Only *.json and *.jsonl files are removed; other files left untouched.

require 'json'
require 'digest/sha256'
require 'mail'
require 'optparse'
require 'date'
require 'fileutils'

# Requirement 4: Fuzzy deduplication via simhash2
begin
  require 'simhash2'
rescue LoadError
  puts "Error: The 'simhash2' gem is required for fuzzy deduplication."
  puts "Please install it using: gem install simhash2"
  exit 1
end

# Requirement 5: Size limits to reject absurdly long messages
MAX_CHAR_LIMIT = 500_000      # 500KB character limit
MAX_TOKEN_ESTIMATE = 125_000  # Rough 4:1 char-to-token ratio

# Default simhash similarity threshold (Hamming distance <= 3 catches near-duplicates)
DEFAULT_SIMHASH_THRESHOLD = 3

def parse_mbox(mbox_path)
  messages = []
  current_message = []
  in_message = false

  File.open(mbox_path, 'r:UTF-8') do |file|
    file.each_line do |line|
      # mbox separator: lines starting with "From " (not "From:")
      if line.start_with?('From ') && !line.start_with?('From:')
        # Save previous message if exists
        if in_message && !current_message.empty?
          messages << current_message.join
          current_message = []
        end
        in_message = true
      else
        current_message << line if in_message
      end
    end
    # Save last message
    if in_message && !current_message.empty?
      messages << current_message.join
    end
  end
  messages
end

def extract_message_id(raw_email)
  begin
    mail = Mail.new(raw_email)
    msg_id = mail.message_id
    # If no Message-ID header, synthesize one from content hash
    if msg_id.nil? || msg_id.empty?
      hash = Digest::SHA256.hexdigest(raw_email)[0..15]
      msg_id = "synthetic-#{hash}@generated"
    end
    msg_id
  rescue => e
    # Fallback if parsing fails completely
    hash = Digest::SHA256.hexdigest(raw_email)[0..15]
    "synthetic-#{hash}@generated"
  end
end

def normalize_subject(subject)
  # Strip Re:, Fwd:, Fw:, etc. and whitespace for subject-based threading
  return "" if subject.nil? || subject.empty?
  subject.gsub(/^(re|fwd?|aw):\s*/i, '').strip.downcase
end

def derive_thread_id(mail, message_id)
  # Threading strategy:
  # 1. Use first References header ID (root of thread)
  # 2. Else use In-Reply-To
  # 3. Else use normalized Subject hash
  # 4. Else use message_id itself (new thread)

  begin
    # Try References header (oldest ancestor)
    if mail.references && !mail.references.empty?
      return mail.references.first.to_s.strip
    end

    # Try In-Reply-To header
    if mail.in_reply_to && !mail.in_reply_to.empty?
      in_reply = mail.in_reply_to.is_a?(Array) ? mail.in_reply_to.first : mail.in_reply_to
      return in_reply.to_s.strip
    end

    # Fallback to normalized subject hash
    subject = mail.subject
    if subject && !subject.empty?
      normalized = normalize_subject(subject)
      if !normalized.empty?
        return "subject-#{Digest::SHA256.hexdigest(normalized)[0..15]}"
      end
    end

    # Final fallback: this message starts a new thread
    return message_id
  rescue => e
    # On any parse error, treat as new thread
    return message_id
  end
end

def stamp_cohort_id(mail, mbox_path, override_cohort)
  # Cohort stamping strategy:
  # 1. Use --cohort override if provided
  # 2. Else parse Date: header from email
  # 3. Else use mbox file mtime as fallback

  return override_cohort if override_cohort

  begin
    # Try Date: header
    if mail.date
      return mail.date.strftime('%Y-%m')
    end
  rescue => e
    # Parse error, fall through to mtime
  end

  # Fallback to file modification time
  File.mtime(mbox_path).strftime('%Y-%m')
end

# Requirement 3: Check if message is spam (SpamAssassin X-Spam-Flag: YES)
def is_spam?(raw_email)
  # Look for X-Spam-Flag: YES header (case-insensitive)
  raw_email.lines.any? do |line|
    break false if line.strip.empty?  # End of headers
    line =~ /^X-Spam-Flag:\s*YES/i
  end
end

# Requirement 3: Validate that input file has SpamAssassin headers
def validate_sa_format!(messages)
  return if messages.empty?

  # Check first 10 messages for any X-Spam-* headers
  sample = messages.first(10)
  has_sa_headers = sample.any? { |msg| msg.include?("X-Spam-") }

  unless has_sa_headers
    puts "Error: Input file does not appear to be SpamAssassin-processed."
    puts "Required: mbox must contain X-Spam-* headers (e.g., X-Spam-Status, X-Spam-Flag)."
    puts ""
    puts "Pre-filter your mbox with SpamAssassin first:"
    puts "  formail -s spamc < raw.mbox > filtered.mbox"
    puts "  ruby mbox_pre-parser.rb filtered.mbox --output-dir emails/"
    exit 1
  end
end

# Requirement 4: Fuzzy deduplication tracker
class DuplicateTracker
  def initialize(threshold = DEFAULT_SIMHASH_THRESHOLD)
    @fingerprints = []
    @threshold = threshold
  end

  def duplicate?(text)
    return false if text.nil? || text.strip.empty?

    # Generate simhash fingerprint
    fp = Simhash.hash(text)

    # Check against existing fingerprints
    @fingerprints.each do |existing_fp|
      distance = hamming_distance(fp, existing_fp)
      return true if distance <= @threshold
    end

    # Not a duplicate - remember this fingerprint
    @fingerprints << fp
    false
  end

  private

  def hamming_distance(a, b)
    (a ^ b).to_s(2).count('1')
  end
end

# Requirement 5: Check if message exceeds size limits
def exceeds_size_limit?(raw_email)
  raw_email.size > MAX_CHAR_LIMIT
end

# Find existing JSON/JSONL files in directory (shards and single-file outputs)
def find_existing_json_files(output_dir)
  return [] unless Dir.exist?(output_dir)
  Dir.glob(File.join(output_dir, "*.{json,jsonl}"))
end

# Delete only JSON/JSONL files, leave other files untouched
def delete_json_files!(output_dir)
  json_files = find_existing_json_files(output_dir)
  json_files.each { |f| File.delete(f) }
  json_files.size
end

# Determine the target directory for cleanup based on output mode
def resolve_output_dir(options)
  if options[:output]
    # Single-file mode: directory is parent of the output file
    File.dirname(File.expand_path(options[:output]))
  else
    # Sharded mode: use output_dir directly
    options[:output_dir]
  end
end

# Parse command-line arguments
options = {
  shard_size: 1000,           # Default shard size
  output_dir: 'emails',       # Default output directory for shards
  output_dir_explicit: false, # Track if user explicitly set --output-dir
  output_explicit: false,     # Track if user explicitly set --output
  simhash_threshold: DEFAULT_SIMHASH_THRESHOLD,
  force: false,
  yes: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby mbox_pre-parser.rb input.mbox [OPTIONS]"

  opts.separator ""
  opts.separator "Input file must be SpamAssassin-processed mbox (with X-Spam-* headers)."
  opts.separator "Messages with X-Spam-Flag: YES are automatically skipped."
  opts.separator ""
  opts.separator "By default, writes sharded JSONL files to emails/part-NNNNN.jsonl"
  opts.separator "Use --output FILE to override and write single JSON file instead"
  opts.separator ""
  opts.separator "Options:"

  opts.on("-o", "--output FILE", "Write single JSON file (overrides default sharding)") do |o|
    options[:output] = o
    options[:output_explicit] = true
  end

  opts.on("--cohort COHORT", "Override cohort_id (YYYY-MM format)") do |c|
    options[:cohort] = c
  end

  opts.on("--shard-size N", Integer, "Messages per shard (default: 1000)") do |s|
    options[:shard_size] = s
  end

  opts.on("--output-dir DIR", "Output directory for shards (default: emails/)") do |d|
    options[:output_dir] = d
    options[:output_dir_explicit] = true
  end

  opts.on("--simhash-threshold N", Integer, 
          "Hamming distance for fuzzy dedup (0-10, default: #{DEFAULT_SIMHASH_THRESHOLD})",
          "  Lower = stricter (fewer false positives, may miss variants)",
          "  Higher = looser (catches more variants, risk of false positives)") do |t|
    if t < 0 || t > 10
      puts "Error: --simhash-threshold must be between 0 and 10"
      exit 1
    end
    options[:simhash_threshold] = t
  end

  opts.on("-f", "--force", "Overwrite existing JSON/JSONL files in output directory") do
    options[:force] = true
  end

  opts.on("-y", "--yes", "Automatically confirm destructive operations") do
    options[:yes] = true
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

# Validate input file argument
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

# Safety checks for both output modes (--output FILE and --output-dir)
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

  # Require explicit output path when using --force (safety against accidents)
  unless options[:output_explicit] || options[:output_dir_explicit]
    puts "Error: When using --force, you must explicitly specify --output or --output-dir."
    puts "This prevents accidental deletion of files in the default directory."
    exit 1
  end

  # Confirmation prompt unless --yes given
  unless options[:yes]
    puts "Warning: The following #{existing_json_files.size} JSON/JSONL file(s) will be deleted from '#{target_dir}':"
    existing_json_files.first(10).each { |f| puts "  - #{File.basename(f)}" }
    puts "  ... and #{existing_json_files.size - 10} more" if existing_json_files.size > 10
    print "Proceed? [y/N] "
    response = STDIN.gets.chomp.downcase
    unless response == 'y' || response == 'yes'
      puts "Aborted."
      exit 0
    end
  end

  # Delete existing JSON/JSONL files only (leave other files untouched)
  deleted_count = delete_json_files!(target_dir)
  puts "Deleted #{deleted_count} existing JSON/JSONL file(s)."
end

puts "Parsing mbox: #{mbox_path}"
raw_messages = parse_mbox(mbox_path)
puts "Found #{raw_messages.size} messages"

# Requirement 3: Validate SpamAssassin format
validate_sa_format!(raw_messages)

# Initialize counters for filtering stats
stats = {
  spam_skipped: 0,
  oversized_skipped: 0,
  duplicate_skipped: 0,
  processed: 0
}

# Requirement 4: Initialize duplicate tracker with configured threshold
dedup_tracker = DuplicateTracker.new(options[:simhash_threshold])
puts "Fuzzy dedup threshold: Hamming distance <= #{options[:simhash_threshold]}"

# Convert to required JSON format with threading and cohort
json_output = []

raw_messages.each do |raw_email|
  # Requirement 3: Skip spam messages
  if is_spam?(raw_email)
    stats[:spam_skipped] += 1
    next
  end

  # Requirement 5: Skip oversized messages
  if exceeds_size_limit?(raw_email)
    stats[:oversized_skipped] += 1
    next
  end

  # Requirement 4: Skip fuzzy duplicates (based on body content)
  mail = Mail.new(raw_email)
  body_text = mail.body.decoded.to_s rescue raw_email
  if dedup_tracker.duplicate?(body_text)
    stats[:duplicate_skipped] += 1
    next
  end

  message_id = extract_message_id(raw_email)
  thread_id = derive_thread_id(mail, message_id)
  cohort_id = stamp_cohort_id(mail, mbox_path, options[:cohort])

  json_output << {
    "message_id" => message_id,
    "thread_id" => thread_id,
    "cohort_id" => cohort_id,
    "email_message" => raw_email.strip
  }

  stats[:processed] += 1
end

# Write output: sharded by default, single file if --output specified
if options[:output]
  # Single-file mode
  output_dir = File.dirname(File.expand_path(options[:output]))
  FileUtils.mkdir_p(output_dir) unless output_dir == '.'

  File.open(options[:output], 'w') do |f|
    f.write(JSON.pretty_generate(json_output))
  end
  puts "Output written to: #{options[:output]} (single file)"
else
  # Default sharded mode
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
        shard.each do |record|
          f.puts JSON.generate(record)
        end
      end
      puts "  Written shard #{index}/#{shard_count}: #{shard_file} (#{shard.size} messages)"
    end
    puts "Output written to: #{output_dir}/ (#{shard_count} shards)"
  end
end

# Summary statistics
puts ""
puts "=== Processing Summary ==="
puts "Total parsed:       #{raw_messages.size}"
puts "Spam skipped:       #{stats[:spam_skipped]}"
puts "Oversized skipped:  #{stats[:oversized_skipped]} (>#{MAX_CHAR_LIMIT} chars)"
puts "Duplicates skipped: #{stats[:duplicate_skipped]} (threshold: #{options[:simhash_threshold]})"
puts "Messages output:    #{stats[:processed]}"

if json_output.any?
  # Thread statistics
  thread_counts = json_output.group_by { |m| m["thread_id"] }.transform_values(&:size)
  puts ""
  puts "Unique threads: #{thread_counts.size}"
  puts "Largest thread: #{thread_counts.values.max} messages"

  # Cohort statistics
  cohort_counts = json_output.group_by { |m| m["cohort_id"] }.transform_values(&:size)
  puts "Cohorts: #{cohort_counts.keys.sort.join(', ')}"

  puts ""
  if options[:output]
    puts "Ready for: ruby splitter.rb -i #{options[:output]} -o splits/ --pin YYYY-MM"
  else
    puts "Ready for: ruby splitter.rb -i #{options[:output_dir]}/ -o splits/ --pin YYYY-MM"
  end
end