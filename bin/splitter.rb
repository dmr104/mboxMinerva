#!/usr/bin/env ruby
# splitter.rb - Immutable, deterministic train/val/test split with cohort_id pinning
# Usage: splitter.rb -i emails_dir -o output_dir -manifest assignments.json [--pin YYYY-MM] [--incremental] [-s seed]

# thread_id gets added by mbox_pre-parser.rb

# Each thread_id gets ONE frozen split, and all its windows inherit that split, so overlap duplicates data
# within train (or val, or test) for better context coverage, but never leak's the same thread's context across
# splits.  It is split-pure by design.  

# A thread's "context" = the entire conversation for a thread; so splitter assigns from thread_id, and chunks from that thread
# never cross train/val/test

# window_idx is a sequence counter (0, 1, 2...) that numbers each sliding window within a long thread: i.e. when you chop a 300-message
# conversation into overlapping 100-message chunks, window_idx tags them as thread_abc_window_0, thread-abc_window_1, etc. so you 
# can track and deduplicate chunks without losing which slice of the thread you are looking at.

# bin/splitter.rb groups by thread_id, and always hashes with a deterministic seed to assign train/val/test (80/10/10) to the immutable 
# manifest, writing immutably to assignments.json.  To say this again, splitter.rb assigns per-thread splits using a deterministic hash 
# (seeded) to hit a fixed ratio so that the inputs always map to the same split in the immutable manifest unless you change the seed or 
# config ratio (which you should not do midstream because this would invalidate previous assignments, and if you do you must recreate the 
# whole manifest and then materialize it). In bin/splitter.rb when --window-size is enabled, ALL windows of a thread inherit the SAME 
# deterministic split, and when omitted splitter.rb assigns the entire thread as a single manifest entry.  So in either case, there is not 
# any context leakage across train/val/test.

# window_range is a [start, end] index pair that records which slice of the thread's messages went into that window: so, if 
# window_0 grabbed messages 0-99 and window_1 grabbed 90-189 (with a 10-message overlap), you can trace back exactly which 
# chunk of the conversation each window covers.

# --pin YYYY-MM filters rows to cohort_id <= pin (upper-bound cutoff for materialization)
# Warns on nil cohort_id (missing stamping from mbox_pre-parser.rb)

require 'json'
require 'digest'
require 'optparse'
require 'fileutils'

# Parse CLI options
options = {
  input: nil,
  output: nil,
  manifest: 'assignments.json',
  incremental: false,
  seed: 42,
  window_size: nil,      # e.g., 100 messages per window
  window_overlap: 0,     # e.g., 10 messages overlap
  pin: nil               # e.g., '2025-01' - upper-bound cohort_id cutoff
  exclude: nil,              # Path to exclusion_ids.txt
  materialize: 'all'         # Which splits to materialize
}

OptionParser.new do |opts|
  opts.banner = "Usage: splitter.rb [options]"
  opts.on("-i", "--input DIR", "Input directory with JSON emails") { |v| options[:input] = v }
  opts.on("-o", "--output DIR", "Output directory for splits") { |v| options[:output] = v }
  opts.on("-m", "--manifest FILE", "Immutable manifest JSON (default: assignments.json)") { |v| options[:manifest] = v }
  opts.on("--incremental", "Append-only mode: only add new IDs") { options[:incremental] = true }
  opts.on("-s", "--seed SEED", Integer, "Random seed for deterministic hashing (default: 42)") { |v| options[:seed] = v }
  opts.on("--window-size SIZE", Integer, "Rolling window size (messages per chunk)") { |v| options[:window_size] = v }
  opts.on("--window-overlap OVERLAP", Integer, "Rolling window overlap (default: 0)") { |v| options[:window_overlap] = v }
  opts.on("--pin COHORT", "Cohort_id pin (YYYY-MM) - upper-bound filter for materialization") { |v| options[:pin] = v }
  opts.on("--exclude FILE", "Exclusion list (row IDs to filter out)") { |v| options[:exclude] = v }
  opts.on("--materialize SPLIT", "Materialize only specific split (train|val|test|all)") { |v| options[:materialize] = v }
end.parse!

abort "Missing -i input directory" unless options[:input]
abort "Missing -o output directory" unless options[:output]

# Validate --pin format if provided
if options[:pin] && options[:pin] !~ /^\d{4}-\d{2}$/
  abort "Error: --pin must be in YYYY-MM format (e.g., 2025-01)"
end

# Load or initialize manifest
manifest = File.exist?(options[:manifest]) ? JSON.parse(File.read(options[:manifest])) : {}

# Split ratios
TRAIN_RATIO = 0.8
VAL_RATIO = 0.1
TEST_RATIO = 0.1

# Deterministic hash-bucket assignment
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

# Load exclusion list if provided
exclusion_ids = Set.new
if options[:exclude] && File.exist?(options[:exclude])
  exclusion_ids = File.readlines(options[:exclude]).map(&:strip).to_set
  puts "Loaded #{exclusion_ids.size} exclusion IDs from #{options[:exclude]}"
end

emails = []
Dir.glob("#{options[:input]}/**/*.json").each do |file|
  data = JSON.parse(File.read(file))
  # Handle both single emails and arrays
  batch = data.is_a?(Array) ? data : [data]
  
  # Filter out excluded IDs
  batch.reject! do |e|
    row_id = e['message_id'] || e['id']
    exclusion_ids.include?(row_id)
  end
  
  emails.concat(batch)
end

excluded_count = exclusion_ids.size
puts "Loaded #{emails.size} emails (#{excluded_count} excluded)"

# Warn on nil cohort_id
nil_cohort_count = emails.count { |e| e['cohort_id'].nil? || e['cohort_id'].empty? }
if nil_cohort_count > 0
  warn "WARNING: #{nil_cohort_count} emails have nil/empty cohort_id - re-run mbox_pre-parser.rb with cohort stamping"
  warn "         These emails will be included but may cause unexpected behavior with --pin filtering"
end

# Filter by --pin if specified (cohort_id <= pin)
if options[:pin]
  original_count = emails.size
  emails = emails.select do |e|
    cohort = e['cohort_id']
    cohort.nil? || cohort.empty? || cohort <= options[:pin]
  end
  puts "Pin filter (cohort_id <= #{options[:pin]}): #{emails.size}/#{original_count} emails retained"
end

# Group by thread_id
threads = emails.group_by { |e| e['thread_id'] || e['Message-Id'] }

puts "Grouped into #{threads.size} threads"

# Process threads with optional windowing
threads.each do |thread_id, messages|
  split = nil
  
  # Check if thread already assigned
  if manifest[thread_id]
    split = manifest[thread_id]['split']
  else
    # New thread - assign deterministically
    split = assign_split(thread_id, options[:seed])
  end
  
  # If no windowing, assign entire thread
  if options[:window_size].nil?
    # Single assignment for whole thread
    unless manifest[thread_id]
      manifest[thread_id] = {
        'split' => split,
        'thread_id' => thread_id
      }
    end
  else
    # Rolling window chunking
    sorted_messages = messages.sort_by { |m| m['Date'] || '' }
    window_size = options[:window_size]
    overlap = options[:window_overlap]
    stride = window_size - overlap
    
    window_idx = 0
    pos = 0
    
    while pos < sorted_messages.size
      window_end = [pos + window_size, sorted_messages.size].min
      window_id = "#{thread_id}_window_#{window_idx}"
      
      unless manifest[window_id]
        manifest[window_id] = {
          'split' => split,  # All windows of a thread share the same split
          'thread_id' => thread_id,
          'window_idx' => window_idx,
          'window_range' => [pos, window_end]
        }
      end
      
      window_idx += 1
      pos += stride
      break if pos >= sorted_messages.size
    end
  end
end

# Save updated manifest (append-only)
File.write(options[:manifest], JSON.pretty_generate(manifest))
puts "Manifest updated: #{options[:manifest]} (#{manifest.size} IDs)"

# Materialize train/val/test lists based on --materialize option
FileUtils.mkdir_p(options[:output])

splits = { 'train' => [], 'val' => [], 'test' => [] }
manifest.each do |id, entry|
  splits[entry['split']] << entry
end

# Determine which splits to write
splits_to_write = case options[:materialize]
when 'all'
  ['train', 'val', 'test']
when 'train', 'val', 'test'
  [options[:materialize]]
else
  abort "Invalid --materialize value: #{options[:materialize]} (must be train|val|test|all)"
end

splits_to_write.each do |split_name|
  entries = splits[split_name]
  outfile = File.join(options[:output], "#{split_name}.json")
  File.write(outfile, JSON.pretty_generate(entries))
  puts "Wrote #{entries.size} IDs to #{outfile}"
end

if options[:pin]
  puts "Done. Manifest frozen for #{manifest.size} IDs (materialized #{splits_to_write.join(', ')} with pin <= #{options[:pin]})."
else
  puts "Done. Manifest frozen for #{manifest.size} IDs (materialized #{splits_to_write.join(', ')})."
end
