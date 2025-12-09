## Architectural Components

### 1. Hash-Bucket Deterministic Assignment

Instead of random shuffling, we use **deterministic hash bucketing**:

```ruby
bucket = Digest::SHA256.hexdigest("#{thread_id}-#{seed}").to_i(16) % 100
split = case bucket
  when 0..79 then 'train'   # 80%
  when 80..89 then 'val'    # 10%
  else 'test'                # 10%
end
```

**Benefits**:
- Same seed + same thread_id = same split (forever)
- No randomness = no accidental drift
- Quota enforcement at bucket level

### 2. Windowing for Mega-Threads

Long threads are sliced into **overlapping windows**:

```
Thread with 250 messages, window_size=100, overlap=10:
  window_0: messages 0-99
  window_1: messages 90-189   (10-message overlap)
  window_2: messages 180-249
```

**All windows inherit the thread's split assignment** - if `thread_xyz` is assigned to `train`, then `thread_xyz_window_0`, `thread_xyz_window_1`, etc. all go to train.

**Rationale**: Windows are overlapping "study slices" of one conversation, not independent examples.

Both --window-size and --window-overlap (options to splitter.rb) are fixed in the manifest creation within assignments.json;
therefore these **Window flags** are missing from retrain.rb, because retrain.rb merely consumes that manifest.


### 3. Sharding (Orthogonal Concept)

`--save-train-shards` in `retrain.rb` splits the **already-assigned train set** into multiple files for I/O performance:

```
train_shard_0.jsonl  (10k examples)
train_shard_1.jsonl  (10k examples)
...
```

**Not split assignment** - just packaging for faster loading/resuming. Use both windowing (logical slicing) and sharding (physical I/O) together.

---

## Tool Chain

### **mbox_pre-parser.rb**

Parses raw mbox into JSON with Message-Id, thread_id, subject, body, etc.:

```bash
mbox_pre-parser.rb my_archive.mbox > emails/intermediate.json
```

### **splitter.rb**

Assigns/appends IDs to the immutable manifest and outputs split directories:

```bash
splitter.rb \
  -i emails \
  -o split_output \
  -m assignments.json \
  --incremental \
  -s 42 \
  --window-size 100 \
  --window-overlap 10
```

**Flags**:
- `-i`: Input directory with intermediate.json
- `-o`: Output directory for split JSONLs
- `-m`: Manifest file (reused forever)
- `--incremental`: Only process new IDs not in manifest
- `-s`: Hash seed (never change after first run!)
- `--window-size/--window-overlap`: Chunking for mega-threads

**On first run**: Creates `assignments.json` and assigns all IDs  
**On retrain**: Reads existing manifest, only appends new IDs with same deterministic logic

### **immutable_manifest.rb**

Utility for manifest operations:

```bash
# Add a single ID manually
immutable_manifest.rb assign -m assignments.json -i msg@example.com -t thread_abc -s 42

# Materialize split lists from manifest
immutable_manifest.rb materialize -m assignments.json -o split_output

# Inspect manifest stats
immutable_manifest.rb stats -m assignments.json
```

**Materialize** reads the manifest and generates:
```
split_output/train.jsonl
split_output/val.jsonl
split_output/test.jsonl
```

### **retrain.rb** (with shard_window_manager.rb)

CPT training script with rolling-window incremental learning:

```bash
retrain.rb \
  --train splits/train.jsonl \
  --val splits/val.jsonl \
  --save-train-shard data/shards \
  --base-model model_v1.pth
  --keep-shards 8
```

**Sampler.rb** in the CI Workflow Pipeline

#### Overview

`sampler.rb` (StratifiedReplaySampler) implements stratified rehearsal sampling to prevent catastrophic forgetting during incremental CPT training. It ensures **rare senders and threads** get minimum representation in each epoch's rehearsal quota, while maintaining global proportionality.

---

#### What It Does

**StratifiedReplaySampler** takes **old training data** (from previous shards), builds hierarchical buckets (sender → thread → samples), and samples a stratified rehearsal batch that:

1. **Guarantees minimum representation** for each sender/thread bucket (default: 2 samples/bucket).
2. **Fills remaining quota proportionally** by sender frequency and thread weight.
3. **Interleaves rehearsal batches with new data** at a configurable ratio (default: 1:4 replay:new).

---

#### Key Class API

```ruby
require 'sampler'

# Initialize with old training data (JSON array of {sender:, thread_id:, ...})
sampler = StratifiedReplaySampler.new(
  old_train_data,              # Array of prior training examples
  min_per_bucket: 2            # Minimum samples per sender/thread bucket
)

# Sample n rehearsal examples with stratified weighting
rehearsal_batch = sampler.sample(n)  # Returns Array of n samples
```

---

#### Integration in CI Workflow

##### **1. Invocation Point**

`sampler.rb` is invoked **before** `retrain.rb` to prepare a **replay manifest** for the current training window:

```bash
# Step 1: Generate stratified replay batch for window_idx=3
ruby lib/sampler.rb \
  data/old_shards/shard_0_2_train.json \
  data/shard_3_train.json \
  --replay-ratio 1:4 \
  --batch-size 16 \
  --min-per-bucket 2 \
  --output data/shard_3_replay_manifest.json
```

**Inputs:**
- `OLD_TRAIN.json` — Consolidated train-split from previous shards (0–N-1).
- `NEW_TRAIN.json` — Current window's train-split examples (shard N).
- `--replay-ratio` — Rehearsal:new interleave ratio (e.g., 1:4 = 20% rehearsal).
- `--batch-size` — Batch size for interleaving calculation.
- `--min-per-bucket` — Minimum samples per sender/thread to avoid rare-bucket erasure.
- `--output` — Path to write the interleaved training manifest (rehearsal + new, shuffled).

**Outputs:**
- `shard_3_replay_manifest.json` — Interleaved batch manifest (new + stratified replay, shuffled).

---

##### **2. CI Workflow Integration**

A CI workflow pipeline is the automated build-test-lint-and-often-deploy sequence that runs on code
changes.  It used YAML because YAML is a human-readable, declarative, versioned config that cleanly 
describes jobs, and dependencies.  The CI service parses the YAML, starts runners (VM/containers), 
injects secrets, restores caches, and executes the directed acyclic graphs (DAG) with concurrency rules,
uploads artifacts, posts logs and status checks, and optionally deploys.

**Full pipeline sequence:**

```yaml
# .github/workflows/cpt_train.yml
steps:
  - name: Load assignments.json
    run: |
      # assignments.json: frozen split assignments (id → {split, thread_id, window_idx})
      # Determines which thread-windows belong to train/val/test per window_idx.
  
  - name: Extract current window train-split
    run: |
      # Parse assignments.json to extract train-split IDs for current window_idx=N
      ruby scripts/extract_split.rb \
        --assignments data/assignments.json \
        --window-idx $WINDOW_IDX \
        --split train \
        --output data/shard_${WINDOW_IDX}_train.json
  
  - name: Consolidate old shards (0–N-1)
    run: |
      # Merge all prior train-split shards into one consolidated file
      cat data/shard_0_train.json ... data/shard_$((WINDOW_IDX-1))_train.json \
        | jq -s 'add' > data/old_shards_train.json
  
  - name: Generate stratified replay manifest
    run: |
      ruby lib/sampler.rb \
        data/old_shards_train.json \
        data/shard_${WINDOW_IDX}_train.json \
        --replay-ratio 1:4 \
        --batch-size 16 \
        --min-per-bucket 2 \
        --output data/shard_${WINDOW_IDX}_replay_manifest.json
  
  - name: Train with replay manifest
    run: |
      ruby retrain.rb \
        --model-path models/checkpoint_window_$((WINDOW_IDX-1)) \
        --train-manifest data/shard_${WINDOW_IDX}_replay_manifest.json \
        --val-split data/shard_${WINDOW_IDX}_val.json \
        --output-path models/checkpoint_window_${WINDOW_IDX} \
        --epochs 3 \
        --lr 5e-5 \
        --batch-size 16
  
  - name: Upload checkpoint + replay manifest
    uses: actions/upload-artifact@v3
    with:
      name: checkpoint_window_${WINDOW_IDX}
      path: |
        models/checkpoint_window_${WINDOW_IDX}/
        data/shard_${WINDOW_IDX}_replay_manifest.json
```

---

##### **3. Deterministic Seeding**

To ensure **reproducible rehearsal sampling** across CI runs:

```ruby
# In sampler.rb, add seed parameter:
def initialize(old_train_data, min_per_bucket: 2, seed: 42)
  @seed = seed
  Random.srand(@seed)  # Set global seed
  # ... rest of initialization
end

def sample(n)
  rng = Random.new(@seed)  # Use seeded RNG for reproducibility
  # Replace .sample(take) with .sample(take, random: rng)
end
```

**CLI flag:**
```bash
ruby sampler.rb ... --seed 12345
```

---

##### **4. Caching & Artifacts**


**Cache old_shards_train.json** to avoid re-parsing assignments.json every run:

```yaml
- name: Cache old shards
  uses: actions/cache@v3
  with:
    path: data/old_shards_train.json
    key: old-shards-${{ env.WINDOW_IDX }}
```

**Upload replay manifests** as CI artifacts for audit/debug:

```yaml
- name: Upload replay manifest
  uses: actions/upload-artifact@v3
  with:
    name: replay_manifest_window_${{ env.WINDOW_IDX }}
    path: data/shard_${WINDOW_IDX}_replay_manifest.json
```

---

#### Rationale

**Why Stratified Sampling?**
- **Prevents rare-sender erasure:** Ensures low-volume senders/threads get minimum rehearsal slots.
- **Maintains global distribution:** Proportional sampling respects overall sender frequency.
- **Catastrophic forgetting mitigation:** Interleaving old examples during incremental training prevents model collapse on new data.

**Why Pre-generate Manifest?**
- **Decouples sampling from training:** Sampler.rb runs once per window, output is cached/auditable.
- **Enables batch-level control:** Retrain.rb consumes a static manifest, no runtime randomness.
- **Reproducibility:** Seeded sampling + frozen manifest = deterministic training pipeline.

---

#### Alternative: Inline Sampler in retrain.rb

If you prefer **on-the-fly sampling** instead of pre-generated manifests:

```ruby
# In retrain.rb:
require 'sampler'

old_train = JSON.parse(File.read('data/old_shards_train.json'))
new_train = JSON.parse(File.read("data/shard_#{window_idx}_train.json"))

sampler = StratifiedReplaySampler.new(old_train, min_per_bucket: 2, seed: 42)

# Interleave during epoch loop:
new_train.each_slice(batch_size * 4) do |new_chunk|
  replay_batch = sampler.sample((new_chunk.size * 0.25).ceil)
  combined = (new_chunk + replay_batch).shuffle(random: Random.new(42))
  train_batch(combined)
end
```

**Trade-off:**
- ✅ Simpler pipeline (no separate sampler.rb step).
- ❌ Harder to audit/cache rehearsal selection.
- ❌ Seeding must be managed inside retrain.rb.

---


# The following was added by David Roderick


## sampler.rb
Step 4: Create a mixed group of 20% replayed email threads with 80% new threads from batches

sampler.rb builds the actual training mix.  It takes the historical mixed emails (old_train.json) and the fresh batch
(new_train.json) and samples them with the requested ratio (e.g. 1:4 = one part old to 4 prts new), using the stratified 
replay rules and writes "mixed_train.json", which is exactly what we pass to retrain.rb on a run of lora_checkpoint_selector.rb 


# Prior to RAG
```bash
jq -c '.[]' train.json > train.jsonl
jq -c '.[]' val.json > val.jsonl
jq -c '.[]' test.json > test.jsonl

cat train.jsonl val.jsonl test.jsonl > Rag_train.jsonl 
```
The advantage of jsonl for weaviate database is that JSONL lets you stream and append with one object per line, 
cat/pipe/parallelize shards trivially

# Plan for RAG
1. Build a RAG baseline (Postgres+pgvector)
2. train LoRA on Colab with retrain.rb with train.jsonl using --early-stop --old-train old_train.json




## End-to-End Workflow

### **Initial Training**

1. **Parse mbox**:
   ```bash
   mbox_pre-parser.rb archive_v1.mbox > emails/intermediate.json
   ```

2. **Split with manifest creation**:
   ```bash
   splitter.rb -i emails/intermediate.json -o splits -m assignments.json --incremental -s 42 \
     --window-size 100 --window-overlap 10
   ```
   ➜ Creates `assignments.json` with frozen assignments

3. **Materialize splits**:
   ```bash
   immutable_manifest.rb materialize -m assignments.json -o splits
   ```
   ➜ Generates `splits/{train,val,test}.jsonl`

4. **Train model**:
   ```bash
   retrain.rb --train splits/train.jsonl --val splits/val.jsonl \
     --save-train-shard data/shards base-model model_v1.pth
   ```

### **Incremental Retrain (New Emails Arrive)**

1. **Parse new mbox**:
   ```bash
   Mbox_pre-parser.rb archive_v2.mbox > emails_new/intermediate.json
   ```

2. **Re-run splitter with same manifest and seed**:
   ```bash
   splitter.rb -i emails_new -o splits -m assignments.json --incremental -s 42 \
     --window-size 100 --window-overlap 10
   ```
   ➜ **Only appends new IDs** to `assignments.json`; existing entries untouched

3. **Re-materialize**:
   ```bash
   immutable_manifest.rb materialize -m assignments.json -o splits
   ```
   ➜ Updates splits with new data, but old assignments stay frozen

4. **Continue training**:
   ```bash
   retrain.rb --train splits/train.jsonl --val splits/val.jsonl \
     --base-model model_v1.pth --save-train-shard data/shards
   ```

---
