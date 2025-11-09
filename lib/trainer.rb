# frozen_string_literal: true

# trainer.rb - Minimal Training Loop Scaffold
#
# PURPOSE:
#   Provides a lightweight, integration-friendly training loop scaffold that:
#   - Accepts batches from DataLoader
#   - Logs progress (step, loss, throughput)
#   - Simulates or orchestrates checkpoint saves
#   - Supports custom training step logic via block/lambda
#
# USAGE (as library):
#   require_relative 'trainer'
#   require_relative 'dataloader'
#
#   trainer = Trainer.new(
#     model_path: 'meta-llama/Llama-3.2-1B',
#     output_dir: './checkpoints',
#     learning_rate: 1e-4,
#     epochs: 3,
#     log_every: 10
#   )
#
#   loader = DataLoader.new(schedule_path: 'epoch_00001_schedule.json', batch_size: 32, seed: 42)
#
#   trainer.train(loader) do |batch_chunk_ids, step|
#     # Custom training step logic (call your ML framework here)
#     loss = simulate_training_step(batch_chunk_ids)
#     loss  # Return loss for logging
#   end
#
# USAGE (CLI demo mode):
#   ./trainer.rb \
#     --schedule epoch_00001_schedule.json \
#     --batch-size 32 \
#     --seed 42 \
#     --output-dir ./checkpoints \
#     --epochs 3 \
#     --log-every 10
#
# ARGUMENTS:
#   --schedule         Path to epoch schedule JSON
#   --batch-size       Batch size for DataLoader
#   --seed             RNG seed
#   --output-dir       Directory to save checkpoints
#   --epochs           Number of training epochs
#   --log-every        Log progress every N steps
#
# OUTPUT:
#   - Progress logs to stdout (step, loss, throughput)
#   - Checkpoint metadata written to output_dir/checkpoint_<step>.json (simulated in demo)
#   - Final summary with total steps, avg loss, elapsed time
#
# INTEGRATION:
#   retrain.rb imports Trainer and DataLoader, wires them together,
#   and provides a custom training step that calls your LoRA fine-tuning framework.

require 'json'
require 'fileutils'
require 'benchmark'

class Trainer
  attr_reader :model_path, :output_dir, :learning_rate, :epochs, :log_every

  def initialize(model_path:, output_dir:, learning_rate: 1e-4, epochs: 1, log_every: 10)
    @model_path = model_path
    @output_dir = output_dir
    @learning_rate = learning_rate
    @epochs = epochs
    @log_every = log_every
    FileUtils.mkdir_p(@output_dir)
  end

  def train(dataloader, &step_block)
    abort "No training step block provided!" unless block_given?

    total_steps = 0
    total_loss = 0.0
    start_time = Time.now

    @epochs.times do |epoch_idx|
      puts "\n=== Epoch #{epoch_idx + 1}/#{@epochs} ==="
      dataloader.each_batch.with_index do |batch, batch_idx|
        step = total_steps + 1
        loss = step_block.call(batch, step)
        total_loss += loss
        total_steps += 1

        if step % @log_every == 0
          avg_loss = total_loss / total_steps
          elapsed = Time.now - start_time
          throughput = total_steps / elapsed
          puts "[Step #{step}] Loss: %.4f | Avg Loss: %.4f | Throughput: %.2f steps/s" % [loss, avg_loss, throughput]
        end

        # Simulate checkpoint save every 100 steps
        save_checkpoint(step, loss) if step % 100 == 0
      end
    end

    elapsed = Time.now - start_time
    avg_loss = total_steps > 0 ? total_loss / total_steps : 0.0
    puts "\n=== Training Complete ==="
    puts "Total steps: #{total_steps}"
    puts "Average loss: %.4f" % avg_loss
    puts "Elapsed time: %.2f seconds (%.2f steps/s)" % [elapsed, total_steps / elapsed]
  end

  private

  def save_checkpoint(step, loss)
    checkpoint_path = File.join(@output_dir, "checkpoint_#{step}.json")
    metadata = {
      step: step,
      loss: loss,
      timestamp: Time.now.iso8601,
      model_path: @model_path,
      learning_rate: @learning_rate
    }
    File.write(checkpoint_path, JSON.pretty_generate(metadata))
    puts "  → Saved checkpoint: #{checkpoint_path}"
  end
end

# CLI demo mode
if __FILE__ == $PROGRAM_NAME
  require_relative 'dataloader'
  require 'optparse'

  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: trainer.rb [options]"
    opts.on("--schedule PATH", "Path to epoch schedule JSON") { |v| options[:schedule] = v }
    opts.on("--batch-size N", Integer, "Batch size") { |v| options[:batch_size] = v }
    opts.on("--seed SEED", Integer, "RNG seed") { |v| options[:seed] = v }
    opts.on("--output-dir DIR", "Checkpoint output directory") { |v| options[:output_dir] = v }
    opts.on("--epochs N", Integer, "Number of epochs") { |v| options[:epochs] = v }
    opts.on("--log-every N", Integer, "Log every N steps") { |v| options[:log_every] = v }
  end.parse!

  [:schedule, :batch_size, :seed, :output_dir].each do |key|
    abort "Missing required argument: --#{key.to_s.tr('_', '-')}" unless options[key]
  end

  loader = DataLoader.new(
    schedule_path: options[:schedule],
    batch_size: options[:batch_size],
    seed: options[:seed]
  )

  trainer = Trainer.new(
    model_path: 'meta-llama/Llama-3.2-1B',  # Demo placeholder
    output_dir: options[:output_dir],
    epochs: options[:epochs] || 1,
    log_every: options[:log_every] || 10
  )

  puts "Starting demo training loop..."
  trainer.train(loader) do |batch_chunk_ids, step|
    # Simulate training step with random loss
    simulated_loss = 2.0 + rand * 0.5 - step * 0.001  # Slowly decreasing loss
    simulated_loss = [simulated_loss, 0.1].max  # Floor at 0.1
    simulated_loss
  end
end