# mboxMinerva

**Production-grade email archive LLM fine-tuning with immutable splits, PII safety, and RAG deployment**

[![License](https://img.shields.io/badge/license-All%20Rights%20Reserved-red.svg)](LICENSE)
- [INITIAL SETUP](./INITIAL_SETUP/README_FIRST.md)
- [Sales Pitch](./SALES_PITCH.md)
- [Technical details](./TECHNICAL.md)

---

# Aims of this repo

This repo is an attempt to fine-tune an AI model based upon the contents of an mbox, and then implement RAG upon this mbox based upon utilizing this fine-tuned llm.

# Email CPT/RAG Pipeline: Immutable Split Architecture Tutorial

## Overview

This pipeline enables **production-grade continuous pre-training (CPT) on email archives** with **frozen train/val/test splits** that remain stable across incremental retraining cycles. Key design goals:

1. **Reproducibility**: Once an email is assigned to train/val/test, that assignment never changes
2. **Incrementality**: New emails can be ingested without reshuffling existing assignments
3. **Thread awareness**: Emails in the same conversation thread stay in the same split
4. **Scalability**: Handle 45k+ emails with rolling-window chunking for mega-threads

---

This architecture provides **production-grade ML hygiene** for email CPT:

1. **Parse** → intermediate JSON
2. **Split** → immutable manifest (append-only, deterministic, thread-aware)
3. **Materialize** → train/val/test JSONLs
4. **Train** → CPT with sharded I/O

**The golden rule**: Treat `assignments.json` as **permanent marker**. Once written, never erase. Only append.

**Result**: Scientifically reproducible, incrementally trainable, leakage-proof email AI.

---

## Core Concepts

### ID Taxonomy

The system works with three types of stable identifiers:

- **Message-Id**: Unique email header (e.g., `<abc123@example.com>`)
- **thread_id**: Computed from conversation grouping (e.g., `thread_xyz`)
- **window_id**: For chunked mega-threads (e.g., `thread_xyz_window_0`)

Each ID receives a **permanent train/val/test assignment** recorded in the immutable split manifest.

---

### Immutable Split Manifest (`assignments.json`)

A single **append-only map** structure:

```json
{
  "message123@example.com": {
    "split": "train",
    "thread_id": "thread_abc"
  },
  "thread_xyz_window_0": {
    "split": "val",
    "thread_id": "thread_xyz",
    "window_idx": 0
  }
}
```

**Key properties**:
- **Immutable**: Existing entries never change
- **Append-only**: New IDs added on ingest; old IDs frozen
- **Deterministic**: Assignment via SHA256 hash-bucketing with quotas (80/10/10 train/val/test)
- **Thread-level**: All messages/windows in a thread share the same split

---

### Background information
* PII = personally identififable information
* RAG = retrieval augmentation generation
* RNG = a pseudorandom number generator initalized with a specific seed so the "random" sequence is
deterministic and repeatable.  The same seeds leads to the same shuffles/samples.  different seeds 
cause different but reproducible runs.  So we log the seed and don't use nondeterministic operations
that can break bitwise repeatability.

## Design Guarantees

✅ **Reproducibility**: Same manifest + same seed = identical splits across runs  
✅ **Immutability**: Test set never contaminates train set in future retrains  
✅ **Thread integrity**: All messages/windows in a thread share the same split  
✅ **Incrementality**: New data appends deterministically without reshuffling old data  
✅ **Scalability**: Windowing handles mega-threads; sharding handles I/O

---

## Overview

mboxMinerva enables **continuous pre-training (CPT) on email archives** with:
- **Frozen train/val/test splits** that remain stable across incremental retraining
- **Thread-aware assignment** to prevent data leakage
- **PII scrubbing at ingestion** with deterministic pseudonymization
- **Stratified rehearsal sampling** to prevent catastrophic forgetting
- **Data Subject Request (DSR) compliance** with export/delete tooling
- **RAG baseline** (Postgres+pgvector) for email search

**Key Design Principles:**
1. **Reproducibility**: Same seed + data = identical splits (forever)
2. **Immutability**: Test set never contaminates training in future retrains
3. **Privacy-first**: PII scrubbed before splits, reversible for DSR compliance
4. **Incrementality**: New emails append deterministically without reshuffling

---


## Architecture

### Immutable Split Manifest

**Core concept**: The manifest file is an **append-only map** where each ID (Message-Id, thread_id, or window_id) receives a **permanent split assignment**.

**Properties**:
- **Immutable**: Existing entries never change
- **Append-only**: New IDs added on ingest; old IDs frozen
- **Deterministic**: Assignment via SHA256 hash-bucketing with 80/10/10 quotas
- **Thread-level**: All messages/windows in a thread share the same split

**Hash-Bucket Algorithm** (`bin/mbox_pre-parser.rb`):
```ruby
# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

TRAIN_RATIO = 0.8
VAL_RATIO = 0.1
TEST_RATIO = 0.1

# -----------------------------------------------------------------------------
# Split Assignment
# -----------------------------------------------------------------------------

# Deterministic hash-bucket assignment based on thread_id and seed
def assign_split(thread_id, seed)
  hash = Digest::SHA256.hexdigest("#{seed}:#{thread_id}").to_i(16)
  bucket = hash % 100
  
  if bucket < (TRAIN_RATIO * 100)
    'train'
  elsif bucket < ((TRAIN_RATIO + VAL_RATIO) * 100)
    'val'
  else
    'test'
  end
end

```

**Why this matters**:
- Same seed + same thread_id = same split (forever)
- No randomness = no accidental drift
- Scientific reproducibility: test set never leaks into training

---

**Important**: Tombstones are **append-only**. Never mutate `assignments.json`.

---

**Metrics**:
- Recall@K: Fraction of test queries where correct answer in top K
- MRR (Mean Reciprocal Rank): Average 1/rank of first correct answer
- Precision@K: Fraction of retrieved chunks that are relevant

---


## Design Decisions FAQ

### Why hash-bucketing instead of random sampling?

**Determinism**: Random splits are non-reproducible without serializing the entire RNG state. Hash-bucketing guarantees the same thread always lands in the same bucket given the same seed.

### Why append-only manifest?

**Frozen reproducibility**: Never mutate existing assignments. Scientific experiments require fixed test sets. Adding new data shouldn't change how we evaluate old performance.

### Why thread-level assignment?

**Leakage prevention**: If message A and message B are in the same conversation, training on A and testing on B violates independence. Thread-level assignment prevents this.

### Why do windows inherit thread splits?

**Same reason**: Windows are slices of one conversation, albeit overlapping ones. Training on `thread_xyz_window_0` and testing on `thread_xyz_window_1` is leakage.

### Why two-layer design (manifest + materialize)?

**Efficiency**: Manifest is a compact map; materialization generates full splits on demand. Supports multiple export formats (JSONL, CSV) from one source of truth.

### Why thread-level assignment?
**Leakage prevention**: If message A and message B are in the same conversation, training on A and testing on B violates independence. Thread-level assignment prevents this.

---

## Troubleshooting

**Q: I changed the seed and now my splits are different!**  
A: Don't do that. The seed is part of the experiment signature. Changing it invalidates reproducibility.

**Q: Can I manually move an ID from train to test?**  
A: You *can* edit `assignments.json`, but you're breaking immutability. Only do this if you have a very good reason (e.g., discovered PII in test set).

**Q: What if I delete old emails from the archive?**  
A: The manifest retains their assignments. If you re-materialize, those IDs won't appear in the output (no source data), but the manifest preserves history.

**Q: How do I reset everything and start fresh?**  
A: Delete `assignments.json` and re-run with a new seed. All assignments will be recomputed.

---



## License

© 2025 David Roderick. All Rights Reserved.

No warranty provided. See `LICENSE` for full terms.

---

## Citation

If you use mboxMinerva in your research, please cite:

```bibtex
@software{mboxminerva2025,
  author = {Roderick, David},
  title = {mboxMinerva: Privacy-Safe Email LLM Training},
  year = {2025},
  url = {https://github.com/dmr104/mboxMinerva}
}
```

---

## Acknowledgments

- Immutable manifest design inspired by [DVC](https://dvc.org/) and [Pachyderm](https://www.pachyderm.com/)
- Stratified rehearsal sampling adapted from [GEM benchmark](https://gem-benchmark.com/)
- PII scrubbing patterns from [Microsoft Presidio](https://microsoft.github.io/presidio/)

---

## Contact

- **GitHub Issues**: [dmr104/mboxMinerva/issues](https://github.com/dmr104/mboxMinerva/issues)
- **Docs**: See `docs/` directory for detailed guides

---

**The Golden Rule**: Treat `assignments.json` as **permanent marker**. Once written, never erase. Only append.

**Result**: Scientifically reproducible, incrementally trainable, privacy-safe email AI.


