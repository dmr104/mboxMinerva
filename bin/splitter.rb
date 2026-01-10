#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# splitter.rb - Deterministic train/val/test split with cohort pinning
# =============================================================================
#
# SYNOPSIS
#   ruby splitter.rb -i INPUT -o OUTPUT_DIR [OPTIONS]
#
# DESCRIPTION
#   Reads JSONL/JSON output from mbox_pre-parser.rb, assigns each thread to a
#   deterministic train/val/test split using seeded hashing, and materializes
#   the splits into separate files for ML training pipelines.
#
#   Thread integrity is preserved: all messages (and windows) from a single
#   thread share the same split assignment, preventing context leakage across
#   train/val/test boundaries.
#
# INPUT FORMAT (from mbox_pre-parser.rb)
#   Each record must contain:
#     {
#       "internal_id":          "sha256-hex",      # Primary key (collision-proof)
#       "original_message_id":  "<abc@example>",   # Raw Message-ID for diagnostics
#       "thread_id":            "<root@example>",  # Thread root for grouping
#       "cohort_id":            "2025-01",         # YYYY-MM cohort stamp
#       "email_message":        "cleaned body..."  # Email content
#     }
#
# OUTPUT FORMAT
#   Manifest (assignments.json):
#     Immutable append-only JSON object mapping internal_id to split assignment:
#     {
#       "abc123...": { "split": "train", "thread_id": "...", "cohort_id": "2025-01" },
#       ...
#     }
#
#   Materialized splits (train.jsonl, val.jsonl, test.jsonl):
#     JSONL files containing full email records for each split.
#
# SPLIT ASSIGNMENT LOGIC
#   1. Group emails by thread_id
#   2. Hash thread_id with seed to bucket (0-99)
#   3. Assign: 0-79 = train, 80-89 = val, 90-99 = test (80/10/10 ratio)
#   4. All emails/windows in a thread inherit the thread's split
#
# COHORT PINNING
#   --pin YYYY-MM filters materialization to cohort_id <= pin value.
#   This allows train.jsonl to grow with new cohorts while val/test stay frozen.
#
# WINDOWING (optional)
#   --window-size N chunks long threads into overlapping windows.
#   Each window gets a unique manifest entry (thread_id_window_N) but inherits
#   the parent thread's split assignment.
#
# OPTIONS
#   -i, --input DIR|FILE     Input directory (globs *.json/*.jsonl) or single file
#   -o, --output DIR         Output directory for materialized splits
#   -m, --manifest FILE      Manifest path (default: assignments.json)
#   --incremental            Append-only mode: preserve existing assignments
#   -s, --seed SEED          Random seed for deterministic hashing (default: 42)
#   --window-size SIZE       Rolling window size (messages per chunk)
#   --window-overlap N       Rolling window overlap (default: 0)
#   --pin COHORT             Cohort_id upper-bound filter (YYYY-MM)
#   --exclude FILE           Exclusion list (internal_ids to filter out)
#   --materialize SPLIT      Which splits to write: train|val|test|all (required)
#   -h, --help               Show this help
#
# EXAMPLES
#   # Basic split and materialize all
#   ruby splitter.rb -i emails/ -o splits/ --materialize all
#
#   # Incremental with cohort pin
#   ruby splitter.rb -i emails/ -o splits/ --incremental --pin 2025-01 --materialize train
#
#   # With windowing for long threads
#   ruby splitter.rb -i emails/ -o splits/ --window-size 100 --window-overlap 10 --materialize all
#
# =============================================================================

require 'json'
require 'digest'
require 'optparse'
require 'fileutils'
require 'set'

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

TRAIN_RATIO = 0.8
VAL_RATIO = 0.1
TEST_RATIO = 0.1

# -----------------------------------------------------------------------------
# Split Assignment
# -----------------------------------------------------------------------------

# Deterministic hash-bucket assignment based on thread_id and seed
def assign_split(thread_id, seed)
  hash = Digest::SHA256.hexdigest("#{seed}:#{thread_id}").to_i(16)
  bucket = hash % 100
  
  if bucket < (TRAIN_RATIO * 100)
    'train'
  elsif bucket < ((TRAIN_RATIO + VAL_RATIO) * 100)
    'val'
  else
    'test'
  end
end

# -----------------------------------------------------------------------------
# Input Loading
# -----------------------------------------------------------------------------

def load_emails(input_path)
  emails = []
  
  if File.directory?(input_path)
    # Directory mode: glob all JSON/JSONL files
    pattern = File.join(input_path, '**', '*.{json,jsonl}')
    files = Dir.glob(pattern)
    
    if files.empty?
      abort "Error: No JSON/JSONL files found in #{input_path}"
    end
    
    files.each do |file|
      emails.concat(load_file(file))
    end
  elsif File.file?(input_path)
    # Single file mode
    emails = load_file(input_path)
  else
    abort "Error: Input path not found: #{input_path}"
  end
  
  emails
end

def load_file(filepath)
  records = []
  
  if filepath.end_with?('.jsonl')
    # JSONL: one record per line
    File.foreach(filepath) do |line|
      line = line.strip
      next if line.empty?
      records << JSON.parse(line)
    end
  else
    # JSON: single object or array
    data = JSON.parse(File.read(filepath))
    records = data.is_a?(Array) ? data : [data]
  end
  
  records
end

# -----------------------------------------------------------------------------
# Exclusion List
# -----------------------------------------------------------------------------

def load_exclusion_list(exclude_path)
  return Set.new unless exclude_path && File.exist?(exclude_path)
  
  ids = File.readlines(exclude_path).map(&:strip).reject(&:empty?)
  Set.new(ids)
end

# -----------------------------------------------------------------------------
# Option Parsing
# -----------------------------------------------------------------------------

options = {
  input: nil,
  output: nil,
  manifest: 'assignments.json',
  incremental: false,
  seed: 42,
  window_size: nil,
  window_overlap: 0,
  pin: nil,
  exclude: nil,
  materialize: nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: splitter.rb [options]"
  opts.separator ""
  opts.separator "Deterministic train/val/test split with cohort pinning."
  opts.separator "See header comments for full documentation."
  opts.separator ""
  opts.separator "Options:"

  opts.on("-i", "--input PATH", "Input directory or file with JSON/JSONL emails") do |v|
    options[:input] = v
  end

  opts.on("-o", "--output DIR", "Output directory for materialized splits") do |v|
    options[:output] = v
  end

  opts.on("-m", "--manifest FILE", "Immutable manifest JSON (default: assignments.json)") do |v|
    options[:manifest] = v
  end

  opts.on("--incremental", "Append-only mode: preserve existing assignments") do
    options[:incremental] = true
  end

  opts.on("-s", "--seed SEED", Integer, "Random seed for deterministic hashing (default: 42)") do |v|
    options[:seed] = v
  end

  opts.on("--window-size SIZE", Integer, "Rolling window size (messages per chunk)") do |v|
    options[:window_size] = v
  end

  opts.on("--window-overlap N", Integer, "Rolling window overlap (default: 0)") do |v|
    options[:window_overlap] = v
  end

  opts.on("--pin COHORT", "Cohort_id pin (YYYY-MM) - upper-bound filter") do |v|
    options[:pin] = v
  end

  opts.on("--exclude FILE", "Exclusion list (internal_ids to filter out)") do |v|
    options[:exclude] = v
  end

  opts.on("--materialize SPLIT", "Materialize splits: train|val|test|all (required)") do |v|
    options[:materialize] = v
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

# -----------------------------------------------------------------------------
# Input Validation
# -----------------------------------------------------------------------------

abort "Error: Missing -i input path" unless options[:input]
abort "Error: Missing -o output directory" unless options[:output]
abort "Error: --materialize is required (train|val|test|all)" unless options[:materialize]

unless %w[train val test all].include?(options[:materialize])
  abort "Error: Invalid --materialize value: #{options[:materialize]} (must be train|val|test|all)"
end

if options[:pin] && options[:pin] !~ /^\d{4}-\d{2}$/
  abort "Error: --pin must be in YYYY-MM format (e.g., 2025-01)"
end

# -----------------------------------------------------------------------------
# Load Manifest
# -----------------------------------------------------------------------------

manifest = {}
if File.exist?(options[:manifest])
  manifest = JSON.parse(File.read(options[:manifest]))
  puts "Loaded existing manifest: #{options[:manifest]} (#{manifest.size} entries)"
end

# -----------------------------------------------------------------------------
# Load and Filter Emails
# -----------------------------------------------------------------------------

puts "Loading emails from: #{options[:input]}"
emails = load_emails(options[:input])
puts "Loaded #{emails.size} emails"

# Validate input format (check for internal_id)
sample = emails.first
if sample && !sample.key?('internal_id')
  if sample.key?('message_id')
    abort "Error: Input uses old format (message_id). Re-run mbox_pre-parser.rb to generate internal_id field."
  else
    abort "Error: Input missing required 'internal_id' field. Ensure input is from mbox_pre-parser.rb."
  end
end

# Load and apply exclusion list
exclusion_ids = load_exclusion_list(options[:exclude])
if exclusion_ids.any?
  original_count = emails.size
  emails.reject! { |e| exclusion_ids.include?(e['internal_id']) }
  excluded_count = original_count - emails.size
  puts "Exclusion filter: #{excluded_count} emails removed (#{emails.size} remaining)"
end

# Warn on nil/empty cohort_id
nil_cohort_count = emails.count { |e| e['cohort_id'].nil? || e['cohort_id'].to_s.empty? }
if nil_cohort_count > 0
  warn "WARNING: #{nil_cohort_count} emails have nil/empty cohort_id"
  warn "         Re-run mbox_pre-parser.rb with --cohort flag if this is unexpected"
  warn "         These emails will be included but may behave unexpectedly with --pin"
end

# Apply cohort pin filter
if options[:pin]
  original_count = emails.size
  emails.select! do |e|
    cohort = e['cohort_id']
    cohort.nil? || cohort.to_s.empty? || cohort <= options[:pin]
  end
  puts "Pin filter (cohort_id <= #{options[:pin]}): #{emails.size}/#{original_count} emails retained"
end

if emails.empty?
  abort "Error: No emails remaining after filters"
end

# -----------------------------------------------------------------------------
# Group by Thread and Assign Splits
# -----------------------------------------------------------------------------

# Group emails by thread_id
threads = emails.group_by { |e| e['thread_id'] }
puts "Grouped into #{threads.size} threads"

# Track new assignments
new_assignments = 0
inherited_assignments = 0

threads.each do |thread_id, messages|
  # Determine split for this thread
  split = nil
  
  # Check if any message from this thread is already in manifest
  existing_entry = manifest.values.find { |entry| entry['thread_id'] == thread_id }
  
  if existing_entry
    split = existing_entry['split']
    inherited_assignments += 1
  else
    split = assign_split(thread_id, options[:seed])
    new_assignments += 1
  end
  
  if options[:window_size].nil?
    # No windowing: one manifest entry per email
    messages.each do |email|
      internal_id = email['internal_id']
      
      next if options[:incremental] && manifest.key?(internal_id)
      
      manifest[internal_id] = {
        'split' => split,
        'thread_id' => thread_id,
        'cohort_id' => email['cohort_id'],
        'original_message_id' => email['original_message_id']
      }
    end
  else
    # Windowing: chunk messages and create window entries
    sorted_messages = messages.sort_by { |m| m['cohort_id'] || '' }
    window_size = options[:window_size]
    overlap = options[:window_overlap]
    stride = [window_size - overlap, 1].max
    
    window_idx = 0
    pos = 0
    
    while pos < sorted_messages.size
      window_end = [pos + window_size, sorted_messages.size].min
      window_messages = sorted_messages[pos...window_end]
      
      # Create a synthetic window ID
      window_id = "#{thread_id}_window_#{window_idx}"
      
      unless options[:incremental] && manifest.key?(window_id)
        manifest[window_id] = {
          'split' => split,
          'thread_id' => thread_id,
          'window_idx' => window_idx,
          'window_range' => [pos, window_end - 1],
          'internal_ids' => window_messages.map { |m| m['internal_id'] },
          'cohort_id' => window_messages.last['cohort_id']
        }
      end
      
      window_idx += 1
      pos += stride
    end
  end
end

puts "Split assignments: #{new_assignments} new threads, #{inherited_assignments} inherited"

# -----------------------------------------------------------------------------
# Save Manifest
# -----------------------------------------------------------------------------

File.write(options[:manifest], JSON.pretty_generate(manifest))
puts "Manifest saved: #{options[:manifest]} (#{manifest.size} entries)"

# -----------------------------------------------------------------------------
# Materialize Splits
# -----------------------------------------------------------------------------

FileUtils.mkdir_p(options[:output])

# Build split buckets
splits = { 'train' => [], 'val' => [], 'test' => [] }

# Index emails by internal_id for fast lookup
email_index = emails.each_with_object({}) { |e, h| h[e['internal_id']] = e }

# Assign emails to splits based on manifest
if options[:window_size].nil?
  # Non-windowed: materialize full email records
  manifest.each do |internal_id, entry|
    email = email_index[internal_id]
    next unless email  # Skip if email not in current filtered set
    
    splits[entry['split']] << email
  end
else
  # Windowed: materialize window records with embedded messages
  manifest.each do |window_id, entry|
    next unless entry['internal_ids']  # Only process window entries
    
    window_emails = entry['internal_ids'].map { |id| email_index[id] }.compact
    next if window_emails.empty?
    
    window_record = {
      'window_id' => window_id,
      'thread_id' => entry['thread_id'],
      'window_idx' => entry['window_idx'],
      'window_range' => entry['window_range'],
      'cohort_id' => entry['cohort_id'],
      'messages' => window_emails
    }
    
    splits[entry['split']] << window_record
  end
end

# Determine which splits to write
splits_to_write = case options[:materialize]
when 'all'
  %w[train val test]
else
  [options[:materialize]]
end

# Write materialized splits
splits_to_write.each do |split_name|
  entries = splits[split_name]
  outfile = File.join(options[:output], "#{split_name}.jsonl")
  
  File.open(outfile, 'w') do |f|
    entries.each { |record| f.puts JSON.generate(record) }
  end
  
  puts "Wrote #{entries.size} records to #{outfile}"
end

# -----------------------------------------------------------------------------
# Summary Statistics
# -----------------------------------------------------------------------------

puts ""
puts "=== Split Summary ==="
puts "Train: #{splits['train'].size} records"
puts "Val:   #{splits['val'].size} records"
puts "Test:  #{splits['test'].size} records"

total = splits.values.map(&:size).sum
if total > 0
  train_pct = (splits['train'].size.to_f / total * 100).round(1)
  val_pct = (splits['val'].size.to_f / total * 100).round(1)
  test_pct = (splits['test'].size.to_f / total * 100).round(1)
  puts "Ratio: #{train_pct}% / #{val_pct}% / #{test_pct}% (target: 80/10/10)"
end

if options[:pin]
  puts ""
  puts "Pin applied: cohort_id <= #{options[:pin]}"
  puts "To refresh train with newer cohorts, bump --pin and re-run with --materialize train"
end