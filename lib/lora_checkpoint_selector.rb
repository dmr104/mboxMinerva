#!/usr/bin/env ruby
# lora_checkpoint_selector.rb
#
# Orchestrates LoRA adapter training & selection based on validation loss:
#   1) Scans checkpoint directory for adapters
#   2) Reads trainer_state.json to find checkpoint with lowest eval_loss
#   3) Caches best checkpoint
#   4) Optionally re-trains with adjusted hyperparameters if improvement lags
#   5) Freezes (preserves) or merges best adapter into base model
#
# USAGE:
#   ruby lora_checkpoint_selector.rb [OPTIONS]
#
# FLAGS:
#   --checkpoint-dir DIR          Path to checkpoints directory (default: ./checkpoints)
#   --improvement-threshold NUM   Min improvement to avoid retraining (default: 0.01)
#   --retrain-cmd "COMMAND"       Command template to re-run training with adjusted params
#                                 Use {LR}, {REPLAY_RATIO}, {EPOCHS} placeholders
#                                 Example: "ruby retrain.rb --train train.json --val val.json --lr {LR} --replay-ratio {REPLAY_RATIO} --epochs {EPOCHS} --output checkpoints/retrain_{ATTEMPT}"
#   --lr-adjust FACTOR            Multiply LR by this on retrain (default: 0.5)
#   --replay-adjust DELTA         Add this to replay ratio on retrain (default: 0.05)
#   --epochs-adjust DELTA         Add this to epochs on retrain (default: 1)
#   --max-retrain-attempts NUM    Max retraining iterations (default: 3)
#   --freeze                      Freeze best adapter (copy) instead of merging
#   --merge-cmd "COMMAND"         Command template to merge adapter into base
#                                 Use {CHECKPOINT} placeholder
#                                 Example: "ruby merge_lora.rb --base meta-llama/Llama-3.2-1B --adapter ./checkpoint-1000 --out ./merged_model"
#   --best-cache FILE             JSON file tracking best checkpoint (default: best_checkpoint.json)
#   --base-lr NUM                 Initial learning rate (default: 3e-4)
#   --base-replay NUM             Initial replay ratio (default: 0.2)
#   --base-epochs NUM             Initial epochs (default: 3)
#   --dry-run                     Print commands without executing
#   --verbose                     Print detailed progress
#
# EXAMPLES:
#
#   # Basic usage: select best checkpoint by val_loss
#   ruby lora_checkpoint_selector.rb \
#     --checkpoint-dir ./checkpoints/run_001 \
#     --merge-cmd 'ruby merge_lora.rb --adapter {CHECKPOINT} --out final_model'
#
#   # With retraining on plateau
#   ruby lora_checkpoint_selector.rb \
#     --checkpoint-dir ./checkpoints/run_001 \
#     --retrain-cmd 'ruby retrain.rb --train mixed.json --val val.json --old-train old_train.json \
#                        --output checkpoints/run_001 --lr 2e-4 --epochs 3 --replay-ratio 0.2 \
#                        --early-stop --patience 3 --min-delta 0.001 \
#                        --save-train-shard data/train_shards \
#                        --update-old-train --keep-shards 5 --shard-manager ./shard_window_manager.rb'
#     --improvement-threshold 0.02 \
#     --max-retrain-attempts 2 \
#     --freeze

require 'json'
require 'fileutils'
require 'optparse'

# Default configuration
config = {
  checkpoint_dir: './checkpoints',
  improvement_threshold: 0.01,
  retrain_cmd: nil,
  lr_adjust: 0.5,
  replay_adjust: 0.05,
  epochs_adjust: 1,
  max_retrain_attempts: 3,
  freeze: false,
  merge_cmd: nil,
  best_cache: 'best_checkpoint.json',
  base_lr: 3e-4,
  base_replay: 0.2,
  base_epochs: 3,
  dry_run: false,
  verbose: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: lora_checkpoint_selector.rb [OPTIONS]"

  opts.on('--checkpoint-dir DIR', 'Checkpoint directory') { |v| config[:checkpoint_dir] = v }
  opts.on('--improvement-threshold NUM', Float, 'Min improvement') { |v| config[:improvement_threshold] = v }
  opts.on('--retrain-cmd CMD', 'Retrain command template') { |v| config[:retrain_cmd] = v }
  opts.on('--lr-adjust FACTOR', Float, 'LR adjustment factor') { |v| config[:lr_adjust] = v }
  opts.on('--replay-adjust DELTA', Float, 'Replay ratio delta') { |v| config[:replay_adjust] = v }
  opts.on('--epochs-adjust DELTA', Integer, 'Epochs delta') { |v| config[:epochs_adjust] = v }
  opts.on('--max-retrain-attempts NUM', Integer, 'Max retraining iterations') { |v| config[:max_retrain_attempts] = v }
  opts.on('--freeze', 'Freeze instead of merge') { config[:freeze] = true }
  opts.on('--merge-cmd CMD', 'Merge command template') { |v| config[:merge_cmd] = v }
  opts.on('--best-cache FILE', 'Best checkpoint cache') { |v| config[:best_cache] = v }
  opts.on('--base-lr NUM', Float, 'Initial learning rate') { |v| config[:base_lr] = v }
  opts.on('--base-replay NUM', Float, 'Initial replay ratio') { |v| config[:base_replay] = v }
  opts.on('--base-epochs NUM', Integer, 'Initial epochs') { |v| config[:base_epochs] = v }
  opts.on('--dry-run', 'Print without executing') { config[:dry_run] = true }
  opts.on('--verbose', 'Detailed progress') { config[:verbose] = true }
end.parse!

def log(msg, verbose)
  puts "[#{Time.now.strftime('%H:%M:%S')}] #{msg}" if verbose
end

def run_command(cmd, dry_run, verbose)
  log("Executing: #{cmd}", verbose)
  return "[DRY-RUN OUTPUT]" if dry_run
  
  output = `#{cmd} 2>&1`
  raise "Command failed: #{cmd}\n#{output}" unless $?.success?
  output
end

def find_best_checkpoint_from_trainer_state(checkpoint_dir, verbose)
  # Look for trainer_state.json in the checkpoint directory
  trainer_state_path = File.join(checkpoint_dir, 'trainer_state.json')
  
  unless File.exist?(trainer_state_path)
    raise "trainer_state.json not found in #{checkpoint_dir}. Make sure training completed successfully."
  end
  
  log("Reading trainer_state.json...", verbose)
  trainer_state = JSON.parse(File.read(trainer_state_path))
  
  # HuggingFace Trainer saves best_model_checkpoint when load_best_model_at_end=True
  best_checkpoint = trainer_state['best_model_checkpoint']
  best_metric = trainer_state['best_metric']
  
  if best_checkpoint && best_metric
    log("Found best checkpoint from trainer_state: #{best_checkpoint} (eval_loss: #{best_metric})", verbose)
    return { checkpoint: best_checkpoint, eval_loss: best_metric }
  end
  
  # Fallback: scan log_history for lowest eval_loss
  log("best_model_checkpoint not in trainer_state, scanning log_history...", verbose)
  log_history = trainer_state['log_history'] || []
  
  eval_logs = log_history.select { |entry| entry['eval_loss'] }
  raise "No eval_loss entries found in trainer_state.json" if eval_logs.empty?
  
  best_entry = eval_logs.min_by { |entry| entry['eval_loss'] }
  best_step = best_entry['step']
  best_loss = best_entry['eval_loss']
  
  # Find matching checkpoint directory
  checkpoints = Dir.glob(File.join(checkpoint_dir, 'checkpoint-*')).select { |f| File.directory?(f) }
  best_checkpoint = checkpoints.find { |ckpt| ckpt.match(/checkpoint-#{best_step}$/) }
  
  raise "Could not find checkpoint directory for step #{best_step}" unless best_checkpoint
  
  log("Found best checkpoint from log_history: #{best_checkpoint} (eval_loss: #{best_loss})", verbose)
  { checkpoint: best_checkpoint, eval_loss: best_loss }
end

# Validate checkpoint directory
raise "Checkpoint dir not found: #{config[:checkpoint_dir]}" unless Dir.exist?(config[:checkpoint_dir]) || config[:dry_run]

# Load previous best
previous_best = nil
if File.exist?(config[:best_cache])
  previous_best = JSON.parse(File.read(config[:best_cache]))
  log("Loaded previous best: #{previous_best['checkpoint']} (eval_loss: #{previous_best['eval_loss']})", config[:verbose])
end

# Find best checkpoint from current run
best = if config[:dry_run]
  { checkpoint: "#{config[:checkpoint_dir]}/checkpoint-100", eval_loss: 1.234 }
else
  find_best_checkpoint_from_trainer_state(config[:checkpoint_dir], config[:verbose])
end

puts "\n==> Best checkpoint: #{File.basename(best[:checkpoint])} (eval_loss: #{best[:eval_loss]})"

# Check if we should retrain
retrain_attempts = 0
current_lr = config[:base_lr]
current_replay = config[:base_replay]
current_epochs = config[:base_epochs]

if config[:retrain_cmd] && previous_best
  # Lower eval_loss is better, so improvement is previous - current
  improvement = previous_best['eval_loss'] - best[:eval_loss]
  
  while improvement < config[:improvement_threshold] && retrain_attempts < config[:max_retrain_attempts]
    retrain_attempts += 1
    puts "\n==> Improvement (#{improvement.round(4)}) below threshold (#{config[:improvement_threshold]}), retraining attempt #{retrain_attempts}/#{config[:max_retrain_attempts]}..."
    
    # Adjust hyperparameters
    current_lr *= config[:lr_adjust]
    current_replay += config[:replay_adjust]
    current_replay = [current_replay, 0.9].min  # Cap at 0.9
    current_epochs += config[:epochs_adjust]
    
    puts "  New hyperparameters: lr=#{current_lr}, replay=#{current_replay}, epochs=#{current_epochs}"
    
    # Retrain
    retrain_cmd = config[:retrain_cmd]
      .gsub('{LR}', current_lr.to_s)
      .gsub('{REPLAY_RATIO}', current_replay.to_s)
      .gsub('{EPOCHS}', current_epochs.to_s)
      .gsub('{ATTEMPT}', retrain_attempts.to_s)
    
    run_command(retrain_cmd, config[:dry_run], config[:verbose])
    
    # Re-evaluate new checkpoint directory
    new_checkpoint_dir = config[:retrain_cmd].match(/--output\s+(\S+)/)[1].gsub('{ATTEMPT}', retrain_attempts.to_s) rescue nil
    
    unless new_checkpoint_dir && Dir.exist?(new_checkpoint_dir)
      puts "  Warning: Could not find new checkpoint directory after retraining"
      break
    end
    
    new_best = find_best_checkpoint_from_trainer_state(new_checkpoint_dir, config[:verbose])
    
    new_improvement = best[:eval_loss] - new_best[:eval_loss]
    
    if new_improvement > 0
      improvement = previous_best['eval_loss'] - new_best[:eval_loss]
      best = new_best
      puts "  New best: #{File.basename(best[:checkpoint])} (eval_loss: #{best[:eval_loss]}, improvement: #{new_improvement.round(4)})"
    else
      puts "  No improvement from retraining (eval_loss: #{new_best[:eval_loss]})"
      break
    end
  end
end

# Cache best checkpoint
cache_data = {
  'checkpoint' => best[:checkpoint],
  'eval_loss' => best[:eval_loss],
  'timestamp' => Time.now.iso8601,
  'retrain_attempts' => retrain_attempts,
  'final_hyperparameters' => {
    'lr' => current_lr,
    'replay' => current_replay,
    'epochs' => current_epochs
  }
}

unless config[:dry_run]
  File.write(config[:best_cache], JSON.pretty_generate(cache_data))
  puts "\n==> Cached best checkpoint to #{config[:best_cache]}"
end

# Freeze or merge
if config[:freeze]
  frozen_path = 'best_adapter_frozen'
  unless config[:dry_run]
    FileUtils.cp_r(best[:checkpoint], frozen_path)
  end
  puts "\n==> Frozen best adapter to #{frozen_path}"
else
  if config[:merge_cmd]
    merge_cmd = config[:merge_cmd].gsub('{CHECKPOINT}', best[:checkpoint])
    puts "\n==> Merging adapter..."
    run_command(merge_cmd, config[:dry_run], config[:verbose])
    puts "==> Merge complete!"
  else
    puts "\n==> Warning: No --merge-cmd specified and --freeze not set. Best checkpoint cached but not applied."
  end
end

puts "\n==> Done! Final eval_loss: #{best[:eval_loss]}"
