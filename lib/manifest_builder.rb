# frozen_string_literal: true

# manifest_builder.rb - Rehearsal Manifest Generator
#
# PURPOSE:
#   Reads assignments.json (immutable train/val/test split ground truth),
#   filters train chunk_ids from shards OUTSIDE the current rolling window,
#   applies stratified sampling with length-bucketing and per-bucket caps,
#   and emits old_shards_train.json (the "rehearsal manifest").
#
# USAGE:
#   ./manifest_builder.rb \
#     --assignments assignments.json \
#     --length-metadata length_metadata.json \
#     --window-idx current_window.json \
#     --output old_shards_train.json \
#     --seed 42 \
#     --bucket-caps '{"short":100,"medium":200,"long":50}' \
#     --max-total 500 \
#     [--include-n-minus-1]
#
# ARGUMENTS:
#   --assignments         Path to assignments.json (chunk_id → split mapping)
#   --length-metadata     Path to length_metadata.json (chunk_id → {length, sender, thread_id})
#   --window-idx          Path to current_window.json (list of chunk_ids in active rolling window)
#   --output              Path to write rehearsal manifest (old_shards_train.json)
#   --seed                Integer RNG seed for deterministic sampling
#   --bucket-caps         JSON hash of bucket→cap (e.g., {"short":100,"medium":200,"long":50})
#   --max-total           Global cap on total rehearsal chunks (applied after per-bucket caps)
#   --include-n-minus-1   Optional: include train IDs from N-1 window for continuity
#
# OUTPUT:
#   old_shards_train.json: Array of chunk_ids stratified by length bucket,
#                          capped per-bucket and globally, deterministically shuffled.
#
# ALGORITHM:
#   1. Load assignments.json and filter to train split
#   2. Load current window_idx and exclude those chunk_ids (optionally keep N-1)
#   3. Load length_metadata and classify each chunk into length bucket (short/medium/long)
#   4. For each bucket, sample up to cap using deterministic SHA256-seeded RNG
#   5. Merge buckets, shuffle globally with seed, apply max-total cap
#   6. Write deterministic rehearsal manifest to output path
#
# DETERMINISM:
#   All sampling uses SHA256(seed:bucket:chunk_id) mod 2^32 → Random.new(seed_int)
#   to ensure reproducible rehearsal sets across runs with same inputs + seed.

require 'json'
require 'digest/sha256'
require 'optparse'

# Parse CLI arguments
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: manifest_builder.rb [options]"
  opts.on("--assignments PATH", "Path to assignments.json") { |v| options[:assignments] = v }
  opts.on("--length-metadata PATH", "Path to length_metadata.json") { |v| options[:length_metadata] = v }
  opts.on("--window-idx PATH", "Path to current_window.json") { |v| options[:window_idx] = v }
  opts.on("--output PATH", "Output path for old_shards_train.json") { |v| options[:output] = v }
  opts.on("--seed SEED", Integer, "RNG seed") { |v| options[:seed] = v }
  opts.on("--bucket-caps JSON", "Per-bucket caps as JSON hash") { |v| options[:bucket_caps] = JSON.parse(v) }
  opts.on("--max-total N", Integer, "Global max rehearsal chunks") { |v| options[:max_total] = v }
  opts.on("--include-n-minus-1", "Include N-1 window for continuity") { options[:include_n_minus_1] = true }
end.parse!

[:assignments, :length_metadata, :window_idx, :output, :seed, :bucket_caps, :max_total].each do |key|
  abort "Missing required argument: --#{key.to_s.tr('_', '-')}" unless options[key]
end

# Load inputs
assignments = JSON.parse(File.read(options[:assignments]))
length_metadata = JSON.parse(File.read(options[:length_metadata]))
current_window = JSON.parse(File.read(options[:window_idx]))

# Filter train IDs outside current window
train_ids = assignments.select { |id, split| split == 'train' }.keys
excluded_ids = Set.new(current_window)
past_train_ids = train_ids.reject { |id| excluded_ids.include?(id) }

puts "Total train IDs: #{train_ids.size}"
puts "Current window IDs: #{excluded_ids.size}"
puts "Past train IDs (rehearsal candidates): #{past_train_ids.size}"

# Classify into length buckets
BUCKET_THRESHOLDS = { 'short' => 0..512, 'medium' => 513..2048, 'long' => 2049..Float::INFINITY }
buckets = Hash.new { |h, k| h[k] = [] }

past_train_ids.each do |chunk_id|
  meta = length_metadata[chunk_id]
  abort "Missing length_metadata for chunk #{chunk_id}" unless meta
  length = meta['length']
  bucket = BUCKET_THRESHOLDS.find { |name, range| range.include?(length) }&.first || 'long'
  buckets[bucket] << chunk_id
end

puts "Bucket distribution: #{buckets.transform_values(&:size)}"

# Deterministic sampling per bucket
def deterministic_sample(array, n, seed, context)
  digest = Digest::SHA256.hexdigest("#{seed}:#{context}")
  rng = Random.new(digest.to_i(16) % (2**32))
  array.shuffle(random: rng).take(n)
end

sampled_buckets = {}
options[:bucket_caps].each do |bucket_name, cap|
  candidates = buckets[bucket_name] || []
  sampled = deterministic_sample(candidates, [cap, candidates.size].min, options[:seed], bucket_name)
  sampled_buckets[bucket_name] = sampled
  puts "Sampled #{sampled.size} from bucket '#{bucket_name}' (cap: #{cap}, available: #{candidates.size})"
end

# Merge and apply global cap
merged = sampled_buckets.values.flatten
puts "Merged rehearsal chunks: #{merged.size}"

# Global shuffle and cap
final_rehearsal = deterministic_sample(merged, [options[:max_total], merged.size].min, options[:seed], "global")
puts "Final rehearsal manifest size: #{final_rehearsal.size} (global cap: #{options[:max_total]})"

# Write output
File.write(options[:output], JSON.pretty_generate(final_rehearsal))
puts "Wrote rehearsal manifest to #{options[:output]}"
