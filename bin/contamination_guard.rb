#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# contamination_guard.rb - Cross-split contamination detection and audit
# =============================================================================
#
# SYNOPSIS
#   ruby contamination_guard.rb --train train.jsonl --val val.jsonl --test test.jsonl \
#        --output contamination_report.json [OPTIONS]
#
# DESCRIPTION
#   Downstream of splitter.rb: reads materialized train/val/test JSONL splits,
#   detects potential cross-split contamination using SimHash fingerprinting
#   and Jaccard shingle similarity, and emits an audit report with optional
#   exclusion list for trainer-side filtering.
#
#   This is an AUDIT-ONLY tool - it does not modify splits directly. The output
#   exclusion list can be fed to splitter.rb's --exclude option on next
#   rematerialization, or used by training scripts to filter at load time.
#
# INPUT FORMAT (from splitter.rb)
#   Each record must contain:
#     {
#       "internal_id":          "sha256-hex",      # Primary key (collision-proof)
#       "original_message_id":  "<abc@example>",   # Raw Message-ID for diagnostics
#       "thread_id":            "<root@example>",  # Thread root for cross-thread detection
#       "cohort_id":            "2025-01",         # YYYY-MM cohort stamp
#       "email_message":        "cleaned body..."  # Email content
#     }
#
#   OR windowed format (when splitter.rb used --window-size):
#     {
#       "window_id":    "thread_id_window_N",
#       "thread_id":    "...",
#       "window_idx":   N,
#       "cohort_id":    "2025-01",
#       "messages":     [ { full email records... } ]
#     }
#
# OUTPUT
#   Contamination report (JSON):
#     {
#       "timestamp":            "2025-01-09T21:00:00Z",
#       "splits":               { "train": N, "val": N, "test": N },
#       "contamination_pairs":  N,
#       "contamination_pct":    0.5,
#       "flagged_pairs":        [ { internal_id_a, internal_id_b, jaccard, hamming, ... } ],
#       "exclusion_internal_ids": ["abc123...", ...],
#       "status":               "PASS" | "FAIL"
#     }
#
#   Exclusion list (text, one internal_id per line):
#     For feeding to splitter.rb --exclude or trainer scripts.
#
# DETECTION METHODS
#   1. SimHash fingerprinting with Hamming distance threshold
#   2. Jaccard similarity on w-shingle sets
#   3. Exact content hash matching (catches identical bodies)
#
#   Cross-thread matches are flagged as contamination. Same-thread matches
#   are expected (thread integrity) and skipped.
#
# QUARANTINE POLICIES
#   quarantine_eval  - Flag val/test items for exclusion (default, protects train)
#   quarantine_both  - Flag both sides of contaminated pairs
#   report_only      - Generate report without exclusion recommendations
#
# OPTIONS
#   --train FILE             Train split JSONL (required)
#   --val FILE               Val split JSONL (required)
#   --test FILE              Test split JSONL (required)
#   --output FILE            Contamination report JSON (default: contamination_report.json)
#   --exclusion-list FILE    Output exclusion internal_ids (default: exclusion_ids.txt)
#   --threshold FLOAT        Jaccard similarity threshold (0.0-1.0, default: 0.7)
#   --shingle-width INT      w-gram shingle width (default: 5)
#   --hamming-threshold INT  Max Hamming distance for SimHash (default: 8)
#   --quarantine-policy POL  quarantine_eval | quarantine_both | report_only
#   --[no-]strip-quotes      Strip quoted text before comparison (default: true)
#   --max-contamination-pct  Max allowed contamination % before FAIL (default: 1.0)
#   --verbose                Print detailed match information
#   -h, --help               Show this help
#
# EXAMPLES
#   # Basic contamination check
#   ruby contamination_guard.rb --train train.jsonl --val val.jsonl --test test.jsonl
#
#   # Strict threshold with verbose output
#   ruby contamination_guard.rb --train train.jsonl --val val.jsonl --test test.jsonl \
#        --threshold 0.5 --hamming-threshold 4 --verbose
#
#   # Feed exclusions back to splitter
#   ruby splitter.rb -i emails/ -o splits/ --exclude exclusion_ids.txt --materialize all
#
# =============================================================================

require 'json'
require 'digest'
require 'optparse'
require 'set'

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

SIMHASH_BITS = 64

# -----------------------------------------------------------------------------
# Option Parsing
# -----------------------------------------------------------------------------

options = {
  train: nil,
  val: nil,
  test: nil,
  output: 'contamination_report.json',
  exclusion_list: 'exclusion_ids.txt',
  threshold: 0.70,
  shingle_width: 5,
  hamming_threshold: 8,
  quarantine_policy: 'quarantine_eval',
  strip_quotes: true,
  max_contamination_pct: 1.0,
  verbose: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: contamination_guard.rb [options]"
  opts.separator ""
  opts.separator "Cross-split contamination detection for ML training pipelines."
  opts.separator "See header comments for full documentation."
  opts.separator ""
  opts.separator "Options:"

  opts.on("--train FILE", "Train split JSONL (required)") do |v|
    options[:train] = v
  end

  opts.on("--val FILE", "Val split JSONL (required)") do |v|
    options[:val] = v
  end

  opts.on("--test FILE", "Test split JSONL (required)") do |v|
    options[:test] = v
  end

  opts.on("--output FILE", "Contamination report JSON (default: contamination_report.json)") do |v|
    options[:output] = v
  end

  opts.on("--exclusion-list FILE", "Output exclusion internal_ids (default: exclusion_ids.txt)") do |v|
    options[:exclusion_list] = v
  end

  opts.on("--threshold FLOAT", Float, "Jaccard similarity threshold (0.0-1.0, default: 0.7)") do |v|
    options[:threshold] = v
  end

  opts.on("--shingle-width INT", Integer, "w-gram shingle width (default: 5)") do |v|
    options[:shingle_width] = v
  end

  opts.on("--hamming-threshold INT", Integer, "Max Hamming distance for SimHash match (default: 8)") do |v|
    options[:hamming_threshold] = v
  end

  opts.on("--quarantine-policy POLICY", "quarantine_eval | quarantine_both | report_only") do |v|
    options[:quarantine_policy] = v
  end

  opts.on("--[no-]strip-quotes", "Strip quoted text before comparison (default: true)") do |v|
    options[:strip_quotes] = v
  end

  opts.on("--max-contamination-pct FLOAT", Float, "Max allowed contamination % (default: 1.0)") do |v|
    options[:max_contamination_pct] = v
  end

  opts.on("--verbose", "Print detailed match information") do
    options[:verbose] = true
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end.parse!

# -----------------------------------------------------------------------------
# Input Validation
# -----------------------------------------------------------------------------

abort "Error: Missing --train" unless options[:train]
abort "Error: Missing --val" unless options[:val]
abort "Error: Missing --test" unless options[:test]

unless %w[quarantine_eval quarantine_both report_only].include?(options[:quarantine_policy])
  abort "Error: Invalid --quarantine-policy: #{options[:quarantine_policy]}"
end

%i[train val test].each do |split|
  path = options[split]
  abort "Error: File not found: #{path}" unless File.exist?(path)
end

# -----------------------------------------------------------------------------
# JSONL Loading
# -----------------------------------------------------------------------------

def load_jsonl(path)
  records = []
  File.foreach(path).with_index do |line, idx|
    next if line.strip.empty?
    begin
      records << JSON.parse(line)
    rescue JSON::ParserError => e
      warn "Warning: Skipping malformed JSON at #{path}:#{idx + 1} - #{e.message}"
    end
  end
  records
end

# -----------------------------------------------------------------------------
# Content Extraction
# -----------------------------------------------------------------------------

# Handle both direct email records and windowed records
def extract_content_items(record, split_name)
  items = []

  if record.key?('messages')
    # Windowed format: extract each message within the window
    record['messages'].each_with_index do |msg, idx|
      items << {
        internal_id: msg['internal_id'],
        original_message_id: msg['original_message_id'],
        thread_id: record['thread_id'],
        cohort_id: msg['cohort_id'] || record['cohort_id'],
        content: msg['email_message'] || '',
        split: split_name,
        window_id: record['window_id']
      }
    end
  else
    # Direct email format
    items << {
      internal_id: record['internal_id'],
      original_message_id: record['original_message_id'],
      thread_id: record['thread_id'],
      cohort_id: record['cohort_id'],
      content: record['email_message'] || '',
      split: split_name,
      window_id: nil
    }
  end

  items
end

# -----------------------------------------------------------------------------
# Text Normalization
# -----------------------------------------------------------------------------

def strip_quoted_blocks(text)
  return '' if text.nil?

  lines = text.lines
  cleaned = lines.reject do |line|
    # Remove lines starting with > (quoted text)
    line.strip.start_with?('>') ||
    # Remove "On ... wrote:" attribution lines
    line =~ /^\s*On\s+.{10,80}\s+wrote:\s*$/i
  end
  cleaned.join
end

def normalize_content(text, strip_quotes_flag)
  text = strip_quoted_blocks(text) if strip_quotes_flag
  # Lowercase, collapse whitespace, strip
  text.downcase.gsub(/\s+/, ' ').strip
end

# -----------------------------------------------------------------------------
# Fingerprinting: Shingles
# -----------------------------------------------------------------------------

def generate_shingles(text, width)
  tokens = text.split
  return Set.new if tokens.size < width

  (0..tokens.size - width).map { |i| tokens[i, width].join(' ') }.to_set
end

def jaccard_similarity(set_a, set_b)
  return 0.0 if set_a.empty? && set_b.empty?

  intersection = (set_a & set_b).size
  union = (set_a | set_b).size
  union.zero? ? 0.0 : intersection.to_f / union
end

# -----------------------------------------------------------------------------
# Fingerprinting: SimHash
# -----------------------------------------------------------------------------

def compute_simhash(text, bits = SIMHASH_BITS)
  tokens = text.split
  return 0 if tokens.empty?

  vector = Array.new(bits, 0)

  tokens.each do |token|
    hash_val = Digest::SHA256.hexdigest(token).to_i(16)
    bits.times do |i|
      bit_set = (hash_val >> i) & 1
      vector[i] += bit_set == 1 ? 1 : -1
    end
  end

  fingerprint = 0
  vector.each_with_index do |val, i|
    fingerprint |= (1 << i) if val > 0
  end
  fingerprint
end

def hamming_distance(hash_a, hash_b)
  (hash_a ^ hash_b).to_s(2).count('1')
end

# -----------------------------------------------------------------------------
# Fingerprinting: Exact Content Hash
# -----------------------------------------------------------------------------

def content_hash(text)
  Digest::SHA256.hexdigest(text)
end

# -----------------------------------------------------------------------------
# Fingerprint Builder
# -----------------------------------------------------------------------------

def build_fingerprints(records, split_name, shingle_width, strip_quotes_flag)
  fingerprints = []

  records.each do |record|
    items = extract_content_items(record, split_name)

    items.each do |item|
      normalized = normalize_content(item[:content], strip_quotes_flag)

      fingerprints << {
        internal_id: item[:internal_id],
        original_message_id: item[:original_message_id],
        thread_id: item[:thread_id],
        cohort_id: item[:cohort_id],
        split: split_name,
        window_id: item[:window_id],
        shingles: generate_shingles(normalized, shingle_width),
        simhash: compute_simhash(normalized),
        content_hash: content_hash(normalized),
        content_preview: normalized[0..200]
      }
    end
  end

  fingerprints
end

# -----------------------------------------------------------------------------
# Contamination Detection
# -----------------------------------------------------------------------------

def detect_contamination(fps_a, fps_b, split_a_name, split_b_name, threshold, hamming_threshold, verbose)
  contaminated = []
  exact_matches = Set.new  # Track content_hash matches to avoid double-counting

  fps_a.each do |fp_a|
    fps_b.each do |fp_b|
      # Skip same-thread comparisons (expected similarity)
      next if fp_a[:thread_id] && fp_a[:thread_id] == fp_b[:thread_id]

      # Skip if we've already flagged this exact content pair
      pair_key = [fp_a[:content_hash], fp_b[:content_hash]].sort.join(':')
      next if exact_matches.include?(pair_key)

      # Check for exact content match
      exact_match = fp_a[:content_hash] == fp_b[:content_hash]

      # Check SimHash Hamming distance
      hamming = hamming_distance(fp_a[:simhash], fp_b[:simhash])
      simhash_match = hamming <= hamming_threshold

      # Check Jaccard similarity
      jaccard = jaccard_similarity(fp_a[:shingles], fp_b[:shingles])
      jaccard_match = jaccard >= threshold

      if exact_match || simhash_match || jaccard_match
        exact_matches.add(pair_key) if exact_match

        match = {
          split_a: split_a_name,
          split_b: split_b_name,
          internal_id_a: fp_a[:internal_id],
          internal_id_b: fp_b[:internal_id],
          original_message_id_a: fp_a[:original_message_id],
          original_message_id_b: fp_b[:original_message_id],
          thread_id_a: fp_a[:thread_id],
          thread_id_b: fp_b[:thread_id],
          cohort_id_a: fp_a[:cohort_id],
          cohort_id_b: fp_b[:cohort_id],
          jaccard: jaccard.round(4),
          hamming: hamming,
          exact_match: exact_match,
          match_reason: exact_match ? 'exact' : (simhash_match ? 'simhash' : 'jaccard')
        }

        contaminated << match

        if verbose
          puts "  MATCH [#{match[:match_reason]}]: #{fp_a[:internal_id][0..12]}... (#{split_a_name}) <-> #{fp_b[:internal_id][0..12]}... (#{split_b_name})"
          puts "         Jaccard: #{jaccard.round(3)}, Hamming: #{hamming}, Exact: #{exact_match}"
        end
      end
    end
  end

  contaminated
end

# -----------------------------------------------------------------------------
# Main Processing
# -----------------------------------------------------------------------------

puts "Loading splits..."
train_data = load_jsonl(options[:train])
val_data = load_jsonl(options[:val])
test_data = load_jsonl(options[:test])

puts "Loaded #{train_data.size} train, #{val_data.size} val, #{test_data.size} test records"

# Validate input format
sample = train_data.first || val_data.first || test_data.first
if sample
  has_internal_id = sample.key?('internal_id') || 
                    (sample.key?('messages') && sample['messages'].first&.key?('internal_id'))

  unless has_internal_id
    if sample.key?('message_id') || (sample.key?('messages') && sample['messages'].first&.key?('message_id'))
      abort "Error: Input uses old format (message_id). Re-run splitter.rb with updated mbox_pre-parser.rb output."
    else
      abort "Error: Input missing required 'internal_id' field. Ensure splits are from current pipeline."
    end
  end
end

puts "Building fingerprints..."
train_fps = build_fingerprints(train_data, 'train', options[:shingle_width], options[:strip_quotes])
val_fps = build_fingerprints(val_data, 'val', options[:shingle_width], options[:strip_quotes])
test_fps = build_fingerprints(test_data, 'test', options[:shingle_width], options[:strip_quotes])

puts "Fingerprints: #{train_fps.size} train, #{val_fps.size} val, #{test_fps.size} test"

puts "Detecting cross-split contamination..."
puts "" if options[:verbose]

contamination = []

# Train vs Val
puts "  Checking train vs val..." if options[:verbose]
contamination.concat(
  detect_contamination(train_fps, val_fps, 'train', 'val', 
                       options[:threshold], options[:hamming_threshold], options[:verbose])
)

# Train vs Test
puts "  Checking train vs test..." if options[:verbose]
contamination.concat(
  detect_contamination(train_fps, test_fps, 'train', 'test',
                       options[:threshold], options[:hamming_threshold], options[:verbose])
)

# Val vs Test
puts "  Checking val vs test..." if options[:verbose]
contamination.concat(
  detect_contamination(val_fps, test_fps, 'val', 'test',
                       options[:threshold], options[:hamming_threshold], options[:verbose])
)

puts ""
puts "Found #{contamination.size} contaminated pairs"

# -----------------------------------------------------------------------------
# Apply Quarantine Policy
# -----------------------------------------------------------------------------

exclusion_ids = Set.new

case options[:quarantine_policy]
when 'quarantine_eval'
  # Flag val/test items for exclusion, preserving train
  contamination.each do |pair|
    if pair[:split_a] == 'train'
      # Train vs val/test: exclude the eval side
      exclusion_ids << pair[:internal_id_b]
    else
      # Val vs test: exclude test side (protect val for hyperparameter tuning)
      exclusion_ids << pair[:internal_id_b] if pair[:split_b] == 'test'
      exclusion_ids << pair[:internal_id_a] if pair[:split_a] == 'test'
    end
  end

when 'quarantine_both'
  # Flag both sides of contaminated pairs
  contamination.each do |pair|
    exclusion_ids << pair[:internal_id_a]
    exclusion_ids << pair[:internal_id_b]
  end

when 'report_only'
  # No exclusions, audit only
  puts "Policy 'report_only': no exclusion recommendations generated"
end

puts "Quarantine policy '#{options[:quarantine_policy]}': #{exclusion_ids.size} internal_ids flagged"

# -----------------------------------------------------------------------------
# Calculate Contamination Rate
# -----------------------------------------------------------------------------

total_fingerprints = train_fps.size + val_fps.size + test_fps.size
contamination_pct = total_fingerprints > 0 ? (contamination.size.to_f / total_fingerprints) * 100 : 0.0

# -----------------------------------------------------------------------------
# Build Report
# -----------------------------------------------------------------------------

report = {
  timestamp: Time.now.utc.iso8601,
  pipeline_version: 'v2-internal_id',

  # Split sizes (record counts from JSONL)
  splits: {
    train: train_data.size,
    val: val_data.size,
    test: test_data.size
  },

  # Fingerprint counts (may differ if windowed)
  fingerprints: {
    train: train_fps.size,
    val: val_fps.size,
    test: test_fps.size
  },

  # Detection parameters
  parameters: {
    jaccard_threshold: options[:threshold],
    hamming_threshold: options[:hamming_threshold],
    shingle_width: options[:shingle_width],
    strip_quotes: options[:strip_quotes]
  },

  # Results
  contamination_pairs: contamination.size,
  contamination_pct: contamination_pct.round(4),
  max_contamination_pct: options[:max_contamination_pct],

  # Policy and exclusions
  quarantine_policy: options[:quarantine_policy],
  exclusion_count: exclusion_ids.size,
  exclusion_internal_ids: exclusion_ids.to_a.sort,

  # Detailed findings
  flagged_pairs: contamination,

  # Pass/fail
  status: contamination_pct <= options[:max_contamination_pct] ? 'PASS' : 'FAIL'
}

# -----------------------------------------------------------------------------
# Write Outputs
# -----------------------------------------------------------------------------

File.write(options[:output], JSON.pretty_generate(report))
puts "Contamination report written to: #{options[:output]}"

if exclusion_ids.any?
  File.write(options[:exclusion_list], exclusion_ids.to_a.sort.join("\n") + "\n")
  puts "Exclusion list written to: #{options[:exclusion_list]} (#{exclusion_ids.size} internal_ids)"
else
  # Write empty file to avoid stale exclusion lists
  File.write(options[:exclusion_list], '')
  puts "Exclusion list written to: #{options[:exclusion_list]} (empty - no exclusions)"
end

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

puts ""
puts "=== Contamination Guard Summary ==="
puts "Train fingerprints:     #{train_fps.size}"
puts "Val fingerprints:       #{val_fps.size}"
puts "Test fingerprints:      #{test_fps.size}"
puts "Contaminated pairs:     #{contamination.size}"
puts "Contamination rate:     #{contamination_pct.round(4)}%"
puts "Max allowed:            #{options[:max_contamination_pct]}%"
puts "Exclusions recommended: #{exclusion_ids.size}"
puts ""

# Breakdown by match type
if contamination.any?
  by_reason = contamination.group_by { |c| c[:match_reason] }
  puts "Match breakdown:"
  puts "  Exact content:  #{by_reason['exact']&.size || 0}"
  puts "  SimHash:        #{by_reason['simhash']&.size || 0}"
  puts "  Jaccard:        #{by_reason['jaccard']&.size || 0}"
  puts ""
end

# Final status
if report[:status] == 'FAIL'
  puts "STATUS: FAIL"
  puts "Contamination rate #{contamination_pct.round(2)}% exceeds max #{options[:max_contamination_pct]}%"
  puts ""
  puts "Recommended actions:"
  puts "  1. Review flagged pairs in #{options[:output]}"
  puts "  2. Apply exclusions: ruby splitter.rb ... --exclude #{options[:exclusion_list]}"
  puts "  3. Re-run contamination_guard.rb to verify"
  exit 1
else
  puts "STATUS: PASS"
  puts "Contamination rate #{contamination_pct.round(2)}% within acceptable limit"

  if exclusion_ids.any?
    puts ""
    puts "Optional: Apply #{exclusion_ids.size} exclusions for cleaner splits:"
    puts "  ruby splitter.rb -i INPUT -o OUTPUT --exclude #{options[:exclusion_list]} --materialize all"
  end
end