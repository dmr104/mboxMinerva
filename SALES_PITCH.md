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

**Business Value**: "Reproducibility = trust. Regulators, auditors, and your data science team all see the same split."

**Technical details**: 
A split is the role tag on each manifest row (train, val, or test) withi "assignments.json" which controls which shard it materializes into, and and how it updates (train can be re-cut anytime; val and test stay pinned and only change on DSR subtracts or a deliberate pin bump).  A pin bump is the deliberate advancing done to the cohort_id cutoff for val and test (e.g. 2025-01 goes to 2025-07), followed by rematerialization of those splits to include the newer cohorts. Materialization is the process of extracting previously split data from the immutable manifest (the file "assignments.json") and writing the results to the files "train.jsonl", "val.jsonl", and "test.jsonl".  When you train with incoming newer data (emails), you can re-materialize exclusively to train.jsonl to absorb new emails in existing cohorts, while val/test stay frozen so that benchmarks don't move, i.e. assuming that we have no DSR requests within this time interval, you can keep re-cutting under the old pin; but val/test move only when you bump the pin.  When a DSR request comes in, we tombstone the data in the immutable manifest file ("assignments.json") and trigger a clean rematerialization (without bumping the pin).  Pin bumps are an explicit operational decision (e.g. a "roll forward" event), not something that happens automatically as part of a deletion request.  The file as "bin/splitter.rb" is the CLI (command line interface) we invoke to materialize or rematerialize splits from the immutable manifest (e.g. `splitter.rb --pin 2025-01 --materialize train`) will trigger a clean rematerialization of "train.jsonl" including all cohorts prior to that particular date, excluding tombstoned rows, but won't touch val/test unless we do `splitter.rb --pin 2025-01 --materialize all` which will rematerialize train/val/test using only cohorts with cohort_id <= 2025-01, and which won't include newer cohorts, and won't change the pre-existing composition of what already got put into val and test (beyond DSR effects).  

Notice that "splitter.rb" has an input argument `-i EMAILS_DIR` but not a specific input file (which is the output file from "mbox_pre-parser.rb").  This is intentional as instead of a single file, "splitter.rb" walks over all the sharded pre-parsed files in that directory (the outputs from "mbox_pre-parser.rb") so that it can deterministically assign whole threads to splits across the full range of data in one pass.  Shards are non-overlapping.  "mbox_pre-parser.rb" walks messages in order and assigns each one to exactly one part-XXXXX.jsonl file, so that together the shards are just a clean partition of the body of emails rather than copied of each other.  Note that for simplicity and downstream tooling, the outputs from "splitter.rb" are materialized as single flat files like "train.jsonl" / "val.jsonl" / "test.jsonl".

The `--window-size` option to "splitter.rb" is an argument which tells "splitter.rb" how big a sliding window of recent messsage and cohorts is to be considered when balancing train/val/test such that "splitter.rb" can keep a specific ratio healthy on *recent* newly arriving email data without touching the older data frozen in the immutable manifest "assignments.json".  'splitter.rb" never breaks threads, and it just limits the balancing logic to the last N units instead of the entire history.

A cohort is just a timestamped batch of rows within the manifest file "assignments.json", e.g. "2025-01" which tags all emails ingested in that perioid so we can freeze, and pin, and talk about the data that existed as of that particular cohort_id as to be considered within each split, for retrains and audits.

The difference between a retrain and rematerialization is that during a retrain we are actually retraining LoRA adapters to fit on top of an existing large language model, while a rematerialization is when the files (train/val/test.jsonl) which the latest model reads, are deterministically rebuilt from our immutable manifest "assignments.json".  Upon rematerialization, the data which is tombstoned in the "assignments.json" simply does not get written into any of the new train/val/test.jsonl. We retrain the model from its base checkpoint by creating a new LoRA adaptor and refitting it: it is like painting a new canvas (retraining), as opposed to merely touching up the old one (remateralization).    

What would happen if I bump the pin, and then receive a DSR deletion request for data which exists within a previous cohort_id?  Does a `--materialize all` option to splitter.rb wipe tis data out within these files?  Answer.  Yes.

So, if I retrain the model using this newer train/val (with those tombstones) in practices the trained model *replaces* the previous adapter which was upon the base model.  You don't layer adapters in order to forget things.  Instead you swap in a freshly trained one that never saw the deleted rows in the first place.  As we retrain when specific key performance indicators are breached, OR upon a fixed cadence, say "max staleness" as a time period between every 6 to 12 months, thus upon a receipt of a DSR deletion request, we retrain upon whichever comes first; and hence we may fulfill legal or contractual obligations to have done so within the service level agreement which may have stipulated a clause such like "the model is always up to date with data such that the data it is trained upon is never older than 6 months prior to the date of the present moment, and hence DSRs are always updated to this model (i.e. deleted from it) periodically every six months, or sooner".

At what stage does the cohort_id get written into the immutable manifest rows?  Answer. At ingest time:  when "bin/mbox_pre-parser.rb" appends new rows, it stamps cohort_id (usually YYYY-MM as 'received_at:' which is from within the email data, or from the latest configured batch cutoff as specified as a command line argument to "mbox_pre-parser.rb" as the --cohort argument).  

For the first full cut from "bin/mbox_pre-parser.rb" we run somthing like `bin/splitter.rb --manifest data/manifest.jsonl --pin 2025-01 --materialize all --out-dir data/splits` to deterministically assign email threads and emit "train.jsonl", "val.jsonl", and "test.jsonl" for training under that initial pin.  The --pin argument is something which is set when the script in invoked, i.e. if all my emails thus far are earlier than 2025-01, then 2025-01 will do it, and we can keep rematerializing "train.jsonl" at the start of each month without bumping the pin, and bump the pin every, say, 6 months, or 12 months, (or sooner if drift or the exclusion-backlog shows that our eval is getting stale) in order to let newer cohorts into val/test and refresh our benchmarks in a controlled step-change rather than a constant creep.

Drift is the gap that opens when the distribution or meaning of data coming in shifts away from what the model was trained/evaluated upon. Think of data drift as something that happens when the data being input changes; and concept drift is when the output of the model changes correctly.  Label drift is when the class mix changes: that is, the proportion of each type of email in our data changes (for instance if on a professional mailing list a lot of emails arrive talking about fluffy dogs), and when that mix changes the mix shifts, the model's expectations drift, so we watch it and rebalance training and thresholds to keep the specific metrics we track to be within acceptable thresholds, and this in turn leads to an improved customer experience in accordance with the service level agreements.  In short, drift is a distribution mismatch between what the model has as data we have already fitted, and thus measure against, and what real traffic (and thus what the manifest) contains

Exclusion-backlog is simply the growing pile of new emails the model has to ignore under the current pin (newer cohorts and quarantined threads).  We measure it as a count and as a percentage of recently receive email data that is out-of-scope for train/va/test, and once that percentage passes a threshold this is our cue to bump the pin or refresh the model.

We bake in email and Slack/webhooks so that when exlustion-backlog or drift indicators cross a configurable threshold the admin gets a message that (a) shows the current stats, (b) states which key performance area this indicator pertains to, and (c) recommends a definite action, such as "time to bump the pin", or "time to schedule a retrain on cohorts less than or equal to a specific PIN, or "tighten contamination thresholds for these cohorts".  To wire it into your repo, edit `config/alerts.yml` with your SMTP/Slack URLs, and schedule via cron (`0 9 * * 1`) or GitLab pipeline schedules, i.e. when exclusion-backlog hits 15% it'll tell you "bump the pin to 2025-04", when contamination crosses 1% it recommends tightening thresholds, and when tombstones pile up past 100 it nudges you toward a retrain.


---

### What are unique thread ids?
**Customer language**: "thread_id is the conversation key that keeps all emails from one thread glued to the same split to avoid train/val/test leakage and enable sliding-window chunking; It is derived in bin/mbox_pre-parser.rb; then bin/splitter.rb groups on thread_id to assign one deterministic split and annotate window_idx and window_range for that thread."

**Business value**: "Each thread_id gets ONE frozen split, and all its windows inherit that split, so overlap duplicates data
within train (or val, or test) for better context coverage, but never leaks the same thread's context across
splits.  It is split-pure by design.  A thread's "context" = the entire conversation for a thread; so chunks from that thread never cross thread/val/test. 

**Technical details**:
"bin/splitter.rb" groups by thread_id, and always hashes with a deterministic seed to assign train/val/test (80/10/10) to the immutable manifest, writing immutably to assignments.json.  To say this again, splitter.rb assigns per-thread splits using a deterministic hash (seeded) to hit a fixed ratio so that the inputs always map to the same split in the immutable manifest unless you change the seed or configured ratio (which you should not do midstream because this would invalidate previous assignments; and IF YOU DO this then you ***MUST*** recreate the whole manifest and then materialize it!). In "bin/splitter.rb" when --window-size is enabled, ALL windows of a thread inherit the SAME deterministic split, and when omitted, "splitter.rb" assigns the entire thread as a single manifest entry.  So in either case, there is not any context leakage across train/val/test."


### Why Deterministic Hash-Bucketing?
**Customer Language**: "We use a mathematical fingerprint of each email thread to decide whether it goes into training, validation, or test; so the split is automatic, fair, and stable. Add new emails tomorrow? They slot into the right bucket without reshuffling everything."

**Business Value**: No manual sorting, no human bias, always explainable to auditors.

---

### Why Thread-Level Splits (Not Message-Level)?
**Customer Language**: "Email conversations are like chapters in a book.  Splitting mid-thread would leak answers into the test set. We keep entire threads together so the AI learns naturally and evaluations are honest."

**Business Value**: Better model accuracy, no inflated test scores, defensible ML hygiene.

---

### Why do we protect against contamination between data sets?
**Customer language**: "Whether by accident or by design, if an employee of your company, or anybody who has sent emails to your mailing list, duplicates a quantity of text from one thread to another thread, then this might leak answers into the test set.  To guard against accidental contaminination, we guard against lines which begin as "On ... (a certain date, somebody) wrote", and to guard more stringently against possible data contamination we run cross-split near-duplication detection using mathematical techniques (e.g. local-sensitivity hashing accelerated >70% Jaccard overlap or >0.9 cosine with strict verification) where similar items collide with a high probability, letting us bucket and find near-duplicates fast before quarantining them."

**Business Value**:"It buys trustworthy evals and repeatable wins (not leakage fueled mirages), fewer regressions and the necessity for long-term support because of a broken model. It provides provable compliance and audit trails, and allows us to view the performance of our model more accurately, and it lowers the total cost of ownership by avoiding bad retrains.  It avoids service level agreement breaches if and when drift or sabotage hit."

---

### Why PII (personally identifiable information) Scrubbing *Before* Training?the
**Customer Language**: "We replace real names, email addresses, and IPs with pseudonyms before the data ever touches the model. If someone requests deletion (GDPR 'right to be forgotten'), we tombstone their pseudonym and retrain.  This is clean, auditable, with no residual PII."

**Business Value**: GDPR/CCPA compliance by design, reduced breach risk, exportable DSR workflows.

---

### Why timely retraining on a DSR (Data Subject Request)?
**Customer language**: "When a DSR comes in, the first thing we do is mark the user as tombstoned within the immutable manifest. Then we AFTER WE HAVE RECEIVED so many of these DSL deletion requests, OR after a limited period of time, say between 24 to 72 hours after the first DSL deletion request, we regenerate the dataset (train.jsonl); and then, within a reasonable time period.

while not retraining immediately upon every DSR request, we may receive several DSR deletion requests within a time period of a fixed cadence, say, 72 hours: of which we tombstone each of those immediately, and via rematerialization of the RAG shards we stop serving their content and purge any caches, so the data subject will be removed sooner." 

**Business value**: "Immediate tombstoning/rematerializing gives you a proof of hard compliance with risk reduction in the sense that you stop serving personal data now, meeting GDPR/CCPA SLAs (service level agreements), cutting fines and liability, preserving trust and contract renewals, which makes enterprise deals with clean audit logs attractive to the customer base, and will avoid costly hotfixes by decoupling what data is being served from slower retraining of models."

---

### What is this "train.jsonl" thing?
**Customer language**: "When I rematerialize the dataset from the immutable manifest, normally only "train.jsonl" gets materialized, and "val.jsonl" and "test.jsonl" remain fixed, except for (a) DSRs, when you re-materialize them to subtract tombstoned rows only, and (b) your planned rollover, when you bring in the newer cohort rows from the immutable manifest to your train/val/test.jsonl, and you bump the pin, and retrain the LoRA adapter, and then you flip the symlink which points from the present adapter to this latest one. Normal weekly rematerializations (e.g. `splitter.rb --pin 2025-01 --materialize train`) leave val.jsonl and test.jsonl untouched."   

**Business value**:"Understanding this at a customer level proves GDPR/DSR (General Data Protection Regulations / Data Subject Request) compliance and reproducibility, setting customer expectations, and turns a scary "black box" in an auditable service level agreement."

**Technical details**
 A cohort_id (e.g. 2025-01) is the stable tag for a cohort, and a cohort is simple a group of emails that arrived during this bucketed time-interval, say, 1 month. Because the file "bin/splitter.rb" is normally run weekly with `--materialize train` and a fixed cohort pin, it filters the from append-only manifest and writes exclusively to a newly versioned train.jsonl monolithic file. A fixed cohort pin is the explicit cutoff tag (e.g. cohort_id=2025-01) that val.jsonl and test.jsonl are locked to, so that if I do a planned rollover yearly, and have no DSRs within this time, my explicit cutoff will change only once per year at the planned bump. This doesn't prevent us doing an ad-hoc bump if drift gets too bad.  To recap, drift is a distribution mismatch between what the model has as data we have already fitted, and thus measure against, and what real traffic (and thus what the manifest) contains.

---

### What is a planned rollover?
**Customer Language**: "We keep a “golden benchmark” of emails frozen so your results are apples-to-apples across months, and we isolate new test-candidate emails for quiet, real‑world shadow checks; and once a year we roll them in to update the benchmark"

**Business Value**: "A clearer compliance story, with faster stakeholder sign‑off, and less rework because we only change the yardstick on a planned cadence, say every 12 months. We have a trustworthy before/after ROI (return on investment) proof with no leakage from train.jsonl, or surprise regressions in production: such as when we add newer emails in test.jsonl and update the benchmark to make these newer emails, headline metrics can dip, and this *would* be our early-warning system, but we have already fixed data hygiene in-house and intend to keep customer outcomes trending up, not down."

---

### Why *we* don't chop train.jsonl into shards ourselves.
**Customer Language**: "We only ever manage one clean train.jsonl and the Machine Learning stack worries about sharding, which means that with one file per split, experimenting and data processing are very simple, so the team can plug it into any training recipe or cloud vendor without having to wrestle with custom formats or brittle shard conventions."

**Business Value**: "The risk of operations and the total cost of ownership drops: with fewer moving parts within our pipeline, there are fewer places where bugs or issues with formatting compliance can hide, giving us the flexibility to change our training infracstructure (different GPU vendors, or hosted services elsewhere) without having to rewrite the data layer every time."

**Technical details**: 
In our code base there is no ruby file that chops train.jsonl into shards -- "splitter.rb" merely produces one flat train.jsonl file, and the actual "sharding" happens later inside the training stack's data loader (e.g. the finetune script, / vLLM or PyTorch+DeepSpeed job that reads train.jsonl and automatically splits it across workers).

---

### Why does a planned rollover involving flipping a symlink?
**Customer Language**: "A planned rollover is exactly the process of training, and then the process of validating this new adapter which has been generated from this training.  Then we flip the symlink pointing from the present adapter to this latest one in a controlled step, typically wrapped in a deploy script so we can flip, test, and roll-back if something doesn't look right.

**Business Value**: "Give us atomic, low-risk cutovers and instant rollbacks, which directly translates to fewer outages, cheaper operations, and a much easier way to keep our model uptime and fulfill our SLA reliability promises to customers."

**Technical details**:
The symlink may point to the actual model checkpoint (LoRA adapter) directory, which may reside, for example, at `current/.../releases/2025-01-15-clean` so that flipping the symlink would atomically switch from serving the old adapter to the newly trained DSR-clean one without changing any runtime configurations.

---

### How do we validate that the newer LoRA adapter does a better job than the last one?
**Customer Language**: "Before we switch the models to the lastest, we quietly test the new one on the *same* held-out emails and only ship it if it clearly answers better and stays inside our guardrails. "Guardrails" are the rules that keep the model from doing the wrong thing, i.e. the policies and safety rails that stop the model from leaking private data, going off-topic, giving illegal or unsafe advice, or failing to comply with its intended tone of speaking.  Our aim is that every model remains helpful, on-policy, and non-scary for the users and the legal team."

**Business Value**: "Fewer bad surprises after deployment, a higher quality of learning from the inbox than would be otherwise leading to a greater usefulness of the overall system by the disapplication of a less-efficient model, with hard evidence what you can show in quarterly business reviews to demonstrate that each rollout is an upgrade, and not a gamble."

**Technical details**:
We validate by running both adapters on the same frozen test set, checking that the new one "wins" on our key performance indicators (accuracy, helpfulness, safety, inbox quality), and doesn't regress on guardrails.  

---

### Why git-crypt for the Vault?
**Customer Language**: "The mapping between real identities and pseudonyms lives in an encrypted vault checked into your Git repository. Only authorized team members and CI/CD runners with the right key can decrypt it.  So it's versioned, backed up, and access-controlled."

**Business Value**: No separate secret management system, auditable access logs, works on any Git hosting (GitHub, GitLab, self-hosted).

**Technical details**
In practice, the vault key lives in a KMS (hardware-backed key management service) or HSM (hardware security module), rather than in code or in configuration files.  A KMS is something like Amazon Web Service KMS, or Google Cloud Platform KMS; and a HSM is a tamper-resistent hardware box that protects those keys so they can be used (e.g. to decrypt the vault without anyone ever seeing or exporting the raw secret).  For self-hosted runners the *real* vault key lives in an external secret store, and GitLab injects only a short-lived masked secret into the runner at job runtime such that the key is never within the repo, and won't be baked into Docker images, and is scoped to specific projects and environments, so that it only exists within RAM on that runner whilst the particular CI job is decrypting the vault.

HashiCorps Vault is a self-hosted secrets manager that acts as a locked safe for passwords, API keys, and encyption keys, giving you a central place to store them encrypted, and to fetch short-lived credentials at runtime instead of hardcoding them in configs or in GitLab.

On-premises KMS/HSM means that instead of storing your encryption keys in a public cloud, they stay logically and physically under your control via your organisation running its own key-management system and hardware security modules within *your* own data centre which will be managed still by a central locked-down service.

A hardened OS/Kubernetes secrets backend is basically "Vault-lite" in the sense that you store secrets in the Kubernetes store which runs atop of the underlying operating system which is running on your servers (typically a hardened Linux distro like Ubuntu, Debian, or RHEL).  You make sure that the secrets which are stored in the Kubernetes store are encrypted at rest, and you lock the read-access to a tiny set of service accounts, injecting them into jobs only at runtime via the environment variables (temporary key=value settings which are visible only to that running process) or ephemeral volumes  (temporary filesystem mounts that exist only while the container/pod is alive). Every user/service gets the *minimum* permissions they need and nothing more, so only a few well-defined identities are ever allowed to read or use the encyption key.  You lock down each server which is within your cluster by disabling unused services. You lock down ports (by using a firewall on each host), and you enforce strong authentification like SSH keys, or 2-factor authentification, or SSO (Single Sign-On) with identity providers, such that an attacker will need more than one stolen credential to break in.  With SSO, you log in once with a central identity provider (which is an infrastructure--which is an identity provider service like Okta, Azure AD, or Google Workspace) that checks your login (password, multi-factor authentification, etc) and validates your account, and then issues short-lived tokens trusted tokens that the other apps accept as proof of who you are.

In any case, whichever key management system you choose to use, the idea is that the vault key will never live within images, repos, or on long-lived disks and thus would be very hard to exfiltrate even if a node becomes compromised. 

---

### Why GitLab CI/CD?
**Customer Language**: "Every code change triggers automated tests: which involve data integrity checks, security scans, and split validation. When you push to Git, the pipeline does the training, evaluating, and deployment.  There are no manual steps; and thus the experience that simply because 'it worked on my laptop' is not used as a litmus test for other systems and hardware setups."

**Business Value**: "Faster iteration, fewer bugs in production, one-click rollback."

---

### Why vLLM for Serving?
**Customer Language**: "vLLM is like a hyper-efficient switchboard for your GPU.  It serves dozens of simultaneous queries without wasting computation. You buy one GPU, and serve your whole team upon it."

**Business Value**: "Lower hardware cost per query, with faster response times, and scaling with concurrency."

---

### Why RAG (Retrieval-Augmented Generation)?
**Customer Language**: "The fine-tuned model understands your email style and domain jargon. RAG adds live search: when a user asks a question, the system pulls relevant threads from the archive and hands them to the model as context.  So answers cite actual emails, not hallucinations."

**Business Value**: "Grounded responses, source traceability, regulatory defensibility."

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
> "Your best salespeople, engineers, and execs have years of email wisdom, customer objections, product decisions, competitive intel. mboxMinerva turns that into a fine-tuned model so new hires can ask 'How did we handle X in 2018?' and get answers grounded in actual threads."

**When to Use**: Leadership, knowledge management buyers, organizations with high turnover or tribal knowledge risk.

---

### Talk Track: "Self-Hosted or Cloud"
> "Start on a laptop with 16 GB GPU for proof-of-concept. Scale to a 128 GB RAM server for production. Or offload heavy training to Vertex AI GPUs. Same pipeline, same Git repo—no vendor lock-in."

**When to Use**: IT/DevOps buyers, budget-conscious prospects, hybrid cloud strategies.

---

### Objection: "We don't have ML expertise."
**Response**:  
"You don't need a data science PhD because mboxMinerva ships with sensible defaults. Your DevOps team runs `git pull`, sets up GitLab CI, and the pipeline handles splits, training, and evals automatically."

---

### Objection: "Our email has too much sensitive data."
**Response**:  
"That's exactly why we built PII scrubbing into step one. The model trains on pseudonymized text: no real names, emails, or IPs. You control the vault encryption key, and DSR tooling lets you delete or export any individual's data on demand."

---

### Objection: "Training LLMs is expensive."
**Response**:  
"We use QLoRA: a memory-efficient method that fine-tunes 7B–13B models on a single consumer GPU (16–24 GB VRAM). A $2,000 GPU trains overnight. For bigger models or faster iteration, rent cloud GPUs only when you need them. Most customers start with a $3,000 workstation."

---

### Objection: "What if we already have a RAG system?"
**Response**:  
"Great. Fine-tuning *complements* RAG. RAG pulls relevant chunks; fine-tuning teaches the model your domain language and style so it generates better responses. mboxMinerva outputs a model you drop into your existing RAG pipeline."

---

### Objection: "How do we know the model actually improved?"
**Response**:  
"We include a before/after eval harness: measure perplexity on a held-out test set before fine-tuning, train, measure again. A lower perplexitymeans that the model learnt your email patterns. You get quantitative proof, not just vibes."

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
2. **Show**: `bin/pii_scrubber --input emails/ --output scrubbed/ --vault vault/`  
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
| Enterprise knowledge graphs | "Structured knowledge > unstructured email" | Email is where decisions actually happen. Graphs need manual curation, we're automated |
| Build-it-yourself | "OSS is free" | True, but we ship tested pipelines, privacy tooling, and GitLab CI. Your team focuses on business logic, not ML plumbing |

---

## 10. Closing Tips

1. **Lead with pain**: "Where is your institutional knowledge locked up?" → email, Slack, wikis → "We solve email first, it's the richest data."
2. **Demo early**: Schedule a technical demo. Seeing is believing.
3. **Anchor on compliance**: If they're in healthcare, finance, or EU markets, lead with PII scrubbing and DSR tooling.
4. **Offer a pilot**: "Let's start with 10k emails, train a proof-of-concept model, measure perplexity improvement."
5. **Partner with their DevOps**: mboxMinerva is GitOps-native. If they love CI/CD, they'll love this.

---

**Questions?** Escalate technical deep-dives to the engineering team. For pricing/licensing, see sales ops.

---