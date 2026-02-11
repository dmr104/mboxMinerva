## What is a cohort?
A cohort is just a timestamped batch of rows within the manifest file "assignments.json", e.g. "2025-01" which tags all emails ingested in that period so we can freeze, and pin, and talk about the data that existed as of that particular cohort_id as to be considered within each split, for retrains and audits.

A cohort_id (e.g. 2025-01) is the stable tag for a cohort ; and a cohort is simply a group of emails that arrived during this bucketed time-interval, say, 1 month. Because the file "bin/splitter.rb" may be run weekly, or monthly, with `--materialize all` and a Cohort_id `--pin YYYY-MM` matching the month of the current date, "bin/splitter.rb" filters only the messages within the manifest file which have a cohort_id from the append-only manifest which is less than or equal to the `--pin YYYY-MM` argument value passed to "bin/splitter.rb", whereby it writes these exclusively to a newly versioned "train.jsonl" monolithic file, a newly versioned "val.jsonl" file, and a newly versioned "test.jsonl".  The pin is a ceiling, not a floor.

A fixed cohort pin is the explicit cutoff tag (e.g. cohort_id=2025-01) that "test.jsonl", "val.jsonl", and "test.jsonl" are locked to ; so that if I do a planned rollover yearly, and have no DSRs within this time, my explicit cutoff might change several times per year at each planned bump and subsequent rematerialisation. This doesn't prevent us doing an ad-hoc retrain if drift gets too bad.  Drift is a distribution mismatch between what the model has as data we have already fitted, and what present traffic contains.

At what stage does the cohort_id get written into the immutable manifest rows?  Answer. At ingest time.  When "bin/mbox_pre-parser.rb" appends new rows, it stamps into them the cohort_id, which is of the format as YYYY-MM which is derived from the either: (1) the "Date:" field from within the email, or (2) `File.mtime(mbox_path).strftime('%Y-%m')`, i.e. the mbox modification time, which is the latest time this particular mbox was written to.  So, thus, this cohort_id is *not* derived from the "Received:" heading (which is within the email), but *can* be overwritten manually as the latest configured batch cutoff as specified by the command line argument `--cohort` to "mbox_pre-parser.rb" (which will override the cohort_id received from (1) or (2)).  This is good because it will avoid a race condition if the "Date:" is the last seconds of the month, but the "Received:" is a few minutes later.  We don't want the cohort to jump in this case, just to be pedantic. 

When "bin/mbox_pre-parser.rb" appends new rows, it also stamps into them the key as "received" with a value as a non-localised universal-time timestamp (which an example of the format is as "2025-01-15T09:30:00Z"), which is derived from the either: (1) the "Date:" field from within the email, (2) the value of the key as "Received:" (which is a field within the email) (this will be the first "Received:" field read, so the latest one), or (3) `File.mtime(mbox_path).utc.iso8601` (i.e. the mbox modification time, which is the latest time this particular mbox was written to).
We need this "received" field so that "bin/splitter.rb" can sort the messages within any given thread to become in order so that the LoRA training will experience them chronologically.

## What is a split?
A split is the role tag on each manifest row (train, val, or test) within "assignments.json" which controls which "split file" it materializes into ("train.jsonl", "val.jsonl", or "test.jsonl"), and how it updates (train can be re-cut anytime ; val and test stay pinned and only change on DSR subtracts or a deliberate pin bump).  

## What is a pin bump?
A pin bump is the deliberate advancing done to the cohort_id cutoff for train, val, and test (e.g. 2025-01 goes to 2025-07), followed by rematerialization of all those splits to include the newer cohorts. The output from "bin/mbox_pre-parser.rb" (provided that the `--cohort` argument is not used, and therefore the cohort_id will be extrapolated from the "Received:" file within the email, OR that the `--cohort` argument is used very judiciously) ought to include those newer emails into shard files located within its own sub-directory potentially indicated by the name as a date, (e.g. pre_parsed_emails/until_2025_02), and the `--pin` argument to "bin/splitter.rb" would be passed the value as `--pin 2025_02` with the `--input` argument as `--input pre_parsed_emails/until_2025_02`.  A pin bump *might* be followed by a rollover, or it might not. Just think. An email arriving within the month of July 2025 might be as a response to an email that previously arrived in January, and thus within the same email thread. Here `--input pre_parsed_emails/until_2025_02` will capture and include this latest email, and its metadata will be attributed to the correct split and the correct thread within the manifest file.  This is why we do not attribute a date range to the name of the subdirectory of our `--input` argument to "bin/mbox_pre-parser.rb" because this would be misleading to say `--input pre_parsed_emails/2025_07_to_2025_08` as nothing would exclude the possibility that it easily contains a message in response to a January thread, or that the original email in January didn't arrive, by some strange technical problem, until the month of July.

## What is a rollover?
A planned rollover involves the flipping of a symlink.  This symlink may point to the actual model checkpoint (LoRA adapter) directory, which may reside, for example, at `current/releases/2025-01-15-clean` so that flipping the symlink would atomically switch from serving the old adapter to the newly trained DSR-clean one without changing any runtime configurations.

## What is a materialization?
Materialization is the process of extracting previously split data from the immutable manifest (the file "assignments.json") and writing the results to either, or all of, the files "train.jsonl", "val.jsonl", and "test.jsonl". 

## What is a retrain?
The difference between a retrain and materialization is that during a retrain we are actually retraining LoRA adapters to fit on top of an existing large language model, while a materialization is when the metadata files (train/val/test.jsonl) which the latest model reads, are deterministically rebuilt from our immutable manifest "assignments.json".  
 
Upon materialization, the data which is tombstoned in the "assignments.json" simply does not get written into any of the new train/val/test.jsonl. We then may retrain the model from its base checkpoint by creating a new LoRA adaptor and refitting it : it is like painting a new canvas (retraining), as opposed to merely touching up the old one (rematerialization). 

What would happen if I bump the pin, and then receive a DSR deletion request for data which exists within a previous cohort_id?  Does a `--materialize all` option to splitter.rb wipe its data out within these files (train/val/test.jsonl)?  Answer : Yes.

So, if I retrain the model using this newer train/val (with those tombstones), in practice the trained model *replaces* the previous adapter which was fitted upon the base model.  You don't layer adapters in order to forget things.  Instead, you swap in a freshly trained one that never saw the deleted rows in the first place.  Because we retrain when specific key performance indicators are breached, OR upon a fixed cadence (say "max staleness" as a time period between every 6 to 12 months), thus upon a receipt of a DSR deletion request, we may retrain upon whichever comes first: the breach of specific performance indicators, or this fixed cadence ; and hence we may fulfill legal or contractual obligations to have done so within the service level agreement which may have stipulated a clause such like "the model is always up to date with data such that the data it is trained upon is never older than 6 months prior to the date of the present moment, and hence DSRs are always updated to this model (i.e. deleted from it) periodically every six months, or sooner". 

## Updates to "train.jsonl", "val.jsonl", and "test.jsonl" 
When you train with incoming newer data (emails), you ought to have materialized all three sets : "train.jsonl", "val.jsonl" and "test.jsonl" to absorb new emails from existing cohorts.  You will have bumped the pin and rematerialized.  You want all three splits (train, val, and test) from that same new cohort snapshot so that they are consistent.  Then you train on the new train, validate on the new val, and evaluate on the new test.  Mixing old and new splits would be messy data versioning. The newer sets will incorporate any DSR deletion requests as metadata which these DSRs have tombstoned within the manifest file will not become included within these newer jsonl sets which are output from "bin/splitter.rb".

## What is spot-checking?
What is the point of a `--materialize train` as we ought not to retrain the LoRA adapters to fit atop the large language model without also rematerializing "val.jsonl" and "test.jsonl" to the same `--pin` value too?  Answer. One reason you might wish to do this is for spot-checking, whereby you regenerate "train.jsonl" via updating the `--pin` argument to "bin/splitter.rb" while passing it (via `--input pre_parsed_emails/2025-01_to_2025_02) the pre-processed newer corpus of emails from the output from "bin/mbox_pre-parser.rb" (which has just been processed after the newer corpus of emails have arrived), so that you can take a sample of your emails from "train.jsonl", "val.jsonl", or "test.jsonl", and spot-check data quality.  Spot checking means opening a sample of these email_bodies to check that these emails are not just scrambled gibberish or full of technical junk that would confuse the LLM during the training of the LoRA adapters which will be applied to and sit atop of it. In more technical language, spot checking is the process of verifying schema conformance, the encoding integrity, and the examination of tokenisation edge cases. 

## What is an epoch?
When training a model's LoRA adapter, an epoch is one full pass through "train.jsonl".  Mid-epoch means pausing part-way to evaluate against "val.jsonl" to check loss curves. 

## Can anything newer be set for training LoRA without bumping the cohort pin?
No. Nothing newer ought to be allocated for training (to either train, val, or test) without bumping the cohort pin. When you *do* bump the pin, if your intention is to train LoRA you ought rematerialize **all three** (train/val/test) together to the same pin boundary so that distributions stay aligned, because otherwise, leaving "test.jsonl" at an older pin while training upon newer data would invalidate your final benchmark. Don't do this.

## What about updates to "train.jsonl", "val.jsonl", and "test.json"?
Here, updates are being made to this metadata, which may be including newer emails beyond that which the cohort pin which the existing model is already trained upon.  But we do this for the purposes of spot-checking, and for the purposes of RAG.  We want RAG (retrieval augmentation generation) to also pay attention to newer emails and DSR requests. RAG is a later indexing system which we intend will utilize our LoRA adapter : that is, the latest model which excludes the tombstones and yet still retains good performance metrics.  Training is the training of the LoRA adapter itself, which requires a bump of the cohort pin and the rematerialisation of "train", "val", and "test".

If you are within the same cohort when a newer corpus of emails arrives (i.e. in the second week of January we can still use the cohort pin as 2025-01) you can materialize all three sets for the purposes of RAG (without bumping the cohort pin to February).  But if the date is the 3rd week of February when the corpus arrives, I would recommend bumping the pin to 2005-02 (as an argument to "bon/splitter.rb") so as not to miss any emails that have been pre-processed also. 

## What if loss spikes (perplexity diverges upwards) mid-epoch?
Then Houston we have a problem.  So we do spot-checking to examine whether the issue is upstream data corruption (malformed headers, encoding rot) or hyperparameter misconfiguration or genuine distribution drift from production traffic.

## Tell me about DSRs (Data Subject Requests)
DSR deletion requests *don't* get removed from the output files from "bin/mbox_pre-parser.rb" (the "part-00001.jsonl" files, etc) as that would add an extra layer of complexity, and also it would break our record of what data got pre-processed from the mbox at this stage, which is useful to retain for later analysis, as it will retain the data which the DSR may have deleted the metadata of in the output from "bin/splitter.rb". Instead, we break immutability within our immutable manifest file and jsonl set files (metadata output from "bin/splitter.rb") upon DSRs alone by marking this data as tombstoned within the manifest file and omitting such tombstoned data from our jsonl set files (train/val/test). This is the tradeoff between our possible legal obligations to remove data and personally identifiable information from the data sets (and also subsequently RAG) so that we will not retrain the model upon a user's "request to be forgotten", and we will not reference this individual within any retrieval augmentation system (RAG -- which may subsequently use this model) at inference time.  The training of each LoRA adapter will thus not be 100% reproducible as we MUST NOT use the data in training for which a DSR deletion request has been enacted AFTER this DSR request has been received. Thus we won't be able to retrain including it, and thus we may wish to keep each LoRA adapter itself after it has become no longer in use for our records if this is deemed useful, though it might not be deemed useful, as, so I would be made aware, an AI LLM (artificially intelligent large language models) at inference time uses "temperature" which introduces randomness through weighted sampling, and fixing this to zero while keeping the seed, the hardware, and the batching constant is too much of an advanced computer science project for an enterprise whose purpose is merely to read an archived mbox!

Note that DSR requests lead to quarantined messages at the level of metadata : this metadata becomes marked as tombstoned within the manifest file, and omitted from a rematerialisation of the pools/sets. This process of quarantining has nothing to do with deduplication of messages, or the removal of messages which contain binaries : the non-inclusion of which happens at the pre-parser stage. Neither does it have anything to do with fuzzy dedupe which checks for contamination of email-body content between sets.  Fuzzy dedupe happens at the time of the training of the LoRA adapter, not at ingest time.

## What about Data Subject Requests (DSRs)?
When a DSR request comes in, we may tombstone the data in the immutable manifest file ("assignments.json") and later trigger a clean rematerialization (after bumping the pin).  Pin bumps are an explicit operational decision (e.g. a "roll forward" event), not something that happens automatically as part of a deletion request.  

The file as "bin/splitter.rb" is the CLI (command line interface) we should invoke to rematerialize all three splits from the immutable manifest (e.g. `splitter.rb --pin 2025-07 --materialize all`) which should trigger a clean rematerialization of "train.jsonl" and "val.jsonl" and "test.jsonl", including all cohorts prior to that particular date, excluding tombstoned rows ; and thus will rematerialize train/val/test using only cohorts with cohort_id <= 2025-07, and which won't include newer cohorts than this date, and which won't change the pre-existing composition of what already got put into train, val, and test, beyond DSR effects, but may update "train", "val", and "test", up to and including emails received at 2025-07-31 23:59.

## How does my split data grow?
If I do a `splitter.rb --pin 2025-01 --materialize all`, and a year later I do a `splitter.rb --pin 2026-01 --materialize all`, then the possibility exists that a new thread from 2025-04 may enter "train.jsonl", "test.jsonl" or "val.jsonl", as we are specifically expanding the "Time Horizon" to include everything up to that new date ; whereby the April 2025 thread transitions from being an "ignored future data" (in the 2025 context) to being "eligible historical data" (in the 2026 context), and will enter the lottery as to where it lands based upon its hash, and your split ratio.

## What is the `--materialize all` to "bin/splitter.rb", without bumping the pin, ever used for in practice? 
Answer. For RAG (not training/evaluation of the LoRA adapter). When later-arriving emails arrive within your current pin's cohort ceiling without the pin neing bumped, this will refresh all three pools as "train", "val", and "test": which will need to be regenerated because we want the newer emails within existing threads to receive the latest email updates to them.  This will occur.  What will also occur is that potentially later but newer conversational threads than which the previous pin inferred (with newer email thread ids), will go into the manifest into our train/val/test probability split of 80/10/10, and those newer conversations which ended up in exclusively one of those sets/pools will become included within the ".jsonl" files output from "bin/splitter.rb" when it eventually becomes rematerialized.  Why is this useful?  Well, generalisation is the ability to say that the model has not merely memorized and regurgitated verbatim the patterns (grammar, intent structure, reasoning) from "train.jsonl" and this assists towards that end, and more data means that the model has a better ability to make generalisations. Later arrivals, within an existing cohort, each arriving in their deterministic destination within one of these pools, gives us the option to retrain the LoRA adapters at a later time upon a specific cohort pin (potentially a later one) with their inclusion implied, in order to improve the model's quality within that existing time boundary. A pin bump is a needed when you want to to shift the model's knowledge horizon into a new time period ; whereas RAG involves the model having data from all three sets : the latest data included (with or without a retraining done to LoRA).  With "bin/splitter.rb" if you had `--input emails/until_end_of_2025-08` but you DIDN'T update the pin from `--pin 2025-07` to `--pin 2025-08` then this will filter in any late arriving emails from prior to the month of August which have arrived yet, even if those emails from July got lost in transit, and weren't transmitted to the destination until August.  This isn't a very useful use case though.  What is more common is to update the pin to `--pin 2025-08` at the same time.  Before the month of September, however, we can merrily and blithely `--materialize all --pin 2025-08 --input emails/until_end_of_2025-08` without bumping the pin in order to furnish RAG with the latest weekly quotient, because the calendar month od September has not yet arrived!

## Would running `splitter --materialize all` to include recently arrived emails for training the LoRA adapters break reproducibility?  
Answer. Yes. You are putting more metadata stuff into your pools which reference real newly arriving email data from your pre-parser. Also `splitter --materialize all` can always break reproducibility because of independently arriving DSR tombstones within the manifest file.  We MUST NOT retrain AFTER these are received, and the latest `splitter --materialize all` will have removed these from our pools/sets. 
 
## If the pin is bumped to 2025-06, and we have rematerialized all the pre-processed emails up to and including the emails by 2025-06, but *don't* retrain the LoRA adapter until 2025-08, then will the LoRA adapter trained in August be reproducible after the bump in June?
Apart from this delay being a funny way to work, DSRs received in July will not yet have resulted in their corresponding rows vanishing from the pools/sets, because the latest DSR tombstones within the manifest won't have become omitted from the latest versions of "train.jsonl", "val.jsonl" or "test.jsonl".  The point being that as soon as you issue a `splitter --materialize all` you *will* lose reproducibility. So the answer is : in practice no because you have forgotten to remove the DSRs from the pools/sets ; but technically you *could*, if you really wanted to, keep a specific versioning of "train.jsonl", "val.jsonl", and "test.jsonl" ; but, really, can you guarantee that all of your hyperparameters are constant, and that the implementation details of the hardware you are training on is the same? The point of an AI is that it is supposed to appear pseudo-intelligent, of course, so should you really be thinking of it like a chemistry experiment?

## Tell me again. Won't DSR tombstones break reproducibility?  
Answer. Yes, deliberately. That is the legal tradeoff.  You *cannot* and *must not* reproduce data a person exercised their GDPR right to erase, but you still preserve *attestation* : this being an auditable record of what had been removed from "train.jsonl", "val.jsonl", and "test.jsonl" at training time in a tombstone log showing what was removed and when.  So your audit trail becomes "This particular LoRA (reference name) was trained after DSR removed X, Y, Z", rather than byte-for-byte regeneration of "train.jsonl", "val.json", and "test.json", as this byte-for-byte regeneration of previously tombstoned data would be a breach of data protection regulations.

TO DO.  Implement this logging facility. post record of tombstones to logs/tombstones.jsonl with who/what + timestamp + reason ; audit logs to logs/audit.jsonl recording each attempt to train LoRA with a record of keys (who/what) within the tombstones which apply to the training session, i.e. the X,Y,Z within the audit.jsonl reference the same key identity (who/what) within the tombstones.jsonl.  check whether bin/dsr_delete actually writes these tombstone records.  implement a way to query the jsonl data structure of audit.jsonl which in turn will query each key reference within the jsonl with an --output option as to output to a file instead of the default STDOUT.  We want `tombstone_audit list lora` to output the reference names of the LoRA adaptersm and `tombstone_audit query reference1` to output "This particular LoRA (reference name) was trained after DSR removed X, Y, Z", with a -v option introducing a timestamp in human readable form, and a -vv option introducing also the recorded reason for its removal, if any such reason was recorded at all. 

## How does splitter.rb start out?
For the first full cut from "bin/mbox_pre-parser.rb" we run something like `bin/splitter.rb --input /mbox_pre-parsed/until_end_of_2025-01/name_of_mbox ---output metadata --pin 2025-01 --materialize all` to deterministically assign email threads and emit "train.jsonl", "val.jsonl", and "test.jsonl" for training under that initial pin.  The `--pin` argument is something which is set when the script in invoked, i.e. if all my emails thus far are earlier than the end of 2025-01, then 2025-01 will do it, and we can keep rematerializing all three pools/sets (after pre-processing) at the start of each month after bumping the pin for RAG ; whilst rematerializing (after pre-processing) for RAG weekly, whilst keeping the pin as 2025-01, while the calendar month is the month of January within the real world.  We could retrain our LoRA on a longer cadence, every, say, 6 months, or 12 months, (or sooner if **drift** or the **exclusion-backlog** shows that our LoRA adapter which sits atop an existing LLM is getting stale).

## Is there any point to a `splitter --materialize all` without a subsequent retrain of the model?
Yes. This may be done for staging and inspection and also for RAG.  You *can* rematerialize to audit row counts (say, within "train.jsonl") after these emails from the newer cohort have been ingested, and to spot-check data quality (encoding errors, schema conformance).  This process may validate that late-arriving emails have landed correctly. This "train.jsonl" is now a stage which is before that of training the model (the LoRA adapters), as will "val.jsonl" and "test.jsonl" be.  This training of the model may now be scheduled for an overnight retrain without burning GPU hours the moment when the emails arrive.  Monitoring the growth of the row count from "train.jsonl", for example, allows us to quantify exactly how much new information (emails) have arrived and accumulated before we decide it is time to incur the expense and electricity cost of a fresh training run done to the model.

## What is drift?
Drift is the gap that opens when the distribution or meaning of data coming in shifts away from what the model was trained/evaluated upon. Think of "data drift" as something that happens when the data being input changes. For instance, if on a professional mailing list for dental surgeons, a lot of emails arrive talking about fluffy dogs, then this is "data shift" because the vocabulary has shifted.

"Concept drift" is when the underlying relationships between inputs being fed into the model and outputs from the model changes over time, i.e. if the input concept such as "this is a complaint" changes to something like "this is feedback" then the "concept drift" happens where the model is still thinking that it is the former when it should be the latter.  To further elaborate upon this, if customers yesterday complained by saying "this is broken" but today complain by sarcastically saying "This is great! Great job team!" then the concept within the identification of "complaint" would have changed.

In short, drift is a distribution mismatch between what the model has as data we have already fitted, and thus measure against, and what real traffic contains.

## What would "label drift" prior to training be?
"Label drift" is when the class mix of emails changes : that is, the proportion of each type of email in our data changes. For instance, if on a professional mailing list for dental surgeons, a lot of emails arrive talking about fluffy dogs then a *human* may label this email as "superfluous" *before* training at the labelling stage in order to audit the annotation pipeline carefully. "Label drift" happens when this mix of labels changes, i.e. when the label as "superflous" suddenly jumps from 2% to 15%. 

Can I automate the decision of labelling in response to the content of the reply to these messages about fluffy dogs on the dental surgeons' mailing list? For example, if the reply was "Please keep subject matters relevant to the topic of this list." then is there any way to automate the process of labelling these messages as "superflous" based upon the content of the mailing list?  Answer.  Yes. That is called "weak supervision" or "distant supervision".  You would write heuristics that pattern-match reply content to automatically generate labels like "superfluous".  Tools like Snorkel formalize this by combining multiple noisy labeling functions into probabilisitic labels : trading annotation precision for massive scaling without hiring an army of human taggers ; whereby you write "Labeling Functions" (mini-scripts like regexes, heuristics, or small models which either propose a label, or abstains from doing so) which cast "votes" in order to make these decisions. A Label Model mathematically learns which Labelling Functions are reliable and which are noisy, and then merges their votes into a single high-quality probabilistic label for every row.

The reason why, within our particular codebase in mboxMinerva, as a coding decision, it is NOT a good idea to make labels on the data prior to training LoRA adapters for the LLM is because *if* the labels are computed dynamically at materialization time then reproducibility would break because the labels may change several times within one cohort even, or over the space of several cohorts also : later data (emails arriving and being processed) may change the "votes" cast by earlier data.  For example, if the response to the first email about fluffy cats on the dental surgeons' mailing list was "Yeah, yeah. Roll over, Beethoven.", the model might not pick up upon the implication that the fluffy cats were "superflous", and might list the email as "relevant", but the second message might be "please stop spamming this list" at which point the model might realise the truth.  

So, because reproducibility would be broken, it would not be feasible to stamp a record of these labels into the manifest.  So we will, instead, defer labeling to RAG inference time, keeping the manifest purely structural, and letting classification logic (the code/prompts/rules of this "weak supervision") live in a separate independently versioned RAG layer within (or potentially outside of) the mboxMinerva git repo which will let us debug, test, and rollback to known good versions of these heuristics if a new heuristic misfires.

## What is exclusion-backlog?
Exclusion-backlog is simply the growing pile of new emails the LoRA has not yet been trained upon under the current pin.  We measure it as a count and as a percentage of recently receive email data that is out-of-scope for train/val/test under the current pin, and once that count or percentage passes a threshold this is our cue to bump the pin and rematerialize, and potentially train LoRA depending upon your organisation's operational decision-making.

## What about automatic notifications and included advice?
We bake in email and Slack/webhooks so that when exclusion-backlog or drift indicators cross a configurable threshold the admin gets a message that

- (a) shows the current stats, 
- (b) states which key performance area this indicator pertains to, 
- (c) recommends a definite action, such as "time to bump the pin", or "time to schedule a retrain on cohorts less than or equal to a specific PIN", or "tighten contamination thresholds for these cohorts".  

To wire it into your repo, edit `config/alerts.yml` with your SMTP/Slack URLs, and schedule via cron (`0 9 * * 1`) or GitLab pipeline schedules, (e.g. when exclusion-backlog hits 15% it'll tell you "do bump the pin to 2025-04 and schedule a training of LoRA to replace the existing LoRA adapter", or when contamination crosses 1% it will recommend "do tighten contamination thresholds", or when tombstones pile up past 100 it nudges you toward a retrain of LoRA).

## Why does mbox_pre-parser.rb output shard files?
Notice that "bin/splitter.rb" has an input argument `-i DIR` which is not specifically a single output file from "mbox_pre-parser.rb".  This is intentional, as instead of a single file, "splitter.rb" walks over all the sharded pre-parsed files in that directory (the outputs from "mbox_pre-parser.rb") so that it can deterministically assign whole threads to splits across the full range of data in one pass.  Shards are non-overlapping.  "mbox_pre-parser.rb" walks messages in order and assigns each one to exactly one part-XXXXX.jsonl file, so that together the shards are just a clean partition of the body of emails rather than containing overlapping copies of each other.  Note that for simplicity and downstream tooling for the training of LoRA, the outputs from "splitter.rb" are materialized as single flat files as "train.jsonl", "val.jsonl", and "test.jsonl" as these contain metadata only and are quite "skinny", and thus require inexpensive disk I/O (input/output) on a modern solid state drive and interface.  The costly work is the parsing of mbox files during pre-processing, and the tokenizing of email bodies during training of LoRA.

"bin/mbox_pre-parser.rb" defaults to writing JSONL files (e.g. "emails/part-00001.jsonl") unless you override it with the `--output` flag, which then collapses everything into a pretty-printed JSON array.  Instead, if it had been designed differently, it may have had only one output file per execution.  This is not, however, the case.

Recall that "bin/mbox_pre-parser.rb" is being called upon a raw MBOX. Raw mboxes are often one huge file per list history so far, or per month, or per week.  The pre-parser converts the physical MBOX into logical JSONL Rows. A **Logical Row** is the *atom* (one single email or thread entry), while a **Shard** is the *bucket* (the actual .jsonl file holding thousands of those atoms).  The pre-parser outputs shards so that the downstream tools (which are invoked at training time) can process data in parallel chunks instead of choking upon one massive 50GB file.

In our code base there is no ruby file that chops "train.jsonl" into shards : "splitter.rb" merely produces one flat "train.jsonl" file, and the actual "sharding" happens later inside the training stack's data loader (e.g. the finetune script, / vLLM or PyTorch+DeepSpeed job that reads "train.jsonl" and automatically splits it across workers).

## When are my unique `thread_id`s created?  
These are created by "bin/mbox_pre-parser.rb" ; then, later, "bin/splitter.rb" assigns one deterministic split from these thread ids and annotates the window_idx and the window_range for that thread.

## What is meant by "windows of a thread"?
When a thread has 50 messages, but you set `--window-size 20 --window-overlap 5`, "bin/splitter.rb" chunks these messages into overlapping sliding windows (e.g. messages 0-19, then 15-34, the 30-49) such that each training example/chunk stays within a manageable context length overlapping with other chunks.  Note that we are dealing with, and referencing, metadata here only. The purpose of doing this is to provide overlapping context between chunks of data passed to the process of training LoRA.  The critical design is that ALL of these windows inherit the **same** split from their parent thread_id in order to prevent data leakage, i.e. if window 0 lands in "test" then window 1 cannot sneak into "train" because this would contaminate the training and evaluation of the LoRA adapter.  The context of the conversation within any email thread ***will not*** be shared!

## What is a sliding window?
In "bin/splitter.rb" when --window-size is enabled, ***all*** windows of a thread inherit the ***same*** deterministic split into either "train", "val", or "test" ; and when omitted, "bin/splitter.rb" assigns the **entire thread** as a single manifest entry.  In both cases, this infers that the **entire thread** (i.e. the entire conversation) lands deterministically and atomically with a probability of ~80% in train, ~10% in val, and ~10% in test.  

The `--window-size N` option is specifically about chunking long threads into overlapping segments for training whereby each chunk gets a manifest entry keyed by `manifest[window_id]` where `window_id = "#{thread_id}_window_#{window_idx}"` such that 
```ruby
    # Windowing: chunk messages and create window entries
    sorted_messages = messages.sort_by { |m| m['received'] || '' }
    window_size = options[:window_size]
    overlap = options[:window_overlap]
    stride = [window_size - overlap, 1].max
    
    window_idx = 0
    pos = 0
    
    while pos < sorted_messages.size
      window_end = [pos + window_size, sorted_messages.size].min
      window_messages = sorted_messages[pos...window_end]
      
      # Create a synthetic window ID
      window_id = "#{thread_id}_window_#{window_idx}"
      
      unless options[:incremental] && manifest.key?(window_id)
        manifest[window_id] = {
          'split' => split,
          'thread_id' => thread_id,
          'window_idx' => window_idx,
          'window_range' => [pos, window_end - 1],
          'internal_ids' => window_messages.map { |m| m['internal_id'] },
          'cohort_id' => window_messages.last['cohort_id']
        }
      end
      
      window_idx += 1
      pos += stride
```
where the `'window_range' => [pos, window_end]` value pair records exactly which slice of messages went into that window.  But only windowed threads get this notation.  Bare threads do not get this range metadata.

## What is the window_idx for a thread?
It is the zero-based index of a sliding window chunk which occurs when `--window-size N` splits a long thread into overlapping segments.

## What is the window_range for a thread?
It is the `[start_pos, end_pos]` tuple which is stored within each manifest row showing exactly which message indices from the original thread are included within that window chunk. e.g. `window_range: [0,19]` means messages 0-19, and `window_range: [15, 34]` will be the next overlapping chunk if overlap=5, window_size=20.

## Explain `--window-overlap M` option to "splitter.rb"
This is the number of messages shared between consecutive windows.  It ensures that each window has leading context from the previous one, preventing "cold start" at window boundaries where the model would otherwise see a conversation mid-stream with no preceding step. This is important and relevant for the training of the model because without overlap, each window starts "cold" mid-conversation and the model learns to predict responses without seeking what prompted them.  It would be trained upon fragments stripped of causal content.  The overlap gives each window a "warm-up runway" of prior messages so that LoRA learns the actual patterns you care about (i.e. how *this* reply follows *that* context), instead of just learning how to create plausible-sounding text in a vacuum.

## What would a "Rolling Retention Policy" be?
A **Rolling Retention Policy** would tell the splitter to filter by data freshness and ignore data older than `N` days/months/years relative to the Pin, ensuring that your model trains only on relevant, recent patterns and isn't going to be trained upon ancient, drifted history: drifted because the "ground truth" changes as the world evolves; vocabulary shifts (new slang evolves, old terms become deprecated), spammers use newer tactics to evade filters, and crucially, the structure of business data within an organisational structure might change, (e.g. a "purchase order" from 2018 might look completely different than one from 2025), meaning that patterns from very old data might mislead the model about today's reality.  

## Why we *don't* use a "Rolling Retention Policy"?
Because:
- 1. It would totally break the guarantee of append-only immutability.  Although no rows would subsequently disappear from out immutable manifest, we are saying that these rows would subsequently become barred from being read after they had timed out when a `--materialize` option to "bin/splitter.rb" became invoked.
- 2. It would prevent the reproducibility of past training runs if the source data would age out.
- 3. Sometimes the stale data would be perfect for making generalisations from.  Older does not always necessarily mean that it should be treated as obsolete. That is a truism.

## What is "Lookback Horizon" for data curation?
It is how many months/cohorts of historical data you include in your training corpus. Within our project we include all of it in order not to break reproducibility (except for DSR requests).  It shapes *what* the model learns.

## What is "Lookback Horizon" for the training of the model?
A "Lookback Horizon" in this context is a model or inference-time configuration set in your training or vLLM.  It is ***not*** within the data pipeline.  It is a concept pertaining to model inference specifically dealing with how far back the model's attention span reaches.  It is how much preceding context you feed the model when training it to predict the next token/response.  

## What is "Lookback Horizon" for the vLLM?
At inference time, lookback horizon is how much of the conversation history (system prompt + user messages + assistant replies so far) the vLLM keeps the the key-value cache when generating the next token: which is bounded by the "context window length" (e.g. 8k tokens).

## What is "context window length"?
This is how many tokens the model can see in a single forward pass at inference time (e.g. 8k or 128k tokens of conversation). It shapes *how much* input it can reason over at any moment. Each sequences of tokenized text fed into LoRA at training time can be at most "context-length" tokens.

## Explain how the "lookback horizon" for the vLLM is bounded by the "context window length"
The "context window length" is a physical hard bound baked into the model architecture at pre-training time (it **cannot** exceed 8192 tokens on an 8k model at all).  The "lookback horizon" for the vLLM is your optional choice **within** that ceiling.  You might choose to only feed in 2k tokens of history even though 8k is available, but you can never exceed the architectural limit.

## What are thread segments?
The `mbox_pre-parser.rb` can and often does chop a long email thread into multiple segments to fit context limits, which are ceilings upon the amount of information (measured in "tokens", a token being roughly 0.75 words) a llm (large language model) can hold in its "short-term memory" instantaneously (e.g. 4,096 or 8,192 tokens).  mbox files are just dumb records as flat lists of emails stored in the order of their arrival which can often be an interleaved order of arrival. An mbox has no inherent concept of "threads" or "token windows".  If a thread exceeds this limit, then the pre-parser will chop it into smaller "segments" to feed in to the llm, otherwise the llm effectively crashes or truncates the overflow.  This is also called "chunking", or "windowing".

## Don't suddenly change your splitter seed or configured ratio! 
"bin/splitter.rb" groups by thread_id, and always hashes with a deterministic seed to assign train/val/test (80/10/10) to the immutable manifest, writing immutably to assignments.json.  To say this again, splitter.rb assigns per-thread splits using a deterministic hash (seeded) to hit a fixed ratio so that the inputs always map to the same split in the immutable manifest unless you change the seed or configured ratio (which you ***must not*** do midstream because this would invalidate previous assignments; and if you ***do*** do this then you ***MUST*** recreate the **whole** manifest again and then materialize it!--effectively wiping the slate clean). 

## Does "bin/splitter.rb" prevent any context leakage across train/val/test?
Yes!!!

## Does "bin/splitter.rb" create the manifest file *and* the train/val/test JSONL set files?
Yes.

## Won't the recreation of the whole manifest file every time a new batch/corpus of emails arrives be costly in terms of processing and disk I/O?
In practice, no. This is because the manifest is just metadata (thread_id, split, cohort_id), not email bodies, so even a million threads is maybe 50-100MB of JSON, which rewrites in under a second on a modern disk.  The costly work is the parsing of mbox files and tokenizing bodies, which dwarfs the manifest I/O by orders of magnitude. 

## Do the train/val/test JSONL files contain the actual email body as well as the same metadata that the manifest file contains?
No. They are "skinny".  These files contain exactly the same metadata fields than the manifest but **do not contain the email bodies**.  These files serve as a deterministic index for your trainer/sampler to then look up the actual content from the raw shards.  These raw shards are exactly the same `.jsonl` files which are/were generated by "bin/mbox_pre-parser.rb", which contain the actual email bodies and headers. "train.jsonl" is just a bunch of metadata which points back to those shard files, and the same can be said of "val.jsonl" and "test.jsonl".

## How exactly does "bin/mbox_pre-parser.rb" operate?
### The emails' encoding
First, "bin/mbox_pre-parser.rb" opens the mbox as a read binary. Then, for each message, it checks whether the field as `Content-Type: charset` is present within each message, reading the message in the charset specifiedif it is ; and if this charset field is not present within the email message we auto-detect the encoding of this email using the `charlock_holmes` gem, with a final fallback which replaces unrepresentable bytes with "?".  Otherwise ruby may treat strings within the email as raw bytes (ASCII-8BIT) but JSON needs valid UTF-8.

If the pre-parser splits a long thread into segments/chunks, then the fact that the pre-parser has split this long email thread into separate segments/chunks means that each segment has gotten put into a shard output file from "bin/mbox_pre-parser.rb", which simply slices the flat array of processed messages, which are held in memory (RAM -- random access memory), every 1000 entries (or whatever your `--shard-size M` option is).   

The shard files output from "bin/mbox_pre-parser.rb" are JSONL files where each row is a single JSON object containing keys like thread_id, internal_id, original_message_id, thread_id, cohort_id, and email_message.  The pre-parser outputs **one row per email message**, not one row per thread or per chunk.  A 264-message thread becomes 264 separate JSONL rows (each with the same thread_id) potentially separated across shards purely by arrival order in the mbox, if, for example, there are already 800 messages within the current output shard at the point when this 264-message thread becomes processed.  Each shard has a maximum number of rows (each corresponding to an individual email message) which each can contain before another shard takes over as the output file.  This default limit is 1000 rows (emails) per shard.

## What is the field as "internal_id" within the output files from "bin/mbox_pre-parser.rb"?
It is a collision-proof SHA256 hash of the `Message-ID` plus the email body hash, serving as a unique primary key to depduplicate exact content matches while tracking different versions of the same Message-ID. This means that within a historical inbox of many emails spanning decades, although RFC 2822 says that email Message-IDs should be globally unique, we are protecting ourselves in case two separate email_message body contents arrive (potentially decades apart) with the same Message-ID (a collision), in which case the internal_ids would be different, and we don't reject these messages from either RAG or training LoRA ; but we *will* reject exact duplications of the same email (which have the same internal_id as both the Message-ID and the hash of the email body will be identical).

## Omitting --window-size N
Because the physical fragmentation from the pre-parser is invisible to the splitting logic, if the `--window-size N` option to `splitter.rb` is omitted, "splitter.rb" treats each thread as an atomic unit.  

Because bare threads do not involve a window_id, each email from a thread all carry the same `thread_id`, and the splitter treats those multiple rows singly logically, forcing them all into the same bucket (train/val/test) within the manifest such you don't fracture the conversation between "train", "val" and "test".  In this case (whereby --window-size is omitted) "bin/splitter.rb" does an
```ruby
emails.group_by { |e| e['thread_id'] }
```
*after* loading all shard files into a single flat "emails" array, and this intentionally reads but does not preserve any fragmented sharding from the pre-parser as far as the processing within "bin/splitter.rb" is concerned, thus ensuring that you always can subsequently window (the verb is "to window") over the full, reassembled conversation.  So even if `--window-size N` is omitted to "bin/splitter.rb", the entire conversation within a thread (all messages sharing a particular "thread_id") lands within a single manifest entry and materializes into one split file as "bin/splitter.rb" does treat each thread as an atomic unit.  This is the default behaviour.

Note that even if the pre-parser sharded a long thread across multiple output files (e.g., `part-00001.jsonl`, `part-00002.jsonl`) for I/O efficiency when training LoRA, `splitter.rb` reassembles all messages sharing the same `thread_id` before assignment. Pre-parser sharding is purely a file-size concern.

### When to omit `--window-size N`

Although this is not recommended in general for larger mboxes, it is possible when:

- Threads are short enough to fit comfortably within your model's context window
- You want maximum conversational coherence per training example upon these short threads (which don't exceed the maximum sequence length of LoRA training -- the "context window length").
- Simplicity is preferred over fine-grained chunking

### Trade-off

Without windowing, longer threads may exceed transformer context limits at training time, forcing truncation (losing early messages) or rejection. If your corpus contains threads exceeding ~6k tokens, consider using `--window-size` with `--window-overlap` to produce manageable, overlapping context slices while preserving causal continuity. ~6k tokens was plucked from the air as it will give a ~2k space to reach the "context window length" of an 8k model.

## Using --window-size n
"bin/splitter.rb" has *no* segment-awareness; it reads from `Dir.glob("*.{json,jsonl}")`, groups *all* loaded messages by thread_id, sorts by Date, then optionally windows over that merged pool. 

If the pre-parser splits a long thread into segments/chunks, and then the `--window-size N` option to `splitter.rb` is used (for example, if I issue `splitter --window-size 40 --window-overlap 10`), which operates upon a mega-thread containing 2687 email messages, then, after the pre-parser has output 3 segments/chunks of 1000 rows, 1000 rows, and 687 rows, then, as all these messages share the same thread_id, "splitter.rb" will re-assemble these messages into one 2687-message thread, and then rechunks with stride length of 30 (40 minus 10) yielding windows 0-39, 30-69, 60-99... up through 89 windows which *all* inherit the same deterministic split from the hash of the parent thread_id (with the last window, with the window_id=88, as the window_idx variable is zero based, containing the final 17 messages). Recall that these shards output from "bin/mbox_pre-parser.rb", are not "skinny": they contain rows which are containing the emails' message bodies. The pre-parser's sharding is purely concerned with file-size. It is just disk I/O (filesystem input/output) logistics.  All semantic windowing occurs within "bin/splitter.rb". The pre-parser's output shards are just raw data structure chunks assembled from the mbox, while the windows which splitter creates are semantic context metadata slices assembled for the time when training of LoRA will occur.

## Non-dynamic (static) window-sizing
**`--window-size N` is applied uniformly to all threads regardless of their length.** There is no dynamic adaptation.  A 5-message thread with `--window-size 100` simply produces one undersized window containing all 5 messages. The flag does not skip, expand, or contract based on thread size.  Why is this a design decision?  Using dynamic window-sizing would be an example of solving a non-problem.  Although it would not hurt the training of the model, short threads already become single complete windows (semantically ideal), and long threads ideally already get chunked up into multiple overlapping windows (context-capped as intended) hopefully without the loss of data via truncation. Dynamic sizing would add code complexity to optimize something that the training framework already handles transparently via padding and/or packing, so the ROI (return on investment) is near to zero, rather than actually harmful. The real goal of windowing is to cap context (with overlap between chunks) for long threads, not to stretch out short ones.  

**`--window-size N` is applied uniformly to all threads regardless of their length.** There is no dynamic adaptation. A 5-message thread with `--window-size 100` simply produces one undersized window containing all 5 messages. The flag does not skip, expand, or contract based on thread size.

## Split Inheritance
All windows derived from a single thread inherit the **same deterministic split** (train/val/test) based on the parent `thread_id` hash. This prevents data leakage. You'll never have window 0 of a thread in "train" and window 1 in "val".

### Relationship to Pre-Parser Sharding

| Layer | Tool | Purpose |
|-------|------|---------|
| **Output sharding** | `mbox_pre-parser.rb` | I/O logistics. It splits large output into manageable files (default 1000 rows/shard) |
| **Semantic windowing** | `splitter.rb --window-size` | This is a training concern. It chunks threads to fit a transformer context window |

The pre-parser outputs one JSONL row per email message (not per thread). If a 264-message thread's emails are broken across `part-00003.jsonl` and `part-00004.jsonl` by arrival order, `splitter.rb` reassembles the full thread via `thread_id` grouping into RAM before applying any windowing logic.

## How will new batches of emails arriving not result in previous shards becoming overwritten?
By default "mbox_pre-parser.rb" resets the filename index to 1 for every run, so it *will* overwrite the file as "part-00001.jsonl" if you point it at the same folder, but will prevent you from doing this unless you use the --force option, and even then it will warn you about this unless you use the --yes option also.  You should output each new batch to a unique subdirectory (e.g. `--output my_project/pre_parsed/2026-01-05`) so that your library grows without collisions, while "bin/splitter.rb" still loads everything via its input glob; so `ruby mbox_pre-parser.rb my_project/emails/2026-01-01/ --output-dir my_project/pre_parsed/2026-01-01/` and `ruby mbox_pre-parser.rb my_project/emails/2026-01-15/ --output-dir my_project/pre_parsed/2026-01-15/` will both be read by "bin/splitter.rb" by the code
```ruby
pattern = File.join(input_path, '**', '*.{json,jsonl}')
files = Dir.glob(pattern)
``` 
when we issue `ruby splitter.rb --input my_project/emails/`

### CLI Optimization (`--force` and `--yes` to "mbox_pre-parser.rb")
For integration into CI/CD or automated pipelines:
- `--force`: This will bypass safety checks when the output directory or file already exists, performing a surgical deletion of existing `*.json` and `*.jsonl` files before starting.
- `--yes`: Will auto-approves prompts (such as confirming the deletion of thousands of files), enabling non-interactive execution.  ***Use with caution!!***

## What happens if a malicious user sends one email with 50,000 words in it (possibly garbage) in order to attempt to cause the window to exceed the 8192 tokens which was the "context window length" baked into the model?
This is an astute observational concern as `--window-size` counts *messages*, not tokens, so a single email with 50k-words (~ 37k tokens) is just "1 message" to splitter.rb, and would cause truncation to 8192 tokens happening downstream at tokenisation time.  So to avoid truncation at training time due to a malicious user sending excessively large messages to the mailing list, there exists a token/char limit to each email within `mbox_pre-parser.rb` to reject absurdly long single messages before they even hit the the output from "bin/mbox_pre-parser.rb" (and thus subsequently the manifest). 

## Is it possible that we can ever have a Message-ID collision within a very large (20 years) inbox?
RFC 2822 says that these should be "globally unique", but upon an historical mbox (prior to modern Mail Transfer Agents [MTA]s using MD5/UUID-based generation) dupes *can* occur from broken clients (old Outlook Express, some PHP mailers, misconfigured MTAs that rewrite the Message-IDs) leading to the same Message-ID but with completely different content ending up within the same inbox. More relevantly, a more common issue is *missing* Message-IDs.  

## How could we have implemented the removal of email message duplications naively in a way which will not detect Message-ID collisions?
During, and prior, to this process (i.e. prior to fuzzy dedupe), we could have already issued a `cat original.mbox | formail -D 50000000 .msgid.cache -s cat > unique.mbox` to generate a "unique.mbox" by using `formail`, and this will remove exact duplicates across the entire mbox (across all threads). It is purely a "Message-ID lookup" that doesn't care about the surrounding context.  It will *not* detect Message-ID collisions. Neither will it detect missing Message-IDs.

### How would this have been naive?
It is not thorough enough.  We want to compare emails by examing the hashes of the email body too in order to remove exact dedupes because, if within an older history of emails a Message-ID collision *has* occurred, then we don't want to omit the inclusion of the bodies of email messages blindly when the email contents may well be very relevant.  

### So what could we have done then in an ersatz manner?
We could have piped through a custom script which catches true collisions, whereby both Message_IDs are identical, but the email body (and thus the hash of) is not, and this inferior script could have included both messages for output instead of silently dropping one at ingest time.

Since we are already parsing the mbox within "mbox_pre-parser.rb", we could have just built the association in RAM (read only memory) between the Message-ID and the body_sha256 index there.  When a duplicate Message-ID is discovered we could have compared the hashes, and if these body_sha256 hashes *were* identitical then we would have known that this is was an exact duplicate ; but if these *were not*, then we alternatively would have known that a Message-ID collision has occured, and that these *should not have been* treated as exact duplicates.  This logic would have been for both logging a triage file outlining the fact that this collision has occurred, and also for the decision-making process in deciding *not* to reproduce exact duplicates in the output file, or output shard files, from "mbox_pre-parser.rb", but otherwise to write the metadata from each email entity into this output where a collision has occured upon the Message-ID (a rare event).

## Tell me about what we *really* do about removing exact duplicates.
As we don't want to treat our original Message-ID as an immutable "Rosetta Stone" for threading (even where these ID collision occur), so we must not use it as our primary key for the downstream processing ("bin/splitter.rb") and the immutable manifest.  Instead we create a synthetic `internal_id = sha256(message_id + body_hash)` which *is* deterministic *and* unique, to use as the primary key.  This way we still retain the ability to make connections between Message-IDs, via their In-reply-to or References headers, and yet no data is ever silently overwritten by a collision.  This means that EVERY row within the immutable manifest will now have an internal_id metadata in order to conform with schema consistency. In the 99.99% of non-collision cases it is still unique and deterministic, without the need for conditional logic querying whether to use internal_id or message_id downstream ; and yet by the collision scenario, it becomes unremarkable because the formula already handled it.  This is quite a clever way to work. 

### Explain this again to me.
We should record the as "key" within our shard outputs from `mbox_pre-parser.rb` (and subsequently our manifest file) the "internal_id' which comprises of a hash of the message_id concatenated with the raw (not yet decribbed) email body. This way, if the message id is not missing, this hash will confer the ability to detect the difference between an exact duplication and an email collision.

## What are cribs.
Cribs are certain sign-offs, and other common repetitive patterns, appearing within emails at certain predictable places within the email body text, and also taken out of place.  For example, if Hans always signs off with his address, then this crib will appear both in the set as "train" and the set as "val" and the set as "test" every time an email from Hans appears in these sets/pools, albeit on separate email threads.

In reality we will NOT be creating a boiler_plate dictionary at ingest time via an AI inference model or via standard regexps.  Instead we will use an AI to do so at the time of training LoRA.

## I am worried about boilerplate code appearing within the emails (such as email signatures), getting put into all three sets : "train", "val" and "test".  This *will* happen. How can I guard against it by stripping emails of all repetitive sign-offs, greeting sign-ins, and/or boilerplates?
You could mistakenly attempt a three-pronged defence at the ingest time (which we will ***NOT*** be doing here at all in favour of doing it at the time of data curation prior than training of the LoRA adapters) in which you might:  
- 1. Strip RFC 3676 sig blocks (everything after "-- \n")
- 2. Run frequency analysis during ingest to build a boilerplate_dictionary (anything appearing verbatim in >N% of threads is template cruft).
- 3. Make "mbox_pre-parser.rb" default to removing (via regexps) common patterns appearing within the boilerplate dictionary (such as "Best regards," "Sent from my iPhone", legal disclaimers, etc).

### Would "mbox_pre-parser.rb" utilize the boilerplate_dictionary previously created?
If the concept was not flawed, that would be a design AT INGEST TIME involving a two-pass workflow where pass 1 uses an AI model (called "weak supervision") to build the boilerplate_dictionary scanning your corpus (body of email messages), and it would emit a JSONL file of high-frequency text blocks (such as those which have a configurable threshold of say appearing in >5% of threads).  Then pass 2 would load that current dictionary and excise matches (alongside hardcoded RFC 3676 sig-block regexp and the usual "Sent from my iPhone" suspects) before subsequent processing.  

### Why we don't perform this (hypothetical) crib removal at ingest time.
We don't do this (and I mention this as a dead-end in terms of a hypothetical proof of concept which failed) because 
- 1. We would, unfortunately, be required to duplicate the data from within the shard files output from "bin/mbox_pre-parser.rb" in order to process further this version of the data with the cribs excised.  This data duplication would kind of be a poor design decision because it breaks the DRY (don't repeat yourself) principle of data computation in general.
- 2. If would be very difficult without using an AI inference time model (like GPT-4, Claude, Deepseek) to non-manually decide what is to be considered as a crib or boilerplate within a corpus of 20 years of emails.  It would be too much work to manually sample and to enable a human to decide what is a crib as humans are prone to tiredness and human error.  

## So what do we want to do them?
Instead, we *do* want to automate this boilerplate_dictionary creation *after* INGEST TIME but *prior* than AT TRAINING TIME using an inferrence AI model ("weak supervision"), with possibly another model to supervise that it has not missed anything.  In particular, if somebody (a user) copies the boilerplate text and injects it into the middle of an email then we still subsequently want a script to remove this boilerplate (which might well contain personally identifiable information) replacing it by stable placeholders (e.g. [USER_NAME], [PHONE_NUMBER]). This would maintain the structural utility of the email for training while severing the link to the actual individual. 

***IMPORTANT!!!***

- It is highly recommended that this boiler_plate dictionary creation (at LoRA adapter training time) ought to be by an llm model ***hosted locally*** (at the inference time of this llm).  This way you can guarantee that no PII (personally identifiable information) has been sent to the cloud at all, and therefore that no cloud model has retained your prompt or response data containing any PII. The same applies to any AI model involved in the process of PII scrubbing.

## What is the crux of the matter?
Emails often contain repeated quoted material within an email thread. For instance on Tuesday George writes in an email:
```txt
What is the price of a hamburger?
What is the price of a cheese burger?
What is the price of fries?
```
The reply to this email might be
```txt
>What is the price of a hamburger?
$4.25
>What is the price of a cheese burger?
$4.75
>What is the price of fries?
$2.50
```
Notice that the questions have been repeated and reduplicated with a ">" character.

This not labeling.  This is a way to process the data in order to make it such that ML (machine learning can train upon it).  Note that we will omit the ">" (and multiples of it appearing) in our Alpaca format.  You would use a regex to capture the quoted lines and strip the >+ from them. We are performing dataset curation here. 

Most LoRA tools (axolotl, unsloth, etc.) accept the Alpaca format natively which is a JSONL structure as something like
```jsonl
{"instruction": "Write a haiku about IRC chat.", "input":"", "output": "Nicknames flicker fast,\nScroll of jokes and late-night code-\nPings fade into dawn."}
```

Modern trainers like Unsloth and Axolotl allow Alpaca to have four fields : "instruction" (task), "input" (extra context, can be empty), "output" (response), plus optional "system" and an optional "history".  

"instruction" is a static string template you define to guide the model's behaviour, whereas "input" and "output" receive their values from dynamic variables which contain your specific email snippets.

So we will keep "system" as a static persona (e.g. "You are a professional assistant") ; "instruction" as something like "Draft a professional reply to the following email", or "Summarize the following thread" ; and we will combine both the previous message and the quoted text in "input", and your actual reply in "output". The actual reply to the input comes from the non-quoted part of the reply email, and I need to include this to train the model upon the "input". The non-quoted part of the email becomes the "output" field, while the "instruction" and "input" serve together as the prompt context.  

The "instruction" is the *task description* telling the model what to do (a directive like "Reply to this quoted portion professionally), while "output" is the *actual email text that got written* within the reply.  

Think of "instruction" as the prompt, and "output" as the target completion that the model is being trained to generate. 

A further issue is that within the original email there may be a lot more "instruction" (say 25 lines of it) than the quoted text within the second email (say 2 lines of it). In this case 

We ought to use both the quoted portion of the reply message as your instruction, *and* the full original of the previous message which this reply email is a reply to, so that that quoted fragment of the reply email is the true "prompt" that the model should learn to respond to. The unquoted parts within the previous email provide the HUMAN context which drives our human decisions (what we have read). The model learns human reasoning style without conflating "stuff you read" with "stuff you directly respond to".

The reply is a response to what the replier chose to engage with.

## When I combine the original email and the quoted part of the present email, should I strip >+ quote marks?
We should keep the ">" quote marks, as LLMs recognize them as standard markers for conversational history ; whereas stripping them can make the model confuse who said what.  You should normalize messy nesting (like ">>>") to keep the context clean.

### Explain more about how to normalize messy nesting.
You ought to standardize inconsitent quoting.  Emails often have formats like "> > >" with spaces, ">>>" without, or random indentations.  You must collapse these to consistent "> " per nesting level (one "> " = original, "> > " = reply-to-reply), and trim excessive depth beyond 2-3 levels because ancient context rarely helps the model learn.

## Within the "input" field, can I have multiple quote blocks and responses to that previous email?
That is the question! Email replies often interleave multiple quote blocks and responses, and you naturally would wish to interleave this and not repeat the previous email for each repetition. This is in order not to break the DRY (don't repeat yourself) principle in data structures.  There appears to be 2 methods within the AI industry currently of doing this.  One is called ShareGPT and the other is called ChatML.  I don't think that either are programmatically viable in terms of data curation, so I will break the DRY principle on this occasion.  

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
- 3. Would it be as effective at ML than repeating the previous email within the "input" field for each reply to quotation taken from within the present email in association with its unquoted text from the present email as the value of the "output" field?
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
The bottom line is that this is far from an easy data structure to utilize or create.  Let's just break DRY and be done with this absurdity.

## What we shall do with Alpaca
email 1 is:
```
What is the price of a hamburger?
What is the price of a cheese burger?
What is the price of fries?
```
email 2 is:
```
>What is the price of a hamburger?
$4.25
>What is the price of a cheese burger?
$4.75
>What is the price of fries?
$2.50
```
email 3 is:
```
> > What is the price of a cheese burger?
> $4.75
Infation just happened: now $4.80
```
So we will have in our JSONL
```jsonl
{"instruction": "Reply to this email professionally.", "input":"What is the price of a hamburger?\nWhat is the price of a cheese burger?\nWhat is the price of fries?\n> What is the price of a hamburger?", "output": "$4.25"}
{"instruction": "Reply to this email professionally.", "input":"What is the price of a hamburger?\nWhat is the price of a cheese burger?\nWhat is the price of fries?\n> What is the price of a cheese burger?", "output": "$4.75"}
{"instruction": "Reply to this email professionally.", "input":"What is the price of a hamburger?\nWhat is the price of a cheese burger?\nWhat is the price of fries?\n> What is the price of fries?", "output": "$2.50"}
{"instruction": "Reply to this email professionally.", "input":"> What is the price of a hamburger?\n$4.25\n> What is the price of a cheese burger?\n$4.75\n> What is the price of fries?\n$2.50\n> > What is the price of a cheese burger?\n> $4.75", "output": "Inflation just happened: now $4.80"}
```
Notice that we are not overly-complicating things.

## A pyramid
Each JSONL line should be one training example (input + output pair), so every reply in the thread gets its own line.  The "apex fanning out" means that you might get multiple lines where the same parent message appears in different inputs, paired with different sibling replies as outputs, which teaches varied response styles.  

So I can iteratively combine the previous message and quoted text from the present message as "input" and have the non-quoted text from the present email message as "output".  I can do this for every email in a thread with the apex original fanning out a pyramid structure.  I will omit the apex vertex from the training as this does not have anything within its "input" field at all.

## A proposal
I was thinking about, at data curation time (not at ingest time), a boilerplate file created (via "weak supervision") which contains stats about cribs (email signoffs, PIIs, "many thanks", etc.) so that state (pertaining to these cribs) can be retained between training runs (not regenerated totally each training time of LoRA). Then do a simHash on the email_body after crib removal, keeping a record of each simHash for each email_body (after crib substitution by intelligible placeholders and >+ removals). 

Now we have the data to do the inspecting of the Hamming distance between emails.  This is done so that we can ignore both cribs and duplicates *between* threads for Alpaca so that downstream training of LoRA can ignore verbatim content (or near-verbatim content) which was copied between email threads. This hence will hopefully assist towards prevention of contamination between our sets/pools.  Stripping boilerplate before simhash means we are comparing actual content semantics, not just shared label signatures ;  though we need to make sure that our simhash Hamming distance threshold is tuned on a sample with manual labels, because the "correct" cutoff varies wildly by domain (emails can be legitimately similar without being duplicates). Contamination is primarily about **verbatim or near-verbatim overlap**, not semantic similarity, i.e. not upon *content meaning* but upon *verbatim content*.  We don't want the model memorizing exact text from "train" that appears in "val", artifically inflating your metrics. 

## Why I ought not to do simHash Hamming dedupe *within* an email thread.
Because the first email might be 
```txt
printg('Hello')
```
whereas the reply might be 
```txt
printf('Hello')
```
Intra-thread similarity is a signal (corrections, refinements, quoted context).  But if this is the exclusive email content *between* threads then we *do* wish to filter it both to avoid dataset pollution, and to avoid repetition of info within a set/pool.  Inter-thread is noise. Our dedupe should only compare emails across different thread_ids, treating each thread as a conversational unit where internal redundancy is intentional and meaningful.

## How would this dictionary accrue newer signatures from newer users whose messages are arriving in newer email batches? Do we need a dictionary mutable manifest file like a JSON structure?  
A mutable "boilerplate_dict.json" makes sense. This file ought to be able to evolve over time.

## And how would we treat two near-signatures, for example "with love from George" and "with love from Jorge"?
You would store *templatized* patterns (regex or slot-based like `"with love from {NAME}"`) rather than verbatim strings, or regex "with love from \w+" as I don't want to fill the boilerplate crib data file with "with love from George" and with "with love from Jorge".  We are specifying within our boilerplate/crib file (potentially a JSON file) that both are the same, and are to be omitted from the next stages of fuzzy dedupe (simhash Hamming distance) between datasets/pools, and Alpaca format creation.  

## Advise me how to set score levels for my fuzzy deduplication of email messages. Do I vary the input level that the mbox_pre-parser.rb dedupes upon?
You should vary the threshold mbox_pre-parser.rb uses would use for the deduplication via a hypothetical `--simhash-threshold` input option.  It defaults to 3.  A higher number (e.g. 5 to 7) will catch more similarly looking variants, while a lower number (1 to 2) is safer to avoid false-positive deletions of legimate short replies like "Thank you" or "Okay", which I suspect are not very useful for AI training.  

## So what exactly *are* we doing within "mbox_pre-parser.rb"?
We are:
- 1. Removing exact deduplicates where Message-IDs match *and* the body matches.
- 2. Adding a token/char limit in `mbox_pre-parser.rb` to reject absurdly long single messages before they even hit the manifest.
- 3. Dropping all emails which contain binary data or text-encoded binary data so we will not be training our model upon jibberish.
- 4. Creating an internal_id which is reproducible and deterministic for ALL received emails, keeping the message_id as valuable metadata.

## What are we *not* doing within "mbox_pre-parser.rb"?
What we will *NOT* be doing at the ingest time (in favour of doing it at data curation time) would be:
- i. Creating a boiler_plate dictionary of cribs and repeated pattens within our email_bodies by using frequency analysis during ingest to do this.
- ii. Removing cribs and boilerplate duplications from the email_body before fingerprinting this modified email_body (with the cribs excised) using simHash for fuzzy dedupe. 
- iii. Performing fuzzy deduplication on these fingerprints so that the metadata of messages which are too near to each other in content don't get put into the manifest file.  This would have been done to avoid training upon absurd messages like "thankyou" or "cheers", and so that similar messages won't appear both in the "train" and "val" sets, or in "train" and "test".

Within this failed and rejected proof of concept, we would have used "fuzzy dedupe" in fingerprints at the pre-parser stage after crib removal in order to *not* include these similar messages within the JSONL output shard files from "mbox_pre-parser.rb", and hence the metadata for these similar messages would not be able to have gotten put into the manifest file!  We reject this approach because:

* The Data Curation stage involves the creation or amendment to a JSON-based pattern crib, in order to use boilerplate stripping via regex patterns like {NAME}, so that we can do simhash fingerprinting on all email bodies which have the cribs excised and replaced by placeholders, in order to perform inter-thread simhash filtering, while keeping the intra-thread signal clean for the Alpaca format output.
* We do all this at Data Curation stage (rather than the Pre-processing stage or the Manifest Creation stage) because (a) the train/val/test split must happen upon stable, content complete data, so that we can regenerate Alpaca ouputs with different pattern cribs without invalidating the split manifest, (b) boilerplate patterns are iteratively discovered during creation, so baking them in to pre-processing creates a rebuild-everything loop, and (c) inter-thread simhash filtering is semantically a curation decision (deciding what is "too similar") rather than a data quality gate, and we want it tunable independently of the immutable shards ouput from "mbox_pre-parser.rb".
* We have the right separation of concerns to avoid the "Oh no. I have to rebuild everything" trap that kills so many ML data projects.

## An astute observation.
I have an observation whereby the problem is the following.  
- The problem. The context of the location of the crib within the email is paramount.  If we blithely and blindly remove "love from" from the sentence mid-email as "Russia's latest aggression comes with love from Vlladimir Putin" then this sentence becomes "de-cribbed" to become "Russia's latest agression comes with Vlladimir Putin" where the crib was not actually a crib.  This is not what we want to do.
- The proposed solution. Our crib patterns need positional anchors (e.g. "appears within last N lines or "preceded by blank line or a signature delimiter) or stuctural content like "followed by {NAME}" in order to disambiguate sign-off boilerplate from legitimate text.

# Why we don't perform intra-thread fuzzy dedupe (after crib removal) at curation time.
If we would perform intra-thread fuzzy dedupe (after crib removal) at Data Curation time, then two emails with similar content, but within the same thread will be deduped.  This is especially relevant where you are training the LoRA adapters upon code-rich emails.  For example, if a correction to the verbatim code contained within an email was made, then this crucial correction might involve only a few characters, but, by fuzzy dedupe these emails would be very similar in terms of Hamming distance and one or both would be blocked.  We don't want this at all as we NEED this orignal context and the response to it (therewith, the content which this response was a response to and the response itself), eventually within the same thread, and thus within the same set (e.g. say, "train") in order for ML (machine learning) to happen : i.e. we don't wish to drop either emails from the content which is being read from the JSONL shards which were output from "bin/mbox_pre-parser.rb".  

We WILL eventually desire to do a test of Hamming distance between emails between "train" and "val" at training time (and "train" and "test"), to protect us against the case whereby some clever user, whether by accident or design, has copied a load of text between threads which would otherwise (without Jaccard and fuzzy dedupe between sets) impair our model's ability to make generalisations instead of regurgitation, after this content had randomly, but deterministically, gotten positioned in both "train" and "val", or in "train" and "test".  This would be contamination and would impair ML.

# Why we do train upon '>' characters when we create our Alpaca format output at the end of the Curation stage.
We must not remove the quoted text less than 4 ">"s, (i.e. "> > > " or less) from each email which contains quotes from previous messages within this thread at curation time because the model may need these to learn; but our model can't train upon a lots of quoted text, more than quotes within quotes within quotes. 

We must not censor this data content duplication intra-thread, less than 4 ">"s, because doing so would break our model's ability to learn associations between concepts. So, we must remember to remove more than 3 levels of quoted text at curation time, writing the stripped version to the relevant part of the data Alpaca data structure format. After we have done this, we also trim trailing white space from the end of each line within the email body in our attempt to avoid hallucinations.  We wish to keep the whitespace at the beginning of, and within, the middle of each line as this may be beneficial to the model learning syntax.

# Why we don't ignore this duplication of data from a previous email which is being quoted within the present one.
We would be mistaken to think that we ought to ignore quoted text within reply-to emails or that we ought to do this in order to remove "noise" and to remove duplication : quoted text is often a repetition of information from earlier within an email thread. If we don't imply "context" as the previous email which this present one is as an "In-Reply-To" (which is a field taken from the email header), then this can distort the model's understanding, and also waste computational resources.  We also wish to preserve the "style" of individual persons without polluting it.

## What is meant by simHash fingerprinting within "bin/contamination_guard.rb"?
In this context, "fingerprinting" is the process of turning a long email body into a compact, mathematical signature so that the system can instantly compare two messages for similarity without performing slow word-for-word text matching. It is how we detect "near-duplicates" and do cross-split contamination guarding. SimHash generates a 64-bit "fingerprint" for text where similar documents produce similar fingerprints. Unlike MD5/SHA, small changes result in small hash differences, allowing fuzzy matching via Hamming distance (count of differing bits). For fuzzy deduplication we may use the rubygem as simhash2.

## What is a key-management service?
In practice, the crypt key lives in a KMS (hardware-backed key management service) or HSM (hardware security module), rather than in code or in configuration files.  A KMS is something like Amazon Web Service KMS, or Google Cloud Platform KMS; and a HSM is a tamper-resistent hardware box that protects those keys so they can be used (e.g. to decrypt the crypt without anyone ever seeing or exporting the raw secret).  For self-hosted runners the *real* crypt key lives in an external secret store, and GitLab injects only a short-lived masked secret into the runner at job runtime such that the key is never within the repo, and it won't be baked into Docker images, and is scoped to specific projects and environments, so that it only exists within RAM on that runner whilst the particular CI job is decrypting the crypt.

HashiCorps Vault (or Openbao) is a self-hosted secrets manager that acts as a locked safe for passwords, API keys, and encyption keys, giving you a central place to store them encrypted, and to fetch short-lived credentials at runtime instead of hardcoding them in configs or in GitLab.

On-premises KMS/HSM means that instead of storing your encryption keys in a public cloud, they stay logically and physically under your control via your organisation running its own key-management system and hardware security modules within *your* own data centre which will be managed still by a central locked-down service.

A hardened OS/Kubernetes secrets backend is basically "Vault-lite" in the sense that you store secrets in the Kubernetes store which runs atop of the underlying operating system which is running on your servers (typically a hardened Linux distro like Ubuntu, Debian, or RHEL).  You make sure that the secrets which are stored in the Kubernetes store are encrypted at rest, and you lock the read-access to a tiny set of service accounts, injecting them into jobs only at runtime via the environment variables (temporary key=value settings which are visible only to that running process) or ephemeral volumes  (temporary filesystem mounts that exist only while the container/pod is alive). Every user/service gets the *minimum* permissions they need and nothing more, so only a few well-defined identities are ever allowed to read or use the encyption key.  You lock down each server which is within your cluster by disabling unused services. You lock down ports (by using a firewall on each host), and you enforce strong authentification like SSH keys, or 2-factor authentification, or SSO (Single Sign-On) with identity providers, such that an attacker will need more than one stolen credential to break in.  With SSO, you log in once with a central identity provider (which is an infrastructure--which is an identity provider service like Okta, Azure AD, or Google Workspace) that checks your login (password, multi-factor authentification, etc) and validates your account, and then issues short-lived tokens trusted tokens that the other apps accept as proof of who you are.

In any case, whichever key management system you choose to use, the idea is that the crypt key will never live within images, repos, or on long-lived disks and thus would be very hard to exfiltrate even if a node becomes compromised. 

## What are RAG Shards?
In the RAG (retrieval) world, a **Shard** is an horizontal partition of your **Vector Index**" (the database holding your embeddings).  Basically, instead of one giant searchable map that chokes a single server, you slice the map into pieces (shards) distributed across multiple nodes so you can search them in parallel (where "nodes" means the individual machines or logical database instances in the cluster).  

These RAG shards are conceptually distinct from the shards which are just the split-up JSONL files from "mbox-pre-parser.rb" which just hold many rows up to a limit after "mbox_pre-parser.rb" has done its processing upon the mbox. These latter particular shards are just an I/O concern.  Rag Shards are particular to Machine Learning and the implementation of artificial intelligence.

## How do these "nodes" work then?
Each node holds one or more RAG Shards of the index and runs it own little search engine, and a co-ordinator fans your query out to those nodes and then merges their results back together.

## How do we validate that the newer LoRA adapter does a better job than the last one?
We validate by running both adapters on the same frozen test set, checking that the new one wins on our key performance indicators (accuracy, helpfulness, safety), and doesn't regress on guardrails. These guardrails are the **runtime safety and compliance filters** (checking for PII, hallucinations, or toxicity like hate speech, harassment, or slurs) that intervene during the process of inference, and the frozen test set (test.jsonl) serves as the **unseen calibration set** used to measure the **False Positive Rate** of these guardrails--thus verifying that these safety rules aren't so aggressive that they accidentally block valid *future* use-cases from training the language model during a rollover pin bump.  The model + guardrails should allow and handle correctly future use-cases rather than blocking them as unsafe or as being outside of the distribution.

## Why we do *not* need git-crypt 
We do **not** need git-crypt at all for four reasons:

- 1. git-crypt can only store encrypted files within a git directory.
- 2. We don't require git commits or tracking on the email vault.
- 3. It would be technically difficult to map a git repo in any Job Container to a backend directory on the Host.
- 4. We don't want to store *any* email data (encrypted or clear) in our main repo.

If we were to store encrypted emails addresses within an email_crypt (which I do *not* implement) we would use `gpg` instead, and store these outside of the mboxMinerva repo.

We would thereby treat the "crypt" (which is our email "vault") which stores our encrypted email hashes on the Container pipeline backend as "opaque GPG blobs".  On the Host we could generate a long-lived GPG keypair (or symmetric passphrase) and store this secret in OpenBao.  Within the CI we could pull this secret and use it to unlock the gpg encrypted email_crypt (which is our vault of encrypted email hashes).  Depending upon the design decision we could do this either at a file level (each file that stores emails get encrypted), or at a granular level (whereby each encrypted email hash is stored one-by-one within a clear file).  In any case, it is unclear what benefit storing `gpg` hashes of each email (or even each email address) would achieve.  I include this within this document as it was a useful thought experiment which lead to this dead-end being eliminated from the design.

TO DO.  implement `contamination_guard.rb`

## What is "bin/contamination_guard.rb" for?
`contamination_guard.rb` is a post-materialization audit tool that catches data leakage across inter-thread splits, and thus across your train/val/test splits. After we have done previously boilerplate ceation of the cribs within the emails, and have done dynamic crib removal from these emails, `contamination_guard.rb` fingerprints each record using both k-shingles (Jaccard similarity) and a hand-rolled SHA256-based SimHash (Hamming distance), either facilitating :

* 1. By default, no local-sensitivity, which will subsequently require an inspection of O(n²) pairwise comparisons across splits to find near-duplicates that slipped past the thread_id hashing (e.g., forwarded emails, templates, copy-pasted content in unrelated threads). 
* 2. With local-sensitivity, whereby each fingerprint is bucketed into bands : so that we will only compare decribbed email bodies that land within the same bucket.  For n decribbed email bodies, the time taken to put each into a bucket is O(n), and to compare the items within the same bucket is near to O(1) per bucket if the number of buckets has been tuned correctly. We need to compare every bucket in train against every bucket in val, and every bucket in train with every bucket in test, and every bucket in val with every bucket in test. 

In both cases, if contamination is found, `contamination_guard.rb` applies a quarantine policy (nuke test/val items, nuke both sides, or flag for coassignment) and outputs an exclusion_ids.txt for downstream filtering -- failing the pipeline if contamination exceeds 1%. Worth noting: it rolls its own simhash() function.

### When you say it nukes test/val items, does this mean that this is kind of like a tombstone and the items within the immutable manifest get nuked/altered/marked, or does this "nuking" merely mean that an entry is made to the "exclusions.txt" file for downstream filtering?
It is strictly the latter.  The contamination guard will overwrite "exclusions.txt" (via `generate_exclusion_list`) leaving your immutable manifest and original shards untouched.  This downstream list is then used by training/eval pipelines to ignore high-signal "leakage" rows. No rematerialization is needed as the immutable manifest file is not touched anyway.

### Does "exclusions.txt" contain only metadata or does it contain the email bodies itself?
It is strictly metadata.  The `generate_exclusion_list` method simply takes the set of flagged `record_id`s and joins these with newlines, so you get a plain text file of unique IDs (hashes) that the model trainer should ignore. No email content is included.

### What is Jaccard similarity?
This is the intersection-over-union of sets. It is used for plagarism detection.

### What is cosine similarity?
This measures how similar two vectors are by the cosine of the angle between them. 1 means an identical direction. 0 means unrelated.

### What are shingles?
A shingle (of k-shingle) is just another name for a k-gram, which is a sequence of k consecutive words or characters used to break a document into a set of overlapping fragments so you can mathematically compare how similar two texts are using tools like Jaccard or MinHash.  

### What is MinHash?
MinHash is the LSH (Locality-Sensitivity Hashing) technique that actually approximates Jaccard similarity.  

### What is simHash
simHash is the LSH technique that approximates cosine similarity.

### Tell me about LSH.
This is a family of techniques that hash similar items into the same buckets with high probability, so instead of comparing everything O(n²) pairwise, you only compare hings that land in the same bucket, making near-duplication detection feasible at scale (minHash an simHash are both specific LSH schemes).

### Comparison and fingerprint length.
If I do a simHash on the text "Peter is a happy lad" and "Peter is a happy lad who has a dog", then because simHash always produces a fixed-sized fingerprint regardless of input length, and because the shorter text's features (tokens/shingles) are almost entirely contained in the longer one, the shared features will dominate the final hash, so the Hamming distance will be small.

Whereas if I do a simHash on the text "Anne is a sad girl who has a dog" and "Peter is a happy lad who has a dog", these text differ in 3 content words and have a 5/9 shared number of words.  Using bigram shingles, we have 4/8 shared bigrams ("is a", "who has", "has a", "a dog").

But if I do a simHash on the text as "Peter is a happy lad with a dog" and "Peter is a happy lad without a horse", then they share 5/8 words and 4/7 bigrams.

## SpamAssassin (SA)
SpamAssassin is a mult-layered scoring engine.  It combines regex pattern matching (sketchy phrases, ALL CAPS), Bayesian classification (trained of spam/ham corpora), DNS blocklists (known bad sender IPs), header forgery detection, and collaborative databases to assign cumulation points: pertaining to which if a threshold is crossed (default is 5.0) then this is marked as spam.

SpamAssassin would create a "tagged.mbox", which now has has spam messages marked with headers like:

```
X-Spam-Flag: YES
X-Spam-Status: Yes, score=15.4 required=5.0 ...
Subject: *****SPAM***** Buy cheap whatever...
```
(for setup of SpamAssassin see [SpamAssassin](./extra_docs/spam_assassin.md))

SpamAssassin does not use Jaccard overlap.  It relies upon Bayesian probabilities and regular expression heuristics.  Header heuristics are regex/pattern rules that score suspect header traits : things like missing or forged header ids, received chains that don't trace back properly, date headers in the future, mismatched From/Reply-to domains, sketchy X-Mailer strings, and technical footprints left by automated software, like "Precedence: bulk" or "List-Unsubscribe" headers or specific X-Mailer tags (e.g. MailChimp, SendGrid) that indicate that a message was not individually typed by a human.  Although not technically spam by definition, they often trigger scores is SpamAssassin because they signal non-personal, low-priority content. 

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

## Fuzzy Deduplication ("bin/contamination_guard.rb")
If the same message was sent twice with different Message-IDs (common in cross-postings or resends within a thread),  `bin/mbox_pre-parser.rb` will miss them -- that is where our simHash-based deduplication in `bin/contamination_guard.rb` provides the necessary safety net AT DATA CURATION TIME, NOT INGEST TIME.

We want to do this at data curation time (curation of the LoRA adapters), *not* at ingest time, because at ingest time, "bin/mbox_pre-parser.rb" has no semantic concept of email threads, and we *don't* wish to drop either of or both of two similar (Hamming distance) messages from *within* any thread because these messages, although appearing similar, may contain crucial amendments in a code-rich email (even by as little as a character, or a few characters).  Think of an email containing "My code is `printg "hello world"`", to which the response is "Typo dude. Use `printf "Hello world"`". 

To catch near-duplicates at curation time (which an exact examination will miss) *between* threads, not *within* threads will miss, the "bin/contamination_guard.rb" bakes in its own version of simhash.
- **Logic**: It generates a 64-bit fingerprint of message bodies and compares them using Hamming distance.
- **Sensitivity**: Controlled by `--threshold FLOAT` (default: 0.7). A lower threshold is more strict (requiring closer similarity to trigger a drop), while a higher threshold catches more distantly related variations.
- **Performance**: We are comparing a constant number of buckets in one set against a constant number of buckets in another set, thus the two numbers mulitplied by each other is O(constant), or O(1) time.

---

## Post-Materialization Audit

### Contamination Guard (`contamination_guard.rb`)
While the primary split logic relies on deterministic `thread_id` hashing to keep threads whole, to prevent cross-split leakage occuring via forwarded messages or boilerplate content. 

The `contamination_guard.rb` tool acts as a final audit gate:
1. **Methods**: It uses dual-fingerprinting:
   - **W-Shingling**: Measures Jaccard Similarity (set-based overlap of word triplets).
   - **SimHash**: Measures bit-wise Hamming distance between body content signatures.
2. **Detection**: It performs O(n²), or even O(n), comparisons across the materialized `train.jsonl`, `val.jsonl`, and `test.jsonl` files.
3. **Quarantine Policies**:
   - `quarantine_test` (default): Drops the test/val side of a contaminated pair.
   - `quarantine_both`: Completely removes contaminated IDs from the workflow.
   - `coassign`: Theoretically flags items for manual relocation (infrastructure dependent).
4. **Outputs**:
   - `contamination_report.json`: Detailed breakdown of every found link and similarity score.
   - `exclusions.txt`: A plain-text list of `record_id`s to be ignored by downstream trainers. Note : This file is **overwritten** on each run; cumulative lists must be managed manually.

