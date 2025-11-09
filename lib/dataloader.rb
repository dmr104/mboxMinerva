#!/usr/bin/env ruby
# frozen_string_literal: true

# dataloader.rb - Deterministic Batch Iterator
#
# PURPOSE:
#   Consumes a training schedule (epoch_schedule.json from sampler.rb),
#   yields batches of chunk_ids deterministically, with optional shuffling
#   within each batch (for local GPU batch variance without breaking global schedule).
#
# USAGE (as library):
#   require_relative 'dataloader'
#   loader = DataLoader.new(
#     schedule_path: 'epoch_00001_schedule.json',
#     batch_size: 32,
#     shuffle_within_batch: true,
#     seed: 42
#   )
#   loader.each_batch do |batch_chunk_ids|
#     # Train on batch_chunk_ids
#     puts "Processing batch: #{batch_chunk_ids.inspect}"
#   end
#
# USAGE (CLI demo):
#   ./dataloader.rb \
#     --schedule epoch_00001_schedule.json \
#     --batch-size 32 \
#     --seed 42 \
#     [--shuffle-within-batch]
#
# ARGUMENTS:
#   --schedule            Path to epoch schedule JSON (array of chunk_ids from sampler.rb)
#   --batch-size          Number of chunks per batch
#   --seed                Integer RNG seed for deterministic within-batch shuffling
#   --shuffle-within-batch  Optional: shuffle chunk order within each batch
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
  attr_reader :schedule, :batch_size, :shuffle_within_batch, :seed

  def initialize(schedule_path:, batch_size:, shuffle_within_batch: false, seed: 42)
    @schedule = JSON.parse(File.read(schedule_path))
    @batch_size = batch_size
    @shuffle_within_batch = shuffle_within_batch
    @seed = seed
  end

  def each_batch
    @schedule.each_slice(@batch_size).with_index do |batch, batch_idx|
      batch = shuffle_batch(batch, batch_idx) if @shuffle_within_batch
      yield batch
    end
  end

  private

  def shuffle_batch(batch, batch_idx)
    digest = Digest::SHA256.hexdigest("#{@seed}:batch:#{batch_idx}")
    rng = Random.new(digest.to_i(16) % (2**32))
    batch.shuffle(random: rng)
  end
end

# CLI demo mode
if __FILE__ == $PROGRAM_NAME
  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: dataloader.rb [options]"
    opts.on("--schedule PATH", "Path to epoch schedule JSON") { |v| options[:schedule] = v }
    opts.on("--batch-size N", Integer, "Batch size") { |v| options[:batch_size] = v }
    opts.on("--seed SEED", Integer, "RNG seed") { |v| options[:seed] = v }
    opts.on("--shuffle-within-batch", "Shuffle within each batch") { options[:shuffle] = true }
  end.parse!

  [:schedule, :batch_size, :seed].each do |key|
    abort "Missing required argument: --#{key.to_s.tr('_', '-')}" unless options[key]
  end

  loader = DataLoader.new(
    schedule_path: options[:schedule],
    batch_size: options[:batch_size],
    shuffle_within_batch: options[:shuffle] || false,
    seed: options[:seed]
  )

  puts "DataLoader initialized: #{loader.schedule.size} chunks, batch size #{loader.batch_size}"
  loader.each_batch.with_index do |batch, idx|
    puts "Batch #{idx}: #{batch.size} chunks → #{batch.take(5).inspect}#{'...' if batch.size > 5}"
  end
end
