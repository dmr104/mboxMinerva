# frozen_string_literal: true

# dataloader.rb - Deterministic Batch Iterator (with DSR tombstone filtering)
#
# PURPOSE:
#   Consumes a training schedule (epoch_schedule.json from sampler.rb),
#   yields batches of chunk_ids deterministically, with optional shuffling
#   within each batch (for local GPU batch variance without breaking global schedule).
#   Automatically filters out tombstoned records if vault/dsr_tombstones.jsonl exists.
#
# USAGE (as library):
#   require_relative 'dataloader'
#   loader = DataLoader.new(
#     schedule_path: 'epoch_00001_schedule.json',
#     batch_size: 32,
#     shuffle_within_batch: true,
#     seed: 42,
#     respect_tombstones: true,        # default: true
#     tombstones_path: 'vault/dsr_tombstones.jsonl'  # default
#   )
#   loader.each_batch do |batch_chunk_ids|
#     # Train on batch_chunk_ids (tombstoned records already filtered out)
#     puts "Processing batch: #{batch_chunk_ids.inspect}"
#   end
#
# USAGE (CLI demo):
#   ./dataloader.rb \
#     --schedule epoch_00001_schedule.json \
#     --batch-size 32 \
#     --seed 42 \
#     [--shuffle-within-batch] \
#     [--no-respect-tombstones]
#
# ARGUMENTS:
#   --schedule            Path to epoch schedule JSON (array of chunk_ids from sampler.rb)
#   --batch-size          Number of chunks per batch
#   --seed                Integer RNG seed for deterministic within-batch shuffling
#   --shuffle-within-batch  Optional: shuffle chunk order within each batch
#   --no-respect-tombstones Optional: disable tombstone filtering (default: enabled)
#   --tombstones-path     Override tombstones file path (default: vault/dsr_tombstones.jsonl)
#
# OUTPUT:
#   Iterates over schedule in deterministic batches, optionally shuffling within each.
#   In CLI mode, prints each batch to stdout for inspection.
#
# INTEGRATION:
#   retrain.rb imports this as a library and calls DataLoader#each_batch,
#   passing each batch to Trainer#train_step.

require 'json'
require 'digest/sha256'
require 'optparse'

class DataLoader
  attr_reader :schedule, :batch_size, :shuffle_within_batch, :seed, :respect_tombstones

  def initialize(schedule_path:, batch_size:, shuffle_within_batch: false, seed: 42, 
                 respect_tombstones: true, tombstones_path: 'vault/dsr_tombstones.jsonl')
    @schedule = JSON.parse(File.read(schedule_path))
    @batch_size = batch_size
    @shuffle_within_batch = shuffle_within_batch
    @seed = seed
    @respect_tombstones = respect_tombstones
    @tombstones_path = tombstones_path
    
    # Load tombstones if filtering is enabled
    @tombstoned_chunks = load_tombstoned_chunks if @respect_tombstones
    
    # Filter schedule upfront if tombstones exist
    filter_schedule! if @respect_tombstones && @tombstoned_chunks && !@tombstoned_chunks.empty?
  end

  def each_batch
    @schedule.each_slice(@batch_size).with_index do |batch, batch_idx|
      batch = shuffle_batch(batch, batch_idx) if @shuffle_within_batch
      yield batch
    end
  end

  private

  def load_tombstoned_chunks
    return Set.new unless File.exist?(@tombstones_path)
    
    tombstoned = Set.new
    File.readlines(@tombstones_path).each do |line|
      record = JSON.parse(line.strip)
      # Tombstone records contain chunk_id field
      tombstoned.add(record['chunk_id']) if record['chunk_id']
    rescue JSON::ParserError => e
      warn "Warning: Skipping malformed tombstone line: #{e.message}"
    end
    
    if tombstoned.any?
      warn "DataLoader: Loaded #{tombstoned.size} tombstoned chunks from #{@tombstones_path}"
    end
    
    tombstoned
  end

  def filter_schedule!
    original_size = @schedule.size
    @schedule.reject! { |chunk_id| @tombstoned_chunks.include?(chunk_id) }
    filtered_count = original_size - @schedule.size
    
    if filtered_count > 0
      warn "DataLoader: Filtered out #{filtered_count} tombstoned chunks (#{original_size} → #{@schedule.size})"
    end
  end

  def shuffle_batch(batch, batch_idx)
    digest = Digest::SHA256.hexdigest("#{@seed}:batch:#{batch_idx}")
    rng = Random.new(digest.to_i(16) % (2**32))
    batch.shuffle(random: rng)
  end
end

# CLI demo mode
if __FILE__ == $PROGRAM_NAME
  options = { respect_tombstones: true, tombstones_path: 'vault/dsr_tombstones.jsonl' }
  OptionParser.new do |opts|
    opts.banner = "Usage: dataloader.rb [options]"
    opts.on("--schedule PATH", "Path to epoch schedule JSON") { |v| options[:schedule] = v }
    opts.on("--batch-size N", Integer, "Batch size") { |v| options[:batch_size] = v }
    opts.on("--seed SEED", Integer, "RNG seed") { |v| options[:seed] = v }
    opts.on("--shuffle-within-batch", "Shuffle within each batch") { options[:shuffle] = true }
    opts.on("--no-respect-tombstones", "Disable tombstone filtering") { options[:respect_tombstones] = false }
    opts.on("--tombstones-path PATH", "Override tombstones file path") { |v| options[:tombstones_path] = v }
  end.parse!

  [:schedule, :batch_size, :seed].each do |key|
    abort "Missing required argument: --#{key.to_s.tr('_', '-')}" unless options[key]
  end

  loader = DataLoader.new(
    schedule_path: options[:schedule],
    batch_size: options[:batch_size],
    shuffle_within_batch: options[:shuffle] || false,
    seed: options[:seed],
    respect_tombstones: options[:respect_tombstones],
    tombstones_path: options[:tombstones_path]
  )

  puts "DataLoader initialized: #{loader.schedule.size} chunks, batch size #{loader.batch_size}"
  puts "  Tombstone filtering: #{loader.respect_tombstones ? 'ENABLED' : 'DISABLED'}"
  loader.each_batch.with_index do |batch, idx|
    puts "Batch #{idx}: #{batch.size} chunks → #{batch.take(5).inspect}#{'...' if batch.size > 5}"
  end
end