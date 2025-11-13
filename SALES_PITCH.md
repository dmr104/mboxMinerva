# mboxMinerva Sales Training Manual
**Version 1.0 | For Customer-Facing Teams**

---

## 1. Executive Summary

**What is mboxMinerva?**  
mboxMinerva is a production-grade email archive processing platform that safely prepares your organization's email data for fine-tuning large language models (LLMs). It turns decades of institutional knowledge locked in email archives into AI models that understand your business context, language, and workflows—while protecting privacy and ensuring regulatory compliance.

**Elevator Pitch (30 seconds)**  
"Your email archive is your organization's memory: decades of decisions, expertise, and relationships. mboxMinerva transforms that knowledge into custom AI models that speak your language and understand your business, while automatically handling privacy, compliance, and data governance. You get better AI that's trained on *your* institutional knowledge, not generic internet data."

---

## 2. Customer Outcomes & Business Value

### What Customers Get
- **Custom AI trained on institutional knowledge**: Models understand domain-specific terminology, workflows, decision patterns, and organizational context
- **Privacy-safe pipeline**: Automatic PII (personally identifiable information) scrubbing with audit trails, GDPR/CCPA compliance built-in
- **Reproducible ML (machine learning) operations**: Every training run is deterministic and traceable with no guessing why results changed
- **Catastrophic forgetting prevention**: Rehearsal sampling ensures models remember old knowledge while learning new patterns
- **Self-hosted or cloud**: Train on your laptop, a server, or cloud GPUs: the same pipeline everywhere
- **Retrieval-Augmented Generation (RAG) ready**: Deploy models with live email search to answer questions grounded in actual correspondence

### ROI (Return on investment) facets
- **Faster onboarding**: New employees query the AI instead of digging through years of archived threads
- **Decision support**: "What did we decide about X in 2019?" answered instantly with source citations
- **Competitive intelligence**: We can extract repeatable patterns in customer/partner communication
- **Risk & compliance**: We can identify sensitive topics, and automate DSR (data service request) workflows
- **Knowledge retention**: When experts leave, their email-based expertise stays trainable

---

## 3. Design Decisions Explained (For Customers)

### Why Immutable Manifests?
**Customer Language**: "Think of it like a blockchain for your training data: once we assign an email thread to 'training' or 'validation,' that assignment never changes. This means you can re-run training next month and compare apples-to-apples, or audit exactly which data was used in a regulatory inquiry."

**Business Value**: "Reproducibility = trust. Regulators, auditors, and your data science team all see the same split.  A split is the role tag on each manifest row (train, val, or test) which controls which shard it materializes into, and and how it updates (train can be re-cut anytime; val and test stay pinned and only change on DSR subtracts or a deliberate pin bump).  A pin bump is the deliberate advancing done to the cohort_id cutoff for val and test (e.g. 2025-01 goes to 2025-07), followed by rematerialization of those splits to include the newer cohorts. Train can keep re-cutting under the old pin, but val/test only move when you bump.  The file as bin/splitter.rb is the CLI (command line interface) we invoke to materialize or rematerialize splits from the immutable manifest (e.g. `splitter.rb --pin 2025-01 --materialize train` will materialize including all cohorts prior to that particular date, excluding tombstoned rows, but won't touch val/test unless we do `splitter.rb --pin 2025-01 --materialize all` which will rematerialize train/val/test using only cohorts with cohort_id <= 2025-01, and won't include newer cohorts, and won't change the pre-existing composition of what already got put into val and test beyond DSR effects).  At what stage does the cohort_id get written into the immutable manifest rows?  Answer. At ingest time:  when bin/mbox_pre-parser.rb appends new rows, it stamps cohort_id (usually YYYY-MM from 'received_at:' which is from within the email, or from the latest configured batch cutoff)."

---

### What are unique thread ids?
**Customer language**: "thread_id is the conversation key that keeps all emails from one thread glued to the same split to avoid train/val/test leakage and enable sliding-window chunking; It is derived in bin/mbox_pre-parser.rb; then bin/splitter.rb groups on thread_id to assign one deterministic split and annotate window_idx and window_range for that thread."

**Business value**: "Each thread_id gets ONE frozen split, and all its windows inherit that split, so overlap duplicates data
within train (or val, or test) for better context coverage, but never leaks the same thread's context across
splits.  It is split-pure by design.  A thread's "context" = the entire conversation for a thread; so chunks from that thread never cross thread/val/test. 

bin/splitter.rb groups by thread_id, and always hashes with a deterministic seed to assign train/val/test (80/10/10) to the immutable manifest, writing immutably to assignments.json.  To say this again, splitter.rb assigns per-thread splits using a deterministic hash (seeded) to hit a fixed ratio so that the inputs always map to the same split in the immutable manifest unless you change the seed or config ratio (which you should not do midstream because this would invalidate previous assignments, and if you do you must recreate the whole manifest and then materialize it). In bin/splitter.rb when --window-size is enabled, ALL windows of a thread inherit the SAME deterministic split, and when omitted splitter.rb assigns the entire thread as a single manifest entry.  So in either case, there is not any context leakage across train/val/test."


### Why Deterministic Hash-Bucketing?
**Customer Language**: "We use a mathematical fingerprint of each email thread to decide whether it goes into training, validation, or test; so the split is automatic, fair, and stable. Add new emails tomorrow? They slot into the right bucket without reshuffling everything."

**Business Value**: No manual sorting, no human bias, always explainable to auditors.

---

### Why Thread-Level Splits (Not Message-Level)?
**Customer Language**: "Email conversations are like chapters in a book.  Splitting mid-thread would leak answers into the test set. We keep entire threads together so the AI learns naturally and evaluations are honest."

**Business Value**: Better model accuracy, no inflated test scores, defensible ML hygiene.

---

### Why PII (personally identifiable information) Scrubbing *Before* Training?the
**Customer Language**: "We replace real names, email addresses, and IPs with pseudonyms before the data ever touches the model. If someone requests deletion (GDPR 'right to be forgotten'), we tombstone their pseudonym and retrain.  This is clean, auditable, with no residual PII."

**Business Value**: GDPR/CCPA compliance by design, reduced breach risk, exportable DSR workflows.

---

### Why timely retraining on a DSR (Data Subject Request)?
**Customer language**: "When a DSR comes in, the first thing we do is mark the user as tombstoned within the immutable manifest. Then we regenerate the dataset (train.jsonl); and then, within a reasonable time period, we retrain the model from its base checkpoint by creating a new LoRA adaptor and refitting it: it is like painting a new canvas, as opposed to merely touching up the old one.  Upon receipt of a DSR deletion request, as we retrain on set cadence (e.g. monthly), we may fulfill any legal or contractual obligations to have done so; and while not retraining immediately upon every DSR request, we may receive several DSR deletion requests within the month: of which we tombstone each of those immediately, and via rematerialization of the RAG shards we stop serving their content and purge any caches, so the data subject will be removed sooner." 

**Business value**: "Immediate tombstoning/rematerializing gives you hard compliance proof and risk reduction in the sense that you stop serving personal data now, meeting GDPR/CCPA SLAs (service level agreements), cut fines and liability, preserve trust and renewals, unblock enterprise deals with clean audit logs, and avoid costly hotfixes by decoupling serving from slower retrains."

---

### What is this "train.jsonl" thing?
**Customer language**: "When I rematerialize the dataset from the immutable manifest, normally only train.jsonl gets materialized, and val.jsonl and test.jsonl remain fixed, except (a) for DSRs, you re-materialize them to subtract tombstoned rows only, and (b) for your planned rollover, you bump the pin, bringing in the newer cohort rows from the immutable manifest. Normal weekly rematerializations leave val.jsonl and test.jsonl untouched. A cohort_id (e.g. 2025-01) is the stable tag for a cohort, and a cohort is simple a group of emails that arrived during this bucketted time-interval, say, 1 month. Because the file called splitter.rb is normally run weekly with targets=train and a fixed cohort pin, it filters the append-only manifest from split=train and writes exclusively to a newly versioned train shard (flipping the symlink).  A fixed cohort pin is the explicit cutoff tag (e.g. cohort_id=2025-01) that val.jsonl and test.jsonl are locked to, so that if I do a planned rollover yearly, and have no DSRs within this time, my explicit cutoff will change only once per year at the planned bump. This doesn't prevent us doing an ad-hoc bump if drift gets too bad.  Drift is a distribution mismatch between what the model has as data we have already fitted and thus measure against, and what real traffic (and thus what the manifest) contains."   

**Business value**:"Understanding this at a customer level proves GDPR/DSR (General Data Protection Regulations / Data Subject Request) compliance and reproducibility, setting customer expectations, and turns a scary "black box" in an auditable service level agreement."

---

### What is a planned rollover?
**Customer language**: "We keep a “golden benchmark” of emails frozen so your results are apples-to-apples across months, and we quarantine new test-candidate emails for quiet, real‑world shadow checks; and once a year we roll them in to update the benchmark"

**Business value**: "A clearer compliance story, with faster stakeholder sign‑off, and less rework because we only change the yardstick on a planned cadence, say every 12 months. We have a trustworthy before/after ROI proof with no leakage from train.jsonl, or surprise regressions in production: such as when we add newer emails in test.jsonl and update the benchmark to make these newer emails, headline metrics can dip, and this *would* be our early-warning system, but we have already fixed data hygiene in-house and intend to keep customer outcomes trending up, not down."

---

### Why git-crypt for the Vault?
**Customer Language**: "The mapping between real identities and pseudonyms lives in an encrypted vault checked into your Git repository. Only authorized team members and CI/CD runners with the right key can decrypt it.  So it's versioned, backed up, and access-controlled."

**Business Value**: No separate secret management system, auditable access logs, works on any Git hosting (GitHub, GitLab, self-hosted).

---

### Why GitLab CI/CD?
**Customer Language**: "Every code change triggers automated tests: data integrity checks, security scans, split validation. You push to Git; the pipeline trains, evaluates, and deploys—no manual steps, no 'it worked on my laptop.'"

**Business Value**: Faster iteration, fewer bugs in production, one-click rollback.

---

### Why vLLM for Serving?
**Customer Language**: "vLLM is like a hyper-efficient switchboard for your GPU—it serves dozens of simultaneous queries without wasting compute. You buy one GPU, serve your whole team."

**Business Value**: Lower hardware cost per query, faster response times, scales with concurrency.

---

### Why RAG (Retrieval-Augmented Generation)?
**Customer Language**: "The fine-tuned model understands your email style and domain jargon. RAG adds live search: when a user asks a question, the system pulls relevant threads from the archive and hands them to the model as context—so answers cite actual emails, not hallucinations."

**Business Value**: Grounded responses, source traceability, regulatory defensibility.

---

## 4. How It Works (End-to-End)

### Phase 1: Ingestion & Privacy
1. **Parse**: Load mbox archives (Thunderbird, Apple Mail, Outlook export)
2. **Scrub PII**: Replace emails, names, IPs with pseudonyms; store mapping in encrypted vault
3. **Thread extraction**: Group messages into conversation threads

### Phase 2: Split & Manifest
1. **Hash-bucket**: Assign each thread to train/val/test (80/10/10) via deterministic hash
2. **Immutable manifest**: Write split assignments to append-only JSONL—never changes
3. **Rehearsal sampling**: Reserve a slice of old data to prevent catastrophic forgetting

### Phase 3: Training
1. **QLoRA fine-tuning**: Memory-efficient 4-bit training on consumer GPUs (16–48 GB VRAM)
2. **Checkpointing**: Save model snapshots every N steps
3. **Eval harness**: Measure perplexity before/after to prove the model improved

### Phase 4: Deployment
1. **Merge LoRA**: Combine fine-tuned adapter with base model
2. **Quantize**: Convert to 4-bit/8-bit for faster serving
3. **vLLM server**: Launch OpenAI-compatible API with continuous batching
4. **RAG integration**: Connect to Postgres+pgvector for semantic search over email threads

### Phase 5: Governance
1. **DSR export**: User requests their data → CLI exports all threads by pseudonym
2. **DSR delete**: User requests deletion → CLI writes tombstones, filters them in next training run
3. **Audit logs**: Every action (scrub, split, train, DSR) is logged and versioned in Git

---

## 5. Sales Talk Tracks & Objection Handling

### Talk Track: "Privacy-First AI"
> "Most AI projects bolt on compliance as an afterthought. mboxMinerva scrubs PII *before* training, so your model never sees real names or addresses. If someone requests deletion, we tombstone their pseudonym and retrain—clean, auditable, GDPR-compliant from day one."

**When to Use**: Data officers, compliance teams, privacy-conscious buyers.

---

### Talk Track: "Reproducible ML Ops"
> "Ever had a model work great in dev, then fail in prod? Or retrain next month and wonder why accuracy dropped? Our immutable manifests lock in your train/val/test split—add new data, nothing shuffles. You can always trace exactly what the model saw."

**When to Use**: Data science teams, MLOps engineers, anyone burned by non-reproducible experiments.

---

### Talk Track: "Institutional Knowledge at Scale"
> "Your best salespeople, engineers, and execs have years of email wisdom—customer objections, product decisions, competitive intel. mboxMinerva turns that into a fine-tuned model so new hires can ask 'How did we handle X in 2018?' and get answers grounded in actual threads."

**When to Use**: Leadership, knowledge management buyers, organizations with high turnover or tribal knowledge risk.

---

### Talk Track: "Self-Hosted or Cloud"
> "Start on a laptop with 16 GB GPU for proof-of-concept. Scale to a 128 GB RAM server for production. Or offload heavy training to Vertex AI GPUs. Same pipeline, same Git repo—no vendor lock-in."

**When to Use**: IT/DevOps buyers, budget-conscious prospects, hybrid cloud strategies.

---

### Objection: "We don't have ML expertise."
**Response**:  
"You don't need a data science PhD because mboxMinerva ships with sensible defaults. Your DevOps team runs `git pull`, sets up GitLab CI, and the pipeline handles splits, training, and evals automatically. We provide setup docs, demo scripts, and optional consulting for tuning."

---

### Objection: "Our email has too much sensitive data."
**Response**:  
"That's exactly why we built PII scrubbing into step one. The model trains on pseudonymized text: no real names, emails, or IPs. You control the vault encryption key, and DSR tooling lets you delete or export any individual's data on demand. Compliance teams love it."

---

### Objection: "Training LLMs is expensive."
**Response**:  
"We use QLoRA: a memory-efficient method that fine-tunes 7B–13B models on a single consumer GPU (16–24 GB VRAM). A $2,000 GPU trains overnight. For bigger models or faster iteration, rent cloud GPUs only when you need them. Most customers start with a $3,000 workstation."

---

### Objection: "What if we already have a RAG system?"
**Response**:  
"Great—fine-tuning *complements* RAG. RAG pulls relevant chunks; fine-tuning teaches the model your domain language and style so it generates better responses. mboxMinerva outputs a model you drop into your existing RAG pipeline. We ship a Postgres+pgvector baseline if you're starting from scratch."

---

### Objection: "How do we know the model actually improved?"
**Response**:  
"We include a before/after eval harness: measure perplexity on a held-out test set before fine-tuning, train, measure again. Lower perplexity = the model learned your email patterns. You get quantitative proof, not just vibes."

---

## 6. Demo Script (15 Minutes)

### Setup (Pre-Demo)
- Have a sanitized mbox archive ready (~10k messages, no real PII)
- Git repo cloned, dependencies installed
- GitLab CI pipeline visible in browser
- vLLM server running on localhost:8000 with base model

---

### Act 1: Ingestion & Privacy (3 min)
1. **Show**: `bin/mbox_pre-parser sample.mbox`  
   Output: Parsed threads, extracted metadata
2. **Show**: `bin/pii_scrubber --input parsed/ --output scrubbed/ --vault vault/`  
   Output: Pseudonymized emails, vault/ folder encrypted
3. **Explain**: "Real email addresses are now ALIAS_0001, ALIAS_0002. The vault stores the mapping, encrypted with git-crypt."

---

### Act 2: Splits & Manifests (3 min)
1. **Show**: `bin/splitter --input scrubbed/ --output manifest.jsonl`  
   Output: 80/10/10 split, immutable manifest
2. **Show**: Open `manifest.jsonl` in editor  
   Explain: "Each line is a thread assignment. Hash 0x1234 → train. Never changes."
3. **Show**: `rspec spec/split_integrity_spec.rb`  
   Output: All tests green—no thread contamination, perfect 80/10/10 ratio

---

### Act 3: Training (4 min)
1. **Show**: GitLab CI pipeline UI  
   Jobs: lint → test → train → eval → deploy (all green)
2. **Show**: `scripts/eval_before_after.py` output  
   Metrics: Perplexity dropped 18% after fine-tuning
3. **Explain**: "The model now understands your email style, product names, jargon."

---

### Act 4: Serving & RAG (3 min)
1. **Show**: `curl http://localhost:8000/v1/chat/completions -d '{"model":"fine-tuned","messages":[{"role":"user","content":"What did we decide about the Q3 pricing strategy?"}]}'`  
   Output: AI-generated answer citing thread IDs
2. **Show**: RAG query in pgAdmin (optional)  
   `SELECT thread_id, similarity FROM threads ORDER BY embedding <-> query_vector LIMIT 5`
3. **Explain**: "vLLM serves 10+ users concurrently on one GPU. RAG grounds answers in actual threads."

---

### Act 5: Governance (2 min)
1. **Show**: `bin/dsr_export --email user@example.com`  
   Output: JSONL of all threads involving that pseudonym
2. **Show**: `bin/dsr_delete --email user@example.com --dry-run`  
   Output: List of threads to tombstone
3. **Explain**: "GDPR right-to-deletion in two commands. Retrain without that user's data."

---

## 7. Glossary (Customer-Friendly)

- **Fine-tuning**: Teaching an AI model your specific domain by training it on your data (vs. using a generic model)
- **QLoRA**: Memory-efficient training method that fits big models on small GPUs
- **Immutable manifest**: A locked-in list of which data goes into training/validation/test—never changes
- **Hash-bucketing**: Using a math formula to automatically and fairly assign data to splits
- **PII (Personally Identifiable Information)**: Names, emails, addresses, IPs—data that can identify a person
- **Pseudonymization**: Replacing real identities with fake codes (ALIAS_0001) while keeping a secure lookup table
- **Tombstone**: A marker that says "this data was deleted"—used for GDPR compliance
- **DSR (Data Subject Request)**: Formal request under GDPR/CCPA to export or delete someone's data
- **RAG (Retrieval-Augmented Generation)**: AI technique that searches your data and uses results to ground answers (no hallucinations)
- **vLLM**: High-performance server for running LLMs that handles many queries at once
- **Perplexity**: A score measuring how "surprised" the model is by test data—lower = better learning
- **Catastrophic forgetting**: When AI forgets old knowledge while learning new stuff (we prevent this with rehearsal sampling)
- **git-crypt**: Tool that encrypts specific files in your Git repo (like the PII vault)
- **GitLab CI/CD**: Automation that runs tests, training, and deployment every time you push code

---

## 8. Roadmap & Maturity Notes

### What's Production-Ready Today
- ✅ Immutable manifests with deterministic splits
- ✅ PII scrubbing + encrypted vault
- ✅ DSR export/delete workflows
- ✅ Split integrity tests
- ✅ GitLab CI/CD pipeline
- ✅ QLoRA training on consumer GPUs
- ✅ vLLM serving with continuous batching

### What's In Development (Q1 2026)
- 🚧 RAG baseline (Postgres+pgvector)—architecture documented, integration WIP

### Positioning Guidance
- **For early adopters / R&D teams**: "Proven architecture, active development, ship-ready for internal pilots"
- **For enterprise buyers**: "Production hygiene in place, recommend pilot + Q1 roadmap commitment before full rollout"
- **For regulated industries**: "Privacy/compliance foundations strong, budget 4-week sprint for security hardening (vault enforcement, audit logging, TLS)"

---

## 9. Competitive Positioning

| **Competitor** | **Their Pitch** | **Our Counter** |
|----------------|-----------------|-----------------|
| Generic fine-tuning services (OpenAI, Cohere) | "Just upload your data" | We handle email-specific PII scrubbing, thread extraction, and on-prem deployment—no sending archives to 3rd-party APIs |
| RAG-only solutions (Pinecone, Weaviate) | "Search beats fine-tuning" | We do *both*—fine-tuned model understands your jargon, RAG grounds answers in actual threads |
| Enterprise knowledge graphs | "Structured knowledge > unstructured email" | Email is where decisions actually happen—graphs need manual curation, we're automated |
| Build-it-yourself | "OSS is free" | True, but we ship tested pipelines, privacy tooling, and GitLab CI—your team focuses on business logic, not ML plumbing |

---

## 10. Closing Tips

1. **Lead with pain**: "Where is your institutional knowledge locked up?" → email, Slack, wikis → "We solve email first, it's the richest data."
2. **Demo early**: Schedule a 15-min technical demo within first two calls—seeing is believing.
3. **Anchor on compliance**: If they're in healthcare, finance, or EU markets, lead with PII scrubbing and DSR tooling.
4. **Offer a pilot**: "Let's start with 10k emails, train a proof-of-concept model, measure perplexity improvement."
5. **Partner with their DevOps**: mboxMinerva is GitOps-native—if they love CI/CD, they'll love this.

---

**Questions?** Escalate technical deep-dives to the engineering team. For pricing/licensing, see sales ops.

---

*Document maintained by MuaddibLLM | Last updated 2025-11-10*