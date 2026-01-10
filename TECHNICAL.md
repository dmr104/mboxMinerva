## What is a cohort?
A cohort is just a timestamped batch of rows within the manifest file "assignments.json", e.g. "2025-01" which tags all emails ingested in that period so we can freeze, and pin, and talk about the data that existed as of that particular cohort_id as to be considered within each split, for retrains and audits.

A cohort_id (e.g. 2025-01) is the stable tag for a cohort, and a cohort is simply a group of emails that arrived during this bucketed time-interval, say, 1 month. Because the file "bin/splitter.rb" is normally run weekly with `--materialize train` and a fixed cohort pin, it filters only the messages with the manifest key as cohort_id from the append-only manifest which is less than or equal to the `--pin` value passed to "bin/splitter.rb", and it writes these exclusively to a newly versioned "train.jsonl" monolithic file.  The pin is a ceiling, not a floor.

A fixed cohort pin is the explicit cutoff tag (e.g. cohort_id=2025-01) that "val.jsonl" and "test.jsonl" are locked to, so that if I do a planned rollover yearly, and have no DSRs within this time, my explicit cutoff will change only once per year at the planned bump. This doesn't prevent us doing an ad-hoc bump if drift gets too bad.  Drift is a distribution mismatch between what the model has as data we have already fitted, and what present traffic contains.

At what stage does the cohort_id get written into the immutable manifest rows?  Answer. At ingest time.  When "bin/mbox_pre-parser.rb" appends new rows, it stamps into them the cohort_id, which is usually of the format as YYYY-MM which is as the value for the key as "received_at:", and this cohort_id is derived from data which is within the email headers, or from the latest configured batch cutoff as specified as the command line argument `--cohort` to "mbox_pre-parser.rb".  

## What is a split?
A split is the role tag on each manifest row (train, val, or test) within "assignments.json" which controls which "split file" it materializes into (train.jsonl, val.jsonl, or test.jsonl), and how it updates (train can be re-cut anytime; val and test stay pinned and only change on DSR subtracts or a deliberate pin bump).  

## What is a pin bump?
A pin bump is the deliberate advancing done to the cohort_id cutoff for val and test (e.g. 2025-01 goes to 2025-07), followed by rematerialization of those splits to include the newer cohorts. 

## What is a rollover?
A planned rollover involves the flipping of a symlink.  This symlink may point to the actual model checkpoint (LoRA adapter) directory, which may reside, for example, at `current/releases/2025-01-15-clean` so that flipping the symlink would atomically switch from serving the old adapter to the newly trained DSR-clean one without changing any runtime configurations.


## What is a materialization?
Materialization is the process of extracting previously split data from the immutable manifest (the file "assignments.json") and writing the results to either or all of the files "train.jsonl", "val.jsonl", and "test.jsonl". 

## What is a retrain?
The difference between a retrain and materialization is that during a retrain we are actually retraining LoRA adapters to fit on top of an existing large language model, while a materialization is when the files (train/val/test.jsonl) which the latest model reads, are deterministically rebuilt from our immutable manifest "assignments.json".  
 
Upon materialization, the data which is tombstoned in the "assignments.json" simply does not get written into any of the new train/val/test.jsonl. We retrain the model from its base checkpoint by creating a new LoRA adaptor and refitting it: it is like painting a new canvas (retraining), as opposed to merely touching up the old one (rematerialization). 

What would happen if I bump the pin, and then receive a DSR deletion request for data which exists within a previous cohort_id?  Does a `--materialize all` option to splitter.rb wipe its data out within these files (train/val/test.jsonl)?  Answer: Yes.

So, if I retrain the model using this newer train/val (with those tombstones), in practice the trained model *replaces* the previous adapter which was upon the base model.  You don't layer adapters in order to forget things.  Instead you swap in a freshly trained one that never saw the deleted rows in the first place.  Because we retrain when specific key performance indicators are breached, OR upon a fixed cadence (say "max staleness" as a time period between every 6 to 12 months), thus upon a receipt of a DSR deletion request, we retrain upon whichever comes first: the breach of specific performance indicators, or this fixed cadence; and hence we may fulfill legal or contractual obligations to have done so within the service level agreement which may have stipulated a clause such like "the model is always up to date with data such that the data it is trained upon is never older than 6 months prior to the date of the present moment, and hence DSRs are always updated to this model (i.e. deleted from it) periodically every six months, or sooner".

When you train with incoming newer data (emails), you can materialize exclusively to "train.jsonl" to absorb new emails from existing cohorts, while val/test stay frozen so that benchmarks don't move, i.e. assuming that we have no DSR requests within this time interval, you can keep re-cutting under the old pin; but val/test move only when you bump the pin.  

## what is spot-checking?
What is the point of a `--materialize train` without a retraining of the LoRA adapters to fit atop the large language model?  Answer. You regenerate "train.jsonl" after DSR exclusions have arrived (without touching the cohort pin) so that you can take a sample of your emails from train.jsonl and spot-check data quality.  Spot checking means opening a sample of these files to check that these emails are not just scrambled gibberish or full of technical junk that would confuse the LLM during the training of the LoRA adapters which will be applied to and sit atop of it. In more technical language, spot checking is the process of verifying schema conformance, the encoding integrity, and the examination of tokenisation edge cases. 

## What is an epoch?
An epoch is one full pass through train.jsonl.  Mid-epoch means pausing partway to evaluate against val.jsonl to check loss curves. 

## Can anything newer be evaulated without bumping the cohort pin?
No. Nothing newer can be evaluated without bumping the cohort pin. When you *do* bump the pin, you rematerialize **all three** (train/val/test) together to the same pin boundary so that distributions stay aligned.  Leaving test.jsonl at an older pin while training upon newer data would invalidate your final benchmark.

## What if loss spikes (perplexity diverges) mid-epoch?
Then Houston we have a problem.  So we do spot-checking to examining whether the issue is upstream data corruption (malformed headers, encoding rot) or hyperparameter misconfiguration or genuine distribution drift from production traffic.

## What about Data Subject Requests (DSRs)?
When a DSR request comes in, we may tombstone the data in the immutable manifest file ("assignments.json") and later trigger a clean rematerialization (without bumping the pin).  Pin bumps are an explicit operational decision (e.g. a "roll forward" event), not something that happens automatically as part of a deletion request.  

The file as "bin/splitter.rb" is the CLI (command line interface) we should invoke to rematerialize all three splits from the immutable manifest, e.g. `splitter.rb --pin 2025-01 --materialize all`, which will trigger a clean rematerialization of "train.jsonl" and "val.jsonl" and "test.jsonl", including all cohorts prior to that particular date, excluding tombstoned rows, and thus will rematerialize train/val/test using only cohorts with cohort_id <= 2025-01, and which won't include newer cohorts than this date, and won't change the pre-existing composition of what already got put into train, val, and test--beyond DSR effects--but may update train, val, and test, up to and including emails received at 2025-01-31 23:59 if the pin has indeed been bumped.

## How does my split data grow?
If I do a `splitter.rb --pin 2025-01 --materialize all` and a year later I do a `splitter.rb --pin 2026-01 --materialize all`, then, for example, the possibility exists that a thread from 2025-04 may enter test.jsonl or val.jsonl, as we are specifically expanding the "Time Horizon" to include everything up to that new date, whereby the April 2025 thread transitions from being an "ignored future data" (in the 2025 context) to being "eligible historical data" (in the 2026 context), and will enter the lottery as to where it lands based upon its hash and your split ratio.

## What is the `--materialize train` to "bin/splitter.rb" ever used for in practice?  Is it ever useful?
Yes. When late-arriving emails arrive within your current pin's cohort ceiling this option refreshes only the training pool.  val/test don't need to be regenerated because we want the email threads within train.jsonl to receive the latest email updates to them.  This will occur.  What will also occur is that potentially later conversations with newer email thread ids will go into the manifest in our train/val/test split (80/10/10), and only those newer conversations which ended up in the set as train will get included within the "train.jsonl" file when it becomes rematerialized.  Why is this useful?  Well, generalization is the ability to say that the model has not merely memorized and regurgitated verbatim the patterns (grammar, intent structure, reasoning) from "train.jsonl".  More training data means that the model has a better ability to make these generalizations. Later arrivals within an existing cohort being added to "train.jsonl" gives us the option to retrain the LoRA adapters on the same cohort pin with their inclusion to improve the model's quality within that existing time boundary, whereas a pin bump is a bigger structural event only needed when you want to to shift the model's knowledge horizon into a new time period. 

Won't running `splitter --materialize train` to include recently arrived emails for training the LoRA adapters technically break reproducibility?  Answer. No.  Question. If the pin bump is 2025-01-01 and we rematerialize train on 2025-02-01 and retrain the LoRA adapter, but only bump on 2025-06-01, then will the LoRA adapter trained in February be reproducible after the bump in June?  Answer.  Yes.  It is still possible *if* you keep a record of the pin used at training time, as then you can regenerate the exact train.jsonl by calling `--materialize train --pin 2025-01`.  Rows never vanish except via DSR tombstones.  The audit trail for February was "trained with --pin 2025-01 on manifest state as of 2025-02-01",pointing to a non-current pin value.

Won't DSR tombstones break reproducibility?  Answer. Yes, deliberately. That is the legal tradeoff.  You *cannot* and *must not* reproduce data a person exercised their GDPR right to erase, but you still preserve *attestation*: being a cryptographic hash of train.jsonl at training time, row counts, tombstone log showing what was removed and when.  So your audit trail becomes "this LoRA was trained on N row with SHA256=abc123 before DSR removed M rows on date X" rather than byte-for-byte regeneration.

TO DO.  Implement this logging facility. tombstones in email_crypt/dsr_tombstones.jsonl with timestamp + reason, audit logs to logs/audit.jsonl.  check whether bin/dsr_delete actually writes these tombstone records with cryptographic hashes of the pre-deletion state, and whether training scripts log manifest SHA256 + row counts at training time.

## How does splitter.rb start out?
For the first full cut from "bin/mbox_pre-parser.rb" we run something like `bin/splitter.rb --manifest data/manifest.jsonl --pin 2025-01 --materialize all --out-dir data/splits` to deterministically assign email threads and emit "train.jsonl", "val.jsonl", and "test.jsonl" for training under that initial pin.  The --pin argument is something which is set when the script in invoked, i.e. if all my emails thus far are earlier than 2025-01, then 2025-01 will do it, and we can keep rematerializing "train.jsonl" at the start of each month without bumping the pin, and bump the pin every, say, 6 months, or 12 months, (or sooner if **drift** or the **exclusion-backlog** shows that our eval is getting stale) in order to let newer cohorts into val/test and refresh our benchmarks in a controlled step-change rather than a constant creep.

## Is there any point to a `splitter --materialize train` without a subsequent retrain of the model?
Yes. This may be done for staging and inspection.  You materialize to audit row counts (within "train.jsonl") post-ingest, spot-check data quality (encoding errors, PII leaks, schema conformance).  This process will validate that late-arriving emails landed correctly. This train.jsonl is now a stage which is before that of training the model (the LoRA adapters).  This training of the model may now be scheduled for an overnight retrain without burning GPU hours the moment when the emails arrive.  Monitoring the growth of the row count from "train.jsonl" allows us to quantify exactly how much new information (emails) have arrived and accumulated before we decide it is time to incur the expense and electricity cost of a fresh training run done to the model.

## What is drift?
Drift is the gap that opens when the distribution or meaning of data coming in shifts away from what the model was trained/evaluated upon. Think of "data drift" as something that happens when the data being input changes. For instance, if on a professional mailing list for dental surgeons, a lot of emails arrive talking about fluffy dogs, then this is "data shift" because the vocabulary has shifted.

"Concept drift" is when the underlying relationships between inputs being fed into the model and outputs from the model changes over time, i.e. if the input concept such as "this is a complaint" changes to something like "this is feedback" then the "concept drift" happens where the model is still thinking that it is the former when it should be the latter.  To further elaborate upon this, if customers yesterday complained by saying "this is broken" but today complain by sarcastically saying "this is great! great job team" then the concept within the identification of "complaint" would have changed.

In short, drift is a distribution mismatch between what the model has as data we have already fitted, and thus measure against, and what real traffic (and thus what the manifest) contains.

## What would "label drift" prior to training be?
"Label drift" is when the class mix of emails changes: that is, the proportion of each type of email in our data changes. For instance, if on a professional mailing list for dental surgeons, a lot of emails arrive talking about fluffy dogs then a HUMAN may label this email as "superfluous" BEFORE training at the labelling stage in order to audit the annotation pipeline carefully. "Label drift" happens when this mix of labels changes, i.e. when the label as "superflous" suddenly jumps from 2% to 40% regardless than what specific words are driving it. 

Can I automate the decision of labelling from a human in response to the content of the reply to these messages about fluffy dogs on the dental surgeons' mailing list? For example, if the reply was "please keep subject matters relevant to the topic of this list" then is there any way to automate the process of labelling these messages as "superflous" based upon the content of the mailing list?  Answer.  Yes. That is called "weak supervision" or "distant supervision".  You would write heuristics that pattern-match reply content to automatically generate labels like "superfluous".  Tools like Snorkel formalize this by combining multiple noisy labeling functions into probabilisitic label, trading annotation precision for massive scaling without hiring an army of human taggers, whereby you write "Labeling Functions" (mini-scripts like regexes, heuristics, or small models which either propose a label of abstains from doing so) that cast "votes" in order to make these decisions. A Label Model mathematically learns which Labelling Functions are reliable and which are noisy, and then merges their votes into a single high-quality probabilistic label for every row.

The reason why, for our particular codebase in mboxMinerva, as a coding decision, it is NOT a good idea to make labels on the data prior to training LoRA adapters for the LLM is because *if* the labels are computed dynamically at materialization time then reproducibility would break because the labels may change several times within one cohort even.  So it would not be feasible to stamp a record of these labels into the manifest.  So we will, instead, defer labeling to RAG inference time, keeping the manifest purely structural, and letting classification logic (the code/prompts/rules) live in a separate independently versioned layer within the mboxMinerva git repo that lets us debug, test, and rollback to known good versions if a new heuristic misfires.

## What is exclusion-backlog?
Exclusion-backlog is simply the growing pile of new emails the model has to ignore under the current pin (newer cohorts and quarantined threads).  We measure it as a count and as a percentage of recently receive email data that is out-of-scope for train/val/test, and once that count or percentage passes a threshold this is our cue to either refresh the model or bump the pin depending upon your organisation's operational decision-making.

## What about automatic notifications and included advice?
We bake in email and Slack/webhooks so that when exclusion-backlog or drift indicators cross a configurable threshold the admin gets a message that

- (a) shows the current stats, 
- (b) states which key performance area this indicator pertains to, and 
- (c) recommends a definite action, such as "time to bump the pin", or "time to schedule a retrain on cohorts less than or equal to a specific PIN, or "tighten contamination thresholds for these cohorts".  

To wire it into your repo, edit `config/alerts.yml` with your SMTP/Slack URLs, and schedule via cron (`0 9 * * 1`) or GitLab pipeline schedules, e.g. when exclusion-backlog hits 15% it'll tell you "bump the pin to 2025-04", or when contamination crosses 1% it recommends tightening thresholds, and when tombstones pile up past 100 it nudges you toward a retrain.

## Why does mbox_pre-parser.rb output shard files?
Notice that "splitter.rb" has an input argument `-i DIR` but not a specific input file (which is the output file from "mbox_pre-parser.rb").  This is intentional, as instead of a single file, "splitter.rb" walks over all the sharded pre-parsed files in that directory (the outputs from "mbox_pre-parser.rb") so that it can deterministically assign whole threads to splits across the full range of data in one pass.  Shards are non-overlapping.  "mbox_pre-parser.rb" walks messages in order and assigns each one to exactly one part-XXXXX.jsonl file, so that together the shards are just a clean partition of the body of emails rather than containing overlapping copies of each other.  Note that for simplicity and downstream tooling, the outputs from "splitter.rb" are materialized as single flat files like "train.jsonl" / "val.jsonl" / "test.jsonl".

"bin/mbox_pre-parser.rb" defaults to writing JSONL files (e.g. "emails/part-00001.jsonl") unless you override it with the `--output` flag which then collapses everything into a pretty-printed JSON array.  Instead, if it had been designed differently, if may have had only one output file per execution, and if it was executed upon one MBOX, it might produce only one JSONL file.  This is not, however, the case.

Raw mboxes are often one huge file per list or month.  The pre-parser converts the physical MBOX into logical JSONL Rows.   A **Logical Row** is the *atom* (one single email or thread entry), while a **Shard** is the *bucket* (the actual .jsonl file holding thousands of those atoms).  The pre-parser outputs shards so that the downstream tools can process data in parallel chunks instead of choking upon one massive 50GB file.

In our code base there is no ruby file that chops train.jsonl into shards -- "splitter.rb" merely produces one flat "train.jsonl" file, and the actual "sharding" happens later inside the training stack's data loader (e.g. the finetune script, / vLLM or PyTorch+DeepSpeed job that reads "train.jsonl" and automatically splits it across workers).

## When are my unique thread ids created?  
These are created by "bin/mbox_pre-parser.rb"; then, later, "bin/splitter.rb" assigns one deterministic split from these thread ids and annotates the window_idx and the window_range for that thread.

## What is meant by "windows of a thread"?
When a thread has 50 messages but you set `--window-size 20 --window-overlap 5`, splitter chunks these messages into overlapping sliding windows (e.g. messages 0-19, then 15-34, the 30-49) such that each training example stays within a manageable context length.  The critical design is that ALL of these windows inherit the **same** split from their parent thread_id in order to prevent data leakage, i.e. if window 0 lands in test then window 1 cannot sneak into train because this would contaminate evaluation.  The context of the conversation ***must not*** be shared!

## What is a sliding window?
In "bin/splitter.rb" when --window-size is enabled, ***all*** windows of a thread inherit the ***same*** deterministic split into either train, val, or test, and when omitted, "bin/splitter.rb" assigns the **entire thread** as a single manifest entry.  In this latter case, this infers that the **entire thread** (i.e. the entire conversation) lands deterministically and atomically with a probability of ~80% in train, ~10% in val, and ~10% in test.  

The `--window-size N` option is specifically about chunking long threads into overlapping segments for training whereby each chunk gets a manifest entry keyed by `manifest[window_id]` where `window_id = "#{thread_id}_window_#{window_idx}"` such that 
```ruby
    window_idx = 0
    pos = 0
    
    while pos < sorted_messages.size
      window_end = [pos + window_size, sorted_messages.size].min
      window_id = "#{thread_id}_window_#{window_idx}"
      
      unless manifest[window_id]
        manifest[window_id] = {
          'split' => split,  # All windows of a thread share the same split
          'thread_id' => thread_id,
          'window_idx' => window_idx,
          'window_range' => [pos, window_end]
        }
      end
      
      window_idx += 1
      pos += stride
      break if pos >= sorted_messages.size
    end
```
where the `'window_range' => [pos, window_end]` value pair records exactly which slice of messages went into that window.  But only windowed threads get this notation.  Bare threads do not get this range metadata.

## What is the window_idx for a thread?
It is the zero-based index of a sliding window chunk which occurs when `--window-size` splits a long thread into overlapping segments.

## What is the window_range for a thread?
It is the `[start_pos, end_pos]` tuple which is stored within each manifest row showing exactly which message indices from the original thread are included within that window chunk. e.g. `window_range: [0,19]` means messages 0-19, and `window_range: [15, 34]` will be the next overlapping chunk if overlap=5.

## Explain `--window-overlap` option to "splitter.rb"
This is the number of messages shared between consecutive windows.  It ensures that each window has leading context from the previous one, preventing "cold start" at window boundaries where the model would otherwise see a conversation mid-stream with no preceding step. This is important and relevant for the training of the model because without overlap, each window starts "cold" mid-conversation and the model learns to predict responses without seeking what prompted them.  It would be trained upon fragments stripped of causal content.  The overlap gives each window a "warm-up runway" of prior messages so that LoRA learns the actual patterns you care about (i.e. how *this* reply follows *that* context), instead of just learning how to create plausible-sounding text in a vacuum.

## What would a "Rolling Retention Policy" be?
A **Rolling Retention Policy** would tell the splitter to filter by data freshness and ignore data older than `N` days/months relative to the Pin, ensuring that your model trains only on relevant, recent patterns and isn't polluted by ancient, drifted history: drifted because the "ground truth" changes as the world evolves; vocabulary shifts (new slang evolves, old terms become deprecated), spammers use newer tactics to evade filters, and crucially, the structure of business data within an organisational structure might change, (i.e. a "purchase order" from 2018 might look completely different than one from 2025), meaning that patterns from very old data might mislead the model about today's reality.  

## Why we *don't* use a "Rolling Retention Policy"?
Because:
- 1. It would break the guarantee of append-only immutability.  Although no rows would subsequently disappear from out immutable manifest, we are saying that these rows would subsequently become barred from being read after they had timed out when a `--materialize` option to "bin/splitter.rb" became invoked.
- 2. It would prevent the reproducibility of past training runs if the source data would age out.
- 3. It would destabilize the val/test sets unless you exempt these rows from being retained, and this would add complexity.
- 4. Sometimes the stale data would be perfect for making generalisations from.  Older does not always necessarily mean that it should be treated as obsolete.

## What is "Lookback Horizon" for data curation?
It is how many months/cohorts of historical data you include in your training corpus. It our project we include all of it in order not to break reproducibility (except for DSR requests).  It shapes *what* the model learns.

## What is "Lookback Horizon" for the training of the model?
A "Lookback Horizon" in this context is a model or inference-time configuration set in your training or vLLM.  It is ***not*** within the data pipeline.  It is a concept pertaining to model inference specifically dealing with how far back the model's attention span reaches.  It is how much preceding context you feed the model when training it to predict the next token/response.  

## What is "Lookback Horizon" for the vLLM?
At inference time, lookback horizon is how much of the conversation history (system prompt + user messages + assistant replies so far) the vLLM keeps the the key-value cache when generating the next token: which is bounded by the "context window length" (e.g. 8k tokens).

## What is "context window length"?
This is how many tokens the model can see in a single forward pass (e.g. 8k or 128k tokens of conversation). It shapes *how much* input it can reason over at any moment. 

## Explain how the "lookback horizon" for the vLLM is bounded by the "context window length"
The "context window length" is a physical hard bound baked into the model architecture at pre-training time (it **cannot** exceed 8192 tokens on an 8k model at all).  The "lookback horizon" for the vLLM is your optional choice **within** that ceiling.  You might choose to only feed in 2k tokens of history even though 8k is available, but you can never exceed the architectural limit.

## What are thread segments?
The `mbox_pre-parser.rb` can and often does chop a long email thread into multiple segments to fit context limits, which are ceilings upon the amount of information (measured in "tokens", a token being roughly 0.75 words) a llm (large language model) can hold in its "short-term memory" instantaneously (e.g. 4,096 or 8,192 tokens).  mbox files are just dumb records as flat lists of emails stored in the order of their arrival which can often be an interleaved order of arrival. An mbox has no inherent concept of "threads" or "token windows".  If a thread exceeds this limit, then the pre-parser will chop it into smaller "segments" to feed in to the llm, otherwise the llm effectively crashes or truncates the overflow.  This is also called "chunking", or "windowing".

## Don't suddenly change your splitter seed or configured ratio! 
"bin/splitter.rb" groups by thread_id, and always hashes with a deterministic seed to assign train/val/test (80/10/10) to the immutable manifest, writing immutably to assignments.json.  To say this again, splitter.rb assigns per-thread splits using a deterministic hash (seeded) to hit a fixed ratio so that the inputs always map to the same split in the immutable manifest unless you change the seed or configured ratio (which you should not do midstream because this would invalidate previous assignments; and IF YOU DO do this then you ***MUST*** recreate the **whole** manifest again and then materialize it!--effectively wiping the slate clean). 

## Does "bin/splitter.rb" prevent any context leakage across train/val/test?
Yes!!!

## Does "bin/splitter.rb" create the manifest file *and* the train/val/test JSONL set files?
Yes.

## Won't the recreation of the whole manifest file every time a new batch/corpus of emails arrives be costly in terms of processing and disk I/O?
In practice, no. This is because the manifest is just metadata (thread_id, split, cohort_id), not email bodies, so even a million threads is maybe 50-100MB of JSON, which rewrites in under a second on a modern disk.  The costly work is the parsing of mbox files and tokenizing bodies, which dwarfs the manifest I/O by orders of magnitude. 

## Do the train/val/test JSONL files contain the actual email body as well as the same metadata that the manifest file contains?
No. They are "skinny".  These files contain exactly the same metadata fields than the manifest but **do not contain the email bodies**.  These files serve as a deterministic index for your trainer/sampler to then look up the actual content from the raw shards.  These raw shards are exactly the same `.jsonl` files which are/were generated by "bin/mbox_pre-parser.rb" which contain the actual email bodies and headers. "train.jsonl" is just a bunch of metadata which points back to those shard files, and the same can be said of "val.jsonl" and "test.jsonl".

## How exactly does "bin/mbox_pre-parser.rb" operate?
If the pre-parser splits a long thread into segments/chunks then the fact that the pre-parser has split this long email thread into separate segments/chunks means that each segment has gotten put into a separate shard output file from "bin/mbox_pre-parser.rb" which simply slices the flat array of processed messages every 1000 entries (or whatever your `--shard-size M` option is).   

The shard files output from "bin/mbox_pre-parser.rb" are JSONL files where each row is a single JSON object containing keys like thread_id, message_id, cohort_id, and body.  The pre-parser outputs **one row per email message*, not one row per thread or per chunk.  A 264-message thread becomes 264 separate JSONL rows (each with the same thread_id) scattered across shards purely by arrival order in the mbox.  Each shard has a maximum number of rows (each corresponding to an individual email message) each can contain before another shard takes over as the output file.  This default limit is 1000 rows (emails) per shard.

### Omitting --window-size N
Because the physical fragmentation from the pre-parser is invisible to the splitting logic because if then the `--window-size N` option to `splitter.rb` is omitted, "splitter.rb" treats each thread as an atomic unit.  

Each email from a thread all carry the same `thread_id`, the splitter treats those multiple rows singly logically, forcing them all into the same bucket (train/val/test) so you don't fracture the conversation between train, val and test. 

"bin/splitter.rb" does an
```ruby
emails.group_by { |e| e['thread_id'] }
```
*after* loading all shard files into a single flat "emails" array, and this completely nullifies any fragmented sharding from the pre-parser and ensures you always can subsequently window (the verb is "to window") over the full, reassembled conversation.  So "splitter.rb" does treat each thread as an atomic unit.  The entire conversation within a thread (all messages sharing a particular "thread_id") lands within a single manifest entry and materializes into one split file.  This is the default behaviour.

Note that even if the pre-parser sharded a long thread across multiple output files (e.g., `part-00001.jsonl`, `part-00003.jsonl`) for I/O efficiency, `splitter.rb` reassembles all messages sharing the same `thread_id` before assignment. Pre-parser sharding is purely a file-size concern; split assignment operates on logically complete threads.

### When to omit

- Threads are short enough to fit comfortably within your model's context window
- You want maximum conversational coherence per training example
- Simplicity is preferred over fine-grained chunking

### Trade-off

Without windowing, very long threads may exceed transformer context limits at training time, forcing truncation (losing early messages) or rejection. If your corpus contains threads exceeding ~6k tokens, consider using `--window-size` with `--window-overlap` to produce manageable, overlapping context slices while preserving causal continuity.

### Using --window-size n
"bin/splitter.rb" has *no* segment-awareness; it reads from `Dir.glob("*.{json,jsonl}")`, groups *all* loaded messages by thread_id, sorts by Date, then windows over that merged pool. 

If the pre-parser splits a long thread into segments/chunks and then the `--window-size N` option to `splitter.rb` is used: for example, if I issue `splitter --window-size 40 --window-overlap 10` which operates upon a mega-thread containing 2687 email messages, after the pre-parser has output 3 segments/chunks of 1000 rows, 1000 rows, and 687 rows, then as these messages share the same thread_id, "splitter.rb" re-assembles these messages into one 2687-message thread, then rechunks with stride length of 30 (40-10) yielding windows 0-29, 30-59, 60-89... up through 89 windows which *all* inherit the same deterministic split from the hash of the parent thread_id. The pre-parser's sharding is purely concerned with file-size. It is just I/O (filesystem input/output) logistics.  All semantic windowing occurs within "bin/splitter.rb". The pre-parser shards are reassemble raw chunks while the windows which splitter creates are context slices for the time when training will occur.

### Non-dynamic (static) window-sizing
**`--window-size` is applied uniformly to all threads regardless of their length.** There is no dynamic adaptation.  A 5-message thread with `--window-size 100` simply produces one undersized window containing all 5 messages. The flag does not skip, expand, or contract based on thread size.  Why is this a design decision?  Using dynamic window-sizing would be an example of solving a non-problem.  Although it would not hurt the training of the model, short threads already become single complete windows (semantically ideal), and long threads already get chunked up into multiple overlapping windows (context-capped as intended). Dynamic sizing would add code complexity tp optimize something that the training framework already handles transparently via padding/packing, so the ROI (return on investment) is near to zero than actually harmful. The real goal of windowing is the cap context for long threads, not to stretch short ones.  

**`--window-size` is applied uniformly to all threads regardless of their length.** There is no dynamic adaptation - a 5-message thread with `--window-size 100` simply produces one undersized window containing all 5 messages. The flag does not skip, expand, or contract based on thread size.

### Split Inheritance
All windows derived from a single thread inherit the **same deterministic split** (train/val/test) based on the parent `thread_id` hash. This prevents data leakage - you'll never have window 0 of a thread in train and window 1 in val.

### Relationship to Pre-Parser Sharding

| Layer | Tool | Purpose |
|-------|------|---------|
| **Output sharding** | `mbox_pre-parser.rb` | I/O logistics - splits large output into manageable files (default 1000 rows/shard) |
| **Semantic windowing** | `splitter.rb --window-size` | Training concern - chunks threads to fit transformer context window |

The pre-parser outputs one JSONL row per email message (not per thread). If a 264-message thread's emails scatter across `part-00003.jsonl` and `part-00004.jsonl` by arrival order, `splitter.rb` reassembles the full thread via `thread_id` grouping before applying any windowing logic.

### How will new batches of emails arriving not result in previous shards becoming overwritten?
By default "mbox_pre-parser.rb" resets the index to 1 for every run, so it *will* overwrite the file as "part-00001.jsonl" if you point it at the same folder but will prevent you from doing this unless you use the --force option, and even then it will warn you about this unless you use the --yes option also.  You should output each new batch to a unique subdirectory (e.g. `--output emails/2026-01-05`) so that your library grows without collisions, while "splitter.rb" still loads everything via its input glob. 

### CLI Optimization (`--force` and `--yes` to "mbox_pre-parser.rb")
For integration into CI/CD or automated pipelines:
- `--force`: Bypasses safety checks when the output directory or file already exists, performing a surgical deletion of existing `*.json` and `*.jsonl` files before starting.
- `--yes`: Auto-approves prompts (such as confirming the deletion of thousands of files), enabling non-interactive execution.

## What happens if a malicious user sends one email with 50,000 words in it (possibly garbage) in order to attempt to cause the window to exceed the 8192 tokens which was the "context window length" baked into the model?
This is an astute observational concern as `--window-size` counts *messages*, not tokens, so a single 30k-email is just "1 message" to splitter.rb and would cause truncation to 8192 tokens happening downstream at tokenisation time.  So there is already added a hard-coded token/char limit in `mbox_pre-parser.rb` to reject absurdly long single messages before they even hit the manifest.  So to avoid truncation at training time due to a malicious user sending excessively large messages to the mailing list there now exists a token/char limit within `mbox_pre-parser.rb` to reject absurdly long single messages before they even hit the manifest. 

## Tell me about what we do about removing exact duplicates
Since we are already parsing the mbox within "mbox_pre-parser.rb" we just build the association in RAM (read only memory) between the Message-ID and the body_sha256 index there.  When a duplicate Message-ID is discovered we should compare the hashes, and if these body_sha256 hashes *are* identitical then we know that this is an exact duplicate, but if these *are not* then we know that a Message-ID collision has occured and that these *should not* be treated as exact duplicates.  This logic is for logging a triage file outlining that this collision has occurred, and also for the decision-making process in deciding *not* to reproduce exact duplicates in the output file or shards from "mbox_pre-parser.rb", but otherwise to write the metadata from each email entity into this output where a collision has occured upon the Message-ID (a rare event). 

We want to treat our original Message-ID as an immutable "Rosetta Stone" for threading (even where these ID collision occur) so we must not use it as our primary key for the downstream processing ("bin/splitter.rb") and the immutable manifest.  Instead we create a synthetic `internal_id = sha256(message_id + body_hash)` which *is* deterministic *and* unique, to use as the primary key.  This way we still retain the ability to make connections between messages via their In-reply-to or References headers and yet no data is ever silently overwritten by a collision.  This means that EVERY row within the immutable manifest will now have an internal_id metadata because schema consistency is king. In the 99.99% of non-collision cases it is still unique and deterministic without the need for conditional logic querying whether to use internal_id or message_id downstream; and yet the collision scenario becomes unremarkable because the formula already handled it.  

# The following is hypothetical.
We will NOT create the boiler_plate dictionary at ingest time.  Instead we will use an AI to do so at training time.

## I am worried about boilerplate code appearing within the emails, such as email signatures, getting put into all three: train, val and test.  This will happen. How can I guard against it by stripping emails of all repetitive sign-offs, greeting sign-ins, and/or boilerplates?
Have a three-pronged defence at the ingest time (which we will ***NOT*** be doing here at all in favour of doing it at the time of training of the LoRA adapters).  
- 1. Strip RFC 3676 sig blocks (everything after "-- \n")
- 2. Run frequency analysis during ingest to build a boilerplate_dictionary (anything appearing verbatim in >N% of threads is template cruft).
- 3. Make "mbox_pre-parser.rb" default to removing (via regexps) common patterns appearing within the (such as "Best regards," "Sent from my iPhone", legal disclaimers, etc) before fingerprinting. 

### Would, by default, "mbox_pre-parser.rb" utilize the boilerplate_dictionary previously created?
If the concept was not flawed, that would be a good design involving a two-pass workflow where pass 1 builds the boilerplate_dictionary scanning your corpus (body of email messages) and emits a JSONL file of high-frequency text blocks (such as those which have a configurable threshold of say appearing in >5% of threads).  Then pass 2 should load that current dictionary and excise matches (alongside hardcoded RFC 3676 sig-block regexp and the usual "Sent from my iPhone" suspects) from the email body before simHash fingerprinting.  In our context, "fingerprinting" is the process of turning a long email body into a compact, mathematical signature so that the system can instantly compare two messages for similarity without performing slow word-for-word text matching. It is how we detect "near-duplicates" and do cross-split contamination guarding.

### How would this dictionary accrue newer signatures from newer users whose messages are arriving in newer email batches? Do we need a dictionary mutable manifest file like a JSON structure?  
A mutable "boilerplate_dict.json" makes sense. This file ought to be able to evolve over time.

### And how would we treat two near-signatures, for example "with love from George" and "with love from Jorge"?
You would store *templatized* patterns (regex or slot-based like `"with love from {NAME}"`) rather than verbatim strings, or you would store the signature's SimHash and match incoming test within the Hammning distance <\N.   This is the same maths as "bin/contamination_guard.rb" but applied to known-boilerplate fingerprints rather than cross-split collision detection, which hopefully all this will greatly assist towards.  

### Advise me how to set score levels for my fuzzy deduplication of email messages. Do I vary the input level that the mbox_pre-parser.rb dedupes upon?
You should vary the threshold mbox_pre-parser.rb uses would use for the deduplication via a hypothetical `--simhash-threshold` input option.  It defaults to 3.  A higher number (e.g. 5 to 7) will catch more similarly looking variants, while a lower number (1 to 2) is safer to avoid false-positive deletions of legimate short replies like "Thank you" or "Okay", which I suspect are not very useful for AI training.  

### So what exactly would we be doing within "mbox_pre-parser.rb" if hypothetically we were to use Jaccard ?
What we would be doing if we had a three-pronged defence at the ingest time (which we will *NOT* be doing) would be:
- 1. Removing exact deduplicates where Message-IDs match *and* the body matches.
- 2. Adding a token/char limit in `mbox_pre-parser.rb` to reject absurdly long single messages before they even hit the manifest.
- 3. Dropping all emails which contain binary data or text-encoded binary data so we will not be training our model upon jibberish.
- 4. Creating an internal_id which is reproducible and deterministic for ALL received emails, keeping the message_id as valuable metadata.
- 5. Creating a boiler_plate dictionary of cribs and repeated pattens within our email_bodies by using frequency analysis during ingest to do this.
- 6. Removing cribs and boilerplate duplications from the email_body before fingerprinting it using simHash for fuzzy dedupe. This amended email_body (with the cribs excised)
- 7. Performing fuzzy deduplication so that the metadata of messages which are too near to each other in content don't get put into the manifest file.  This is done to avoid training upon absurd messages like "thankyou" or "cheers", and so that similar messages won't appear both in the train and val sets, or in train and test.
- 8. Outputing the shard files (or single output file)

Prior to using "fuzzy dedupe" at the pre-parser stage, we will have already not reproduced the metadata of exact duplicates of emails from our mbox, i.e the ouput shards from mbox_pre-parsed do not contain exact duplicates. 

For fuzzy deduplication we may use the rubygem as simhash2.

SimHash generates a 64-bit "fingerprint" for text where similar documents produce similar fingerprints. Unlike MD5/SHA, small changes result in small hash differences, allowing fuzzy matching via Hamming distance (count of differing bits).

# Why we don't perform this (hypothetical) fuzzy dedupe (after crib removal) at ingest time!
Because the problem is the following.  
- 1. The context of the location of the crib within the email is paramount.  If we blithely and blindly remove "love from" then the sentence mid-email as "Russia's latest aggression comes with love from Vlladimir Putin" then this sentence is "de-cribbed" to become "Russia's latest agression comes with Vlladimir Putin" where the crib was not actually a crib.  This is not what we want to do.
- 2. If we perform fuzzy dedupe (after crib removal) then two emails with similar content but within the same thread will be deduped.  This is especially relevant where you are training the LoRA adapters upon code-rich emails.  For example, if a correction to the typeset portrayal of code contained within an email was made, then this crucial correction might involve only a few characters, BUT, and this is a very important BUT, by fuzzy dedupe these emails would be very similar in terms of Hamming distance and one or both would be blocked.  We don't want this at all as we NEED this response, and the content which this response was a response to, eventually within the same set (e.g. train) in order for ML (machine learning) to happen at all, i.e. we don't wish to drop either from the email body content contained within the shards output from "bin/mbox_pre-parser.rb".  We WILL eventually desire to do a test of Hamming distance between emails between train and val at training time (and train and test later on, before bumping the pin), in case some clever user, whether by accident or design, has copied a load of text between threads which would otherwise (without Jaccard and fuzzy dedupe between sets) impair our model's ability to make generalisations instead of regurgitation after this content had randomly, but deterministically, gotten positioned in both train and val, or in train and test.  This would be contamination and would impair ML.
- 3. We would have forgotten to remove the quoted text from each email (which contains copies of previous messages within this thread) at ingest time.  Ouch.  Our model would be training upon a lot of quoted text, and quotes within quotes, also involving data content duplication which would break our model's ability to learn associations between concepts.  So, we must remember to remove this quoted text at ingest time, writing the result to the shard output files (or single flat file if the `--output FILE` option to "bin/mbox_pre-parser.rb" is chosen).  We do this in order to remove "noise" and to remove duplication: quoted text is often a repetition of information from earlier within an email thread. If we don't do this, then this can distort the model's understanding, and also waste computational resources.  We also wish to preserve the "style" of individual persons without polluting it. After we have done this, we also trim trailing white space from the end of each line within the email body in our attempt to avoid hallucintations.  We wish to keep the whitespace at the beginning of and within the middle of each line as this may be beneficial to the model learning syntax.
- 4. If would be very difficult without using an AI inference time model (like deepseek) to non-manually decide what is to be considered as a crib or boilerplate within a corpus of 20 years of emails.  It would be too much work to manually sample and to enable a human to decide what is a crib as humans are prone to tiredness and human error.  We want to automate this boilerplate_dictionary creation at training time using an AI model at inference time, with possibly another model to suprervise that it has not missed anything.  In particular, if somebody (a user) copies the boilerplate text and injects it into the middle of an email then we still subsequently want a script to remove this boilerplate (which might well contain personally identifiable information) replacing it by stable placeholders (e.g. [USER_NAME], [PHONE_NUMBER]). This would maintain the structural utility of the email for training while severing the link to the actual individual. 

***IMPORTANT!!!***

- 4. (continued...) It is highly recommended that this boiler_plate dictionary creation (at LoRA adapter training time) ought to be by an llm model ***hosted locally*** (at the inference time of this llm).  This way you can guarantee that no PII (personally identifiable information) has been sent to the cloud at all, and therefore that no cloud model has retained your prompt or response data containing any PII. The same applies to any AI model involved in the process of PII scrubbing.

# The following is real

## What are RAG Shards?
In the RAG (retrieval) world, a **Shard** is an horizontal partition of your **Vector Index**" (the database holding your embeddings).  Basically, instead of one giant searchable map that chokes a single server, you slice the map into pieces (shards) distributed across multiple nodes so you can search them in parallel (where "nodes" means the individual machines or logical database instances in the cluster).  

These RAG shards are conceptually distinct from the shards which are just the split-up JSONL files from "mbox-pre-parser.rb" which just hold many rows up to a limit after "mbox_pre-parser.rb" has done its processing upon the mbox. These latter particular shards are just an I/O concern.  Rag Shards are particular to Machine Learning and the implementation of artificial intelligence.

## How do these "nodes" work then?
Each node holds one or more RAG Shards of the index and runs it own little search engine, and a co-ordinator fans your query out to those nodes and then merges their results back together.

## How do we validate that the newer LoRA adapter does a better job than the last one?
We validate by running both adapters on the same frozen test set, checking that the new one wins on our key performance indicators (accuracy, helpfulness, safety, inbox quality), and doesn't regress on guardrails. These guardrails are the **runtime safety and compliance filters** (checking for PII, hallucinations, or toxicity) that intervene during the process of inference, and the frozen test set (test.jsonl) serves as the **unseen calibration set** used to measure the **False Positive Rate** of these guardrails--thus verifying that these safety rules aren't so aggressive that they accidentally block valid *future* use-cases from training the language model during a rollover pin bump.  The model + guardrails should allow and handle correctly future use-cases rather than blocking them as unsafe or as being outside of the distribution.

## What about my key to the crypt which stores the encrypted emails addresses?
In practice, the crypt key lives in a KMS (hardware-backed key management service) or HSM (hardware security module), rather than in code or in configuration files.  A KMS is something like Amazon Web Service KMS, or Google Cloud Platform KMS; and a HSM is a tamper-resistent hardware box that protects those keys so they can be used (e.g. to decrypt the crypt without anyone ever seeing or exporting the raw secret).  For self-hosted runners the *real* crypt key lives in an external secret store, and GitLab injects only a short-lived masked secret into the runner at job runtime such that the key is never within the repo, and it won't be baked into Docker images, and is scoped to specific projects and environments, so that it only exists within RAM on that runner whilst the particular CI job is decrypting the crypt.

HashiCorps Vault (or Openbao) is a self-hosted secrets manager that acts as a locked safe for passwords, API keys, and encyption keys, giving you a central place to store them encrypted, and to fetch short-lived credentials at runtime instead of hardcoding them in configs or in GitLab.

On-premises KMS/HSM means that instead of storing your encryption keys in a public cloud, they stay logically and physically under your control via your organisation running its own key-management system and hardware security modules within *your* own data centre which will be managed still by a central locked-down service.

A hardened OS/Kubernetes secrets backend is basically "Vault-lite" in the sense that you store secrets in the Kubernetes store which runs atop of the underlying operating system which is running on your servers (typically a hardened Linux distro like Ubuntu, Debian, or RHEL).  You make sure that the secrets which are stored in the Kubernetes store are encrypted at rest, and you lock the read-access to a tiny set of service accounts, injecting them into jobs only at runtime via the environment variables (temporary key=value settings which are visible only to that running process) or ephemeral volumes  (temporary filesystem mounts that exist only while the container/pod is alive). Every user/service gets the *minimum* permissions they need and nothing more, so only a few well-defined identities are ever allowed to read or use the encyption key.  You lock down each server which is within your cluster by disabling unused services. You lock down ports (by using a firewall on each host), and you enforce strong authentification like SSH keys, or 2-factor authentification, or SSO (Single Sign-On) with identity providers, such that an attacker will need more than one stolen credential to break in.  With SSO, you log in once with a central identity provider (which is an infrastructure--which is an identity provider service like Okta, Azure AD, or Google Workspace) that checks your login (password, multi-factor authentification, etc) and validates your account, and then issues short-lived tokens trusted tokens that the other apps accept as proof of who you are.

In any case, whichever key management system you choose to use, the idea is that the crypt key will never live within images, repos, or on long-lived disks and thus would be very hard to exfiltrate even if a node becomes compromised. 

I chose to use Openbao upon my development machine.

## What is "bin/contamination_guard.rb" for?
`contamination_guard.rb` is a post-materialization audit tool that catches data leakage across your train/val/test splits - it loads all three JSONL files, fingerprints each record using both w-shingles (Jaccard similarity) and a hand-rolled SHA256-based SimHash (Hamming distance), then does O(n²) pairwise comparisons across splits to find near-duplicates that slipped past the thread_id hashing (e.g., forwarded emails, templates, copy-pasted content in unrelated threads). If contamination is found, it applies a quarantine policy (nuke test/val items, nuke both sides, or flag for coassignment) and outputs an exclusion_ids.txt for downstream filtering - failing the pipeline if contamination exceeds 1%. Worth noting: it rolls its own simhash() function.

## When you say it nukes test/val items, does this mean that this is kind of like a tombstone and the items within the immutable manifest get nuked/altered/marked, or does this "nuking" merely mean that an entry is made to the "exclusions.txt" file for downstream filtering?
It is strictly the latter.  The contamination guard will overwrite "exclusions.txt" (via `generate_exclusion_list`) leaving your immutable manifest and original shards untouched.  This downstream list is then used by training/eval pipelines to ignore high-signal "leakage" rows. No rematerialization is needed as the immutable manifest file is not touched anyway.

## Does "exclusions.txt" contain only metadata or does it contain the email bodies itself?
It is strictly metadata.  The `generate_exclusion_list` method simply takes the set of flagged `record_id`s and joins these with newlines, so you get a plain text file of unique IDs (hashes) that the model trainer should ignore. No email content is included.

# The following we don't use.  It is hypothetical again.

## SpamAssassin (SA)
SpamAssassin is a mult-layered scoring engine.  It combines regex pattern matching (sketchy phrases, ALL CAPS), Bayesian classification (trained of spam/ham corpora), DNS blocklists (known bad sender IPs), header forgery detection, and collaborative databases to assign cumulation points: pertaining to which if a threshold is crossed (default is 5.0) then this is marked as spam.

SpamAssassin would create a "tagged.mbox" which now has has spam messages marked with headers like:

```
X-Spam-Flag: YES
X-Spam-Status: Yes, score=15.4 required=5.0 ...
Subject: *****SPAM***** Buy cheap whatever...
```
(for setup of SpamAssassin see [SpamAssassin](./extra_docs/spam_assassin.md))

SpamAssassin does not use Jaccard overlap.  It relies upon Bayesian probabilities and regular expression heuristics.  Header heuristics are regex/pattern rules that score suspect header traits - things like missing or forged header ids, received chains that don't trace back properly, date headers in the future, mismatched From/Reply-to domains, sketchy X-Mailer strings, and technical footprints left by automated software, like "Precedence: bulk" or "List-Unsubscribe" headers or specific X-Mailer tags (e.g. MailChimp, SendGrid) that indicate that a message was not individually typed by a human.  Although not technically spam by definition, they often trigger scores is SpamAssassin because they signal non-personal, low-priority content. 


### Tell me about Bayesian classification
This treats each word as evidence.  During training you feed it known ham and spam. It counts word frequencies in each class to compute the probability of spam give a word using Bayes' theorem.  At runtime it multiplies the spam probabilities of all the words in a message to get an overall score. The combined product decides the verdict.  

### Does SA come by default with a reasonable known dictionary of spam/ham words?
No.  SpamAssassin's Bayes engine actually ships "empty" and it won't even activate until you feed it 200 ham and 200 spam messages via sa-learn.  However the other non-Bayesian modules (like regexp rules, header checks, and DNS blocklists) *do* come with a massive, pre-weighted rulebook that workds out of the box.

# Why I don't need this (hypothetical) SpamAssassin Integration
SpamAssassin integration is probably not worth the hassle because 
- 1. The mbox contains many years of historical emails so DNS blocklists and fingerprint databases won't be usful any more.
- 2. The Bayesian won't work out of the box unless I manually set it with 200 spam and ham.
- 3. The regexp pattern matching, for all I know, might lead to false positives.
- 4. Exact dedupe removals and fuzzy dedupe might be enough.

## Is it possible that we can ever have a Message-ID collision within a very large (20 years) inbox?
RFC 2822 says that these should be "globally unique" but upon an historical mbox (prior to modern Mail Transfer Agents [MTA]s using MD5/UUID-based generation) dupes *can* occur from broken clients (old Oulook Express, some PHP mailers, misconfigured MTAs that rewrite the IDs) leading to the same ID but with different content. More relevantly, a more common issue is *missing* Message-IDs (which `formail` handles poorly), and for which simHash will catch those anyway since they'll have unique content fingerprints.  "simHash" is "fuzzy dedupe", i.e. the catching of messages which will have similar looking content.   

### How can we implement the removal of email message duplications naively in a way which will not detect Message-ID collisions?
During, and prior, to this process (i.e. prior to fuzzy dedupe), we can have already issued a `cat original.mbox | formail -D 50000000 .msgid.cache -s cat > unique.mbox` to generate a "unique.mbox" by using `formail`, and this will remove exact duplicates across the entire mbox (across all threads). It is purely a "Message-ID lookup" that doesn't care about the surrounding context.  It will not detect Message-ID collisions.

#### How is this naive?
It is not paranoid enough.  We want to compare by examing the hashes of the body too in order to remove exact dedupes because if within an older history of emails a Message-ID collision *has* occurred then we don't want to delete the latter messages blindly when they are very relevant.  We want to treat them as separate concerns.  

### So what do we do then?
We should pipe through a custom script which catches true collisions (both Message_IDs are identical but the email body -- and thus the hash of -- is not) and can include both messages for output instead of silently dropping one.  Note that these collisions are being detected AT INGEST TIME.

# The following is real

## Fuzzy Deduplication ("bin/contamination_guard.rb")
On the other side of the coin, if the same message was sent twice with different Message-IDs (common in cross-postings or new-thread resends),  `bin/mbox_pre-parser.rb` will miss them -- that is where our simHash-based deduplication in `bin/contamination_guard.rb` provides the necessary safety net AT TRAINING TIME, NOT INGEST TIME.

We want to do this at training time (training of the LoRA adapters), *not* at ingest time, because at ingest time, "bin/mbox_pre-parser.rb" has no semantic concept of email threads, and we *don't* wish to drop either of or both of two similar (Hamming distance) messages from within any thread because these messages, although appearing similar, may contain crucial amendments in a code-rich email (even by as little as a character, or a few characters).  Think of an email containing "My code is `printg "hello world"`", to which the response is "Typo dude. Use `printf "Hello world"`". 

To catch near-duplicates (which an exact examination will miss) at training time, the "bin/contamination_guard.rb" bakes in its own version of simhash.
- **Logic**: It generates a 64-bit fingerprint of message bodies and compares them using Hamming distance.
- **Sensitivity**: Controlled by `--threshold FLOAT` (default: 0.7). A lower threshold is more strict (requiring closer similarity to trigger a drop), while a higher threshold catches more distantly related variations.
- **Performance**: This check is performed at ingestion time within `mbox_pre-parser.rb`.

---

## Post-Materialization Audit

### Contamination Guard (`contamination_guard.rb`)
While the primary split logic relies on deterministic `thread_id` hashing to keep threads whole, cross-split leakage can still occur via forwarded messages or boilerplate content. 

The `contamination_guard.rb` tool acts as a final audit gate:
1. **Methods**: It uses dual-fingerprinting:
   - **W-Shingling**: Measures Jaccard Similarity (set-based overlap of word triplets).
   - **SimHash**: Measures bit-wise Hamming distance between body content signatures.
2. **Detection**: It performs O(n²) comparisons across the materialized `train.jsonl`, `val.jsonl`, and `test.jsonl` files.
3. **Quarantine Policies**:
   - `quarantine_test` (default): Drops the test/val side of a contaminated pair.
   - `quarantine_both`: Completely removes contaminated IDs from the workflow.
   - `coassign`: Theoretically flags items for manual relocation (infrastructure dependent).
4. **Outputs**:
   - `contamination_report.json`: Detailed breakdown of every found link and similarity score.
   - `exclusions.txt`: A plain-text list of `record_id`s to be ignored by downstream trainers. Note: This file is **overwritten** on each run; cumulative lists must be managed manually.

