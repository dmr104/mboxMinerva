# frozen_string_literal: true

# window_filter.rb
# =================
# Filters assignments.json to extract chunk_ids matching a specific window_idx and split.
#
# **Purpose:**
# After splitter.rb ingests new emails and appends to assignments.json with fresh window_idx,
# this script extracts just the train-split IDs for the current window to feed into sampler.rb
# as "new_train.json" (the current window's training examples to interleave with rehearsal).
#
# **When to run:**
# CI step between splitter.rb and sampler.rb:
#   1. splitter.rb processes new emails → appends to assignments.json with window_idx=W
#   2. window_filter.rb --window W --split train → new_train.json
#   3. sampler.rb --rehearsal old_shards_train.json --new new_train.json → epoch schedule
#
# **Inputs:**
#   --assignments PATH      Path to assignments.json (default: assignments.json)
#   --window IDX            Window index to filter (required)
#   --split SPLIT           Split to filter: train|validation|test (default: train)
#   --format FORMAT         Output format: json|lines (default: lines)
#
# **Outputs:**
#   Writes chunk_ids to stdout (redirect to new_train.json or similar)
#   --format lines: one chunk_id per line (for simple CI tooling)
#   --format json:  JSON array of chunk_ids (for structured pipelines)
#
# **Usage Examples:**
#
# Extract current window train IDs:
#   ./window_filter.rb --assignments assignments.json --window 42 --split train > new_train.json
#
# Extract validation IDs for window 42:
#   ./window_filter.rb --window 42 --split validation --format json > val_42.json
#
# CI integration:
#   W=$(cat current_window.txt)
#   ./window_filter.rb --window "$W" --split train > new_train.json
#   ./sampler.rb --rehearsal old_shards_train.json --new new_train.json --epoch 1 > epoch_1.json
#
# **Algorithm:**
# 1. Load assignments.json as JSON array
# 2. Filter entries where window_idx == W and split == S
# 3. Extract chunk_id from each matching entry
# 4. Output as newline-delimited list or JSON array
#
# **Notes:**
# - Pure filter; never modifies assignments.json
# - Deterministic: same inputs → same outputs
# - Window can be numeric or string (matches exactly)
# - Case-sensitive split matching

require 'json'
require 'optparse'

def main
  options = {
    assignments: 'assignments.json',
    window: nil,
    split: 'train',
    format: 'lines'
  }

  OptionParser.new do |opts|
    opts.banner = "Usage: window_filter.rb [options]"
    opts.on('--assignments PATH', 'Path to assignments.json') { |v| options[:assignments] = v }
    opts.on('--window IDX', 'Window index to filter (required)') { |v| options[:window] = v }
    opts.on('--split SPLIT', 'Split to filter: train|validation|test') { |v| options[:split] = v }
    opts.on('--format FORMAT', 'Output format: json|lines') { |v| options[:format] = v }
    opts.on('-h', '--help', 'Show this help') do
      puts opts
      exit
    end
  end.parse!

  unless options[:window]
    warn "ERROR: --window is required"
    exit 1
  end

  unless File.exist?(options[:assignments])
    warn "ERROR: assignments file not found: #{options[:assignments]}"
    exit 1
  end

  # Load assignments
  assignments = JSON.parse(File.read(options[:assignments]))

  # Normalize window to string for comparison (handles numeric or string windows)
  target_window = options[:window].to_s
  target_split = options[:split]

  # Filter matching entries
  matching_ids = assignments
    .select { |entry| entry['window_idx'].to_s == target_window && entry['split'] == target_split }
    .map { |entry| entry['chunk_id'] }

  # Output
  case options[:format]
  when 'json'
    puts JSON.pretty_generate(matching_ids)
  when 'lines'
    matching_ids.each { |id| puts id }
  else
    warn "ERROR: Unknown format: #{options[:format]}"
    exit 1
  end

  warn "Filtered #{matching_ids.size} chunk_ids (window=#{target_window}, split=#{target_split})"
end

main if __FILE__ == $PROGRAM_NAME