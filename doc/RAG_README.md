# RAG Pipeline Tutorial: Ruby-Only Edition
## For a 45k-Email CPT/RAG System

**Audience:** You have parsed JSON emails from mbox, trained a LoRA adapter, and now need to build the retrieval-augmented generation (RAG) side. You know Ruby, not Python.

**What RAG does:** At query time, RAG searches your email corpus for relevant context, injects it into the prompt, and sends the enriched prompt to your fine-tuned model for generation.

**Pipeline Overview:**
```
Parsed emails → Dequote → Chunk → Index (SQLite FTS5) → Query → Retrieve → Prompt → LLM → Answer
```

## pre-processing step
```bash
jq -c '.[]' train.json > train.jsonl
jq -c '.[]' val.json > val.jsonl
jq -c '.[]' test.json > test.jsonl

cat train.jsonl val.jsonl test.jsonl > corpus.jsonl 
```
---

## Step 1: Dequote Emails

Strip quoted text ("> lines" or "On DATE, SENDER wrote:") so you don't index noise.

**dequote_emails.rb**
```ruby
#!/usr/bin/env ruby
require 'json'

# Remove quoted lines and reply headers
def dequote(text)
  lines = text.split("\n")
  cleaned = []
  lines.each do |line|
    # Skip lines starting with > or common reply patterns
    next if line =~ /^\s*>/
    next if line =~ /^On .+ wrote:/i
    next if line =~ /^From:.+Sent:/i  # Outlook-style
    cleaned << line
  end
  cleaned.join("\n").strip
end

# Read JSON emails, add dequoted_text field
input_path = ARGV[0] || 'emails.json'
output_path = ARGV[1] || 'emails_dequoted.json'

emails = JSON.parse(File.read(input_path))
emails.each do |email|
  email['dequoted_text'] = dequote(email['text'] || '')
end

File.write(output_path, JSON.pretty_generate(emails))
puts "✓ Dequoted #{emails.size} emails → #{output_path}"
```

**Usage:**
```bash
ruby dequote_emails.rb emails.json emails_dequoted.json
```

---

## Step 2: Chunk Emails

Split long emails into overlapping chunks (~400 tokens, 50-token overlap) for retrieval.

**chunk_emails.rb**
```ruby
#!/usr/bin/env ruby
require 'json'

CHUNK_SIZE = 400  # tokens
OVERLAP = 50

# Naive token approximation: split on whitespace
def tokenize(text)
  text.split(/\s+/)
end

def chunk_text(text, chunk_size, overlap)
  tokens = tokenize(text)
  chunks = []
  start = 0
  while start < tokens.size
    chunk_tokens = tokens[start, chunk_size]
    chunks << chunk_tokens.join(' ')
    start += (chunk_size - overlap)
  end
  chunks
end

input_path = ARGV[0] || 'emails_dequoted.json'
output_path = ARGV[1] || 'chunks.json'

emails = JSON.parse(File.read(input_path))
chunks = []

emails.each do |email|
  text = email['dequoted_text'] || email['text'] || ''
  next if text.strip.empty?
  
  chunk_texts = chunk_text(text, CHUNK_SIZE, OVERLAP)
  chunk_texts.each_with_index do |chunk_text, i|
    chunks << {
      'chunk_id' => "#{email['message_id']}_#{i}",
      'message_id' => email['message_id'],
      'thread_id' => email['thread_id'],
      'sender' => email['sender'],
      'subject' => email['subject'],
      'date' => email['date'],
      'chunk_text' => chunk_text
    }
  end
end

File.write(output_path, JSON.pretty_generate(chunks))
puts "✓ Created #{chunks.size} chunks from #{emails.size} emails → #{output_path}"
```

**Usage:**
```bash
ruby chunk_emails.rb emails_dequoted.json chunks.json
```

---

## Step 3: Index Chunks with SQLite FTS5 (BM25)

SQLite's FTS5 implements a BM25-like ranker natively.

**index_chunks.rb**
```ruby
#!/usr/bin/env ruby
require 'json'
require 'sqlite3'

db_path = ARGV[0] || 'rag_index.db'
chunks_path = ARGV[1] || 'chunks.json'

db = SQLite3::Database.new(db_path)

# Create FTS5 virtual table for full-text search
db.execute <<-SQL
  CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    chunk_id UNINDEXED,
    message_id UNINDEXED,
    thread_id UNINDEXED,
    sender UNINDEXED,
    subject,
    date UNINDEXED,
    chunk_text,
    tokenize = 'porter unicode61'
  );
SQL

# Clear old data
db.execute('DELETE FROM chunks_fts')

chunks = JSON.parse(File.read(chunks_path))

db.transaction do
  chunks.each do |chunk|
    db.execute(
      'INSERT INTO chunks_fts (chunk_id, message_id, thread_id, sender, subject, date, chunk_text) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [chunk['chunk_id'], chunk['message_id'], chunk['thread_id'], chunk['sender'], chunk['subject'], chunk['date'], chunk['chunk_text']]
    )
  end
end

puts "✓ Indexed #{chunks.size} chunks into #{db_path}"
db.close
```

**Usage:**
```bash
ruby index_chunks.rb rag_index.db chunks.json
```

---

## Step 4: Retrieve Relevant Chunks

Query FTS5 with BM25 ranking, exclude self and future emails.

**retrieve_chunks.rb**
```ruby
#!/usr/bin/env ruby
require 'sqlite3'
require 'json'
require 'time'

db_path = ARGV[0] || 'rag_index.db'
query_text = ARGV[1] || ''
exclude_message_id = ARGV[2] || nil
max_date = ARGV[3] || Time.now.utc.iso8601  # Exclude future emails
top_k = (ARGV[4] || 5).to_i

db = SQLite3::Database.new(db_path)
db.results_as_hash = true

# FTS5 query with BM25 ranking
sql = <<-SQL
  SELECT 
    chunk_id, message_id, thread_id, sender, subject, date, chunk_text, 
    bm25(chunks_fts) AS score
  FROM chunks_fts
  WHERE chunks_fts MATCH ?
    AND message_id != COALESCE(?, '')
    AND date <= ?
  ORDER BY score
  LIMIT ?
SQL

results = db.execute(sql, [query_text, exclude_message_id, max_date, top_k])

puts JSON.pretty_generate(results)
db.close
```

**Usage:**
```bash
ruby retrieve_chunks.rb rag_index.db "How do I configure the email parser?" "msg123@example.com" "2025-11-01T00:00:00Z" 5
```

Returns top-5 chunks ranked by BM25, excluding `msg123@example.com` and emails after Nov 1.

---

## Step 5: Build Prompt and Call LLM

Construct a RAG-aware prompt and send it to your fine-tuned model (via OpenAI-compatible API or local server).

**rag_query.rb**
```ruby
#!/usr/bin/env ruby
require 'json'
require 'net/http'
require 'uri'

# Config
API_URL = ENV['LLM_API_URL'] || 'http://localhost:8000/v1/chat/completions'
API_KEY = ENV['LLM_API_KEY'] || 'sk-dummy'
MODEL = ENV['LLM_MODEL'] || 'fine-tuned-llama'

db_path = ARGV[0] || 'rag_index.db'
query_text = ARGV[1] || 'How do I parse emails?'
exclude_message_id = ARGV[2] || nil
max_date = ARGV[3] || Time.now.utc.iso8601
top_k = (ARGV[4] || 5).to_i

# Retrieve chunks
retrieve_script = File.expand_path('retrieve_chunks.rb', __dir__)
chunks_json = `ruby #{retrieve_script} "#{db_path}" "#{query_text}" "#{exclude_message_id}" "#{max_date}" #{top_k}`
chunks = JSON.parse(chunks_json)

# Build context from retrieved chunks
context = chunks.map.with_index do |chunk, i|
  "--- Snippet #{i+1} (from #{chunk['sender']}, #{chunk['date']}) ---\n#{chunk['chunk_text']}"
end.join("\n\n")

# Build RAG prompt
prompt = <<~PROMPT
  You are a helpful assistant with access to the user's email archive.

  Context (retrieved from email archive):
  #{context}

  User question: #{query_text}

  Answer the question using ONLY the information in the context above. If the context does not contain the answer, say "I don't have enough information."
PROMPT

# Call LLM API (OpenAI-compatible)
uri = URI.parse(API_URL)
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = (uri.scheme == 'https')

request = Net::HTTP::Post.new(uri.path, {'Content-Type' => 'application/json', 'Authorization' => "Bearer #{API_KEY}"})
request.body = JSON.generate({
  model: MODEL,
  messages: [
    { role: 'user', content: prompt }
  ],
  temperature: 0.7,
  max_tokens: 500
})

response = http.request(request)
result = JSON.parse(response.body)

answer = result.dig('choices', 0, 'message', 'content') || 'Error: No response'

puts "=== RAG Answer ==="
puts answer
puts "\n=== Retrieved Context ==="
puts context
```

**Usage:**
```bash
export LLM_API_URL="https://api.openai.com/v1/chat/completions"
export LLM_API_KEY="sk-your-key"
export LLM_MODEL="gpt-4"

ruby rag_query.rb rag_index.db "How do I configure the email parser?"
```

Or point to your local LoRA-served endpoint (vLLM, llama.cpp server, etc.).

---

## Step 6: End-to-End Workflow

**Pipeline sequence:**
```bash
# 1. Parse mbox → emails.json (you already have this from mbox_pre-parser + email_splitter)
ruby mbox_pre-parser.rb inbox.mbox emails_raw.json
ruby email_splitter.rb emails_raw.json emails.json

# 2. Dequote
ruby dequote_emails.rb emails.json emails_dequoted.json

# 3. Chunk
ruby chunk_emails.rb emails_dequoted.json chunks.json

# 4. Index
ruby index_chunks.rb rag_index.db chunks.json

# 5. Query
ruby rag_query.rb rag_index.db "What is the email retention policy?"
```

---

## Step 7: Integrate with RAG Evaluator

Your `RAG_evaluator.rb` already computes Recall@k and Hit@k using thread-graph gold sets. To test your RAG pipeline:

1. **Generate retrieval results** for each test email:
   ```ruby
   # Modify retrieve_chunks.rb to output JSON array
   # For each test email, construct query from subject + first N lines, retrieve top-k
   ```

2. **Feed to RAG_evaluator.rb** in expected format:
   ```json
   [
     {
       "query_message_id": "msg1@example.com",
       "retrieved_message_ids": ["msg2@example.com", "msg3@example.com", ...]
     }
   ]
   ```

3. **Run evaluation:**
   ```bash
   ruby RAG_evaluator.rb --emails emails.json --retrieved-results retrieval_output.json --k 5 --output eval_report.txt
   ```

This gives you Recall@5, Hit@5, and confidence intervals comparing your RAG system to the thread-graph ground truth.

---

## Troubleshooting

- **Low recall?** Try increasing `top_k`, tuning FTS5's BM25 parameters (https://www.sqlite.org/fts5.html#the_bm25_function), or adding subject/sender boosting.
- **Too much noise?** Improve dequoting (regex for signatures, footers), filter out automated emails (cron, nagios).
- **Want vectors?** Replace SQLite FTS5 with a vector index:
  - Generate embeddings via HTTP API (OpenAI, Cohere, local sentence-transformers server)
  - Store in FAISS (via Ruby FFI or call Python microservice), Qdrant (HTTP API), or Postgres+pgvector
  - Hybrid: BM25 for lexical + vector for semantic, rerank top-20 from each

---

## Summary

You now have a **pure Ruby RAG pipeline**:
1. **Dequote** → strip quoted text
2. **Chunk** → split into overlapping windows
3. **Index** → SQLite FTS5 (BM25)
4. **Retrieve** → query with leakage prevention
5. **Prompt** → inject context + call LLM
6. **Evaluate** → measure Recall@k with your RAG_evaluator.rb

Start with BM25, ship it, measure with your evaluator, then upgrade to vectors if lexical search isn't cutting it. You're ready to build.