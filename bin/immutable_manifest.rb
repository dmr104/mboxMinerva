#!/usr/bin/env ruby
# immutable_manifest.rb - Materialize train/val/test splits from an immutable assignment manifest
#
# Usage:
#   immutable_manifest.rb materialize \
#     -manifest assignments.json \
#     -in emails \
#     -out splits \
#     [--filter-split train|val|test] \
#     [--since YYYY-MM-DD] \
#     [--gzip] \
#     [--shard-size N] \
#     [--no-overwrite] \
#     [--dry-run] \
#     [--id-key message_id]
#
# Usage:
#   ./immutable_manifest.rb assign <thread_id> [window_idx]  # get or assign a split
#   ./immutable_manifest.rb materialize                       # dump train.jsonl, val.jsonl, test.jsonl from manifest
#

# Manifest structure (assignments.json):
#   {
#     "message_abc": {"split": "train", "thread_id": "thread_123", "assigned_at": "2025-11-05T18:50:00Z"},
#     "thread_123_window_0": {"split": "val", "thread_id": "thread_123", "window_idx": 0, "assigned_at": "..."},
#     ...
#   }


require 'json'
require 'optparse'
require 'fileutils'
require 'zlib'
require 'digest'

def main
  cmd = ARGV[0]
  abort "Usage: immutable_manifest.rb <materialize|assign|stats>" unless cmd

  case cmd
  when 'materialize'
    materialize(ARGV[1..-1])
  when 'assign'
    assign(ARGV[1..-1])
  when 'stats'
    stats(ARGV[1..-1])
  else
    abort "Unknown command: #{cmd}"
  end
end

def materialize(args)
  opts = {
    manifest: nil,
    in_dir: '.',
    out_dir: 'splits',
    filter_split: nil,
    since: nil,
    gzip: false,
    shard_size: nil,
    no_overwrite: false,
    dry_run: false,
    id_key: 'message_id'
  }

  OptionParser.new do |o|
    o.banner = "Usage: immutable_manifest.rb materialize [options]"
    o.on('-m', '--manifest FILE', 'Path to assignments.json (required)') { |v| opts[:manifest] = v }
    o.on('-i', '--in DIR', 'Input directory with JSONL files (default: .)') { |v| opts[:in_dir] = v }
    o.on('-o', '--out DIR', 'Output directory for train/val/test splits (default: splits)') { |v| opts[:out_dir] = v }
    o.on('--filter-split SPLIT', 'Only materialize one split (train|val|test)') { |v| opts[:filter_split] = v }
    o.on('--since DATE', 'Only materialize records after YYYY-MM-DD') { |v| opts[:since] = v }
    o.on('--gzip', 'Compress output with gzip') { opts[:gzip] = true }
    o.on('--shard-size N', Integer, 'Max records per output shard') { |v| opts[:shard_size] = v }
    o.on('--no-overwrite', 'Abort if output files exist') { opts[:no_overwrite] = true }
    o.on('--dry-run', 'Print plan without writing') { opts[:dry_run] = true }
    o.on('--id-key KEY', 'JSON key to use as ID (default: message_id)') { |v| opts[:id_key] = v }
  end.parse!(args)

  abort "ERROR: --manifest is required" unless opts[:manifest]
  abort "ERROR: manifest not found: #{opts[:manifest]}" unless File.exist?(opts[:manifest])
  abort "ERROR: input directory not found: #{opts[:in_dir]}" unless Dir.exist?(opts[:in_dir])

  # Load manifest
  manifest = JSON.parse(File.read(opts[:manifest]))
  assignments = manifest['assignments'] || manifest
  puts "[materialize] Loaded #{assignments.size} assignments from #{opts[:manifest]}"

  # Prepare output
  FileUtils.mkdir_p(opts[:out_dir]) unless opts[:dry_run]
  splits = opts[:filter_split] ? [opts[:filter_split]] : %w[train val test]
  
  if opts[:no_overwrite]
    splits.each do |split|
      ext = opts[:gzip] ? '.jsonl.gz' : '.jsonl'
      path = File.join(opts[:out_dir], "#{split}#{ext}")
      abort "ERROR: output exists (use --no-overwrite=false): #{path}" if File.exist?(path)
    end
  end

  # Open output handles
  writers = {}
  shard_counts = {}
  shard_indices = {}
  
  unless opts[:dry_run]
    splits.each do |split|
      shard_indices[split] = 0
      shard_counts[split] = 0
      writers[split] = open_writer(opts[:out_dir], split, 0, opts[:gzip], opts[:shard_size])
    end
  end

  # Stream input files
  input_files = Dir.glob(File.join(opts[:in_dir], '*.json')) + 
                Dir.glob(File.join(opts[:in_dir], '*.jsonl')) +
                Dir.glob(File.join(opts[:in_dir], '*.jsonl.gz'))
  
  abort "ERROR: no input files found in #{opts[:in_dir]}" if input_files.empty?
  
  total = 0
  routed = Hash.new(0)
  skipped = 0

  input_files.sort.each do |path|
    puts "[materialize] Processing #{path}..."
    
    reader = path.end_with?('.gz') ? Zlib::GzipReader.open(path) : File.open(path)
    reader.each_line do |line|
      line.strip!
      next if line.empty?
      
      record = JSON.parse(line)
      id = record[opts[:id_key]]
      
      unless id
        warn "WARN: missing #{opts[:id_key]} in record, skipping"
        skipped += 1
        next
      end
      
      assignment = assignments[id]
      unless assignment
        warn "WARN: no assignment for ID=#{id}, skipping"
        skipped += 1
        next
      end
      
      split = assignment['split']
      unless splits.include?(split)
        skipped += 1
        next
      end
      
      total += 1
      routed[split] += 1
      
      unless opts[:dry_run]
        # Check if we need to rotate shard
        if opts[:shard_size] && shard_counts[split] >= opts[:shard_size]
          writers[split].close
          shard_indices[split] += 1
          shard_counts[split] = 0
          writers[split] = open_writer(opts[:out_dir], split, shard_indices[split], opts[:gzip], opts[:shard_size])
        end
        
        writers[split].puts(line)
        shard_counts[split] += 1
      end
    end
    reader.close
  end

  # Close all writers
  writers.each { |_, w| w.close } unless opts[:dry_run]

  # Report
  puts "\n[materialize] Complete!"
  puts "  Total records: #{total}"
  routed.each { |split, count| puts "    #{split}: #{count}" }
  puts "  Skipped: #{skipped}" if skipped > 0
  puts "  Output: #{opts[:out_dir]}" unless opts[:dry_run]
  puts "  (DRY RUN - no files written)" if opts[:dry_run]
end

def open_writer(out_dir, split, shard_idx, gzip, shard_size)
  ext = gzip ? '.jsonl.gz' : '.jsonl'
  suffix = shard_size ? ".#{shard_idx.to_s.rjust(4, '0')}" : ''
  path = File.join(out_dir, "#{split}#{suffix}#{ext}")
  
  file = File.open(path, 'w')
  gzip ? Zlib::GzipWriter.new(file) : file
end

def assign(args)
  opts = {
    manifest: nil,
    in_dir: '.',
    splits: [0.8, 0.1, 0.1],
    seed: 42,
    incremental: false,
    window_size: nil,
    window_overlap: 0,
    id_key: 'message_id',
    thread_key: 'thread_id'
  }

  OptionParser.new do |o|
    o.banner = "Usage: immutable_manifest.rb assign [options]"
    o.on('-m', '--manifest FILE', 'Path to assignments.json') { |v| opts[:manifest] = v }
    o.on('-i', '--in DIR', 'Input directory with JSONL files (default: .)') { |v| opts[:in_dir] = v }
    o.on('-s', '--seed N', Integer, 'Random seed (default: 42)') { |v| opts[:seed] = v }
    o.on('--splits A,B,C', 'Train/val/test ratios (default: 0.8,0.1,0.1)') do |v|
      opts[:splits] = v.split(',').map(&:to_f)
    end
    o.on('--incremental', 'Append new assignments, preserve existing') { opts[:incremental] = true }
    o.on('--window-size N', Integer, 'Create sliding windows of N messages') { |v| opts[:window_size] = v }
    o.on('--window-overlap N', Integer, 'Window overlap (default: 0)') { |v| opts[:window_overlap] = v }
    o.on('--id-key KEY', 'JSON key for message ID') { |v| opts[:id_key] = v }
    o.on('--thread-key KEY', 'JSON key for thread ID') { |v| opts[:thread_key] = v }
  end.parse!(args)

  abort "ERROR: --manifest is required" unless opts[:manifest]
  
  # Load existing manifest if incremental
  existing = {}
  if opts[:incremental] && File.exist?(opts[:manifest])
    data = JSON.parse(File.read(opts[:manifest]))
    existing = data['assignments'] || data
    puts "[assign] Loaded #{existing.size} existing assignments"
  end

  # Collect threads
  threads = Hash.new { |h, k| h[k] = [] }
  
  input_files = Dir.glob(File.join(opts[:in_dir], '*.json')) + 
                Dir.glob(File.join(opts[:in_dir], '*.jsonl'))
  
  abort "ERROR: no input files in #{opts[:in_dir]}" if input_files.empty?
  
  input_files.each do |path|
    File.readlines(path).each do |line|
      line.strip!
      next if line.empty?
      record = JSON.parse(line)
      id = record[opts[:id_key]]
      thread_id = record[opts[:thread_key]] || id
      threads[thread_id] << { id: id, record: record }
    end
  end

  puts "[assign] Found #{threads.size} threads"

  # Assign threads
  new_count = 0
  train_quota = (threads.size * opts[:splits][0]).round
  val_quota = (threads.size * opts[:splits][1]).round
  
  train_count = existing.values.count { |a| a['split'] == 'train' }
  val_count = existing.values.count { |a| a['split'] == 'val' }
  test_count = existing.values.count { |a| a['split'] == 'test' }

  threads.keys.sort.each do |thread_id|
    # Check if thread already assigned
    sample_id = threads[thread_id].first[:id]
    if existing[sample_id]
      next  # Skip, already assigned
    end

    # Deterministic hash bucket
    hash = Digest::SHA256.hexdigest("#{opts[:seed]}:#{thread_id}")[0..7].to_i(16)
    bucket = hash % 1000
    
    split = if train_count < train_quota && bucket < (opts[:splits][0] * 1000)
              train_count += 1
              'train'
            elsif val_count < val_quota && bucket < ((opts[:splits][0] + opts[:splits][1]) * 1000)
              val_count += 1
              'val'
            else
              test_count += 1
              'test'
            end

    # Assign messages or windows
    if opts[:window_size]
      messages = threads[thread_id].sort_by { |m| m[:record]['date'] || '' }
      step = opts[:window_size] - opts[:window_overlap]
      window_idx = 0
      
      (0...messages.size).step(step).each do |start_idx|
        window = messages[start_idx, opts[:window_size]]
        window.each do |msg|
          window_id = "#{thread_id}:w#{window_idx}"
          existing[msg[:id]] = {
            'split' => split,
            'thread_id' => thread_id,
            'window_id' => window_id,
            'window_idx' => window_idx
          }
          new_count += 1
        end
        window_idx += 1
      end
    else
      threads[thread_id].each do |msg|
        existing[msg[:id]] = {
          'split' => split,
          'thread_id' => thread_id
        }
        new_count += 1
      end
    end
  end

  # Write manifest
  output = {
    'seed' => opts[:seed],
    'splits' => { 'train' => opts[:splits][0], 'val' => opts[:splits][1], 'test' => opts[:splits][2] },
    'total_assignments' => existing.size,
    'assignments' => existing
  }
  
  File.write(opts[:manifest], JSON.pretty_generate(output))
  
  puts "[assign] Wrote #{existing.size} assignments (#{new_count} new)"
  puts "  train: #{train_count}, val: #{val_count}, test: #{test_count}"
end

def stats(args)
  opts = { manifest: nil }
  
  OptionParser.new do |o|
    o.on('-m', '--manifest FILE', 'Path to assignments.json') { |v| opts[:manifest] = v }
  end.parse!(args)
  
  abort "ERROR: --manifest required" unless opts[:manifest]
  abort "ERROR: manifest not found: #{opts[:manifest]}" unless File.exist?(opts[:manifest])
  
  data = JSON.parse(File.read(opts[:manifest]))
  assignments = data['assignments'] || data
  
  splits = Hash.new(0)
  threads = Hash.new { |h, k| h[k] = Hash.new(0) }
  
  assignments.each do |id, meta|
    split = meta['split']
    thread_id = meta['thread_id']
    splits[split] += 1
    threads[split][thread_id] += 1
  end
  
  puts "[stats] Manifest: #{opts[:manifest]}"
  puts "  Total assignments: #{assignments.size}"
  splits.each do |split, count|
    thread_count = threads[split].size
    puts "  #{split}: #{count} messages, #{thread_count} threads"
  end
end

main if __FILE__ == $PROGRAM_NAME