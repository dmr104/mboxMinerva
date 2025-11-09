# mboxMinerva - SETUP & USAGE

## Quick Start

### 1. Install Dependencies
```bash
bundle install
pip install -r requirements.txt  # For eval scripts
```

### 2. Scrub PII from Raw Email Archive
```bash
# Parse mbox to JSON
ruby mbox_pre-parser.rb archive.mbox > emails/raw.json

# Scrub PII (CRITICAL: Do this BEFORE splits)
ruby lib/pii_scrubber.rb \
  --seed 42 \
  --deterministic \
  --save-map vault/pseudonym_map.json \
  emails/raw.json emails/scrubbed.json
```

**⚠️ Store `vault/pseudonym_map.json` securely (encrypted) and NEVER commit it.**

### 3. Create Immutable Splits
```bash
ruby splitter.rb \
  -i emails \
  -o splits \
  -m assignments.json \
  --incremental \
  -s 42 \
  --window-size 100 \
  --window-overlap 10
```

### 4. Materialize Train/Val/Test Files
```bash
ruby immutable_manifest.rb materialize -m assignments.json -o splits
```

### 5. Run Split Integrity Tests
```bash
rspec spec/split_integrity_spec.rb
```

**Tests enforce**:
- Threads never leak across splits
- Assignments never change (immutability)
- 80/10/10 distribution (±5% tolerance)

### 6. Train with Stratified Rehearsal
```bash
# Generate replay manifest
ruby lib/sampler.rb \
  data/old_train.json \
  data/new_train.json \
  --replay-ratio 1:4 \
  --batch-size 16 \
  --output data/replay_manifest.json

# Train model
ruby retrain.rb \
  --train-manifest data/replay_manifest.json \
  --val-split splits/val.jsonl \
  --base-model models/base \
  --output-path models/checkpoint_v1
```

### 7. Evaluate Before/After Fine-Tuning
```bash
python scripts/eval_before_after.py \
  --base-model models/base \
  --finetuned-model models/checkpoint_v1 \
  --test-data splits/test.jsonl
```

**Expected output**:
```
Base perplexity:       45.2
Fine-tuned perplexity: 32.1
Improvement:           +29.0%
✅ Fine-tuning IMPROVED model quality
```

## Data Safety
See [docs/data_safety.md](docs/data_safety.md) for:
- PII handling policy
- Data retention rules
- DSR (data subject request) procedures
- Threat model & mitigations

## CI/CD Integration
Add to `.github/workflows/train.yml`:
```yaml
- name: Scrub PII
  run: ruby lib/pii_scrubber.rb --seed 42 emails/raw.json emails/scrubbed.json

- name: Run split integrity tests
  run: rspec spec/split_integrity_spec.rb

- name: Evaluate checkpoint
  run: python scripts/eval_before_after.py --base-model base --finetuned-model checkpoint --test-data test.jsonl
```

## What's Implemented
✅ PII scrubbing at ingestion (`lib/pii_scrubber.rb`)
✅ Split integrity tests (`spec/split_integrity_spec.rb`)
✅ Data safety documentation (`docs/data_safety.md`)
✅ Before/after evaluation harness (`scripts/eval_before_after.py`)
✅ Immutable manifest architecture (`splitter.rb`, `immutable_manifest.rb`)
✅ Stratified rehearsal sampling (`sampler.rb`)

## Roadmap
- [ ] Implement `retrain.rb` (LoRA fine-tuning script)
- [ ] RAG embedding selection & benchmarking (bge-large vs OpenAI ada-002)
- [ ] nDCG/Recall@k metrics for retrieval quality
- [ ] Hard-negative mining for embedding training
- [ ] Automated DSR deletion workflow
- [ ] Post-training PII leakage scanner

## License
Copyright (c) 2025 dmr104. All rights reserved. See LICENSE for full text.
```

---

## FILE 6: .github/workflows/data_integrity.yml

```yaml
# .github/workflows/data_integrity.yml
name: Data Integrity & Security

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.2
          bundler-cache: true
      
      - name: Run split integrity tests
        run: |
          rspec spec/split_integrity_spec.rb
      
      - name: Verify PII scrubber (unit tests)
        run: |
          # Add unit tests for PIIScrubber class
          rspec spec/pii_scrubber_spec.rb
      
      - name: Check for committed secrets
        run: |
          # Ensure no pseudonym maps or .env files committed
          ! git ls-files | grep -E '(pseudonym_map\.json|\.env$)'
```

---

## Installation Instructions

1. Create the directory structure:
```bash
mkdir -p lib spec docs scripts .github/workflows vault
```

2. Copy each file above into the corresponding path

3. Set permissions:
```bash
chmod +x lib/pii_scrubber.rb scripts/eval_before_after.py
```

4. Add to .gitignore:
```
vault/pseudonym_map.json
.env
*.mbox
emails/raw.json
```

5. Install dependencies:
```bash
bundle install
pip install transformers torch tqdm numpy
```

6. Run tests:
```bash
rspec spec/split_integrity_spec.rb
```

## Key Features

✅ **PII Scrubber**: Deterministic pseudonymization with reversible mapping
✅ **Split Integrity Tests**: Enforce immutability, thread-level assignment, distribution balance
✅ **Data Safety Doc**: GDPR-aware policy with DSR procedures
✅ **Eval Harness**: Quantify fine-tuning improvement via perplexity
✅ **CI/CD Ready**: GitHub Actions workflow for automated testing
✅ **Security**: Never commit secrets, encrypted pseudonym maps

## Next Steps

1. Wire PII scrubber into your ingestion pipeline (before splitter.rb)
2. Run split integrity tests in CI on every commit
3. Use eval_before_after.py to validate each checkpoint
4. Implement remaining roadmap items (retrieval metrics, DSR automation)

===== update 1 to README_UPDATE.md =====

# mboxMinerva - README Update (DSR Export/Delete)

## New DSR Tools

Two CLI tools have been added to support **Data Subject Requests (DSR)** under GDPR/CCPA while maintaining immutable manifests and split integrity:

---

### **bin/dsr_export** - Export user data

Locates all records involving a subject (real email or pseudonym) and exports them to a JSONL bundle.

**Usage:**
```bash
bin/dsr_export --subject user@example.com --manifest manifest.jsonl --output dsr_export/
bin/dsr_export --subject PSEUDO_abc123 --threads  # export entire threads
```

**Options:**
- `-s, --subject SUBJECT` — Real email address or pseudonym (e.g., `PSEUDO_abc123`)
- `-m, --manifest PATH` — Path to manifest.jsonl (default: `manifest.jsonl`)
- `-o, --output DIR` — Output directory (default: `dsr_export/`)
- `-t, --threads` — Export entire threads containing the subject (not just individual messages)
- `-h, --help` — Show help

**Output:**
- `dsr_export/<subject>.jsonl` — All matching records
- `dsr_export/summary.txt` — Export metadata (timestamp, record count, threads)

---

### **bin/dsr_delete** - Delete user data (tombstoning)

Marks records for deletion by appending **tombstones** to `vault/dsr_tombstones.jsonl` without mutating immutable manifests.

**Usage:**
```bash
bin/dsr_delete --subject user@example.com --dry-run  # preview
bin/dsr_delete --subject user@example.com            # commit
bin/dsr_delete --subject PSEUDO_abc123 --threads     # delete entire threads
```

**Options:**
- `-s, --subject SUBJECT` — Real email address or pseudonym
- `-m, --manifest PATH` — Path to manifest.jsonl (default: `manifest.jsonl`)
- `-t, --tombstone PATH` — Tombstone file (default: `vault/dsr_tombstones.jsonl`)
- `-d, --dry-run` — Preview deletions without committing
- `--threads` — Delete entire threads containing the subject
- `-h, --help` — Show help

**How it works:**
1. Scans manifest for records matching the subject (using `vault/pseudonym_map.json`)
2. Appends tombstone entries to `vault/dsr_tombstones.jsonl` with message_id + timestamp
3. **Does not mutate** the original manifest (preserves immutability)
4. Your dataloader/trainer must filter out tombstoned message_ids at runtime

**Tombstone format:**
```json
{"message_id":"<sha256>","subject":"user@example.com","deleted_at":"2025-11-09T14:35:00Z","reason":"DSR deletion request"}
```

---

## Integration with Training Pipeline

### **Dataloader Filter (lib/dataloader.rb)**

dataloader is updated to skip tombstoned records in the following way:

```ruby
require 'json'
require 'set'

class DataLoader
  def initialize(manifest_path:, tombstone_path: 'vault/dsr_tombstones.jsonl')
    @manifest_path = manifest_path
    @tombstones = load_tombstones(tombstone_path)
  end

  def each_record
    File.foreach(@manifest_path) do |line|
      record = JSON.parse(line.strip)
      next if @tombstones.include?(record['message_id'])  # ← FILTER HERE
      yield record
    end
  end

  private

  def load_tombstones(path)
    return Set.new unless File.exist?(path)
    File.readlines(path).map { |l| JSON.parse(l.strip)['message_id'] }.to_set
  end
end
```

**Important:** Tombstones do **not** invalidate your train/val/test splits. The split assignment remains immutable (via hash bucketing), but tombstoned records are simply skipped during training. This ensures:
- No catastrophic forgetting (rehearsal samples remain valid)
- Reproducibility (re-running still yields the same splits, minus tombstoned IDs)
- Compliance (subject data is no longer trained on)

---

## Security & Privacy Notes

1. **Vault access control:**  
   `vault/pseudonym_map.json` and `vault/dsr_tombstones.jsonl` contain sensitive mappings. Encrypt at rest, restrict file permissions (`chmod 600`), and exclude from public repos (`.gitignore`).

2. **Identity verification:**  
   Before running `dsr_delete`, verify the requester's identity (e.g., email challenge, support ticket) to prevent malicious deletion requests.

3. **Audit trail:**  
   Each tombstone includes `deleted_at` and `reason`. Keep deletion logs for compliance audits (e.g., GDPR Article 30).

4. **Model retraining:**  
   After deletion, tombstones take effect on the **next training run**. Existing checkpoints may still encode deleted data. For complete erasure:
   - Retrain from scratch with tombstones active, **or**
   - Use unlearning techniques (e.g., gradient ascent on deleted records' loss)

5. **Backup hygiene:**  
   Apply tombstones to backup archives. Don't restore old manifests without re-applying `dsr_tombstones.jsonl`.

---

## DSR Workflow Example

### 1. User requests data export (GDPR Article 15)
```bash
bin/dsr_export --subject alice@example.com --threads --output exports/
# Deliver exports/alice_example_com.jsonl + summary.txt to requester
```

### 2. User requests deletion (GDPR Article 17 "Right to be Forgotten")
```bash
# Preview
bin/dsr_delete --subject alice@example.com --threads --dry-run

# Commit
bin/dsr_delete --subject alice@example.com --threads

# Next training run automatically filters tombstoned records
bin/retrain.rb --manifest manifest.jsonl  # reads vault/dsr_tombstones.jsonl
```

### 3. Verify deletion
```bash
# Check tombstone file
cat vault/dsr_tombstones.jsonl | grep alice@example.com

# Re-export (should return zero records)
bin/dsr_export --subject alice@example.com
```

---

## CI Integration

Add tombstone checks to `.github/workflows/data_integrity.yml`:

```yaml
- name: Validate tombstones
  run: |
    if [ -f vault/dsr_tombstones.jsonl ]; then
      # Check format
      ruby -rjson -e 'File.foreach("vault/dsr_tombstones.jsonl") { |l| JSON.parse(l.strip) }'
      
      # Ensure no duplicates
      cat vault/dsr_tombstones.jsonl | jq -r .message_id | sort | uniq -d | tee /tmp/dupes
      test ! -s /tmp/dupes || (echo "Duplicate tombstones found" && exit 1)
    fi
```

---

## Roadmap Additions

- [ ] **Automatic model unlearning:** Gradient ascent on deleted records before retraining
- [ ] **Bulk DSR processing:** CSV input for multiple subjects
- [ ] **Legal hold integration:** Flag threads exempt from deletion (e.g., litigation holds)
- [ ] **Anonymization alternative:** Offer "anonymize instead of delete" (replace with generic placeholders)

---

## Questions?

- **"Can I delete without breaking splits?"** Yes—tombstones preserve split assignments; records are just skipped at training time.
- **"What if I delete half a thread?"** Use `--threads` to delete entire conversations (recommended for privacy completeness).
- **"Do tombstones affect RAG?"** Yes—update your pgvector ingestion to skip tombstoned message_ids when embedding.

For issues or feature requests, open a GitHub issue or contact the maintainer.


========================================
Update 2 to FILE: lib/dataloader.rb
========================================

# DataLoader Tombstone Filtering Update

## Changes to `lib/dataloader.rb`

### Summary
`DataLoader` now automatically filters out DSR-tombstoned records at initialization, ensuring deleted subjects' data never enters training batches.

### New Parameters

#### `respect_tombstones:` (default: `true`)
- When `true`, loads `vault/dsr_tombstones.jsonl` and filters chunk_ids from the schedule
- Set to `false` to disable filtering (for debugging or historical replays)

#### `tombstones_path:` (default: `'vault/dsr_tombstones.jsonl'`)
- Override the tombstone file location if needed

### Example Usage

**Library mode (default behavior):**
```ruby
require_relative 'lib/dataloader'

loader = DataLoader.new(
  schedule_path: 'epoch_00001_schedule.json',
  batch_size: 32,
  seed: 42
  # respect_tombstones: true by default - tombstoned chunks auto-filtered
)

loader.each_batch do |batch_chunk_ids|
  # batch_chunk_ids never contains tombstoned records
  train_on_batch(batch_chunk_ids)
end
```

**Disable filtering (not recommended in production):**
```ruby
loader = DataLoader.new(
  schedule_path: 'epoch_00001_schedule.json',
  batch_size: 32,
  seed: 42,
  respect_tombstones: false  # forces inclusion of tombstoned records
)
```

**CLI mode:**
```bash
# Default: respects tombstones
bin/dataloader --schedule epoch_00001_schedule.json --batch-size 32 --seed 42

# Disable tombstone filtering
bin/dataloader --schedule epoch_00001_schedule.json --batch-size 32 --seed 42 --no-respect-tombstones
```

### Behavior

1. **At initialization**, if `respect_tombstones: true` (default):
   - Loads `vault/dsr_tombstones.jsonl`
   - Parses each line, extracting `chunk_id` fields
   - Filters schedule to remove any matching chunk_ids
   - Logs the number of filtered chunks to stderr

2. **During iteration**:
   - Yields batches as before (with optional within-batch shuffling)
   - Tombstoned records are already removed from schedule, so batches are clean

3. **If tombstone file doesn't exist**:
   - No filtering occurs (schedule used as-is)
   - No warnings emitted

### Integration Notes

- **No changes required** in `bin/retrain` or other consumers - existing code automatically gets tombstone filtering
- **Determinism preserved**: schedule filtering happens before batching/shuffling, so RNG seeds still produce identical batches (after tombstones removed)
- **Performance**: tombstone set loaded once at init (O(n) scan), schedule filtering is O(m) where m = schedule size
- **Thread-safety**: load tombstones at init, no mutation during iteration

### Testing

Verify filtering works:

```bash
# 1. Create a fake tombstone
echo '{"chunk_id": "abc123-chunk-5", "deleted_at": "2025-11-09T13:33:00Z"}' >> vault/dsr_tombstones.jsonl

# 2. Run dataloader in CLI mode
bin/dataloader --schedule test_schedule.json --batch-size 8 --seed 42

# Expected output should show:
# DataLoader: Loaded 1 tombstoned chunks from vault/dsr_tombstones.jsonl
# DataLoader: Filtered out 1 tombstoned chunks (N → N-1)
```

### Security Considerations

- **Tombstone file access**: ensure `vault/dsr_tombstones.jsonl` has appropriate read permissions (0600, same as pseudonym vault)
- **Audit trail**: filtered chunk counts logged to stderr for compliance verification
- **Fail-safe**: if tombstone file is corrupted, dataloader warns but continues (skips malformed lines)

### Migration Path

1. **Drop in the updated `lib/dataloader.rb`** (remove shebang if present - it's a library)
2. **No code changes needed** in existing consumers (retrain.rb, etc.)
3. **Existing schedules remain valid** - filtering is transparent
4. **To verify**: check stderr output during next training run for "Loaded N tombstoned chunks" message

---

**Questions?** The filtering is active-by-default to ensure GDPR/CCPA compliance - tombstoned data never enters training unless explicitly overridden.