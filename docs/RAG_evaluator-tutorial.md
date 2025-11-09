# RAG_evaluator.rb Tutorial

## Overview
RAG_evaluator.rb performs automatic quality assessment of retrieval systems using distant supervision. It evaluates how well your RAG pipeline retrieves relevant context by treating email thread relationships as ground truth.

## Prerequisites
- Ruby 2.7+ with stdlib (optparse, json, set, digest)
- Input: JSON file with email data in sampler-ready format

## Quick Start
```bash
# Basic evaluation with defaults (k=5, 1000 samples, 3 query lines)
ruby RAG_evaluator.rb train.json

# Custom parameters
ruby RAG_evaluator.rb train.json --k 10 --sample-size 2000 --query-lines 5 --heuristics
```

## Input Data Format
Your JSON file should contain an array of email objects with these fields:
```json
[
  {
    "message_id": "<abc@example.com>",
    "sender": "alice@example.com",
    "thread_id": "thread_abc123",
    "subject": "Re: Project update",
    "date": "2024-10-15T10:30:00Z",
    "references": "<parent@example.com> <grandparent@example.com>",
    "in_reply_to": "<parent@example.com>",
    "text": "Full email body text here..."
  }
]
```

## Full Pipeline: mbox → Evaluation

### Step 1: Parse mbox to intermediate JSON
```bash
ruby mbox_pre-parser.rb input.mbox > intermediate.json
```
Output: `[{"message_id": "...", "email_message": "raw RFC 822..."}]`

### Step 2: Thread and split emails
```bash
ruby splitter.rb intermediate.json
```
Output: `train.json`, `validation.json`, `test.json` in sampler-ready format

### Step 3: Evaluate RAG retrieval
```bash
ruby RAG_evaluator.rb train.json --k 5 --sample-size 1000
```

## Command-Line Flags

### --k [INTEGER] (default: 5)
Number of top documents to retrieve per query.
- Higher k → better recall, slower evaluation
- Typical values: 3-10 for email retrieval

### --sample-size [INTEGER] (default: 1000)
Number of random emails to use as test queries.
- Larger samples → more reliable metrics, slower runtime
- 1000-2000 recommended for 45k email corpus
- Stratified by sender and thread to prevent bias

### --query-lines [INTEGER] (default: 3)
Number of non-quoted body lines to include in query (beyond subject).
- 0 → subject only
- 3-5 → typical context
- 10+ → verbose queries (may hurt precision)

### --heuristics (flag, default: off)
Enable bonus correctness criteria:
- Retrieved doc shares a Message-ID in query's References chain
- Retrieved doc shares the same thread_id
Use this to credit "near-miss" retrievals that are contextually relevant.

## Understanding the Output

```
=== RAG Evaluation Results ===
Evaluated 1000 queries from 45000 documents

Hit@5:      0.7234 ± 0.0276  (72.34% of queries retrieved ≥1 relevant doc)
Recall@5:   0.4156 ± 0.0198  (retrieved 41.56% of all relevant docs on average)

Macro Hit@5:    0.6891  (average across individual queries)
Macro Recall@5: 0.3892

BM25 Baseline:
  - Term frequency + inverse doc frequency ranking
  - No ML (machine learning), purely statistical
```

### Key Metrics

**Hit@k** (Precision-oriented)
- Did we retrieve *at least one* relevant document?
- Range: 0.0 (never found anything) to 1.0 (always found something)
- Target: >0.70 for good RAG systems

**Recall@k** (Coverage-oriented)
- What fraction of all relevant docs did we retrieve?
- Penalizes missing relevant context
- Target: >0.40 for k=5 (many emails have >5 related docs)

**Macro vs. Micro**
- Micro: Weight queries by gold set size (prolific threads matter more)
- Macro: Equal weight per query (rare voices count equally)

**95% Confidence Interval (±)**
- Statistical uncertainty range
- Smaller CI (confidence interval) → more reliable estimate (larger samples help)

## Gold Set Construction Logic

For each query email Q:
1. Parse References and In-Reply-To headers
2. Build thread graph using JWZ algorithm
3. Gold set G(Q) = ancestors + siblings (emails in same thread)
4. Exclude Q itself (no self-retrieval)
5. Exclude future-dated docs (no time leakage)

## Evaluation Strategy

### Retrieval Process
1. Query = subject + first N non-quoted lines
2. Strip "Re:", "Fwd:", email quotes (>), signatures
3. Tokenize and run BM25 against all docs
4. Rank by relevance score
5. Return top-k

### Scoring
- **Hit@k = 1** if any retrieved doc ∈ G(Q), else 0
- **Recall@k** = |retrieved ∩ G(Q)| / |G(Q)|
- Average across all sampled queries

## Troubleshooting

### "No gold documents found for most queries"
- Check that References/In-Reply-To headers are populated
- Verify thread_id assignment in refactored_splitter output
- Mailing lists often have better threading than personal email

### Low recall scores
- Try increasing --k (retrieve more docs)
- Tune --query-lines (3-5 usually optimal)
- Enable --heuristics to credit near-misses
- Consider text preprocessing (remove footers, normalize)

### Slow execution
- Reduce --sample-size (500-1000 sufficient for trends)
- BM25 is O(n*m) where n=queries, m=docs
- For 45k corpus: ~30-60 seconds for 1k samples

## Comparison to Alternatives

**vs. Manual Labeling**
- RAG_evaluator: Automatic, scales to 45k emails
- Manual: Requires reading/annotating thousands of pairs

**vs. End-task Metrics**
- RAG_evaluator: Direct retrieval quality
- End-task: Depends on downstream LLM (confounded)

**vs. Embedding Similarity**
- RAG_evaluator: Task-relevant (thread context)
- Cosine similarity: May retrieve topically similar but unhelpful docs

## Advanced: Ablation Studies

Test different configurations to optimize your pipeline:
```bash
# Subject-only queries
ruby RAG_evaluator.rb train.json --query-lines 0 --k 5

# Deep context
ruby RAG_evaluator.rb train.json --query-lines 10 --k 10

# With heuristics
ruby RAG_evaluator.rb train.json --heuristics

# Large sample for final benchmark
ruby RAG_evaluator.rb train.json --sample-size 5000 --k 5
```

Compare Hit@k and Recall@k across runs to find optimal settings.

## Related Artifacts
- RAG_evaluator.rb
- splitter.rb
- mbox_pre-parser.rb

## Next Steps
1. Run baseline evaluation: `ruby RAG_evaluator.rb train.json`
2. Note Hit@5 and Recall@5 scores
3. After training your LoRA adapter, re-run on test.json
4. Compare: Did fine-tuning improve retrieval vs. BM25?
5. Iterate on data cleaning, query construction, k-value

The beauty of distant supervision: you get objective, reproducible metrics without manual annotation. Thread relationships *are* the ground truth.