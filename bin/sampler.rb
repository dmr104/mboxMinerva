#!/usr/bin/env ruby
# Stratified Replay Sampler for LoRA CPT with CLI
# ================================================
# 
# WHAT THIS DOES:
# - Stratifies old training data by sender → thread_id
# - Ensures rare buckets get minimum representation (--min-per-bucket, default 2)
# - Fills remaining slots proportionally by sender/thread distribution
# - Interleaves sampled replay data with new training data at --replay-ratio (default 1:4)
# - Uses DETERMINISTIC SHA256-seeded RNG for reproducible shuffles across runs
#
# KEY PRINCIPLE: All randomness is deterministic via --seed (default "stratified_replay_v1")
# and --epoch N. Same seed + epoch = identical sample order, enabling reproducible training.
#
# CLI EXAMPLES:
#   # Basic: interleave old_shards_train.json with new window's train split
#   ./sampler.rb old_shards_train.json new_window_train.json -o epoch_000.json --seed my_seed --epoch 0
#
#   # Adjust replay:new ratio to 1:2 (more replay, slower forgetting)
#   ./sampler.rb old_shards_train.json new_window_train.json --replay-ratio 1:2 --seed my_seed --epoch 1
#
#   # Increase min-per-bucket to 5 for rare sender/thread combinations
#   ./sampler.rb old_shards_train.json new_window_train.json --min-per-bucket 5 --seed my_seed --epoch 2
#
# DETERMINISTIC RNG:
# - All .shuffle and .sample calls use rng = Random.new(sha256_int_seed)
# - sha256_int_seed = SHA256(seed + epoch + context).to_i(16) % (2**32)
# - Different contexts ("phase1_sample", "phase2_sample", "final_shuffle", etc.) ensure
#   independent streams even within the same epoch
#
# USAGE WITH RETRAIN PIPELINE:
#   for epoch in 0 1 2 3 4; do
#     ./sampler.rb old_shards_train.json new_train.json -o epoch_$(printf "%03d" $epoch).json \
#       --seed "CPT_2025Q4" --epoch $epoch
#     ./train.rb epoch_$(printf "%03d" $epoch).json --checkpoint output/checkpoint_$epoch.pt
#   done

require 'json'
require 'optparse'
require 'digest'

class StratifiedReplaySampler
  def initialize(old_train_data, min_per_bucket: 2, seed: "stratified_replay_v1", epoch: 0)
    @min_per_bucket = min_per_bucket
    @seed = seed
    @epoch = epoch
    
    # Build buckets: sender -> thread -> [samples]
    @buckets = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
    old_train_data.each do |sample|
      sender = sample[:sender] || sample["sender"]
      thread = sample[:thread_id] || sample["thread_id"]
      @buckets[sender][thread] << sample
    end
    
    # Count total samples per sender and globally
    @sender_totals = @buckets.transform_values { |threads| threads.values.sum(&:size) }
    @global_total = @sender_totals.values.sum
    
    puts "Initialized with #{@buckets.size} senders, #{@buckets.values.sum(&:size)} threads, #{@global_total} samples"
    puts "RNG seed: \"#{@seed}\", epoch: #{@epoch}"
  end
  
  # Deterministic RNG factory
  def make_rng(context)
    seed_str = "#{@seed}:#{@epoch}:#{context}"
    hash_int = Digest::SHA256.hexdigest(seed_str).to_i(16) % (2**32)
    Random.new(hash_int)
  end
  
  def sample(n)
    result = []
    rng_phase1 = make_rng("phase1_sample")
    rng_phase2 = make_rng("phase2_sample")
    
    # Phase 1: Ensure minimum representation for each bucket
    bucket_index = 0
    @buckets.each do |sender, threads|
      threads.each do |thread, samples|
        take = [@min_per_bucket, samples.size, n - result.size].min
        # Deterministic sampling per bucket
        bucket_rng = make_rng("phase1_bucket_#{bucket_index}")
        result.concat(samples.sample(take, random: bucket_rng))
        bucket_index += 1
        break if result.size >= n
      end
      break if result.size >= n
    end
    
    # Phase 2: Fill remaining slots proportionally
    remaining = n - result.size
    if remaining > 0
      sender_index = 0
      @buckets.each do |sender, threads|
        sender_quota = (remaining * @sender_totals[sender].to_f / @global_total).ceil
        
        thread_index = 0
        threads.each do |thread, samples|
          thread_weight = samples.size.to_f / @sender_totals[sender]
          take = [(sender_quota * thread_weight).ceil, samples.size, n - result.size].min
          # Deterministic sampling per thread
          thread_rng = make_rng("phase2_sender_#{sender_index}_thread_#{thread_index}")
          result.concat(samples.sample(take, random: thread_rng))
          thread_index += 1
          break if result.size >= n
        end
        sender_index += 1
        break if result.size >= n
      end
    end
    
    # Deterministic final shuffle
    rng_final = make_rng("final_shuffle")
    result.shuffle(random: rng_final).take(n)
  end
end

# CLI interface
if __FILE__ == $0
  options = {
    replay_ratio: "1:4",  # replay:new default
    batch_size: 16,
    min_per_bucket: 2,
    output: nil,
    seed: "stratified_replay_v1",
    epoch: 0
  }
  
  OptionParser.new do |opts|
    opts.banner = "Usage: #{$0} OLD_TRAIN.json NEW_TRAIN.json [options]"
    
    opts.on("--replay-ratio RATIO", "Replay:new ratio (default: 1:4)") do |r|
      options[:replay_ratio] = r
    end
    
    opts.on("--batch-size N", Integer, "Batch size (default: 16)") do |n|
      options[:batch_size] = n
    end
    
    opts.on("--min-per-bucket N", Integer, "Min samples per bucket (default: 2)") do |n|
      options[:min_per_bucket] = n
    end
    
    opts.on("--seed SEED", "RNG seed for deterministic sampling (default: stratified_replay_v1)") do |s|
      options[:seed] = s
    end
    
    opts.on("--epoch N", Integer, "Epoch number for RNG (default: 0)") do |e|
      options[:epoch] = e
    end
    
    opts.on("-o", "--output FILE", "Output file (default: STDOUT)") do |f|
      options[:output] = f
    end
    
    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit
    end
  end.parse!
  
  if ARGV.size < 2
    puts "Error: Need OLD_TRAIN.json and NEW_TRAIN.json"
    puts "Usage: #{$0} OLD_TRAIN.json NEW_TRAIN.json [options]"
    exit 1
  end
  
  old_train_file, new_train_file = ARGV
  
  # Parse replay:new ratio
  replay_parts, new_parts = options[:replay_ratio].split(':').map(&:to_i)
  
  puts "Loading old training data from #{old_train_file}..."
  old_train = JSON.parse(File.read(old_train_file))
  
  puts "Loading new training data from #{new_train_file}..."
  new_data = JSON.parse(File.read(new_train_file))
  
  sampler = StratifiedReplaySampler.new(
    old_train,
    min_per_bucket: options[:min_per_bucket],
    seed: options[:seed],
    epoch: options[:epoch]
  )
  
  # Interleave new data with replay batches
  batches = []
  batch_size = options[:batch_size]
  
  new_data.each_slice(batch_size * new_parts).with_index do |new_chunk, chunk_idx|
    batches << new_chunk
    replay_count = (batch_size * replay_parts * new_chunk.size.to_f / (batch_size * new_parts)).ceil
    replay_batch = sampler.sample(replay_count)
    batches << replay_batch
  end
  
  # Flatten and shuffle for training (deterministic)
  rng_interleave = Random.new(
    Digest::SHA256.hexdigest("#{options[:seed]}:#{options[:epoch]}:interleave_shuffle").to_i(16) % (2**32)
  )
  training_data = batches.flatten.shuffle(random: rng_interleave)
  
  puts "Generated #{training_data.size} training samples (#{new_data.size} new + replay)"
  
  output = JSON.pretty_generate(training_data)
  
  if options[:output]
    File.write(options[:output], output)
    puts "Wrote to #{options[:output]}"
  else
    puts output
  end
end