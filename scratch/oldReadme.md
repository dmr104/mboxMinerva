
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

## Roadmap

**Current Status: v0.9 (Pre-release)**

### v1.0 (Q1 2026)
- [x] Immutable split architecture
- [x] PII scrubbing at ingestion
- [x] DSR export/delete tooling
- [x] Split integrity tests
- [ ] CI/CD automation (GitHub Actions)
- [ ] RAG baseline (Postgres+pgvector)
- [ ] Eval harness (scripts/eval_before_after.py)

### v1.1 (Q2 2026)
- [ ] Differential privacy (DP-SGD)
- [ ] Model versioning and tagging
- [ ] Performance optimization (caching, indexing)
- [ ] Multi-mbox support (federated learning)

### v2.0 (Q3 2026)
- [ ] Active learning loop
- [ ] Web UI for DSR management
- [ ] Cloud deployment templates (AWS, GCP, Azure)

---


## RAG Deployment

**Status**: Baseline implementation in progress

**Architecture**:
1. **Embedding Generation**: Sentence-transformers or OpenAI Ada-002
2. **Vector Storage**: Postgres with pgvector extension
3. **Query Pipeline**: Retrieve top-K chunks, pass to LLM for synthesis

### Setup Postgres+pgvector

```bash
# Install pgvector extension
psql -d mboxminerva_rag -c "CREATE EXTENSION IF NOT EXISTS vector;"

# Create embeddings table
psql -d mboxminerva_rag -f scripts/init_rag_schema.sql
```

**Schema** (simplified):
```sql
CREATE TABLE embeddings (
  chunk_id TEXT PRIMARY KEY,
  embedding vector(768),  -- Dimension depends on model
  split TEXT,             -- train/val/test (for eval only)
  metadata JSONB          -- thread_id, sender, timestamp
);
```

### Index Embeddings

```bash
ruby lib/rag_index_builder.rb \
  --input splits/train.json \
  --output embeddings.db \
  --model sentence-transformers/all-MiniLM-L6-v2
```

### Evaluate RAG Baseline

```bash
bin/RAG_evaluator.rb \
  --db postgres://localhost/mboxminerva_rag \
  --test-queries splits/test_queries.json \
  --k 5 \
  --output rag_metrics.json
```

---

### Data Subject Request (DSR) Tools

#### `bin/dsr_export`
Export all data for a given subject (email or pseudonym).

```bash
bin/dsr_export \
  --subject user@example.com \
  --vault vault/pseudonym_map.json \
  --splits data/assignments.json \
  --threads \
  --output exports/user_data.jsonl
```

**Flags**:
- `--subject`: Email address or pseudonym to export
- `--vault`: Path to pseudonym map (default: vault/pseudonym_map.json)
- `--splits`: Path to manifest (default: data/assignments.json)
- `--threads`: Include full threads (not just subject's messages)
- `--output`: Export file path

**Output format** (JSONL):
```json
{"type": "email", "message_id": "...", "split": "train", ...}
{"type": "email", "message_id": "...", "split": "val", ...}
```

Includes summary:
```json
{"summary": {"total_records": 42, "splits": {"train": 35, "val": 5, "test": 2}}}
```

#### `bin/dsr_delete`
Mark records for deletion via append-only tombstones.

```bash
bin/dsr_delete \
  --subject user@example.com \
  --vault vault/pseudonym_map.json \
  --splits data/assignments.json \
  --tombstones vault/dsr_tombstones.jsonl \
  --threads \
  --dry-run
```

**Flags**:
- `--subject`: Email address or pseudonym to delete
- `--vault`: Path to pseudonym map
- `--splits`: Path to manifest
- `--tombstones`: Tombstone file (default: vault/dsr_tombstones.jsonl)
- `--threads`: Delete entire threads (not just subject's messages)
- `--dry-run`: Preview deletion without writing tombstones

**Tombstone format**:
```json
{"chunk_id": "msg123@example.com", "timestamp": "2025-11-09T19:00:00Z", "reason": "DSR deletion"}
```
---


#### `bin/lora_checkpoint_selector.rb`
Select best checkpoint based on eval metrics.

```bash
bin/lora_checkpoint_selector.rb \
  --checkpoints models/ \
  --test splits/test.json \
  --output best_checkpoint.txt
```

#### `bin/merge_lora.rb`
Merge LoRA adapter into base model for deployment.

```bash
bin/merge_lora.rb \
  --base <base_model> \
  --adapter <adapter_path> \
  --output merged_model.bin
```

---

### Training Workflow

**Pipeline**: `sampler.rb` → `retrain.rb` → `lora_checkpoint_selector.rb`

**1. Stratified Rehearsal Sampling**

Tool: `bin/sampler.rb`

**Purpose**: Prevent catastrophic forgetting during incremental training

**How it works**:
- Takes old training data (previous shards) and new training data
- Builds hierarchical buckets (sender → thread → samples)
- Guarantees minimum representation for rare senders/threads (default: 2 samples/bucket)
- Fills remaining quota proportionally (1:4 old:new ratio)

**Example**:
```bash
bin/sampler.rb \
  data/old_train.json \
  data/new_train.json \
  --replay-ratio 1:4 \
  --batch-size 16 \
  --min-per-bucket 2 \
  --seed 42 \
  --output data/mixed_train.json
```

**2. LoRA Fine-Tuning**

Tool: `bin/retrain.rb`

**Key parameters**:
- `--base-model`: Pretrained LLM (e.g., Mistral-7B)
- `--train`: Training manifest (mixed_train.json from sampler)
- `--val`: Validation split (val.json)
- `--epochs`: Training epochs (default: 3)
- `--lr`: Learning rate (default: 5e-5)
- `--save-train-shard`: Output directory for sharded checkpoints

**3. Checkpoint Selection**

Tool: `bin/lora_checkpoint_selector.rb`

**Scoring**: Weighted combination of:
- Perplexity on test split (lower is better)
- RAG@K accuracy (higher is better)

**Output**: `best_checkpoint.txt` with path to winning checkpoint

---


## training LoRA


# Step 7: Evaluate checkpoint
python3 scripts/eval_before_after.py \
  --base mistralai/Mistral-7B-v0.1 \
  --ft models/checkpoint_v1 \
  --test splits/test.json

# Step 8: Select best checkpoint (CI automation)
bin/lora_checkpoint_selector.rb \
  --checkpoints models/ \
  --test splits/test.json \
  --output best_checkpoint.txt

# Step 9: Merge LoRA adapter for deployment
bin/merge_lora.rb \
  --base mistralai/Mistral-7B-v0.1 \
  --adapter models/checkpoint_v1 \
  --output models/merged_v1.bin
```

---

**KPA** = Key Performance Area: the big business outcome you care about.

**KPI** = Key Performance Indicator: the specific dashboard number proving you're winning or losing in that area.

When exclusion backlog crosses 15%, you're risking **stale model predictions** (KPA: Model Freshness) because new email patterns aren't in your training set - the recommended action is to bump the pin so fresh cohorts enter train/val/test and close the drift gap.


### Alert Message Format

**Email** includes:
- KPI name & KPA
- Current value vs threshold
- Recommended CLI command
- Full stats snapshot (JSON)

**Slack** attachment includes:
- Color-coded severity (warning=yellow, critical=red)
- Inline fields for KPI, KPA, value, threshold
- Recommended action

**Webhook** posts raw JSON:

```json
{
  "timestamp": "2025-11-15T16:11:00Z",
  "severity": "warning",
  "kpi": "exclusion_backlog_high",
  "kpa": "Inbox Quality & Model Freshness",
  "current_value": 18.5,
  "threshold": 15.0,
  "recommended_action": "Bump the cohort pin...",
  "stats_snapshot": { ... }
}
```



### Tuning Thresholds

**Conservative (fewer false alarms)**:
- Raise thresholds (e.g., exclusion_backlog: 25% instead of 15%)
- Use `critical` severity sparingly

**Aggressive (catch issues early)**:
- Lower thresholds (e.g., contamination: 0.5% instead of 1%)
- Add more KPIs (e.g., val/test split size minimums)

---

### Alert Channels

#### Email (SMTP)
Configure in `config/alerts.yml`:

```yaml
notifications:
  email:
    enabled: true
    smtp_server: 'smtp.gmail.com'
    smtp_port: 587
    from: 'alerts@example.com'
    to: 'admin@example.com'
```

#### Slack
Get a webhook URL from Slack (Incoming Webhooks app):

```yaml
notifications:
  slack:
    enabled: true
    webhook_url: 'https://hooks.slack.com/services/T00/B00/XXX'
```

#### Generic Webhook
POST JSON payload to your monitoring system:

```yaml
notifications:
  webhook:
    enabled: true
    url: 'https://your-siem.example.com/api/alerts'
```
---

## Metrics Watcher & Alerting

### Overview

`bin/metrics_watcher.rb` computes key performance indicators (KPIs) from your manifest and splits, then fires alerts via email, Slack, or webhooks when thresholds are breached.

**Monitored KPIs**:
- **Exclusion backlog**: % of manifest rows excluded by pin or quarantine (signals drift)
- **Split distribution**: train/val/test ratio (detects imbalance from DSR or filtering)
- **Contamination drift**: cross-split leakage rate (eval trustworthiness)
- **Tombstone count**: DSR deletions accumulating (triggers retrain reminders)

**Key Performance Areas (KPAs)**:
- Inbox Quality & Model Freshness
- Evaluation Trustworthiness
- Training Efficiency
- Privacy Compliance & SLA

### Configuration


Edit `config/alerts.yml` to define:
1. **KPIs**: metric paths, thresholds, recommended actions
2. **Notifications**: SMTP, Slack webhook, or custom webhook endpoints

Example KPI definition:

```yaml
kpis:
  exclusion_backlog_high:
    kpa: 'Inbox Quality & Model Freshness'
    metric_path: 'exclusion_backlog.exclusion_pct'
    threshold: 15.0
    comparison: 'gt'
    severity: 'warning'
    recommended_action: |
      Bump the cohort pin to include newer data:
      bin/splitter.rb --pin 2025-04 --materialize all
```

### Usage

**Manual run**:

```bash
bin/metrics_watcher.rb \
  --config config/alerts.yml \
  --manifest data/manifest.jsonl \
  --pin 2025-01
```

**Scheduled (cron)**:

```cron
# Every Monday at 9am
0 9 * * 1 cd /app && bin/metrics_watcher.rb --config config/alerts.yml
```

**GitLab CI integration** (add to `.gitlab-ci.yml`):

```yaml
metrics_watch:
  stage: monitor
  script:
    - bin/metrics_watcher.rb --config config/alerts.yml --manifest data/manifest.jsonl
  only:
    - schedules  # Triggered by pipeline schedules (daily/weekly)
  allow_failure: true  # Don't block pipeline if alerts fire
```
---


### Configuration Tuning

**High-recall (strict)**: Catch more contamination, more false positives
```bash
--threshold 0.60 --hamming-threshold 10 --max-contamination-pct 0.5
```

**High-precision (permissive)**: Fewer false positives, may miss edge cases
```bash
--threshold 0.80 --hamming-threshold 6 --max-contamination-pct 2.0
```

**Quote-sensitive**: Disable quote stripping to test raw content
```bash
--no-strip-quotes --threshold 0.75
```

### Operational Workflow

**Weekly cadence** (production):
1. Ingest new mboxes → `mbox_pre-parser.rb` with threading + cohort stamping
2. Materialize splits → `splitter.rb` with current pin
3. Run contamination guard → flag exclusions
4. Rematerialize clean splits → apply `--exclude`
5. Flip symlinks → `ln -sfn splits_YYYYMMDD data/splits_active`
6. Archive old splits + reports for audit trail

**On DSR deletion**:
1. Tombstone in manifest
2. Run guard immediately (urgent retraining)
3. Rematerialize with tombstones + exclusions
4. Retrain from base checkpoint

**On pin bump** (quarterly):
1. Advance pin to new cohort (e.g., 2025-01 → 2025-04)
2. Run guard on new val/test distributions
3. Validate contamination stays <1%
4. Archive old pin's splits for reproducibility

### Performance Notes

- **O(n×m)** cross-split comparisons: 10K train × 1K test = 10M pairs
- **Optimization**: LSH prefix bucketing reduces to ~O(n) for SimHash
- **Typical runtime**: ~2-5 min for 50K emails on 16-core box
- **Memory**: ~1-2 GB for fingerprint storage (lightweight)

### Auditing

Contamination report includes:
- `contamination_pairs`: Total flagged pairs
- `contamination_pct`: Rate as % of total records
- `flagged_pairs`: Array of `{row_a, row_b, jaccard, hamming, thread_a, thread_b}`
- `exclusion_count`: IDs quarantined
- `status`: PASS/FAIL against `--max-contamination-pct`

Archive reports with splits for SLA compliance and model provenance.

---


* To Run vLLM’s OpenAI server and point your RAG at it - e.g. 
`docker run --gpus all -p 8000:8000 -v /models:/models vllm/vllm-openai:latest --host 0.0.0.0 --port 8000 --model /models/your-llm --dtype float16 --max-model-len 4096 --gpu-memory-utilization 0.9 --tensor-parallel-size 1 --quantization awq` 
(concurrency is automatic via continuous batching), set OPENAI_BASE_URL=http://vllm:8000/v1 (API key can be a placeholder), and in GitLab CI start this container on your GPU runner (as a service or compose) before your integration tests, then reuse the same compose for prod.

* sampler.rb runs **before** training to interleave stratified rehearsal results with new data (1:4 ration),
* RAG_evaluator.rb triggers **after** training via continuous integration to compute perplexity + RAG@K for 
* each checkpoint, and lora_checkpoint_selector.rb picks the winner using weighted scoring (perplexity + RAG accuracy) and writes best_checkpoint.txt for production deployment.

## Architectural Components

| **Component**       | **Role**                                                                 |
|---------------------|--------------------------------------------------------------------------|
| `sampler.rb`        | Stratified rehearsal sampler (sender/thread buckets + proportional fill) |
| **Inputs**          | `old_shards_train.json` + `shard_N_train.json` + ratio/batch/seed        |
| **Outputs**         | `shard_N_replay_manifest.json` (interleaved new + rehearsal, shuffled)   |
| **CI Integration**  | Step 3 in CI pipeline: generate manifest → pass to retrain.rb            |
| **Reproducibility** | Seeded RNG + frozen manifest = deterministic rehearsal across runs       |
| **Anti-forgetting** | Rare buckets get min representation, common buckets fill proportionally  |

---
RNG is a pseudorandom number generator initalized with a specific seed so the "random" sequence is
deterministic and repeatable.  The same seeds leads to the same shuffles/samples.  different seeds 
cause different but reproducible runs.  So we log the seed and don't use nondeterministic operations
that can break bitwise repeatability.

---