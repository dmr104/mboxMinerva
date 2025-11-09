# Machine Learning README: End-to-End CPT/RAG Pipeline for Email LoRA Fine-Tuning

## Key concepts

Each thread_id gets ONE frozen split, and all its windows inherit that split, so overlap duplicates data on 
within train (or val, or test) for better context coverage, but never leak's the same thread's context across
splits.  It is split-pure by design.

Shards are built by manifest_builder.rb from assignments.json.

manifest_builder shards only past windows (window_idx < W) for rehearsal; the current window W is emitted separately
as new_train.json (no shards).

shard-size is how many records go into each output file when materializing a split -- it chops train/val/test into
numbered shards (e.g. train-00001.json[.gz]) for smaller files and parallel loading: it is packaging only, with no 
effect upon windowing or assignments.

retrain.rb implements deterministic LoRA fine-tuning wired to StratifiedReplaySampler, length bucketing, RAG 
evaluation, and checkpoint selection. It is a deterministic LoRA fine-tuning pipeline with replay-based continual 
learning.

the retrain.rb script uses the input file as "new_train.json", which is the fresh group of emails 
processed together (a batch), which we want the llm (large language model) to learn from now.  

On the first run of retrain.rb we can skip old_shard_train.json because on the first run there is nothing to replay, 
so just feed the new batch (train.json).  

Replay only matters on subsequent runs in order to rehearse past fine-tuning data and to avoid forgetting.  
retrain.rb has --early-stop --patience and --min-delta-flags wired to HuggingFaceStoppingCallback. 

How is new_train.json created from approximately 50 email batches weekly? How does it get into train? Is is created 
from assignments.json? 

Answer. new_train.json is just "this week's window train IDs", built by filtering assignments.json for split=train where 
window_idx==W after splitter.rb ingests the new ~50 emails, chunks them, assigns frozen splits and window, and appends those rows
to assignments.json, 
e.g. to read from assignments and create the new_train.json data, right after splitter.rb call 
`window_filter.rb --assignments assignments.json --window-idx $W --split train > new_train.json` 

You rerun splitter.rb whenever new emails land (or on a schedule) to append only the new chunk IDs with their deterministic split; it must be idempotent and append-only (never rewrites prior entries), while everything else -- sampler/retrain/evaluator/selector -- only 
reads assignments.json and uses fresh rehearsal manifests as needed, which is a newly generated old_shard_train.json -- a deterministic,
stratified, length-bucketed, capped list of past-train chunk_ids from outside the current rolling window -- produced with a seeded 
pseudorandom number generator so replay is balanced and reproducible; you remake it whenever the window advances or you change caps/strata/see, never modifiying assignments.json.  By default, old_shards_train.json only includes past-train IDs from shards outside the 
active rolling window.  You create a fresh rehearsal manifest by running the manifest_builder.rb to regenerate old_shards_manifest.json from assignments.json

retrain.rb is read-only in datasets: it loads new_train.json (current W) plus old_shards_train.json, and with replay, only writes
checkpoints and metrics -- it never edits new_train.json or assignments.json, so the rehearsal is mixed at train time without
contaminating the source files.

Each email gets a name tag. Once we decide "this email is for testing, not training," we may write it 
in a permanent marker. Forever. Even if if you feed in new emails later the old ones stay in their assigned buckets.
We don't append to train.json at all.  We append new items to assignment.json and emit a fresh shard file each 
run.

We make assignments.json a single append-only map of id => {split: train/val/test, thead_id, window_index?};
the hash-bucket "buckets" are only used during assignment, not stored, and you can always materialize 
train/val/test list from this map when needed.

We keep two layers:
1) An immutable split manifest (assignments.json) that deterministically assigns each thread/message 
to train/val/test and never changes for existing IDs (only adds new IDs on ingest); and 
2) rolling continuous pre-training snapshots (e.g. train_2025-11-04.json) that retrain.rb/shard-window-manager 
samples from the train paritition by time/size.

We parse, split, and materialize on the given mbox.  
1) mbox_pre-parser.rb my_mbox > emails/intermediate.json
2) splitter.rb -i emails -o splits -m assignments.json --incremental -s 42 --window-size 100 --window-overlap 10
which create 100-message windows with 10-message overlap.  All windows per thread share the same split assignment.
A window is a sliding, contiguous slice of one thread (size N, step N overlap) which becomes one example with a stable
window_id inheriting the thread's split.  Window's are overlapping "slices" of one conversation you study piece by piece 
(e.g 100 messages at a time), while the --save-train-shards option to retrain.rb just boxes up the already-picked 
training pile into multiple files for faster loading.  

On retrains we just re-run step 2 with new mail to append, then materialize again

IDs = Message-Id (email header), thread_id (grouped messages); and for mega-threads that which get chunked 
into rolling windows, thread-window chunk IDs like "thread_abc_window_0".  

A "run" is a single invocation run of retrain.rb by a cycle, i.e. one end-to-end retraining pass.

Chunks are the training examples we created by sliding a window over each email thread, each stamped with chunk_id +
thread_id + window_idx + split; they are not whole threads or raw emails. These are put within assigments.json.

Both splitter.rb and sampler.rb adopt a sliding window approach 

A "slice" is just a contiguous window from one thread picked deterministically from our sliding window to form one chunk.

A "rehearsal" is a "replay": which is a small, deterministic, stratified slice of thread-window chunks which are marked as
split=train within assignments.json;

A thread-window chunk is a single training example made by taking a deterministic sliding slice of one email thread 
(subject + messages up to a budget token) at a specific window_idx, stamped with chunk_id/thread_id/split within 
assignments.json -- it is basically a bite-size snapshot of that thread corresponding to the window_idx which the dataloader 
is training upon.

The dataloader (lib/dataloader.rb -- instantiated from retrain.rb) walks the thread-window chunks_ids which are marked 
as split=train within assignments.json, tokenizing and collating them, and feeds deterministic batches bucketed by length 
to the trainer.  Val and test use separate eval loader and never leak into train. 

The trainer is Train.train within lib/trainer.rb; and is invoked from retrain.rb, and which runs through batches again and 
again, over and over, checking responses and adjusting the model's weights, saving progress, and pausing for validation. 

A deterministic batch bucketed by length (also known as a length-bucketed batch) is a group of training examples of 
similar length (e.g. 0-256, 257-512).  This is done so that each batch has minimal of padding, a predictable memory footprint,
leading to a faster throughput whereby batches are sampled deterministically from one bucket at a time instead of 
randomly mixing short and log chunks.

window_idx is the monotonically increasing time-bucket tag we stamp on each thread-window chunk to mark which 
rolling training window it belongs to.  A run just takes the last N indices (plus a tiny rehearsal) without reshuffling
shards or changing splits.  

A rehearsal (or playback) curbs "forgetting" while strictly honouring immutable splits and assignments without any reshuffling
or reassigning.

We can concatenate the latest shards as a moving window to create old_train.json (which is an input file to sampler.rb), 
discarding from this run the old shards which are outside of that window.  When retrain.rb saves a shard it triggers 
shard_window_manager.rb which maintains this rolling window of our N most recent train shards (default 5).

The --save-train-shard DIR, option of retrain.rb states "Archive the final train dataset (new + replay) as timestamped 
JSONL shard".  This snapshots the exact active training set for this run (new windows + rehearsal) so we can version it and 
reload it fast later -- it is an archive of what you trained on, not a change to assignments.json or the original source 
shards.  To change windows means to regenerate the manifest file as "extension.json" with new IDs.

old_shards_train.json differs from assignments.json in that old_shards_train.json is the old_shards_train.json is the 
ephemerel rehearsal manifest -- which is a filtered list of chunks whose chunk_ids are marked with split=train, and which 
are bucketed by length from older shards only.  This ought to include those shards which are outside of the rolling window 
(i.e. don't delete them), and preferably exclude those chunks which are from within the active rolling window.  This is 
done so as to avoid double-dipping (also called leakage). old_shards_train.json is fed into the sampler for replay and 
can be generated per window.

old_shard_train.json is past only rehearsal (all windows < W).  new_train.json is only this week's W and sampler takes their 
union by chunk_id.  So there is no duplication as long as manifest_builder.rb  excludes W and assignmentsjson remains append only
with stable IDs.

assignments.json is append-only, and defines each split (each assignation of each chunk) for all time immutably. 

splitter.rb groups by thread_id, hashes with a deterministic seed to assign train/val/test (80/10/10), writes immutable 
assignments.json, and crucially when --window-size is enabled, ALL windows of a thread inherit the SAME split "All windows of a 
thread share the same split", so there is not any context leakage across train/val/test

In your pipeline: splitter.rb shards emails into chunks and writes the immutable assignments.json (train/val/test per ID); length_metadata.json and window_idx map chunk lengths and deterministic slice windows; 

old_shards_train.json is the regenerable rehearsal manifest (past-train IDs outside the rolling window); 

retrain.rb wires it all up - instantiates StratifiedReplaySampler from sampler.rb (length buckets + replay:new ratio, seeded RNG), feeds DataLoader → Trainer to produce LoRA checkpoints; 

retrain.rb has the flag as --save-train-shard which saves each shard with a unique filename.

RAG_evaluator.rb runs post-train to score each checkpoint (perplexity, RAG@K, retrieval recall) on val/test; 

lora_checkpoint_selector.rb parses eval_results.json, applies your weighted score, and emits best_checkpoint.txt (optionally symlink/upload for deploy); 

### lora_checkpoint_selector.rb
lora_checkpoint_selector.rb 
 Orchestrates LoRA adapter training & selection based on validation loss:
   1) Scans checkpoint directory for adapters
   2) Reads trainer_state.json to find checkpoint with lowest eval_loss
   3) Caches best checkpoint
   4) Optionally re-trains with adjusted hyperparameters if improvement lags
   5) Freezes (preserves) or merges best adapter into base model

 Basic usage: select best checkpoint by val_loss
 ```bash
 ruby lora_checkpoint_selector.rb \
     --checkpoint-dir ./checkpoints/run_001 \
     --merge-cmd 'ruby merge_lora.rb --adapter {CHECKPOINT} --out final_model'
```

With retraining on plateau
```bash
ruby lora_checkpoint_selector.rb \
     --checkpoint-dir ./checkpoints/run_001 \
     --retrain-cmd 'ruby retrain.rb --train mixed.json --val val.json --old-train old_train.json \
                        --output checkpoints/run_001 --lr 2e-4 --epochs 3 --replay-ratio 0.2 \
                        --early-stop --patience 3 --min-delta 0.001 \
                        --save-train-shard data/train_shards \
                        --update-old-train --keep-shards 5 --shard-manager ./shard_window_manager.rb'
     --improvement-threshold 0.02 \
     --max-retrain-attempts 2 \
     --freeze
```

CI just orchestrates these steps, and only splitter.rb ever mutates assignments.json - everything else is deterministic, read-only, and reproducible per seed/epoch.

retrain.rb expects a --rehearsal-manifest as input (doesn't generate it).  

The manifest_builder.rb reads assignments.json, filters train IDs outside of current window_idx, applies stratification/caps, 
and writes old_shards_train.json.

The role of sampler.rb is to build the epoch schedule.  It groups those single training example made by taking a 
deterministic sliding slice of one email thread which are marked as split=train within assignments.json, by chunk_id
(where a "chunk" is the training examples we created by sliding a window over each email thread), and it groups those
chunks into "length-buckets" (that is buckets which are catagorised by their length), interleaving the rehearsal quota.  
It then does deterministic reshuffling by seed per epoch (like shuffling to epochs from a particular deck of cards -- the 
seed), and yields these slices from batches (groups of training examples of similar length) in a deterministic order
for the dataloader and the trainer to run.  val and test are not touched.  By default the rehearsal quota is capped at 20%.
This is just the ceiling in the defaults. In practice the rehearsal only draws from older shards, and is capped per bucket,
and it is interleaved every Nth batch.  The effective share can be within 5% to 12%. 

sampler.rb receives as input files old_shard_train.json and new_train.json.  

## Plan of action

### mbox_pre-parser.rb
Parse mbox to intermediate JSON

`ruby mbox_pre-parser.rb input.mbox -o split_emails.json`
Output: `[{"message_id": "...", "email_message": "raw RFC 822..."}]`

### splitter.rb
Thread and split emails

Usage:    `ruby splitter.rb input.json train.json val.json test.json`

i.e. splits however many unique emails breaking upon thread partitions into 3 subsets, which are train, val, test in a 80/10/10 ratio
val set is for tuning hyperparameters without cheating on your test set.  Think of it like a practice exam.
test is used for final unbiased reporting.
Thus train does the fitting
val does the tuning
test doesn't tune any decisions based upon its result

Output schema is: message_id, sender, subject, date, references, in_reply_to, text, thread_id
No thread spans partitions ✓
Compatible with StratifiedReplaySampler ✓

jq is a a fast command-line JSON processor
jq can be installed via apt-get, or brew, or pipx install jq
view the json with: `jq .[0]{sender,thread_id,text} file.json`



## Overview: What Are We Building?

This pipeline **continuously fine-tunes** a Large Language Model (LLM) on your incoming email archive using **LoRA** (Low-Rank Adaptation) and **Retrieval-Augmented Generation (RAG)**, creating a personalized assistant that writes like you, retrieves relevant context from your history, and improves incrementally as new emails arrive.

**Key Philosophy:**
- **Continuous Pre-Training (CPT):** The model is periodically retrained on rolling windows of your email data as new messages come in.
- **Stratified Replay Sampling:** Old data is not discarded; carefully selected historical samples are replayed to prevent catastrophic forgetting.
- **LoRA Fine-Tuning:** Instead of retraining the entire model, we train small adapter matrices (LoRA weights) that modify the base model's behavior efficiently.
- **RAG Evaluation:** After each training run, we measure how well the model retrieves and generates contextually relevant responses.
- **Checkpoint Selection:** From multiple LoRA checkpoints saved during training, we automatically pick the best-performing one based on evaluation metrics.

---

## Core Concepts: The ML 101 Crash Course

### 1. **Training vs. Inference**
- **Training:** The model learns patterns from labeled examples (your emails). It adjusts internal weights to minimize prediction error.
- **Inference:** The trained model generates responses or predictions given new input.

### 2. **Fine-Tuning vs. Pre-Training**
- **Pre-training:** A model learns general language patterns from massive datasets (e.g., Wikipedia, books). This is expensive and done once by model creators.
- **Fine-tuning:** We adapt a pre-trained model to a specific task (your email style) using a smaller dataset. Much cheaper and faster.

### 3. **LoRA (Low-Rank Adaptation)**
- Instead of modifying all billions of parameters in the base model, LoRA adds small trainable matrices (adapters) that inject task-specific knowledge.
- **Why?** Saves memory, speeds up training, and allows multiple LoRA adapters to coexist for different tasks.

### 4. **RAG (Retrieval-Augmented Generation)**
- When generating a response, the model first retrieves relevant email chunks from a vector database (semantic search), then conditions the generation on that context.
- **Why?** Grounds the model in factual email history, reducing hallucination and improving relevance.

### 5. **Stratified Sampling**
- Not all emails are equal. Some senders or threads are rare but important. Stratified sampling ensures:
  - **Every sender and thread** gets minimum representation (no one gets forgotten).
  - **Proportional representation** maintains the overall distribution of your communication patterns.

### 6. **Catastrophic Forgetting**
- If we only train on new data, the model forgets old patterns. **Rehearsal** (replaying old examples) prevents this.

---

## Data Flow: From Raw Emails to Trained Model

```
┌──────────────────────┐
│  Raw Email Archive   │  (Maildir, IMAP, mbox, etc.)
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│  Chunk Extractor     │  Slices emails into overlapping windows (chunks)
└──────────┬───────────┘  Outputs: chunks.json (all chunk metadata)
           │
           ▼
┌──────────────────────┐
│  Split Assigner      │  Labels chunks as train/val/test (by date or thread)
└──────────┬───────────┘  Outputs: assignments.json (immutable ground truth)
           │
           ▼
┌──────────────────────┐
│ Rehearsal Manifest   │  Filters train-split chunks from shards OUTSIDE
│     Generator        │  the current rolling window, stratified by sender/thread
└──────────┬───────────┘  Outputs: old_shards_train.json (regenerable each retrain)
           │
           ▼
┌──────────────────────┐
│   sampler.rb         │  Interleaves old rehearsal samples with new train data
│ (StratifiedReplaySampler)│  using configurable replay:new ratio (e.g., 1:4)
└──────────┬───────────┘  Outputs: Shuffled epoch schedule for DataLoader
           │
           ▼
┌──────────────────────┐
│   DataLoader         │  Fetches tokenized chunks in mini-batches,
│ (lib/dataloader.rb)  │  length-bucketed for efficient padding
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│   Trainer            │  Runs gradient descent, saves LoRA checkpoints
│ (retrain.rb)         │  every N steps or at epoch end
└──────────┬───────────┘  Outputs: checkpoints/step_1000.safetensors, ...
           │
           ▼
┌──────────────────────┐
│ RAG_evaluator.rb     │  Evaluates each checkpoint on val/test sets:
│                      │  - Perplexity (language modeling quality)
│                      │  - RAG@K (retrieval + generation accuracy)
└──────────┬───────────┘  Outputs: eval_results.json
           │
           ▼
┌──────────────────────┐
│ lora_checkpoint_     │  Parses eval_results.json, selects best checkpoint
│   selector.rb        │  by composite metric (e.g., lowest val perplexity + highest RAG@5)
└──────────┬───────────┘  Outputs: best_checkpoint.txt, symlink to winning .safetensors
           │
           ▼
┌──────────────────────┐
│  Production Deploy   │  Loads base model + best LoRA adapter for inference
└──────────────────────┘
```

---

## The Star of the Show: `sampler.rb`

### What It Does

**`sampler.rb`** implements the **StratifiedReplaySampler**, the brain of your training data schedule. Its job:

1. **Load two datasets:**
   - `old_shards_train.json`: Rehearsal samples (train-split chunks from past shards, outside the current rolling window).
   - `new_train.json`: Fresh train-split chunks from the latest rolling window.

2. **Build sender/thread buckets:**
   - Groups old rehearsal samples by `sender` → `thread_id` → `[samples]`.
   - Counts total samples per sender and globally to compute proportions.

3. **Sample with stratification:**
   - **Phase 1 (Minimum Representation):** Ensures every sender/thread bucket contributes at least `--min-per-bucket` samples (default: 2).
   - **Phase 2 (Proportional Fill):** Allocates remaining slots proportionally to sender volume, then thread weight within each sender.
   - Result: Rare senders/threads get visibility; frequent ones maintain dominance; no one is erased.

4. **Interleave replay with new data:**
   - For every batch of new data (size `--batch-size * new_parts`), injects proportional replay samples (`--batch-size * replay_parts`).
   - Example: `--replay-ratio 1:4` → for every 4 batches of new data, replay 1 batch of old data.

5. **Shuffle and output:**
   - Flattens all batches, shuffles globally, outputs JSON training schedule.

### When It Runs

**Triggered during `retrain.rb` setup**, *before* the Trainer starts:

```ruby
# Inside retrain.rb (pseudocode)
old_rehearsal_manifest = "old_shards_train.json"
new_train_chunks = extract_train_chunks_from_rolling_window()

# Invoke sampler.rb to build epoch schedule
system("ruby sampler.rb #{old_rehearsal_manifest} #{new_train_chunks} \
        --replay-ratio 1:4 \
        --batch-size 16 \
        --min-per-bucket 2 \
        -o epoch_schedule.json")

# Feed epoch_schedule.json to DataLoader
dataloader = DataLoader.new(epoch_schedule_file: "epoch_schedule.json", ...)
trainer = Trainer.new(dataloader: dataloader, ...)
trainer.train!
```

### Key CLI Arguments

```bash
ruby sampler.rb old_shards_train.json new_train.json \
  --replay-ratio 1:4 \        # 1 rehearsal sample per 4 new samples
  --batch-size 16 \           # Mini-batch size
  --min-per-bucket 2 \        # Min samples per sender/thread bucket
  -o epoch_schedule.json      # Output file
```

### Why Stratified Sampling Matters

Without stratification, gradient descent would overfit to frequent senders (e.g., automated notifications, your boss) and forget rare but critical correspondents (e.g., quarterly reports from finance). Stratification enforces **representative diversity**.

---

## RAG Evaluation: `RAG_evaluator.rb`

### What It Does

After `retrain.rb` produces multiple LoRA checkpoints (e.g., `step_500.safetensors`, `step_1000.safetensors`, ...), **`RAG_evaluator.rb`** measures their quality on validation/test sets.

**Metrics computed:**

1. **Perplexity (PPL):**
   - Measures how "surprised" the model is by held-out text. Lower = better language modeling.
   - Formula: `exp(average_cross_entropy_loss)`

2. **RAG Accuracy @ K:**
   - For each test email, retrieves top-K similar chunks from the vector database, conditions the model on them, generates a response.
   - Compares generated text to ground truth using BLEU, ROUGE, or exact-match scoring.
   - Higher accuracy = better retrieval + generation integration.

3. **Retrieval Recall @ K:**
   - What fraction of relevant chunks were retrieved in the top-K?

4. **Generation Fluency:**
   - Subjective or automated (perplexity of generated text).

### When It Runs

**Triggered after `retrain.rb` completes**, typically via CI/CD or manual invocation:

```bash
# After training finishes
ruby RAG_evaluator.rb \
  --checkpoints-dir checkpoints/ \
  --val-set val_chunks.json \
  --test-set test_chunks.json \
  --vector-db embeddings.faiss \
  --base-model /models/llama-3-70b \
  -o eval_results.json
```

**Typical CI Workflow:**

```yaml
# .github/workflows/retrain.yml
- name: Train LoRA
  run: ruby retrain.rb --epochs 3 --save-steps 500

- name: Evaluate Checkpoints
  run: ruby RAG_evaluator.rb --checkpoints-dir checkpoints/ -o eval_results.json

- name: Select Best Checkpoint
  run: ruby lora_checkpoint_selector.rb eval_results.json
```

### Outputs

`eval_results.json`:

```json
{
  "checkpoints": [
    {
      "path": "checkpoints/step_500.safetensors",
      "val_perplexity": 12.3,
      "test_perplexity": 13.1,
      "rag_accuracy_at_5": 0.78,
      "retrieval_recall_at_5": 0.85
    },
    {
      "path": "checkpoints/step_1000.safetensors",
      "val_perplexity": 11.8,
      "test_perplexity": 12.9,
      "rag_accuracy_at_5": 0.81,
      "retrieval_recall_at_5": 0.87
    },
    ...
  ]
}
```

---

## Checkpoint Selection: `lora_checkpoint_selector.rb`

### What It Does

**`lora_checkpoint_selector.rb`** is the final judge. It parses `eval_results.json` and picks the **best checkpoint** using a composite scoring function.

**Default scoring strategy:**

```ruby
score = (1.0 / val_perplexity) * 0.5 +  # Lower PPL is better → invert
        rag_accuracy_at_5 * 0.5         # Higher accuracy is better
```

Alternatively, you can configure:
- **Pareto frontier selection:** Non-dominated checkpoints on perplexity vs. RAG accuracy.
- **Weighted multi-objective:** `--weights "ppl:0.4,rag:0.4,recall:0.2"`
- **Thresholding:** Reject checkpoints with `val_perplexity > 15.0`.

### When It Runs

**Immediately after `RAG_evaluator.rb`**, as part of the same CI job:

```bash
ruby lora_checkpoint_selector.rb eval_results.json \
  --strategy weighted \
  --weights "ppl:0.5,rag:0.5" \
  -o best_checkpoint.txt
```

### Outputs

1. **`best_checkpoint.txt`:**
   ```
   checkpoints/step_1000.safetensors
   ```

2. **Symlink creation (optional):**
   ```bash
   ln -sf $(cat best_checkpoint.txt) production_lora.safetensors
   ```

3. **CI artifact upload:**
   ```yaml
   - name: Upload Best Checkpoint
     uses: actions/upload-artifact@v3
     with:
       name: best-lora
       path: production_lora.safetensors
   ```

### Why This Matters

- **Prevents overfitting:** The checkpoint with lowest *training* loss may not generalize. Validation metrics are the arbiter.
- **Automates deployment:** No human judgment needed; CI pipeline automatically promotes the winner.
- **Multi-metric optimization:** Balances language fluency (perplexity) with task performance (RAG accuracy).

---

## Putting It All Together: The Retrain Lifecycle

### Step-by-Step Execution

1. **New emails arrive** → Chunk extractor processes them → `assignments.json` gets new train/val/test IDs appended.

2. **CI trigger fires** (daily cron, push to `main`, or manual):
   ```yaml
   on:
     schedule:
       - cron: '0 3 * * *'  # 3 AM daily
   ```

3. **Rehearsal manifest generation:**
   ```bash
   ruby generate_rehearsal_manifest.rb \
     --assignments assignments.json \
     --current-window-shards "shard_2025-11.json" \
     -o old_shards_train.json
   ```
   Filters `assignments.json` for train-split IDs from shards *not* in the rolling window, applies stratification caps.

4. **Sampler interleaves rehearsal with new data:**
   ```bash
   ruby sampler.rb old_shards_train.json new_train.json \
     --replay-ratio 1:4 \
     --batch-size 16 \
     -o epoch_schedule.json
   ```

5. **Training:**
   ```bash
   ruby retrain.rb \
     --assignments assignments.json \
     --rehearsal-manifest old_shards_train.json \
     --length-metadata length_buckets.json \
     --window-idx 0 \
     --epochs 3 \
     --save-steps 500 \
     --output-dir checkpoints/
   ```
   `retrain.rb` instantiates:
   - `StratifiedReplaySampler` (from `sampler.rb`) → feeds `DataLoader` → feeds `Trainer`.
   - Saves checkpoints every 500 steps + at epoch end.

6. **Evaluation:**
   ```bash
   ruby RAG_evaluator.rb \
     --checkpoints-dir checkpoints/ \
     --val-set val_chunks.json \
     --test-set test_chunks.json \
     --vector-db embeddings.faiss \
     -o eval_results.json
   ```
   For each checkpoint:
   - Loads base model + LoRA adapter.
   - Computes perplexity on val/test.
   - Runs retrieval + generation on test queries.

7. **Checkpoint selection:**
   ```bash
   ruby lora_checkpoint_selector.rb eval_results.json \
     --strategy weighted \
     --weights "ppl:0.5,rag:0.5" \
     -o best_checkpoint.txt
   ```
   Picks winner, writes to `best_checkpoint.txt`.

8. **Deployment:**
   ```bash
   ln -sf $(cat best_checkpoint.txt) /prod/lora_adapter.safetensors
   systemctl restart email-assistant.service
   ```

---

## Key Terminology Recap

| Term | Definition |
|------|------------|
| **Chunk** | Atomic unit: a sliding window of N messages from a thread, tokenized and ready for training. |
| **Shard** | Time-based or size-based partition of the email archive (e.g., `2025-11.json`). |
| **assignments.json** | Immutable ground truth: maps every `chunk_id` to `train`, `val`, or `test`. Append-only. |
| **old_shards_train.json** | Ephemeral rehearsal manifest: train-split chunks from past shards, regenerated each retrain. |
| **Rehearsal** | Replaying old training examples to prevent catastrophic forgetting. |
| **Stratified Sampling** | Ensuring every sender/thread gets minimum representation + proportional weighting. |
| **LoRA Checkpoint** | Snapshot of LoRA adapter weights at a specific training step (e.g., `step_1000.safetensors`). |
| **Perplexity** | `exp(cross_entropy_loss)`. Measures model confidence; lower = better language modeling. |
| **RAG@K** | Retrieval-Augmented Generation accuracy with top-K retrieved chunks. |

---

## Common Pitfalls & Best Practices

### Pitfall 1: Ignoring Stratification
**Symptom:** Model forgets rare senders or overfits to automated emails.  
**Fix:** Use `sampler.rb` with `--min-per-bucket >= 2` and monitor sender distribution in training logs.

### Pitfall 2: Skipping Rehearsal
**Symptom:** Each retrain degrades performance on old data.  
**Fix:** Maintain `old_shards_train.json` and set `--replay-ratio >= 1:4`.

### Pitfall 3: Cherry-Picking Checkpoints Manually
**Symptom:** Overfit to human biases; forgot to check test metrics.  
**Fix:** Always run `RAG_evaluator.rb` + `lora_checkpoint_selector.rb`; trust the metrics.

### Pitfall 4: Immutable `assignments.json` Violations
**Symptom:** Train/val/test leakage, irreproducible results.  
**Fix:** Never modify past entries in `assignments.json`; only append new IDs.

### Best Practice: Seed Everything
```bash
export RANDOM_SEED=42
ruby sampler.rb ... --seed $RANDOM_SEED
ruby retrain.rb ... --seed $RANDOM_SEED
```
Ensures reproducible shuffles and gradient descent.

### Best Practice: Log Stratification Stats
Add to `sampler.rb`:
```ruby
puts "Sender distribution:"
@buckets.each { |sender, threads| puts "  #{sender}: #{threads.values.sum(&:size)} samples" }
```

---

## Further Reading

- **LoRA Paper:** "LoRA: Low-Rank Adaptation of Large Language Models" (Hu et al., 2021)
- **RAG Paper:** "Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks" (Lewis et al., 2020)
- **Catastrophic Forgetting:** "Overcoming catastrophic forgetting in neural networks" (Kirkpatrick et al., 2017)
- **Stratified Sampling:** Classic statistics textbook (e.g., Cochran's "Sampling Techniques")

- [Andrej Karpathy's "A Recipe for Training Neural Networks"](http://karpathy.github.io/2019/04/25/recipe/) - Practical debugging tips
- [fast.ai Practical Deep Learning Course](https://course.fast.ai/) - Hands-on, code-first approach
- [CS231n Convolutional Neural Networks for Visual Recognition](https://cs231n.github.io/) - Stanford course notes (visual focus but concepts apply)
- [Papers With Code](https://paperswithcode.com/) - Browse ML papers with reference implementations

---

## Questions?

- **"Why not just train on all data every time?"** → Computationally prohibitive for 45k emails; incremental training + rehearsal is vastly cheaper.
- **"Can I skip evaluation and just use the last checkpoint?"** → Sure, but you'll deploy overfitted garbage 30% of the time. Your call.
- **"What if `old_shards_train.json` grows huge?"** → Cap it with `--max-rehearsal-samples` in the manifest generator, or sample proportionally from older shards.
- **"How do I know if rehearsal ratio is right?"** → Monitor val perplexity across retrains; if it degrades on old threads, increase replay ratio.

---

**You now have a production-grade ML pipeline.** Run `ruby sampler.rb --help`, `ruby RAG_evaluator.rb --help`, and `ruby lora_checkpoint_selector.rb --help` to explore CLI flags. Happy training! 🚀





