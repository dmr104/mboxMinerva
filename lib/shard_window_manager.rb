# shard_window_manager.rb - Maintains old_train.json as a stratified moving window of recent train shards
#
# Usage:
#   ruby shard_window_manager.rb --shard-dir data/train_shards --output old_train.json --window-size 5 --max-pool-size 20000
#   ruby shard_window_manager.rb --watch --shard-dir data/train_shards --output old_train.json --window-size 5

require 'json'
require 'fileutils'
require 'digest'
require 'optparse'
require 'set'

# Parse CLI arguments
options = {
  shard_dir: 'data/train_shards',
  output: 'old_train.json',
  window_size: 5,              # Keep last N shards
  max_pool_size: nil,          # Optional: downsample to this many emails total (nil = no limit)
  min_per_sender: 2,           # Minimum emails per sender when downsampling
  min_per_thread: 1,           # Minimum emails per thread when downsampling
  watch: false,                # Watch mode: poll for new shards
  watch_interval: 60,          # Seconds between polls in watch mode
  seed: 42                     # Random seed for reproducible stratified sampling
}

OptionParser.new do |opts|
  opts.banner = "Usage: shard_window_manager.rb [options]"
  
  opts.on("--shard-dir DIR", "Directory containing train_shard_*.jsonl files (default: data/train_shards)") do |v|
    options[:shard_dir] = v
  end
  
  opts.on("--output FILE", "Output file for concatenated window (default: old_train.json)") do |v|
    options[:output] = v
  end
  
  opts.on("--window-size N", Integer, "Number of most recent shards to keep (default: 5)") do |v|
    options[:window_size] = v
  end
  
  opts.on("--max-pool-size N", Integer, "Downsample to max N emails using stratified sampling (optional)") do |v|
    options[:max_pool_size] = v
  end
  
  opts.on("--min-per-sender N", Integer, "Minimum emails per sender when downsampling (default: 2)") do |v|
    options[:min_per_sender] = v
  end
  
  opts.on("--min-per-thread N", Integer, "Minimum emails per thread when downsampling (default: 1)") do |v|
    options[:min_per_thread] = v
  end
  
  opts.on("--watch", "Watch mode: continuously poll for new shards") do
    options[:watch] = true
  end
  
  opts.on("--watch-interval N", Integer, "Seconds between polls in watch mode (default: 60)") do |v|
    options[:watch_interval] = v
  end
  
  opts.on("--seed N", Integer, "Random seed for reproducible sampling (default: 42)") do |v|
    options[:seed] = v
  end
  
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

# Ensure shard directory exists
FileUtils.mkdir_p(options[:shard_dir])

# Load JSONL records from file
def load_jsonl(path)
  return [] unless File.exist?(path)
  File.readlines(path).map { |line| JSON.parse(line.strip) }
rescue => e
  warn "Error loading #{path}: #{e.message}"
  []
end

# Write JSONL records to file atomically
def write_jsonl(path, records)
  tmp = "#{path}.tmp.#{Process.pid}"
  File.open(tmp, 'w') do |f|
    records.each { |rec| f.puts(JSON.generate(rec)) }
  end
  File.rename(tmp, path)
ensure
  File.delete(tmp) if File.exist?(tmp)
end

# Find all train shard files sorted by mtime (newest first)
def find_shards(dir)
  pattern = File.join(dir, 'train_shard_*.jsonl')
  Dir.glob(pattern).sort_by { |f| File.mtime(f) }.reverse
end

# Stratified downsample to target size
def stratified_sample(records, target_size, min_per_sender, min_per_thread, seed)
  return records if records.size <= target_size
  
  rng = Random.new(seed)
  
  # Group by sender and thread
  sender_buckets = Hash.new { |h, k| h[k] = [] }
  thread_buckets = Hash.new { |h, k| h[k] = [] }
  
  records.each do |rec|
    sender = rec['sender'] || rec[:sender] || 'unknown'
    thread = rec['thread_id'] || rec[:thread_id] || 'unknown'
    sender_buckets[sender] << rec
    thread_buckets[thread] << rec
  end
  
  # Allocate minimums
  selected = Set.new
  
  # Per-sender minimums
  sender_buckets.each do |sender, bucket|
    n = [min_per_sender, bucket.size, target_size - selected.size].min
    bucket.shuffle(random: rng).take(n).each do |rec|
      selected << rec['message_id'] || rec[:message_id]
    end
  end
  
  # Per-thread minimums (skip if already selected)
  thread_buckets.each do |thread, bucket|
    n = [min_per_thread, bucket.size, target_size - selected.size].min
    bucket.shuffle(random: rng).reject { |rec| selected.include?(rec['message_id'] || rec[:message_id]) }
          .take(n).each do |rec|
      selected << rec['message_id'] || rec[:message_id]
    end
    break if selected.size >= target_size
  end
  
  # Fill remaining budget proportionally by sender
  remaining = target_size - selected.size
  if remaining > 0
    total_remaining = sender_buckets.sum { |_, bucket| bucket.count { |rec| !selected.include?(rec['message_id'] || rec[:message_id]) } }
    
    sender_buckets.each do |sender, bucket|
      available = bucket.reject { |rec| selected.include?(rec['message_id'] || rec[:message_id]) }
      next if available.empty?
      
      allocation = [(available.size.to_f / total_remaining * remaining).ceil, available.size].min
      available.shuffle(random: rng).take(allocation).each do |rec|
        selected << rec['message_id'] || rec[:message_id]
      end
      
      break if selected.size >= target_size
    end
  end
  
  records.select { |rec| selected.include?(rec['message_id'] || rec[:message_id]) }
end

# Main update logic
def update_old_train(options)
  shards = find_shards(options[:shard_dir])
  
  if shards.empty?
    warn "No train shards found in #{options[:shard_dir]}"
    return
  end
  
  # Take last N shards (most recent window)
  window_shards = shards.take(options[:window_size])
  
  puts "Found #{shards.size} total shards, using #{window_shards.size} most recent:"
  window_shards.each { |s| puts "  - #{File.basename(s)} (#{File.mtime(s)})" }
  
  # Load and concatenate all records in window
  all_records = []
  seen_ids = Set.new
  
  window_shards.reverse.each do |shard|  # Oldest to newest
    records = load_jsonl(shard)
    records.each do |rec|
      msg_id = rec['message_id'] || rec[:message_id]
      next if seen_ids.include?(msg_id)
      seen_ids << msg_id
      all_records << rec
    end
  end
  
  puts "Loaded #{all_records.size} unique emails from window"
  
  # Optional: downsample using stratified sampling
  if options[:max_pool_size] && all_records.size > options[:max_pool_size]
    puts "Downsampling from #{all_records.size} to #{options[:max_pool_size]} using stratified sampling..."
    all_records = stratified_sample(
      all_records,
      options[:max_pool_size],
      options[:min_per_sender],
      options[:min_per_thread],
      options[:seed]
    )
    puts "After downsampling: #{all_records.size} emails"
  end
  
  # Write atomically
  write_jsonl(options[:output], all_records)
  
  puts "✓ Wrote #{all_records.size} emails to #{options[:output]}"
  
  # Print stats
  senders = all_records.map { |r| r['sender'] || r[:sender] }.uniq.size
  threads = all_records.map { |r| r['thread_id'] || r[:thread_id] }.uniq.size
  puts "  #{senders} unique senders, #{threads} unique threads"
end

# Run once or watch loop
if options[:watch]
  puts "Watch mode: polling #{options[:shard_dir]} every #{options[:watch_interval]}s"
  puts "Press Ctrl-C to stop"
  
  last_shards = nil
  
  loop do
    current_shards = find_shards(options[:shard_dir])
    
    if current_shards != last_shards
      puts "\n[#{Time.now}] Detected shard changes, updating..."
      update_old_train(options)
      last_shards = current_shards
    end
    
    sleep(options[:watch_interval])
  end
else
  update_old_train(options)
end