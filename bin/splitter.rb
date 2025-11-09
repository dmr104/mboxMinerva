#!/usr/bin/env ruby
# splitter.rb - Immutable, deterministic train/val/test split with rolling-window support
# Usage: splitter.rb -i emails_dir -o output_dir -manifest assignments.json [-incremental] [-s seed] [--window-size N] [--window-overlap M]

# Each thread_id gets ONE frozen split, and all its windows inherit that split, so overlap duplicates data
# within train (or val, or test) for better context coverage, but never leak's the same thread's context across
# splits.  It is split-pure by design.  

# A thread's "context" = the entire conversation for a thread ; so splitter assigns at thread_id, and chunks from that thread
# never cross thread/val/test

# splitter.rb groups by thread_id, hashes with a deterministic seed to assign train/val/test (80/10/10), writes immutable 
# assignments.json, and crucially when --window-size is enabled, ALL windows of a thread inherit the SAME split "All windows of a 
# thread share the same split", so there is not any context leakage across train/val/test

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
  window_overlap: 0      # e.g., 10 messages overlap
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
end.parse!

abort "Missing -i input directory" unless options[:input]
abort "Missing -o output directory" unless options[:output]

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

# Load all emails from input directory
emails = []
Dir.glob("#{options[:input]}/**/*.json").each do |file|
  data = JSON.parse(File.read(file))
  # Handle both single emails and arrays
  emails.concat(data.is_a?(Array) ? data : [data])
end

puts "Loaded #{emails.size} emails"

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

# Materialize train/val/test lists
FileUtils.mkdir_p(options[:output])

splits = { 'train' => [], 'val' => [], 'test' => [] }
manifest.each do |id, entry|
  splits[entry['split']] << entry
end

splits.each do |split_name, entries|
  outfile = File.join(options[:output], "#{split_name}.json")
  File.write(outfile, JSON.pretty_generate(entries))
  puts "Wrote #{entries.size} IDs to #{outfile}"
end

puts "Done. Manifest frozen for #{manifest.size} IDs."