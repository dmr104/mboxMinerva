#!/usr/bin/env ruby
# contamination_guard.rb - Cross-split contamination detection and quarantine
# Usage: contamination_guard.rb --train train.jsonl --val val.jsonl --test test.jsonl \
#          --output contamination_report.json [--threshold 0.7] [--quarantine-policy POLICY]

require 'json'
require 'digest'
require 'optparse'
require 'set'

# CLI options
options = {
  train: nil,
  val: nil,
  test: nil,
  output: 'contamination_report.json',
  exclusion_list: 'exclusion_ids.txt',
  threshold: 0.70,            # Jaccard/SimHash threshold for flagging
  shingle_width: 5,           # w-gram width
  simhash_bits: 64,
  hamming_threshold: 8,       # Max Hamming distance for SimHash match
  quarantine_policy: 'quarantine_test',  # 'quarantine_test', 'quarantine_both', 'coassign'
  strip_quotes: true,
  max_contamination_pct: 1.0  # Fail if >1% contamination rate
}

OptionParser.new do |opts|
  opts.banner = "Usage: contamination_guard.rb [options]"
  opts.on("--train FILE", "Train split JSONL") { |v| options[:train] = v }
  opts.on("--val FILE", "Val split JSONL") { |v| options[:val] = v }
  opts.on("--test FILE", "Test split JSONL") { |v| options[:test] = v }
  opts.on("--output FILE", "Contamination report JSON (default: contamination_report.json)") { |v| options[:output] = v }
  opts.on("--exclusion-list FILE", "Output exclusion row IDs (default: exclusion_ids.txt)") { |v| options[:exclusion_list] = v }
  opts.on("--threshold FLOAT", Float, "Jaccard/Hamming threshold (0.0-1.0, default: 0.7)") { |v| options[:threshold] = v }
  opts.on("--shingle-width INT", Integer, "w-gram shingle width (default: 5)") { |v| options[:shingle_width] = v }
  opts.on("--hamming-threshold INT", Integer, "Max Hamming distance for SimHash (default: 8)") { |v| options[:hamming_threshold] = v }
  opts.on("--quarantine-policy POLICY", "quarantine_test | quarantine_both | coassign") { |v| options[:quarantine_policy] = v }
  opts.on("--[no-]strip-quotes", "Strip quoted text (default: true)") { |v| options[:strip_quotes] = v }
  opts.on("--max-contamination-pct FLOAT", Float, "Max allowed contamination % (default: 1.0)") { |v| options[:max_contamination_pct] = v }
end.parse!

abort "Missing --train" unless options[:train]
abort "Missing --val" unless options[:val]
abort "Missing --test" unless options[:test]

# Load JSONL files
def load_jsonl(path)
  records = []
  File.readlines(path).each_with_index do |line, idx|
    next if line.strip.empty?
    begin
      records << JSON.parse(line)
    rescue JSON::ParserError => e
      warn "Skipping malformed JSON at #{path}:#{idx + 1} - #{e.message}"
    end
  end
  records
end

puts "Loading splits..."
train_data = load_jsonl(options[:train])
val_data = load_jsonl(options[:val])
test_data = load_jsonl(options[:test])

puts "Loaded #{train_data.size} train, #{val_data.size} val, #{test_data.size} test records"

# Strip quoted blocks (lines starting with > or "On ... <email> wrote:")
def strip_quotes(text)
  lines = text.split("\n")
  lines.reject! do |line|
    # Match lines starting with > or reply headers with email addresses
    line.strip.start_with?('>') ||
      line =~ /^\s*On\s+.+<[^>]+>\s+wrote:/i
  end
  lines.join("\n")
end

# Normalize content
def normalize_content(record, strip_quotes_flag)
  content = record['email_message'] || record['content'] || record['text'] || ''
  content = strip_quotes(content) if strip_quotes_flag
  content.downcase.gsub(/\s+/, ' ').strip
end

# Generate w-shingles
def shingles(text, width)
  tokens = text.split
  return Set.new if tokens.size < width
  (0..tokens.size - width).map { |i| tokens[i, width].join(' ') }.to_set
end

# Jaccard similarity
def jaccard(set_a, set_b)
  return 0.0 if set_a.empty? && set_b.empty?
  intersection = (set_a & set_b).size
  union = (set_a | set_b).size
  union.zero? ? 0.0 : intersection.to_f / union
end

# SimHash (64-bit fingerprint)
def simhash(text, bits = 64)
  tokens = text.split
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

# Hamming distance
def hamming_distance(hash_a, hash_b)
  (hash_a ^ hash_b).to_s(2).count('1')
end

# Build fingerprints for each split
def build_fingerprints(data, split_name, shingle_width, strip_quotes_flag, simhash_bits)
  data.map.with_index do |record, idx|
    row_id = record['message_id'] || record['id'] || "#{split_name}_#{idx}"
    content = normalize_content(record, strip_quotes_flag)
    
    {
      row_id: row_id,
      split: split_name,
      content: content,
      shingles: shingles(content, shingle_width),
      simhash: simhash(content, simhash_bits),
      thread_id: record['thread_id']
    }
  end
end

puts "Building fingerprints..."
train_fp = build_fingerprints(train_data, 'train', options[:shingle_width], options[:strip_quotes], options[:simhash_bits])
val_fp = build_fingerprints(val_data, 'val', options[:shingle_width], options[:strip_quotes], options[:simhash_bits])
test_fp = build_fingerprints(test_data, 'test', options[:shingle_width], options[:strip_quotes], options[:simhash_bits])

# Cross-split comparisons
def find_contamination(split_a, split_b, split_a_name, split_b_name, threshold, hamming_threshold)
  contaminated_pairs = []
  
  split_a.each do |fp_a|
    split_b.each do |fp_b|
      # Skip same thread (already handled by thread-level assignment)
      next if fp_a[:thread_id] && fp_a[:thread_id] == fp_b[:thread_id]
      
      # SimHash Hamming distance check
      hamming = hamming_distance(fp_a[:simhash], fp_b[:simhash])
      
      # Jaccard similarity check
      jacc = jaccard(fp_a[:shingles], fp_b[:shingles])
      
      if hamming <= hamming_threshold || jacc >= threshold
        contaminated_pairs << {
          split_a: split_a_name,
          split_b: split_b_name,
          row_a: fp_a[:row_id],
          row_b: fp_b[:row_id],
          jaccard: jacc.round(3),
          hamming: hamming,
          thread_a: fp_a[:thread_id],
          thread_b: fp_b[:thread_id]
        }
      end
    end
  end
  
  contaminated_pairs
end

puts "Detecting cross-split contamination..."
contamination = []
contamination.concat(find_contamination(train_fp, val_fp, 'train', 'val', options[:threshold], options[:hamming_threshold]))
contamination.concat(find_contamination(train_fp, test_fp, 'train', 'test', options[:threshold], options[:hamming_threshold]))
contamination.concat(find_contamination(val_fp, test_fp, 'val', 'test', options[:threshold], options[:hamming_threshold]))

puts "Found #{contamination.size} contaminated pairs"

# Apply quarantine policy
exclusion_ids = Set.new
case options[:quarantine_policy]
when 'quarantine_test'
  # Remove test/val items that contaminate train
  contamination.each do |pair|
    exclusion_ids << pair[:row_b] if pair[:split_b] == 'test' || pair[:split_b] == 'val'
  end
when 'quarantine_both'
  # Remove both sides
  contamination.each do |pair|
    exclusion_ids << pair[:row_a]
    exclusion_ids << pair[:row_b]
  end
when 'coassign'
  # Co-assign to same split (requires rematerialization logic)
  warn "WARN: coassign policy requires manual rematerialization - outputting report only"
else
  abort "Unknown quarantine policy: #{options[:quarantine_policy]}"
end

puts "Quarantine policy '#{options[:quarantine_policy]}': #{exclusion_ids.size} IDs flagged for exclusion"

# Contamination rate
total_records = train_data.size + val_data.size + test_data.size
contamination_pct = (contamination.size.to_f / total_records) * 100

# Build report
report = {
  timestamp: Time.now.utc.iso8601,
  splits: {
    train: train_data.size,
    val: val_data.size,
    test: test_data.size
  },
  contamination_pairs: contamination.size,
  contamination_pct: contamination_pct.round(2),
  threshold: options[:threshold],
  hamming_threshold: options[:hamming_threshold],
  shingle_width: options[:shingle_width],
  quarantine_policy: options[:quarantine_policy],
  exclusion_count: exclusion_ids.size,
  flagged_pairs: contamination,
  status: contamination_pct <= options[:max_contamination_pct] ? 'PASS' : 'FAIL'
}

# Write report
File.write(options[:output], JSON.pretty_generate(report))
puts "Contamination report written to #{options[:output]}"

# Write exclusion list
File.write(options[:exclusion_list], exclusion_ids.to_a.join("\n"))
puts "Exclusion list written to #{options[:exclusion_list]} (#{exclusion_ids.size} IDs)"

# Exit with error if contamination exceeds threshold
if report[:status] == 'FAIL'
  abort "FAIL: Contamination rate #{contamination_pct.round(2)}% exceeds max #{options[:max_contamination_pct]}%"
end

puts "PASS: Contamination rate #{contamination_pct.round(2)}% within acceptable limit"