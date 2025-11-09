# RAG Evaluator Tutorial (For Normal Humans)

## What Is This Thing?

Imagine you have 45,000 emails and you want to build a system that can find the right email when you ask a question. RAG_evaluator.rb tests how good your email-finding system is.

Think of it like testing a librarian: You ask "Where's the book about cats?" and check if they point you to the right shelf. This script does that automatically for thousands of test questions.

## What You Need

1. **Ruby installed** - Type `ruby --version` in your terminal. If you see a version number (like 3.2.0), you're good. If not, install Ruby first.
2. **Your email data as JSON** - A file containing all your emails in a specific format (probably created by the email splitter script).

## Step-by-Step Instructions

### 1. Get the Files Ready

Please see [RAG_evaluator-tutorial.md](./RAG_evaluator-tutorial.md## Full Pipeline: mbox → Evaluation) for complete pipeline.

You need:
- `RAG_evaluator.rb` (the evaluator script)
- `train.json` (or whatever you named your email data file)

Put them in the same folder.

### 2. Run the Basic Command

Open your terminal, navigate to the folder, and type:

```bash
ruby RAG_evaluator.rb train.json
```

That's it! The script will:
- Pick 500 random emails as test questions
- Try to find related emails for each one
- Tell you how well it did

### 3. What You'll See

After a few seconds (or minutes with lots of emails), you'll get output like:

```
Evaluating RAG retrieval with BM25 baseline...
Built thread graph: 8,234 threads from 45,000 emails
Sampled 500 queries

Results (k=5):
Hit@5 (macro): 0.78 ± 0.04
Hit@5 (micro): 0.81 ± 0.03
Recall@5 (macro): 0.45 ± 0.05
Recall@5 (micro): 0.52 ± 0.04
```

**What does this mean?**

- **Hit@5**: "Did we find AT LEAST ONE correct email in the top 5 results?"
  - 0.78 = 78% of the time, yes!
  
- **Recall@5**: "Out of ALL the correct emails, how many did we find?"
  - 0.45 = We found 45% of them on average

- **The ± numbers**: Uncertainty range. Think of it as margin of error.

- **macro vs micro**: 
  - macro = treats rare senders same as frequent senders (fair to everyone)
  - micro = weighted by how many emails each person sent (overall accuracy)

### 4. Tuning Your Test

You can customize the test with flags:

#### Change how many results to check (default is 5):
```bash
ruby RAG_evaluator.rb train.json --k 10
```
Now it checks the top 10 results instead of top 5.

#### Test with more/fewer questions (default is 500):
```bash
ruby RAG_evaluator.rb train.json --sample-size 1000
```
More = slower but more reliable results.

#### Use more email text in queries (default is 5 lines):
```bash
ruby RAG_evaluator.rb train.json --query-lines 10
```
Uses more of the email body to search.

#### Enable smart heuristics:
```bash
ruby RAG_evaluator.rb train.json --heuristics
```
Gives credit for finding emails in the same conversation thread.

#### Combine multiple flags:
```bash
ruby RAG_evaluator.rb train.json --k 10 --sample-size 1000 --heuristics
```

## Reading the Results

### Good Numbers

- **Hit@5 above 0.70** = Pretty good! Finding something relevant most of the time.
- **Recall@5 above 0.40** = Decent! Catching almost half of related emails.

### What to Do If Numbers Are Low

**Hit@5 below 0.50?**
- Your search isn't finding relevant emails often enough
- Try: `--heuristics` flag, or increase `--k` to see if relevant emails are just ranked lower

**Recall@5 below 0.30?**
- You're missing too many related emails
- Try: Increase `--k` to retrieve more results, or use `--query-lines 10` for richer queries

## Troubleshooting

### "cannot load such file -- json"
Your Ruby is missing the JSON library. Run: `gem install json`

### "No such file or directory - train.json"
The script can't find your email file. Make sure:
- The file exists
- You're in the right folder
- You spelled the filename correctly

### "undefined method `[]' for nil"
Your JSON file might be malformed. Check that it has the right structure:
```json
[
  {
    "message_id": "<123@example.com>",
    "subject": "Re: Meeting notes",
    "sender": "alice@example.com",
    "text": "Here are the notes...",
    "references": "<456@example.com>",
    "thread_id": "thread_789",
    "date": "2025-01-15"
  }
]
```

### "All queries have empty gold sets"
Your emails don't have proper threading information (References/In-Reply-To headers). The evaluator needs these to know which emails are related.

## What to Do Next

1. **Run the basic test first**: `ruby RAG_evaluator.rb train.json`
2. **Note your baseline numbers**
3. **Try with heuristics**: Add `--heuristics` and see if it improves
4. **Experiment with k**: Try `--k 3`, `--k 5`, `--k 10` to see how many results you really need
5. **Compare before/after**: After you train your AI model, run the evaluator again to see if it's better than BM25

## Quick Reference

| Flag | What It Does | Example |
|------|-------------|---------|
| `--k N` | Check top N results | `--k 10` |
| `--sample-size N` | Test with N questions | `--sample-size 1000` |
| `--query-lines N` | Use N lines of email body | `--query-lines 10` |
| `--heuristics` | Use smart thread-based matching | `--heuristics` |

## Glossary

- **BM25**: A proven search algorithm (like Google search, but simpler). This is your baseline.
- **RAG**: Retrieval-Augmented Generation - fancy term for "find relevant docs, then use them"
- **Hit@k**: Did we find at least one correct result in the top k?
- **Recall@k**: What percentage of correct results did we find?
- **Gold set**: The emails we KNOW are related (based on email threads)
- **Thread**: A conversation chain of emails replying to each other
- **Macro average**: Treats all email senders equally
- **Micro average**: Weighted by total number of emails
- **CI (Confidence Interval)**: The ± number - margin of uncertainty

## Example Session

```bash
$ ruby RAG_evaluator.rb my_emails.json --k 5 --sample-size 500

Evaluating RAG retrieval with BM25 baseline...
Built thread graph: 6,123 threads from 45,234 emails
Sampled 500 queries

Results (k=5):
Hit@5 (macro): 0.76 ± 0.04
Hit@5 (micro): 0.79 ± 0.03
Recall@5 (macro): 0.43 ± 0.05
Recall@5 (micro): 0.49 ± 0.04

Done in 34.2 seconds
```

**Interpretation**: "76% of the time we found at least one related email in the top 5 results, and we recovered about 43-49% of all related emails on average. Not bad for a baseline!"

---

**Questions?** This tool measures search quality automatically using email thread relationships as ground truth. Higher numbers = better search. Start with defaults, then experiment with flags to understand what works best for your data.