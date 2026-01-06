# Fuzzy Deduplication for mbox_pre-parser.rb
# Using SimHash (Locality-Sensitive Hashing) for near-duplicate email detection

## Overview

SimHash generates a 64-bit "fingerprint" for text where similar documents produce
similar fingerprints. Unlike MD5/SHA, small changes result in small hash differences,
allowing fuzzy matching via Hamming distance (count of differing bits).

## Installation

```bash
# The simhash2 gem is pure Ruby - no native extensions needed
sudo gem install simhash2

# Or add to your Gemfile:
echo "gem 'simhash2'" >> Gemfile
bundle install
```

## Option A: Standalone Dedup Script (run before pre-parser)

Create `dedup_mbox.rb` to filter an mbox file before parsing:

```ruby
#!/usr/bin/env ruby
# dedup_mbox.rb - Remove near-duplicate emails from mbox before parsing
# Usage: ruby dedup_mbox.rb input.mbox > deduped.mbox

require 'simhash2'
require 'mail'

HAMMING_THRESHOLD = 3  # Bits different - lower = stricter (0 = exact match only)

seen = {}  # fingerprint => first occurrence message_id
duplicates = 0
kept = 0

ARGF.binmode
raw = ARGF.read

# Split mbox by "From " line (standard mbox delimiter)
messages = raw.split(/^From (?=\S+@\S+ )/)

messages.each_with_index do |msg, idx|
  next if msg.strip.empty?
  
  # Reconstruct the "From " line for valid mbox format
  full_msg = idx == 0 ? msg : "From #{msg}"
  
  begin
    mail = Mail.read_from_string(full_msg)
    body = (mail.text_part&.decoded || mail.body.decoded || "").encode('UTF-8', invalid: :replace, undef: :replace)
    
    # Normalize: lowercase, collapse whitespace, strip signatures
    normalized = body.downcase.gsub(/\s+/, ' ').gsub(/^-- ?\n.*$/m, '').strip
    
    next if normalized.length < 50  # Skip tiny messages (signatures, bounces)
    
    fingerprint = Simhash.generate(normalized)
    
    # Check against all seen fingerprints for near-matches
    is_dup = seen.any? do |fp, _|
      Simhash.hamming_distance(fingerprint, fp) <= HAMMING_THRESHOLD
    end
    
    if is_dup
      duplicates += 1
      STDERR.puts "DUP [#{duplicates}]: #{mail.message_id || 'no-id'} (subject: #{mail.subject&.slice(0,40)})"
    else
      seen[fingerprint] = mail.message_id
      kept += 1
      puts full_msg  # Write to stdout for piping
    end
    
  rescue => e
    STDERR.puts "WARN: Failed to parse message #{idx}: #{e.message}"
    puts full_msg  # Keep unparseable messages to be safe
    kept += 1
  end
end

STDERR.puts "\n=== Summary ==="
STDERR.puts "Kept: #{kept}, Duplicates removed: #{duplicates}"
```

**Usage:**
```bash
ruby dedup_mbox.rb archive.mbox > archive_deduped.mbox
ruby mbox_pre-parser.rb archive_deduped.mbox --output emails/
```

## Option B: Integrate into mbox_pre-parser.rb

Add this near the top of your pre-parser:

```ruby
require 'simhash2'

# Configuration
DEDUP_ENABLED = true
HAMMING_THRESHOLD = 3  # 0=exact only, 3=catches salted spam, 5+=very fuzzy

# State (reset per run - for cross-run dedup, persist to JSON file)
$seen_fingerprints = {}
$dedup_stats = { kept: 0, skipped: 0 }
```

Add this helper method:

```ruby
def is_near_duplicate?(body_text)
  return false unless DEDUP_ENABLED
  return false if body_text.nil? || body_text.length < 50
  
  # Normalize for comparison
  normalized = body_text.downcase.gsub(/\s+/, ' ').gsub(/^-- ?\n.*$/m, '').strip
  fingerprint = Simhash.generate(normalized)
  
  # Check Hamming distance against all seen fingerprints
  $seen_fingerprints.each do |fp, msg_id|
    if Simhash.hamming_distance(fingerprint, fp) <= HAMMING_THRESHOLD
      STDERR.puts "  [DEDUP] Near-duplicate of #{msg_id}"
      $dedup_stats[:skipped] += 1
      return true
    end
  end
  
  # New unique content - remember it
  $seen_fingerprints[fingerprint] = @current_message_id
  $dedup_stats[:kept] += 1
  false
end
```

In your message processing loop, add the check:

```ruby
# After extracting body but before writing to output:
body = mail.body.decoded.encode('UTF-8', invalid: :replace, undef: :replace)

if is_near_duplicate?(body)
  next  # Skip this message
end

# ... rest of your existing output logic ...
```

At the end, print stats:

```ruby
STDERR.puts "Dedup stats: kept=#{$dedup_stats[:kept]}, skipped=#{$dedup_stats[:skipped]}"
```

## Option C: Persistent Cross-Run Deduplication

For deduping across multiple mbox batches, persist fingerprints to disk:

```ruby
require 'simhash2'
require 'json'

FINGERPRINT_DB = 'fingerprints.json'

def load_fingerprints
  return {} unless File.exist?(FINGERPRINT_DB)
  JSON.parse(File.read(FINGERPRINT_DB)).transform_keys(&:to_i)
rescue
  {}
end

def save_fingerprints(fps)
  File.write(FINGERPRINT_DB, JSON.pretty_generate(fps.transform_keys(&:to_s)))
end

# At script start:
$seen_fingerprints = load_fingerprints

# At script end:
save_fingerprints($seen_fingerprints)
```

## Tuning HAMMING_THRESHOLD

| Threshold | Behavior | Use Case |
|-----------|----------|----------|
| 0 | Exact content match only | Conservative - won't miss anything |
| 1-2 | Very similar (typo-level) | Safe for most corpora |
| 3 | Default - catches salted spam | Recommended starting point |
| 4-5 | Fuzzy - catches rewrites | May false-positive on short msgs |
| 6+ | Very aggressive | Risk of killing legitimate similar emails |

**Test first:** Run with `--dry-run` logging to see what WOULD be deduplicated
before committing to a threshold.

## Performance Notes

- SimHash generation: ~5000 msgs/sec on modest hardware
- Memory: ~16 bytes per fingerprint (64-bit int + overhead)
- 500K emails ≈ 8-16MB fingerprint index in RAM
- The O(N) scan per message is the bottleneck for huge corpora (>1M)
  - For scale, consider BK-trees or LSH bucketing instead

## Why Not Just Use message_id?

- `message_id` catches exact resends but misses:
  - Forwarded copies (new message_id)
  - Mailing list duplicates (list rewrites headers)
  - Spam blasts (each copy has unique id)
  - Re-sent drafts with modifications
  
SimHash catches content similarity regardless of headers.

## Combined Strategy

For best results, layer both:

```ruby
# Level 1: Exact message_id dedup (fast, certain)
if $seen_message_ids.include?(mail.message_id)
  next
end
$seen_message_ids.add(mail.message_id)

# Level 2: Fuzzy content dedup (slower, catches more)
if is_near_duplicate?(body)
  next
end
```