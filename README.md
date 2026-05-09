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
A: Don't do that. Changing it invalidates reproducibility.

**Q: Can I manually move an ID from train to test?**  
A: You *can* edit `assignments.json`, but if you do so, you're breaking immutability, and destroying your record of what has happened. You ought not to do this.

**Q: What if I delete old emails from the archive?**  
A: The manifest retains their assignments. If you re-materialize after tombstoning a particular user, those IDs corresponding to that user should not appear in the output (no source data) metadata files (train.jsonl, val.jsonl, and test.jsonl), but the manifest (assignments.json) preserves history.

**Q: How do I reset my manifest everything and start afresh?**  
A: Rename the `assignments.json` manifest file to preserve its record, and re-run `bin/mbox_pre-parser.rb` with a new seed. Then rematerialise by using `bin/splitter.rb`. All assignments will be recomputed.  Though be careful.  Your renamed manifest file will attest your history.  You should ask why are you doing this?  It does not seem like an appropriate way to work.

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


# Rejected works

## Within the "input" field, can I have multiple quote blocks and responses to that previous email?
That is the question! Email replies often interleave multiple quote blocks and responses, and you naturally would wish to interleave this, and not repeat the previous email, for each repetition. This is in order not to break the DRY (don't repeat yourself) principle in data structures.  There appears to be 2 methods within the AI industry currently of doing this that I know of.  One is called ShareGPT and the other is called ChatML.  I don't think that either are programmatically viable in terms of data curation, so I will break the DRY principle on this occasion. 


### ChatML format used in OpenAI models:
```
chat_template = """<|im_start|>system
{SYSTEM}<|im_end|>
<|im_start|>user
{INPUT}<|im_end|>
<|im_start|>
{OUTPUT}<|im_end|>"""
```
I really don't like this because:
- 1. We are adding a lot of tags like <|im_start|> to what essentially appears to be a text string.
- 2. Is this whole concept going to become obsolete and superceded soon?
- 3. Would it be as effective at ML (machine learning) than repeating the previous email within the "history" field would be for each (latest) reply-to quotation "input" field, taken from within the present email, in association with the most recent unquoted text from the present email : as the value of the "output" field?
- 4. Is the robot which uses the inference llm going to be hackable if I take this approach?  (I have seen people attempt to use these tags as commands to adversely affect robots in public IRC rooms).

### ShareGPT Supervised fine-tuning:
This looks equally to be some kind of a bizarre data structure which some script-kiddy has just thought of, because, really, things *can* be written into JSON like this, however non-descript it may appear. It looks like:
```json
[
  {
    "conversations": [
      {
        "from": "human",
        "value": "something in Chinese"
      },
      {
        "from": "function_call",
        "value": "{\"name\": \"generate_invoice\", \"{arguments}\": {\"more_infernal_stuff\": [{\"oh_no\"}: \"plonk\"]} }"
      },
      {
        "from": "observation",
        "value": "{\"invoice_id\": \"INV12345\", \"{items}\": {\"this_is_crazy\": [{\"oh_yes\"}: \"exactly\"]} }"
      },
      {
        "from": "gpt",
        "value": "more Chinese"
      }     
    ],
    "tools": "[{\"name\": \"generate_invoice\", \"description\": \"I_DO_NOT_CARE_FOR_THE_REST\", \"parameters\": {\"give\", \"me\", \"strength\"}}]"
  }
]
```
The bottom line is that this is far from an easy data structure to utilize, or create.  Let's just break DRY for the purposes of data curation by ML, and be done with this absurdity.

## What we shall do with Alpaca
email 1 is:
```
What is the price of a hamburger?
What is the price of a cheeseburger?
What is the price of fries?
```
email 2 is:
```
>What is the price of a hamburger?
$4.25
>What is the price of a cheeseburger?
$4.75
>What is the price of fries?
$2.50
```
email 3 is:
```
> > What is the price of a cheeseburger?
> $4.75
Infation just happened: now $4.80
```
So we will have in our JSONL
```jsonl
{"instruction": "Reply to this email professionally.", "input":"What is the price of a hamburger?\nWhat is the price of a cheeseburger?\nWhat is the price of fries?\n> What is the price of a hamburger?", "output": ""}
{"instruction": "Reply to this email professionally.", "history":"What is the price of a hamburger?\nWhat is the price of a cheeseburger?\nWhat is the price of fries?\n> What is the price of a hamburger?", "input": "> What is the price of a hamburger?", "output": "$4.25"}
{"instruction": "Reply to this email professionally.", "history":"What is the price of a hamburger?\nWhat is the price of a cheeseburger?\nWhat is the price of fries?\n> What is the price of a cheese burger?", "input": "> What is the price of a cheeseburger?", "output": "$4.75"}
{"instruction": "Reply to this email professionally.", "history":"What is the price of a hamburger?\nWhat is the price of a cheeseburger?\nWhat is the price of fries?\n> What is the price of fries?",  "input": "> What is the price of fries?", "output": "$2.50"}
{"instruction": "Reply to this email professionally.", "history":"> What is the price of a hamburger?\n$4.25\n> What is the price of a cheeseburger?\n$4.75\n> What is the price of fries?\n$2.50", "input": "> > What is the price of a cheese burger?\n> $4.75", "output": "Inflation just happened: now $4.80"}
```
Notice that we are not overly-complicating things. Note also that within the "input" field within our JSONL line derived from email 3, we have "> > " preceding the first line of quoted text, but within the "history" field of the very same JSONL line, there is only one "> " preceding the same line as "What is the price of a cheeseburger?". 

## A pyramid
Each JSONL line should be one training example (input + output pair), so every reply in the thread gets its own line.  I will describe this as "apex fanning out" : by which I mean that you might get multiple lines where the same parent message appears in different inputs, paired with different sibling replies as outputs, which teaches varied response styles.  

So I can successively combine the previous message as "history", with a specific quoted text from the present message as "input", and have the non-quoted text from the present email message as "output".  I can do this for every email in a thread with the apex original fanning out a pyramid structure.  I will not omit the apex vertex from the training as this does have the original email body within its "input" field.  I say I should not require to inform LoRA of the email reference metadata, or the in-reply-to metadata (which are useful for RAG and KG) because this data would be superfluous to how the AI neural network operates.

## Tell me about *how* we will chunk our message_body's.
We don't want *any* overlap between the chunks for Vector embedding and indexing, because Vector doesn't need them : instead, when we are populating the non-DPR Vector DB, we treat our email corpus as one big collection of data.  We chunk each email body, and associate with each chunk this email's metadata ; then we text-embed, and store this embedded vector within a non-DPR Vector database ; and we will now have completed the Vector DB offline stage. 

To have overlap between the chunks of email-bodies (associated with the same email's metadata) for Vector, is not as harmful in the same way that it would be for LoRA training (by overfitting some of the data), but it would be messy data curation, as a Vector DB doesn't specifically learn from duplicates. This approach of having duplicates, which we reject, would bloat storage, resulting in redundant chunks being returned, eating into the top-*k* budget of the most relevantly returned raw text chunks (which *would* actually detriment our performance, and so in this sense *would* be harmful).  As a split between chunks mid-sentence is useless in both halves, I say, the correct approach is to programatically to test for a fixed size, say 0.7, of the embedding model's max tokens, which, when approached in a wall-of-text (the sender wrote 47 lines without hitting the Enter button twice in a row) chunks upon a sentence boundary near to this 70% mark of the max tokens in this case ; whilst otherwise to split upon a paragraph break. This design will incorporate having a look-ahead examination for a wall-of-text, because, just say this wall begins at the 50% mark of the max tokens (pertaining to the email body), and this wall-of-text is 70% of the size of the maximum number of the tokens for this embedding model, we want to break the wall-of-text after about the next 20% (of the size of max tokens) within the next chunk, leaving a remaining wall-of-text now of about 50% of the size of the max number of tokens for the embedding model (which is calulated by 0.7 - 0.2), and then start the next chunk (the third chunk) upon this breakpoint. We will want this look-ahead to happen iteratively for all chunks of an email's body which span multiple chunks. It is a moving window where we are aiming for the 70% size of a max token of the embedding model each time but might miss by give or take 20%. We need within this algorithm the guarantee that we will never make each chunk exceed the 90% of this max token constant.  This algorithm is a type of sliding window.

TO DO.  implement this kind of a chunker.  "bin/chunker_for_vector_db"
