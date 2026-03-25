## What is a cohort?
A cohort is just a timestamped batch of rows within the manifest file "assignments.json", e.g. "2025-01" which tags all emails ingested in that period so we can freeze, and pin, and talk about the data that existed as of that particular cohort_id as to be considered within each split, for retrains and audits.

A cohort_id (e.g. 2025-01) is the stable tag for a cohort ; and a cohort is simply a group of emails that arrived during this bucketed time-interval, say, 1 month. Because the file "bin/splitter.rb" may be run weekly, or monthly, with `--materialize` and a cohort_id `--pin YYYY-MM` matching the month of the current date, "bin/splitter.rb" filters only the messages within the manifest file which have a cohort_id from the append-only manifest, which is less than or equal to the `--pin YYYY-MM` argument value passed to "bin/splitter.rb", whereby it ("bin/splitter.rb") writes these exclusively to a newly versioned "train.jsonl" monolithic file, a newly versioned "val.jsonl" file, and a newly versioned "test.jsonl".  The pin is a ceiling, not a floor.  Note that the `--pin YYYY-MM` argument to "bin/splitter.rb" references a cohort_id which got written to a JSONL shard file from "bin/mbox_pre-parser.rb".

A fixed cohort pin is the explicit cutoff tag (e.g. cohort_id=2025-01) that "test.jsonl", "val.jsonl", and "test.jsonl" are locked to ; so that, if I do a planned rollover yearly, and have no DSRs (data subject requests) within this time, my explicit cutoff might change several times per year at each planned bump and subsequent rematerialisation. This doesn't prevent us doing an ad-hoc retrain if drift gets too bad.  Drift is a distribution mismatch between what the model has as data we have already fitted, and what present traffic contains.

The shard files output from "bin/mbox_pre-parser.rb" are JSONL files, where each row is a single JSON object containing keys like cohort_id,mime_version, thread_id, internal_id, original_message_id, in_reply_to, references, has_attachments, parts, and email_body. The values of all these metadata keys (key-value pairs) have the type of value as string, with the exception of "has_attachments", which is a Boolean, and "attachments", which is an array containining the metadata pertaining to each of the attachments within this email, which are stored externally with a filename and with a unique_attachment_id.  Every leaf in the MIME tree is a "part".  An "attachment" is a specific kind of part : one where the Content-Type is not `text/*` and/or the Content-Disposition is `attachment` or `inline` with a filename.  The plain-text body is a part but it is not an attachment.  Multipart boundaries divide parts. `Content-Disposition + filename` distinguishes attachments from body content.  The Content-Disposition of a plain-text body is `inline` if this is present, or more commonly absent entirely.  The default RFC2183 is inline for text parts, which is how an email client renders those as the message body without prompting for a download. Only the `attachment` disposition triggers the "save file" behaviour. 

### To walk the MIME tree recursively. 

I want to extract all the attachments which are not email-bodies from an email into an array containing entries like 
```json 
{"Content-ID": "", "Content-Type": "", "Content-Disposition": "", "size_of_attachment": "", "filename_of_attachment": "", "unique_attachment_id": "" }
```
with a fallback to rfc822 technology for older non-MIME emails.

For each part:

* Check Content-Type: - if multipart/*, recurse into children using the boundary from the header. If message/rfc822, recurse into the nested message.
* Check Content-Disposition - if attachment or inline with a filename present, it's extractable.
* Pull the fields:
* Pre-MIME (RFC 822) emails are flat ASCII text - no MIME tree, no parts, no attachments. The fallback is literally "return empty array." Here's the combined approach:
```ruby
require 'mail'
require 'securerandom'

def extract_attachments(raw_email)
  mail = Mail.new(raw_email)

  # RFC 822 fallback: no MIME-Version header means flat text, no attachments possible
  unless mail.mime_type && mail.mime_type.start_with?('multipart')
    return []
  end

  attachments = []

  mail.all_parts.each do |part|
    next if part.content_type&.start_with?('multipart/')

    # Skip body text: text/* with no filename and disposition not 'attachment'
    ct = part.content_type&.split(';')&.first&.strip&.downcase || 'application/octet-stream'
    disp = part.content_disposition&.split(';')&.first&.strip&.downcase
    fname = part.filename

    next if ct.start_with?('text/') && fname.nil? && disp != 'attachment'

    cid = part.content_id&.gsub(/[<>]/, '')
    uid = cid || fname || SecureRandom.uuid

    attachments << {
      "Content-ID"          => cid,
      "Content-Type"        => ct,
      "Content-Disposition" => disp,
      "size_of_attachment"  => part.body.decoded.bytesize,
      "filename_of_attachment" => fname,
      "unique_attachment_id"   => uid
    }
  end

  attachments
end
```
The unless mime_type.start_with?('multipart') guard catches both pure RFC 822 messages AND single-part MIME messages (which also can't have attachments separate from the body). Everything pre-1993 falls through cleanly and we handle emails from after 1993 correctly.

Ruby's Mail gem gives you `mail.parts` for top-level, `part.content_type`, `part.filename`, `part.body.decoded`, `part.content_id`, `part.content_disposition`. Just iterate and collect. 

Content-ID is the only guaranteed unique value per RFC 2045. 

Content-ID is the lookup key you enter with, unique_attachment_id is the fallback resolution (Content-ID > filename > generated UUID).

## To continue talking about shard files and cohort-ids 
The pre-parser outputs **one row per email message**, not one row per thread or per chunk.  A 264-message thread becomes 264 separate JSONL rows (each with the same thread_id) potentially separated across shards purely by arrival order in the mbox, if, for example, there are already 800 messages within the current output shard at the point when this 264-message thread becomes processed.  Each shard has a maximum number of rows (each corresponding to an individual email message) which each can contain before another shard takes over as the output file.  This default limit is 1000 rows (emails) per shard.

The pre-parser outputs one JSONL row per email message (not per thread). If a 264-message thread's emails are broken across `part-00003.jsonl` and `part-00004.jsonl` by arrival order, `splitter.rb` reassembles the full thread via `thread_id` grouping into RAM before applying any windowing logic.

At what stage does the cohort_id get written into the output shard files from "bin/mbox_pre-parser.rb"?  Answer. At **ingest time**.  When "bin/mbox_pre-parser.rb" appends new rows, it stamps into them the cohort_id, which is of the format as YYYY-MM which is derived from the either: (1) the "Date:" field from within the email, or (2) `File.mtime(mbox_path).strftime('%Y-%m')`, i.e. the mbox modification time, which is the latest time this particular mbox was written to.  So, thus, this cohort_id is *not* derived from the "Received:" heading (which is within the email), but *can* be overwritten manually as the latest configured batch cutoff as specified by the command line argument `--cohort` to "mbox_pre-parser.rb" (which will override the cohort_id received from (1) or (2)).  This is good because it will avoid a race condition if the "Date:" is the last seconds of the month, but the "Received:" is a few minutes later.  We don't want the cohort to jump in this case, just to be pedantic. 

When "bin/mbox_pre-parser.rb" appends new rows, it also stamps into them the key as "received" with a value as a non-localised universal-time timestamp (which an example of the format is as "2025-01-15T09:30:00Z"), which is derived from the either: (1) the "Date:" field from within the email, (2) the value of the key as the "Received:" field from within the email, (this will be the first "Received:" field read, so the latest one if the email contains another email which this email is as a reply to, or the present email is as a forwarded email, which will contain the same), or (3) `File.mtime(mbox_path).utc.iso8601` (i.e. the mbox modification time, which is the latest time this particular mbox was written to).
We only need this "received" field as data to present to the user within RAG, *not* so that "bin/splitter.rb" can sort the messages within any given thread to become in order so that the LoRA training will experience them chronologically. Nor does the file a "bin/splitter.rb" utilize the `in_reply_to:` and `original_message_id:` from these shard files output at ingest time.  We need the `in_reply_to:` and `original_message_id:` fields in these shard files for KG : i.e. to use as metadata when constructing knowledge graphs. At **digest time** "bin/splitter.rb" groups threads by `thread-id:` and hashes for split assignment, then within windowed mode it sorts by `cohort_id` (YYYY-MM), which is month-granular, not of precise chronological order.

TO DO.  Implement `in_reply_to:` and `original_message_id` for later reference.

## What is a split?
A split is the role tag on each manifest row (train, val, or test) within "assignments.json" which controls which "split file" it materializes into ("train.jsonl", "val.jsonl", or "test.jsonl"), and how these splits become updated.

## What is a pin bump?
A pin bump is the deliberate advancing done to the cohort_id cutoff for train, val, and test (e.g. 2025-01 goes to 2025-07), which is automatically followed by a rematerialization done to all those splits to include the newer cohorts. The output from "bin/mbox_pre-parser.rb" (provided that the `--cohort` argument is not used, and therefore the cohort_id will be extrapolated from the "Received:" file within the email, *or* that the `--cohort` argument is used very judiciously) ought to include those newer emails into shard files located within its own sub-directory, potentially indicated by the name as a date (e.g. pre-parsed_emails/until_2025_02), and the subsequent `--pin` argument to "bin/splitter.rb" would be passed the value as `--pin 2025_02` with the `--input` argument as `--input pre-parsed_emails/until_2025_02`.  A pin bump *might* be followed by a rollover, or it might not. Just think. An email arriving within the month of July 2025 might be as a response to an email that previously arrived in January, and thus within the same email thread. Here `--input pre-parsed_emails/until_2025_02` will capture and include this latest email, and its metadata will be attributed to the correct split, and the correct thread, within the manifest file.  This is why we do not attribute a date range to the name of the subdirectory of our `--input` argument to "bin/mbox_pre-parser.rb" because this would be misleading to say `--input pre-parsed_emails/2025_07_to_2025_08`, as nothing would exclude the possibility that it contains a message in response to a January thread, or that the original email in January didn't arrive, by some strange technical problem, until the month of July.

## What is a rollover?
A planned rollover involves the flipping of a symlink.  This symlink may point to the actual model checkpoint (LoRA adapter) directory, which may reside, for example, at `current/releases/2025-01-15-clean` so that flipping the symlink would atomically switch from serving the old adapter to the newly trained DSR-clean one without changing any runtime configurations.

## What is a materialization?
Materialization is the process of extracting previously split data from the immutable manifest (the file "assignments.json") and writing the results to all of the files as "train.jsonl", "val.jsonl", and "test.jsonl".  This will happen automatically by the command as `splitter.rb --input pre-parsed_emails/until_2025_02 --pin 2025_02 --materialize`

## What is a retrain?
The difference between a retrain and materialization is that during a retrain we are actually retraining LoRA adapters to fit on top of an existing large language model, while a materialization is when the metadata files (train/val/test.jsonl) which the latest model reads, are deterministically rebuilt from our immutable manifest "assignments.json".  
 
Upon materialization, the data which is tombstoned in the "assignments.json" immutable manifest file simply does not get written into any of the new train/val/test.jsonl. We then may retrain the model from its base checkpoint by creating a new LoRA adaptor and refitting it : it is like painting a new canvas, as opposed to merely touching up the old one.  So, if I retrain the model using this newer train/val/test (with those tombstones), in practice the trained model *replaces* the previous adapter which was fitted upon the base model.  You don't layer adapters in order to forget things.  Instead, you swap in a freshly trained one that never saw the deleted rows in the first place.  Because we retrain when specific key performance indicators are breached (say, "max staleness"), or upon a fixed cadence (say, as a time period between every 6 to 12 months), then upon a receipt of a DSR deletion request, we may retrain upon whichever comes first: the breach of specific performance indicators, or this fixed cadence ; and hence we may fulfill legal or contractual obligations to have done so within the service level agreement, which may have stipulated a clause such like "the model is always up-to-date with data, such that the data it is trained upon is never older than 6 months, prior to the date of the present moment, and hence DSRs are always updated to this model (i.e. deleted from it) periodically every six months, or sooner". 

## What would happen if I bump the pin, and then receive a DSR deletion request for data which exists within a previous cohort_id?  
Would then, a `--materialize` option to "bin/splitter.rb" wipe its data out within these files as "train.jsonl", "val.jsonl", and "test.jsonl"?  Answer : Yes.

## Updates to "train.jsonl", "val.jsonl", and "test.jsonl" 
When you train with incoming newer data (emails), you ought to have materialized all three sets : "train.jsonl", "val.jsonl" and "test.jsonl" to absorb new emails from existing cohorts.  You will have bumped the pin and rematerialized.  You want all three splits (train, val, and test) from that same new cohort snapshot so that they are consistent.  Then you train on the new train, validate on the new val, and evaluate on the new test.  Mixing old and new splits would be messy data versioning.  This is prevented by default.  The newer sets will incorporate any DSR deletion requests as metadata which these DSRs have tombstoned within the manifest file, and will not become included within these newer jsonl sets which are output from "bin/splitter.rb".

There would be no point of a `--materialize train` as we ought not to retrain the LoRA adapters to fit atop the large language model without also rematerializing "val.jsonl" and "test.jsonl" to the same `--pin` value too. 

You may regenerate "train.jsonl", "val.json", and "test.jsonl" via updating the `--pin` argument to "bin/splitter.rb" while passing it (via `splitter.rb --input pre-parsed_emails/until_2025_03`) the pre-processed newer corpus of emails from the output from "bin/mbox_pre-parser.rb" from "pre-parsed-emails/until_2025_03" (which has just been processed after the newer corpus of emails have arrived).

TO DO.  Remove the possibility of --materialize train/val/test on their own from bin/splitter.rb

## What is spot-checking?  
Spot checking means opening a sample of these email_bodies to check that these emails are not just scrambled gibberish or full of technical junk that would confuse the LLM (large language model) during the training of the LoRA adapters which will be applied to, and sit atop, of it. In more technical language, spot checking is the process of verifying schema conformance, the encoding integrity, and the examination of tokenisation edge cases. 

## What is an epoch?
When training a model's LoRA adapter, an epoch is one full pass through "train.jsonl".  Mid-epoch means pausing part-way to evaluate against "val.jsonl" to check loss curves. 

## Ought anything newer be set for training LoRA without bumping the cohort pin?
No. Nothing newer ought to be allocated for training (to either train, val, or test) without bumping the cohort pin. When you *do* bump the pin, if your intention is to train LoRA you ought rematerialize **all three** (train/val/test) together to the same pin boundary so that distributions stay aligned, because otherwise, leaving "test.jsonl" at an older pin while training upon newer data would invalidate your final benchmark. Don't do this.

I have made it impossible to do this by default.

## What about updates to "train.jsonl", "val.jsonl", and "test.json"?
Here, updates are being made to this metadata, which may be including newer emails beyond that which the cohort pin which the existing model is already trained upon.  But we do this for the purposes of spot-checking, and for the purposes of Knowledge-Graphs (which requires windowing of emails within threads, whereas RAG does not).  We want RAG (retrieval augmentation generation), and KG (Knowledge-Graphs), to also pay attention to newer emails and DSR requests. They should be updated upon newer corpora of emails, but either be recreated upon DSR deletions, or have the visible data obfuscated, so that it won't become served. RAG is a later indexing system which we intend will utilize our LoRA adapter : the latest model which excludes the tombstones, and yet still retains good performance metrics.  Training is the training of the LoRA adapter itself, which requires a bump of the cohort pin and the rematerialisation of "train", "val", and "test".

KG requires the materialized set files (as these include windowing), but RAG does not.

If you are within the same cohort when a newer corpus of emails arrives (i.e. in the second week of January we can still use the cohort pin as 2025-01) you can materialize all three sets for the purposes of KG (without bumping the cohort pin to February).  But if the date is the 3rd week of February when the corpus arrives, I would recommend bumping the pin to 2005-02 (as an argument to "bin/splitter.rb") so as not to miss any emails that have been pre-processed also. 

## What if loss spikes (perplexity diverges upwards) mid-epoch?
Then Houston we have a problem.  So we do spot-checking to examine whether the issue is upstream data corruption (malformed headers, encoding rot), or hyperparameter misconfiguration, or genuine distribution drift from production traffic.

## Tell me about DSRs (Data Subject Requests)
DSR deletion requests *don't* get removed from the output files from "bin/mbox_pre-parser.rb" (the "part-00001.jsonl" files, etc), as that would add an extra layer of complexity, and also it would break our record of what data got pre-processed from the mbox at this stage, which is useful to retain for later analysis, as it will retain the data which the DSR may have deleted the metadata of, in the output from "bin/splitter.rb". Instead, we break immutability within our immutable manifest file, and jsonl set files (metadata output from "bin/splitter.rb"), upon DSRs alone, by marking this data as tombstoned within the manifest file, and omitting such tombstoned data from our jsonl set files (train/val/test). This is the tradeoff between our possible legal obligations to remove data, from the data sets (and also subsequently KG), and reproducibility, such that we will *not* retrain the model upon a user's "request to be forgotten", and we will *not* reference this individual within any RAG (retrieval augmentation system), which may subsequently use this model at inference time.  As RAG will not be using the output set files from "bin/splitter.rb", it must apply the same exclusion list filter that "bin/splitter.rb" uses, when recreating the embedded indexes within its vector database. Otherwise, upon a few DSR deletions, RAG may simply obfuscate the visible data served, as can KG too. It may be company policy of the enterprise which uses this software, to re-embed the indexes within the vector DB (database) for RAG, and also to recreate the KG from scratch upon every batch of DSRs upon a fixed cadence ; in addition to every retrain, and refitting, done to LoRA. I consider this to be a clean way in which to work : obfuscation of user data upon receipt of an individual DSR requests within a reasonable period of time, via a complete rebuild of RAG and KG, which will also be happening upon a retrain of LoRA happening upon a fixed cadence, say every 6 months, for example. There is nothing to stop you doing a complete rebuild of RAG, and KG, upon the latest pin bump, without a retrain to LoRA.

The training of each LoRA adapter will thus not be 100% reproducible, as we MUST NOT use the data in training for which a DSR deletion request has been enacted *after* this DSR request has been received. Thus we won't be able to retrain including it ; and thus we may wish to keep each LoRA adapter itself after it has become no longer in use for our records if this is deemed useful, though it might not be deemed useful, as, so I would be made aware, an AI LLM (artificially intelligent large language models) at inference time uses "temperature", which introduces randomness through weighted sampling ; and fixing this to zero, while keeping the seed, the hardware, and the batching, all constant, is too much of an advanced computer science project for an enterprise whose purpose is merely to read an archived mbox!

Note that DSR requests lead to quarantined messages at the level of metadata. This metadata becomes marked as tombstoned within the manifest file, and omitted from a rematerialisation of the pools/sets. This process of quarantining has nothing to do with deduplication of messages, which happens at ingest stage ; as the output shard files from "bin/mbox_pre-parser.rb" have no concept of sets, and so this deduplication of identical email messages, which happens at the ingest stage, will have the consequence as that both between, and within, threads, no duplication of identical messages will happen at digest time, or later. Nor does the quarantining of email messages due to DSR requests have anything to do with the removal of messages which contain attachments : the detachment of which happens at ingest stage ("bin/mbox_pre-parser.rb") if the email does have an attachment. Neither does DSR quarantining have anything to do with what we are doing at ingest time to drop excessively long emails, so that the training done to LoRA won't learn to produce cut-off replies.  Neither does this quarantining due to DSR requests have anything to do with fuzzy dedupe done at pre-LoRA training time, which checks for contamination of email-body content between threads, and hence between sets.  Fuzzy dedupe happens at the time of just prior than the training of the LoRA adapter, not at ingest time (mbox_pre-parser.rb), nor at digest time (splitter.rb).

TO DO.  implement this detachment of email attachments at ingest stage (bin/mbox_pre-parser.rb).

## What about Data Subject Requests (DSRs)?
When a DSR request comes in, we may tombstone the data in the immutable manifest file ("assignments.json"), and later trigger a clean rematerialization (after bumping the pin).  Pin bumps are an explicit operational decision (e.g. a "roll forward" event), and not something that happens automatically as part of a deletion request.  Recall that the cohort_id is of the format as "YYYY-MM", and this metadata, within "assignments.json" (the immutable manifest) may be selected vis the `--pin` argument of "bin/splitter.rb".

The file as "bin/splitter.rb" is the CLI (command line interface) we should invoke to rematerialize all three splits from the immutable manifest (e.g. `splitter.rb --pin 2025-07 --materialize`), which should trigger a clean rematerialization of "train.jsonl" and "val.jsonl" and "test.jsonl", including all cohorts prior to that particular date, excluding tombstoned rows ; and thus will rematerialize train/val/test using only cohorts with cohort_id <= 2025-07, and which won't include newer cohorts than this date, and which won't change the pre-existing composition of what already got put into train, val, and test, beyond DSR effects, but may update "train", "val", and "test", up to and including emails received at 2025-07-31 23:59.

## How does my split data grow?
If I do a `splitter.rb --pin 2025-01 --materialize`, and a year later I do a `splitter.rb --pin 2026-01 --materialize`, then the possibility exists that a new thread from 2025-04 may enter "train.jsonl", "test.jsonl" or "val.jsonl", as we are specifically expanding the "Time Horizon" to include everything up to that new date ; whereby the April 2025 thread transitions from being an "ignored future data" (in the 2025 context) to being "eligible historical data" (in the 2026 context), and will enter the lottery as to where it lands based upon its hash, and your split ratio.

## What is the `--materialize` to "bin/splitter.rb", without bumping the pin, ever used for in practice? 
Answer. If you are wishing to retrain LoRA within the same month, without bumping the pin, then I think of this as a viable use case, but this seems to me to be an expensive way of working by retraining so soon. When later-arriving emails arrive within your current pin's cohort ceiling, without the pin being bumped, this will refresh all three pools as "train.jsonl", "val.jsonl", and "test.jsonl", which will be regenerated.  This expensive use case, may well be that we want the newer emails within existing threads to receive the latest email updates to them, for training.  If you do this, this will occur. Generalisation is the ability to say that the model has not merely memorized and regurgitated verbatim the patterns (grammar, intent structure, reasoning) from "train.jsonl", and this assists towards that end, and more data means that the model has a better ability to make generalisations. Later arrivals, within an existing cohort, each arriving in their deterministic destination within one of these sets/pools, gives us the option to retrain the LoRA adapters, at a later time (in this use-case sooner rather than later), upon a specific cohort pin (which here hasn't changed), with their inclusion implied, in order to improve the model's quality, within that existing time boundary. A pin bump is needed when you want to to shift the model's knowledge horizon into a new time period beyond the current pin bump.

What will also occur, is that potentially later, but newer conversational threads than those which the previous pin inferred (with newer email thread ids), will go into the manifest by our train/val/test probability split of 80/10/10 ; and those newer conversations, which ended up in exclusively one of those sets/pools, will become included within the ".jsonl" files output from "bin/splitter.rb", when it eventually becomes rematerialized.  How is this useful?   
 
Whereas RAG involves the model having data from the shard files (output from "bin/mbox_pre-parser.rb"), KG (Knowledge-Graphs) require us to have *windowed* metadata from all three sets/pools (which are output from "bin/splitter.rb"). We may want to have the latest data included (with or without a retraining done to LoRA).  RAG (not training/evaluation of the LoRA adapter) receives its metadata, and the email content, which the RAG database is trained upon, from the shard files which have been output from "bin/mbox_pre-parser.rb". This will confer the attachments to be associated with the email's metadata, such that, for RAG, a semantic similarity search of the email body's embedded text chunks will link back to this metadata, which contains the email message's `internal_id`, whereby any email attachment's filename, mime type, size, and storage path will be retrieved also.  You don't need to *embed* something to find it; you just need it to be associated with something that *is* embedded. On the other hand, KG will read the **pool/set** files in order to establish the windowing required for Knowledge-Graph creation ; the other associated metadata for KG (including the metadata for attachments) will be read from the shard files.  This means that we can make the set files output from "bin/splitter.rb" super-skinny, whereby they only contain the metadata necessary for windowing, and nothing more.  This is in obedience to the DRY (don't repeat yourself) principle of data in general.  KG does *not* contain the email bodies.  The email bodies are reserved for RAG, and a semantic search, as well as to be use during a retrain done to LoRA. 

With "bin/splitter.rb", if you had `--input emails/until_end_of_2025-08`, but you *didn't* update the pin from `--pin 2025-07` to `--pin 2025-08`, then this will filter in any late arriving emails from prior to the month of August, which have now arrived during the month of August, supposing that those emails from July got lost in transit, and weren't transmitted to the destination until August.  This isn't a very useful use case though.  What is more common is to update the pin to `--pin 2025-08` at the same time.  Before the month of September, however, we can run `bin/mbox_pre-parser.rb` without bumping the pin, in order to furnish KG with the latest weekly quotient (with the latest DSRs removed) for a complete rebuild of the KG, while the calendar month of September has not yet arrived! Be careful to put your email corpora into recognisable directories, such as "emails/until_2025_08-07", "emails/until_2025_08-14", "emails/until_2025_08-21", and "emails/until_2025_08-31"

## Would running `splitter --materialize` to include recently arrived emails for training the LoRA adapters, break reproducibility? 
Do you mean the reproducibility of creating the trained LoRA adapters?  If so, then the answer is yes, because they are never reproducible, due to the fact that the data we are curating upon is a dynamically updating target.  Thus we lose reproducibility of recreating any LoRA adapter, i.e. you are non-forensically putting more metadata into your pools/sets, which reference real newly arriving email data shard files (output from "bin/pre-parser.rb"). Also `splitter --materialize` can always break reproducibility, because of independently arriving DSR tombstones within the manifest file.  We *must not* retrain *after* these are received, whereby the latest `splitter --materialize` will have removed these from our pools/sets. The point being, that as soon as you issue a `splitter --materialize`, you *will* lose reproducibility. In addition to these considerations, consider this.  Can you guarantee that all of your hyperparameters are constant, and that the implementation details of the hardware you are training on is the same? The point of an AI is that it is supposed to appear pseudo-intelligent, of course, so should you really be thinking of it like a chemistry experiment?  Ought you really be thinking of AI training to be as an example of deterministic programming?
 
## If the pin is bumped to 2025-06, and we have rematerialized all the pre-processed emails up to, and including, the emails by 2025-06, but *don't* retrain the LoRA adapter until 2025-08, then will the LoRA adapter trained in August still be useful after the bump in June?
Apart from this delay being a funny way to work, DSRs received in July will not yet have resulted in their corresponding rows vanishing from the pools/sets, because the latest DSR tombstones within the manifest won't have become omitted from the latest versions of "train.jsonl", "val.jsonl" or "test.jsonl".  So the answer is : in practice, you will have forgotten to remove the DSRs from the pools/sets, plus you will have not included the corpora of emails between the moment when the pin bump was resulting into such materialization of metadata from the manifest file, and a time just before the training time in August.

## Tell me again. Won't DSR tombstones break reproducibility?  
Answer. Yes, deliberately. That is the legal tradeoff.  You *cannot*, and *must not*, reproduce data a person exercised their GDPR right to erase, but you still preserve *attestation* : this being an auditable record of what had been removed from "train.jsonl", "val.jsonl", and "test.jsonl", at training time, in a tombstone log showing what was removed and when.  So your audit trail becomes, "This particular LoRA (reference name) was trained after DSR removed X, Y, Z". 

## How does splitter.rb start out?
For the first full cut from "bin/mbox_pre-parser.rb", we run something like `bin/splitter.rb --input /mbox_pre-parsed/until_end_of_2025-01/name_of_mbox ---output metadata --pin 2025-01 --materialize`, to deterministically assign email threads and emit "train.jsonl", "val.jsonl", and "test.jsonl", for training under that initial pin.  The `--pin` argument is something which is set when the script is invoked, i.e. if all my emails, thus far, are earlier than the end of 2025-01, then 2025-01 will do it.
 
We could retrain our LoRA on a shorter cadence, say at the beginning of every month, whereby we can materialize the pools/sets (after pre-processing at ingest time) at the start of each month, after bumping the pin ; or we could retrain it upon a longer cadence, say, every 6 months, or 12 months, (or sooner if **drift**, or the **exclusion-backlog**, shows that our LoRA adapter which sits atop an existing LLM is getting stale), while we pre-parse the latest corpus weekly (at digest time) for RAG, and KG, while keeping the pin as 2025-01, until the calendar month is the month of February within the real world..

## Is there any point to a `splitter.rb --materialize` without a subsequent retrain of the model?
Yes.  This is done so that KG will have an updated data source, with all the latest DSR removed, with all the latest emails from the latest corpora, for regeneration of the KG from scratch.

This process also may validate that latest arriving emails have landed correctly, but you could always, preferably, determine that the latest corpus of emails have landed correctly by examing the tail of the latest shard file output during ingestion, which would additionally allow you to perform inspection of the email bodies, and would also facilitate the updating to RAG.  You *can* rematerialize to audit row counts (in which case you would be examining all three "train.jsonl", "val.jsonl", and "test.jsonl") *after* these emails from the newer cohort have been ingested, but to spot-check data quality (encoding errors, schema conformance) the email body is required, not "skinny" metadata only files. It would make more sense though to audit row counts via the inspection of the latest shard file, output from "bin/mbox_pre-parser.rb" during ingestion. 

This `splitter.rb --materialize` makes "train.jsonl" to be now at a stage which is before that of training the model (the LoRA adapters), as will "val.jsonl" and "test.jsonl" be.  This training of the model may now be scheduled for an overnight retrain, without burning GPU hours the moment when the emails arrive.  Monitoring the growth of the row count from "train.jsonl", "val.jsonl', and "test.jsonl", for example, allows us to quantify exactly how much new information (emails) have arrived, and accumulated, before we decide it is time to incur the expense and electricity cost of a fresh training run done to the model, but you can count rows at ingest stage without requiring any digest stage at all : but if you *do* audit this way, remember that the digest stage *is* required to be run before the later stages, and don't forget to run it before pre-LoRA, and LoRA training.

## What is drift?
Drift is the gap that opens when the distribution or meaning of data coming in shifts away from what the model was trained/evaluated upon. Think of "data drift" as something that happens when the data being input changes. For instance, if, on a professional mailing list for dental surgeons, a lot of emails arrive talking about fluffy dogs, then this is "data shift" because the vocabulary has shifted.

"Concept drift" is when the underlying relationships between inputs being fed into the model, and outputs from the model, changes over time, i.e. if the input concept, such as "this is a complaint", changes to something like "this is feedback", then the "concept drift" happens where the model is still thinking that it is the former, when it should be the latter.  To further elaborate upon this, if customers yesterday complained by saying "This is broken", but today complain by sarcastically saying "This is great! Great job team!", then the concept within the identification of "complaint" would have changed.

In short, drift is a distribution mismatch between what the model has as data we have already fitted, and thus measure against, and what real traffic contains.

## What would "label drift" prior to training be?
"Label drift" is when the class mix of emails changes : that is, the proportion of each type of email in our data changes. For instance, if on a professional mailing list for dental surgeons, a lot of emails arrive talking about fluffy dogs then a *human* may label this email as "superfluous" *before* training, at the labelling stage, in order to audit the annotation pipeline carefully. "Label drift" happens when this mix of labels changes, i.e. when the label as "superfluous" suddenly jumps from 2% to 15%. 

Can I automate the decision of labelling in response to the content of the reply to these messages about fluffy dogs on the dental surgeons' mailing list? For example, if the reply was "Please keep subject matters relevant to the topic of this list.", then is there any way to automate the process of labelling these messages as "superfluous" based upon the content of the mailing list?  Answer.  Yes. That is called "weak supervision", or "distant supervision".  You could write heuristics, that pattern-match reply content, to automatically generate labels like "superfluous".  Tools like Snorkel formalize this by combining multiple noisy labelling functions into probabilistic labels : trading annotation precision for massive scaling without hiring an army of human taggers, whereby you write "Labelling Functions" (mini-scripts like regexes, heuristics, or small LLM models, which either propose a label, or abstain from doing so), which cast "votes" in order to make these decisions. A "Label Model" mathematically learns which "Labelling Functions" are reliable and which are noisy, and then merges their votes into a single high-quality probabilistic label for every row.

The reason why, for our AI training, it is probably *not* a good idea to have any labelling at all, is because we would be confusing the content, and style, of the email bodies, with these extra generated labels.  Would these labels be considered metadata?  If so, this *might* be utilisable within semantic RAG searches, but would not really be useful, I say, in training the LoRA adapter, because LoRA learns the language and style from the content of the email bodies.  I say, this content ought not be sullied with labels put into the Alpaca format we are feeding in to LoRA training.

Another reason why, within our particular codebase in mboxMinerva, as a coding decision, it s *not* a good idea to make labels on the data, prior to training LoRA adapters for the LLM, is because *if* the labels are computed dynamically at either ingest, or digest, time, then reproducibility would break, because the labels may change several times within one cohort even, or over the space of several cohorts also : later data (emails arriving and being processed) may change the "votes" cast by earlier data.  For example, if the response to the first email about fluffy cats on the dental surgeons' mailing list was "Yeah, yeah. Roll over, Beethoven.", the model might not pick up upon the implication that the fluffy cats were "superflous", and might list the email as "relevant", but the second message might be "Please stop spamming this list.", at which point the model might realise the truth.  This particular reason why labelling is problematic is equally applicable to its use in RAG.  The brittleness of our labels as metadata, might break due to label drift in the future, in which case we would have to rebuild our metadata choosing what?  The first label, or the second label, as a paradigm? Therefore to keep the RAG implementation simple and pure we ought not bother with labelling at all. 

So, because reproducibility would be broken, it would not be feasible to stamp a record of these labels into the manifest, even for RAG. We ought to be keeping the manifest purely structural. Neither ought we defer labelling to a stage of metadata creation by an AI inference prior to RAG chunking, embedding, and indexing, nor Knowledge-Graph creation, because do we really need these labels? And how far in advance (how many years into the future of email body contents) will the AI inference be able to look?  Not many, as its memory may run out.  Look. The RAG is a semantic search of email body contents.  Therefore adding labels to the metadata makes things brittle, because it assumes we can summarize our email into a label content in the first place.  This is like a tag on an image, or a video, of a post, from the old days, in an attempt to facilitate a search function to find these tags.  We are instead, to use the latest technology of having the meaning of text semantically embedded within vector database. Therefore we don't need these "labels" as metadata.  Therefore, we can forget the idea of letting classification logic (the code/prompts/rules of this "weak supervision") live in a separate independently versioned RAG layer within (or potentially outside of) the mboxMinerva git repo.  We now no longer need to bother worrying about code which will let us debug, test, and rollback to known good versions of these heuristics, if a new heuristic misfires.  Keeping the project simple here, is not only going to be more efficient to the performance of the project, but it is also a way to avoid an over-complicated headache, and it seems to be just the correct way to do this data curation.

## What is exclusion-backlog?
Exclusion-backlog is simply the growing pile of new emails that the most recent LoRA adapter currently in use, has not yet been trained upon under the current pin.  We measure it as a count, and as a percentage of, recently received email data that is out-of-scope for train/val/test under the current pin, and once that count or percentage passes a threshold, this is our cue to potentially bump the pin, and rematerialize, and train LoRA, depending upon your organisation's operational decision-making, and policy decisions.

## What about automatic notifications and included advice?
We can bake in email and Slack/webhooks, so that when exclusion-backlog or drift indicators cross a configurable threshold, the admin gets a message that:

- (a) shows the current stats, 
- (b) states which key performance area this indicator pertains to, 
- (c) recommends a definite action, such as "time to bump the pin", or "time to schedule a retrain on cohorts less than or equal to a specific PIN", or "tighten contamination thresholds for these cohorts".  

To wire it into your repo, edit `config/alerts.yml` with your SMTP/Slack URLs, and schedule via cron (`0 9 * * 1`) or GitLab pipeline schedules, (e.g. when exclusion-backlog hits 15% it'll tell you "do bump the pin to 2025-04 and schedule a training of LoRA to replace the existing LoRA adapter", or when contamination crosses 1% it will recommend "do tighten contamination thresholds", or when tombstones pile up past 100 it nudges you toward a retrain of LoRA).

TO DO. Store state about exlusion backlog + other similar stats on backend (host).

## Why does mbox_pre-parser.rb output shard files?
Notice that "bin/splitter.rb" has an input argument `-i DIR`, which is not specifically a single output file from "bin/mbox_pre-parser.rb".  This is intentional, as instead of a single file, "bin/splitter.rb" walks over all the sharded pre-parsed files in that directory (the outputs from "mbox_pre-parser.rb"), so that it can deterministically assign whole threads to splits across the full range of data in one pass.  Shards are non-overlapping.  

"bin/mbox_pre-parser.rb" walks messages in order and assigns each one to exactly one part-XXXXX.jsonl file, so that together the shards are just a clean partition of the body of emails, rather than containing overlapping copies of each other.  Note that for simplicity, and downstream tooling for the training of LoRA, the outputs from "bin/splitter.rb" are materialized as single flat files as "train.jsonl", "val.jsonl", and "test.jsonl", as these contain metadata only, and are quite "skinny", and thus require inexpensive disk I/O (input/output) on a modern solid state drive, and interface.  The costly work is the parsing of MBOX files during pre-processing, and the tokenizing of email bodies during training of LoRA.

"bin/mbox_pre-parser.rb" defaults to writing JSONL files (e.g. "emails/part-00001.jsonl"), unless you override it with the `--output` flag, which then collapses everything into a pretty-printed JSON array.  Instead, if it had been designed differently, it may have defaulted to only one output file per execution.  This is not, however, the case.

Recall that "bin/mbox_pre-parser.rb" is being called upon a raw MBOX. Raw mboxes are often one huge file per list history so far, or per month, or per week.  The pre-parser converts the physical MBOX into logical JSONL Rows. A **Logical Row** is the *atom* (one single email or thread entry), while a **Shard** is the *bucket* (the actual .jsonl file holding thousands of those atoms).  The pre-parser outputs shards so that the downstream tools (which are invoked at training time) can process data in parallel chunks instead of choking upon one massive 50GB file.

In our code base there is no ruby file that chops "train.jsonl" into shards ; "bin/splitter.rb" merely produces one flat "train.jsonl" file for KG, and the actual "sharding", in LoRA training, happens later inside the training stack's data loader (e.g. the finetune script, / vLLM or PyTorch+DeepSpeed job that reads the Alpaca data structures from pre-LoRA training time, and can automatically segregate and allocate each Alpaca training data the across workers at LoRA training time).

## When are my unique thread_id's created?  
These are created by "bin/mbox_pre-parser.rb" ; then, later, "bin/splitter.rb" assigns one deterministic split from these thread ids, and annotates the window_idx, and the window_range, for that thread.

## What is meant by "windows of a thread"?
When a thread has 50 messages, but you set `--window-size 20 --window-overlap 5`, "bin/splitter.rb" chunks these messages into overlapping sliding windows (e.g. messages 0-19, then 15-34, the 30-49), such that each training example/chunk stays within a manageable context length, overlapping with other chunks.  Note that we are dealing with, and referencing, metadata here only. The purpose of doing this, is to provide overlapping context between chunks of data passed to the process of training LoRA.  The critical design is that ***all*** of these windows inherit the ***same*** split from their parent thread_id, in order to prevent data leakage ; i.e. if window 0 lands in "test", then window 1 cannot sneak into "train", because this would contaminate the training, and evaluation, of the LoRA adapter.  The context of the conversation within any email thread will ***not*** be shared!

## What is a sliding window?
In "bin/splitter.rb" when --window-size is enabled, ***all*** windows of a thread inherit the ***same*** deterministic split into either "train", "val", or "test" ; and when omitted, "bin/splitter.rb" assigns the **entire thread** as a single manifest entry.  In both cases, this infers that the **entire thread** (i.e. the entire conversation) lands deterministically, and atomically, with a probability of ~80% in train, ~10% in val, and ~10% in test.  

The `--window-size N` option is specifically about chunking long threads into overlapping segments for training, whereby each chunk gets a manifest entry keyed by `manifest[window_id]`, where `window_id = "#{thread_id}_window_#{window_idx}"` such that 
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
    end
```
where the `'window_range' => [pos, window_end -1]` value pair, records exactly which slice of messages went into that window.  But only windowed threads get this notation.  Bare threads do not get this range metadata.

## What is the window_idx for a thread?
It is the zero-based index of a sliding window chunk, which occurs when `--window-size N` splits a long thread into overlapping segments.

## What is the window_range for a thread?
It is the `[start_pos, end_pos]` tuple which is stored within each manifest row, showing exactly which message indices from the original thread are included within that window chunk ; e.g. `window_range: [0,19]` means messages 0-19, and `window_range: [15, 34]` will be the next overlapping chunk if overlap=5, window_size=20.

## Explain `--window-overlap M` option to "splitter.rb"
This is the number of messages shared between consecutive windows.  It ensures that each window has leading context from the previous one, preventing "cold start" at window boundaries, during KG creation, whereby the KG retrievel may otherwise see disconnected metadata mid-stream,  with no preceding step to connect this metadata. This is important and relevant for KG, because without overlap during creation, each window would start "cold" mid-data, and in this situation, KG would not learn to connect all its edges ; it would be created upon disconnected fragments.  The overlap gives each window a "warm-up runway" of prior messages, so that KG learns the actual data relationships you care about (i.e. how *this* reply was to that *that* post), instead of missing significant metadata.

## What would a "Rolling Retention Policy" be?
A **Rolling Retention Policy** would tell the splitter to filter by data freshness, and to ignore data older than `N` days/months/years relative to the pin, ensuring that your model trains only on relevant, recent patterns, and isn't going to be trained upon ancient, drifted history : drifted, because the "ground truth" changes as the world evolves ; vocabulary shifts (new slang evolves, old terms become deprecated), spammers use newer tactics to evade filters, and crucially, the structure of business data within an organisational structure might change, (e.g. a "purchase order" from 2018 might look completely different than one from 2025), meaning that patterns from very old data might mislead the model about today's reality.  

## Why we *don't* use a "Rolling Retention Policy"?
Because:
- 1. It would totally break the guarantee of append-only immutability.  Although no rows would subsequently disappear from our immutable manifest, we are saying that these rows would subsequently become barred from being read, after they had timed out, when a `--materialize` option to "bin/splitter.rb" became invoked.
- 2. Sometimes the stale data would be perfect for making generalisations from.  Older does not always necessarily mean that it should be treated as obsolete. That is a truism.

## What is "Lookback Horizon" for data curation?
It is how many months/cohorts of historical data you include in your training corpus. Within our project we include *all* of it, prior to a specified pin (except for DSR requests).  It shapes *what* the model learns.

## What is "Lookback Horizon" for the training of the model?
A "Lookback Horizon" in this context is a model, or inference-time, configuration set in your training.  It is ***not*** within the data pipeline.  It is a concept pertaining to model inference specifically dealing with how far back the model's attention span reaches.  It is how much preceding context you feed the model when training it to predict the next token/response.  

## What is "Lookback Horizon" for the vLLM?
At inference time, lookback horizon is how much of the conversation history (system prompt + user messages + assistant replies), so far, the vLLM keeps within the key-value cache when generating the next token. The lookback horizon is bounded by the "context window length" (e.g. 8k tokens).

## What is "context window length" for the vLLM?
This is how many tokens the model can see in a single forward pass at inference time (e.g. 8k or 128k tokens of conversation). It shapes *how much* input it can reason over at any moment. 

## What is "context window length" during training?
Each of the sequences of tokenized text fed into LoRA at training time can be at most "context-length" tokens.

## Explain how the "Lookback Horizon" for the vLLM is bounded by the "context window length" (both at inference time)
The "context window length" is a physical hard bound baked into the model architecture at pre-training time (it **cannot** exceed 8192 tokens on an 8k model at all).  The "Lookback Horizon" for the vLLM is your optional choice *within* that ceiling.  You might choose to only feed in 2k tokens of history even though 8k is available ; but you can never *exceed* the architectural limit.  A token equals approximatelly 0.75 words.

## What are thread segments?
MBOX files are just dumb records, as flat lists of emails, stored in the order of their arrival, which can often be an interleaved order of arrival, and contain duplicates. An mbox has no inherent concept of "threads", or "token windows". 

The `mbox_pre-parser.rb` can, and often does, chop a long email thread into multiple segments to fit context limits : which are ceilings upon the amount of information (measured in "tokens" : a token being roughly 0.75 words) an llm can hold in its "short-term memory" instantaneously (e.g. 4,096 or 8,192 tokens).  

If a thread exceeds this limit, then the pre-parser will chop it into smaller "segments", to feed in to the llm, otherwise the llm effectively crashes or truncates the overflow.  This is also called "chunking", or "windowing".

## What happens if a malicious user sends one email with 50,000 words in it (possibly garbage) in order to attempt to cause the Lookback Horizon, for the training of the model, to exceed the 8192 tokens, which was the limit of the Lookback Horizon (also called the "context window length"), baked into the model?
This is an astute observational concern, as `--window-size` counts *messages*, not tokens, so a single email with 50k-words (~ 37k tokens) is just "1 message" to splitter.rb, and would cause truncation to 8192 tokens happening downstream at tokenization time.  So to avoid truncation at training time due to a malicious user sending excessively large messages to the mailing list, there exists a token/char limit to each email within `mbox_pre-parser.rb` to reject absurdly long single messages, before they even hit the output from "bin/mbox_pre-parser.rb" (and thus subsequently the manifest).  Doing this at ingest time will also have the added benefit whereby we are protecting RAG from these absurdly long email body lengths too, as, as they never hit the shard files, RAG never sees them. Neither will KG creation see them, as they would *not* be within the input for "bin/splitter.rb" to output.

## Don't suddenly change your splitter seed or configured ratio! 
"bin/splitter.rb" groups by thread_id, and always hashes with a deterministic seed, to assign train/val/test (80/10/10) to the immutable manifest, writing immutably to "assignments.json".  To say this again, "bin/splitter.rb" assigns per-thread splits using a deterministic hash (seeded) to hit a fixed ratio, so that the inputs always map to the same split in the immutable manifest, unless you change the seed, or configured ratio, which you ***must not*** do midstream because this would invalidate previous assignments ; and if you ***do*** do this then you ***MUST*** recreate the **whole** manifest again and then materialize it (!) effectively wiping the slate clean. 

## Does "bin/splitter.rb" prevent any context leakage across train/val/test?
Yes!!!

## Does "bin/splitter.rb" append to the manifest file *and* recreate the train/val/test JSONL set files?
Yes.

## Won't the appending to the whole manifest file every time a new batch/corpus of emails arrives be costly in terms of processing and disk I/O?
In practice, no. This is because the manifest is just metadata (thread_id, split, cohort_id), not email bodies, so even a million threads is maybe 50-100MB of JSON, which can be appended to quickly.  Even the rewriting to the train/val/test JSONL files will happen quite quickly upon a modern disk. The costly work is the parsing of mbox files, and tokenizing bodies, the latter of which dwarfs the manifest I/O by orders of magnitude. 

## Do the train/val/test JSONL files contain the actual email body as well as the same metadata that the manifest file contains?
No. They are "skinny".  These files contain exactly the same metadata fields than the manifest do, but *do not* contain the email bodies.  These files serve to window for your KG to then look up the actual content from RAG.  The raw shards are exactly the same `.jsonl` files which are/were generated by "bin/mbox_pre-parser.rb", which contain the actual email-bodies and metadata. "train.jsonl" is just a bunch of metadata from those shard files, and the same can be said of "val.jsonl" and "test.jsonl".

## The emails' encoding
"bin/mbox_pre-parser.rb" opens the mbox as a read binary. After parsing the inbox to get an array of individual raw emails, and after detaching the attachments for later RAG reference and retrieval, after after extracting the Message-ID, then, for each message, it checks whether the field as `Content-Type: charset` is present within each message, reading the message in the charset specified if it is ; and if this charset field is not present within the email message, we auto-detect the encoding of this email using the `charlock_holmes` gem, whereas if `charlock_holmes` chokes, we assume that the email body is written in UTF-8, in which case we also proceed by replacing unrepresentable bytes with "?".  Otherwise, if we don't do any of this character-set detection, the ruby programming language (which this project is written in) may treat strings within the email as raw bytes (ASCII-8BIT), but JSON (the format within the shard files gets written into) needs valid UTF-8.

If the pre-parser splits a long thread into seperate output shard file, then the fact that the pre-parser, at ingest time, has split this long email thread into separate shard files, means that "bin/mbox_pre-parser.rb" has simply sliced the flat array of raw email messages, held in RAM (random access memory), every 1000 entries (or whatever your `--shard-size M` option is).   

## What is the field as "internal_id" within the output files from "bin/mbox_pre-parser.rb"?
It is a collision-proof SHA256 hash of the `Message-ID` plus the email body hash, serving as a unique primary key to deduplicate exact content matches, while tracking different versions of the same Message-ID. This means that within an historical inbox of many emails spanning decades, although RFC 2822 says that email Message-IDs should be globally unique, we are protecting ourselves in case two separate email_message body contents arrive (potentially decades apart), with the same Message-ID (a collision) : in which case, the internal_ids would be different, and we don't reject these messages from either RAG, or training LoRA, and we use this internal_id as metadata in training LoRA ; but we *will*, at ingest time, reject exact duplications of the same email (which will have the same internal_id, as the hash of the : Message-ID concatenated with the email body, will be identical).

## Omitting --window-size N
Because the physical fragmentation from the pre-parser is invisible to the splitting logic, if the `--window-size N` option to `splitter.rb` is omitted, "splitter.rb" treats each thread as an atomic unit.  

Because bare threads do not involve a window_id, each email from a thread all carry the same `thread_id`, and the splitter treats those multiple rows singly logically, forcing them all into the same bucket (train/val/test) within the manifest, such you don't fracture the conversation between "train", "val" and "test".  In this case (whereby --window-size is omitted), "bin/splitter.rb" does:
```ruby
emails.group_by { |e| e['thread_id'] }
```
*after* loading all shard files into a single flat "emails" array ; and this intentionally reads, but does not preserve, any fragmented sharding from the pre-parser, as far as the processing within "bin/splitter.rb" is concerned, thus ensuring that you always can subsequently window (the verb is "to window") over the full, reassembled conversation.  So even if `--window-size N` is omitted to "bin/splitter.rb", the entire conversation within a thread (all messages sharing a particular "thread_id") lands within a single manifest set, and materializes into one split file (e.g. "train.jsonl"), as "bin/splitter.rb" *does* treat each thread as an atomic unit.  This is the default behaviour.

Note that even if the pre-parser sharded a long thread across multiple output files (e.g., `part-00001.jsonl`, `part-00002.jsonl`) for I/O efficiency when training LoRA, "/bin/splitter.rb" reassembles all messages sharing the same `thread_id` before assignment. Pre-parser sharding is purely a file-size concern.

### When to omit `--window-size N`

Although this is not recommended, in general, for larger MBOXes, it is possible when:

- Threads are short enough to obviate the need for continuity between windows in the creation of the Knowledge-Graph of "who said what, and when, to whom, pertaining to what subject title, and within what thread, with what attachments", or when a KG is not going to be created and used.
- Simplicity is preferred over windowing.

LoRA is trained via the Alpaca format produced from email-bodies from the shard files within the windows of the threads. The windowing, wouldn't happen to solve the "context window problem", whereby very long emails would exceed this context limit, because each Alpaca sample is already one email plus its reply history, not anything to do with a window containing several (shorter) emails.  So here, windowing the threads buys us nothing for LoRA, and would be harmful (see next paragraph). In fact, at the stage of pre-LoRA training, the data looked at, and examined, is from the email-bodies from the shard files, which were output from "bin/mbox_pre-parser.rb" : which has no concept of windows ; and even the thread_id, and the in-reply-to, metadata fields, are not passed to Alpaca : which must be fed with semantic concept, such as what text was a reply to what part of the previous email.  This way of working greatly simplifies things for LoRA training, as, for LoRA training, we don't need to worry about determining what window-size is optimal for an 8k context window, so I don't need to involve myself with producing some frequency distributions of various email lengths, and examining the cumulative probability distribution of various window-size exceeding the context window of 8k.  

If I *were* to embed two successive windows of size thirty emails, with a window overlap of, say, five emails, within the Alpaca data structures for training LoRA, then ***all*** the Alpaca data structures from these overlapping five emails will be repeated to the LoRA training.  This would be harmful to LoRA training, as the duplication of these samples would be an example of overfitting.  The model would see those five email patterns multiple times per epoch, weighting them disproportionately.  LoRA's small parameter space would multiply the effects of this overfitting risk, rather than teaching the model the underlying pattern.  We are seeking to avoid teaching the model to memorize specific Gestalt replies, and we are seeking to avoid the model learning how to create plausible sounding text within a vacuum. To disable overlap for the LoRA training is what we do by examining the shard files, instead of the skinny metadata files output from "bin/splitter.rb" : which will be needed in order to use these window overlaps for continuity in the creation of Knowledge-Graph.  The window overlaps will NOT be used for RAG either, as these windows will not be needed for RAG chunking, and text embedding, and indexing within, a vector database! 

RAG has two stages : offline (chunk and embed and index), and online (retrieve and generate).

#### RAG offline stage
This consists of three phases: CHUNKING, EMBEDDING, and INDEXING.

During CHUNKING, you must chunk your email bodies (e.g. to 512 tokens), and the run each chunk through an EMBEDDING model to obtain a vector. An EMBEDDING model converts text (or images, etc) into a fixed-size vector (typically between 384 to 1536 dimensions). Semantically similar vectors are closer together within the vector space. Then you must store these vectors, plus the text which generated them, within a vector database (FAISS/ChromaDB) with an approximate-nearest-neighbour index for fast lookup. This last stage is called INDEXING.

#### RAG online stage (QUERY TIME)
This consists of 2 phases: RETRIEVAL and GENERATION.

During RETRIEVAL time (the first part of QUERY TIME), you must embed the user's question by using the same embedding model, and ask the vector database to find the top-K nearest chunks by cosine similarity.  Those raw text chunks will become returned.

During GENERATION time (the second part of QUERY TIME), in this stage, you must take those top-K retrieved raw text chunks, and build a prompt like: 
```ini
"Context: [chunk1][chunk2] ... [chunkK]\n\nQuestion: {user query}\n\nAnswer based on the context above." 
```
; where the string as "Answer based upon the context above" could equally have been the string as "Based upon the context, respond to:", or "Using only the previously provided passages, answer...". An example prompt is:
 ```ini
 "Alice sent the crash report on March 3rd.  Bob acknowledged it March 4th. The fix was deployed March 7th.\n\nQuestion: When was the crash resolved?\n\nAnswer based upon the context above."
```

#### RAG synopsis
So the model (which we have previousy LoRA-trained) sees the chunks, and then the question, and then generates the response.  We are just instructing it to use whatever we gave it.  The model reads the injected context as if it "knew" those facts, generates a grounded answer, and ideally won't hallucinate beyond what the chunks inform it of. The prompt budget matters here.  "K chunks + question + answer" must fit the LLM's context window.  Too many chunks is noise.  Too few chunks is missed information.  A typical K is between 3 to 8.  RAG retrieves unstructured text chunks via vector similarity. It gives us fuzzy semantic hints, such as chunks mentioning "outage", or "segfault", during GENERATION time.  Contrast this to kG (Knowledge-Graphs), which is a graph database with explicit nodes+edges for structured relationships (such as who-emailed-whom-when).  As we already have the metadata for KG stored within our shard files (which were output from "bin/mbox_pre-parser.rb") we can construct a KG, and use both it and RAG for hybrid retrieval. We can also use the super-skinny metadata from the set output file (output from "bin/splitter.rb" during digest time) for windowing within KG creation, obtaining the rest of the metadata for KG creation from the fat shard files. 

In particular, for the two successive stages of the RAG online stage : RETRIEVAL and GENERATION, let's say the query is "When did Alice raise the crash issue with Bob?", then step 1 will be parallel retrieval : KG gives us the hard facts (Alice->Bob edges, interal_ids, thread IDs, timestamps, etc).  RAG gives us those fuzzy semantic hits, based upon those internal_ids returned from KG, and passed to RAG.  Step 2 will be to merge both the output from this hybrid KG to RAG retrieval, into a single prompt.  KG provides structure such as who and when ; RAG answers "what was said" ; and LoRA facilitates the model how to say it, where a vanilla model would fumble.

RAG is still constrained by the embedding model's max tokens (e.g. ~256 tokens for all-MiniLM-L6-v2, or ~8191 tokens for OpenAI text-embedding-3-small), which is *not* an example of an LLM context window (where the "Lookback Horizon" of the vLLM is bounded by the "context window length" of it).  We don't want *any* overlap between the chunks for RAG embedding and indexing, because RAG doesn't need them : instead, for populating the RAG vector DB, we treat our email corpus as one big collection of data.  We chunk each email body, and associate with each chunk this email's metadata ; then we text-embed, and store within a vector database ; and we will now have completed the RAG offline stage. Having overlap between the chunks of email bodies (associated with the same email's metadata) for RAG, is not harmful in the same way that it would be for LoRA training (by overfitting some of the data), but it would be messy data curation, as RAG doesn't specifically learn from duplicates. This approach of having duplicates, which we reject, would bloat storage, resulting in redundant chunks being returned, eating into the top-K budget of the most relevantly returned raw text chunks (which *would* actually detriment our performance, and so in this sense *would* be detrimental).  As a split between chunks mid-sentence is useless in both halves, I say the correct approach is to programatically to test for a fixed size, say 0.7, of the embedding model's max tokens, which, when approached in a wall-of-text (the sender wrote 47 lines without hitting the Enter button twice in a row) chunks upon a sentence boundary near to this 70% mark of the max tokens in this case, whilst otherwise to split upon a paragraph break. This design will incorporate having a look-ahead examination for a wall-of-text, because, just say this wall begins at the 0.5 mark of the max tokens (pertaining to the email body), and this wall-of-text is 50% of the size of the maximum number of the tokens for this embedding model, we want to break the wall-of-text after about 20% (of the size of max tokens), leaving a remaining wall-of-text now 30% (of the size of the max number of tokens for the embedding model), and then start the next chunk upon this breakpoint. We will want this look-ahead to happen iteratively for all chunks of an email's body which span multiple chunks.

TO DO.  implement this kind of a chunker.

#### KG databases
These store data as nodes+edges.  Nodes are entities, and edges are relationships. Older databases like SQL look up a key within an index in order to find a row, which is of order O(log N) because B-tree indexes are balanced trees, not flat lists. KG databases are "index-free", which means that relationships are not derived at query time via key lookups. Each node stores pointers to its neighbours in memory, or on disk. To traverse a edge, the pointer becomes dereferenced, et viola, you have arrived.  There is no B-tree lookup, and no index scan. So traversing this edge is of order O(1).  Storage is typically adjacency lists, or edge tables, with node-local indexes.

Please note that we do not need to a graph embedding algorithms (TransE, RotateE, ComplEx) to create our ontological embedding to be stored within our KG database, because, as an ontological embedding specifies "how entities connect", we already have this data as metadata within our shard files output from "bin/mbox_pre-parser.rb" : such data as `internal_id`, `original_message_id`, `references`, `from`, `thread_id`, `timestamp`, `subject`, `has_attachment`, and `attachments` : the latter of which contains the metadata associated with the attachments pertaining to any email.  Let us use this metadata to create our ontological embeddings.

A **Directed Acyclic Graph** (DAG) means that edges have direction, and that they have no loops (acyclic), and that you can't follow edges and end up back where you started.  A "Graph" is all the nodes + edges. A References chain is a DAG because emails point forward in time, so we can never cycle back. Note that we will be thinking of constructing the `original_message_id` of the reply email pointing back to each of the References' `original_message_id`s as the  (`References[0]->original_message_id_of_the_reply_message`), in preference than to do so the other way around.  By index-free adjacency, each node stores its outgoing edges with itself.  So node B physically hold a pointer to node A.

A "Tree" is a special case of DAG whereby each node has one parent.  As References edges can be multiple per node, our schema (which we pass to TransE/RotatE/ComplEx) is a DAG, not a Tree. TransE/RotatE/ComplEx learn vector representations for entities and relationships you have *already defined*. The idea is that we will feed it a list of edge triples, like `(original_message_id, EMAIL_WAS_SENT_BY_PERSON, from)`, e.g. (msg-123, EMAIL_WAS_SENT_BY_PERSON, alice@example.com), and it will produce embeddings that encode structural positions. We do the following.
- 1. We define our ontology: "email addresses are nodes (Person), original-message-ids are nodes (Email), attachments are nodes (Attachment)".
- 2. We define edge types: PERSON_DID_SEND_EMAIL, EMAIL_WAS_SENT_BY_PERSON, EMAIL_IS_A_REPLY_TO_EMAIL, EMAIL_CONTAINS_THE_ATTACHMENT, ATTACHMENT_BELONGS_TO_THE_EMAIL
- 3. Build the graph with actual triples: e.g. (email-123, EMAIL_IS_A_REPLY_TO_EMAIL, email-456).
- 4. Feed that into the embedding model. The model learns that email_123's vector should be close to email-456's vector.

#### Explain KG nodes and edges
Edges aren't containers containing nodes ; they are labeled arrows *between* nodes.  Think of a city map where buildings are nodes, and one-way streets are edges.  The one-way street connects two buildings.  Edges are the "verbs" such as EMAIL_WAS_SENT_BY_PERSON, EMAIL_IS_A_REPLY_TO_EMAIL, ATTACHMENT_BELONGS_TO_THE_EMAIL.  In the graph we may wish to be having: `(alice:Person)-[:PERSON_DID_SEND_EMAIL]->(email:Email)-[:EMAIL_CONTAINS_THE_ATTACHMENT]->(file:Attachment)`. Here Alice is a node. The email is a node.  The attachment is a node. The arrows between them are edges. Nodes can have properties (`internal_id`, `thread_id`, `subject`, `timestamp`).  Edges can too (`timestamp`).  You query by pattern-matching paths through nodes via edges.  An edge triple is (head, relation, tail), e.g. (email-123, EMAIL_WAS_SENT_BY_PERSON, alice@example.com). TransE models is as h + r ≈ t in vector space.  RotatE rotates h by r to reach t. ComplEx uses complex embeddings to handle asymmetric relations.

References (from the email headers) *contain* Message-IDs of other nodes. The original_message_id (Message-ID) is created (hopefully uniquely) upon every email. The references to previously created Message-IDs are what **edges** are. We put `internal_id`, `thread_id`, `subject`,  as node properties, as these are intrinsic attributes/properties. Properties describe "what a thing is".  Edges describe *who it connects to*.  To explain the EMAIL_WAS_SENT_BY_PERSON edge : the metadata contain a `from` field (containing an email address). So we create an edge between the `original_message_id: "email_message_id_123"` and the `from: "alice@example.com"` fields : such as the edge being `alice@example.com->email_message_id_123`, which was created by `email_message_id_123, EMAIL_WAS_SENT_BY_PERSON, alice@example.com`. This will allow us to ask our hybrid KG retrieval to RAG, such a question as "Show me all the emails EMAIL_WAS_SENT_BY_PERSON alice@example.com", as KG will return the internal_ids, and these will be passed to RAG to retrieve the email-bodies.  Note that we do not duplicate the email-bodies within both KG and RAG, as we are seeking to obey the DRY principle.  We may also wish to ask the question to the hybrid KG-RAG, such as "Show me all the reply emails sent from bob@123.com to alice@999.com", so after collecting all the `original_message_id`s (those sent from bob@123.com via examining `bob@123.com->email_message_id_999`, and the like), we filter these within KG in order to retrieve that which has been previously created as `original_message_id_of_the_reply_message EMAIL_IS_A_REPLY_TO_EMAIL References[0]`, i.e. `References[0]->original_message_id_of_the_reply_message`, for example "<48c6a35b-3667-46d1-9d36-303d1abfe824@xs4all.nl>"->"<432p729s-5n0q-6707-rn2r-1p0p8165099r@hzvpu.rqh>", or `email_message_id_999->"email_message_id_123"`.  We will now have a list of `original_message_id`s (from References[0], References[1], ...) that Bob has replied to.  Then we filter these via examining edges such as `References[0], EMAIL_WAS_SENT_BY_PERSON, alice@999.com`, but note that we are here traversing from `References[0]->alice@999.com`, *not* the other way around : as in our previous question as "Show me all the emails EMAIL_WAS_SENT_BY_PERSON alice@example.com".  To do this we do *not* need to use an LPG (labeled property graph) like Neo4j, Amazon Neptune, or Tigergraph, whereby we would be creating reverse indexes.  Instead we will store edges as double pointers, thus maintaining both directions. We write two edges: `(email_message_id_123)-[:EMAIL_WAS_SENT_BY_PERSON]->(alice@example.com)`, in which case our node would be `(email_message_id_123)` ; and `(alice@example.com)-[:SENT_THE_EMAIL]->(email_message_id_123)`, in which case our node would be `(alice@example.com)`  A node is a unique entity within the graph. Here `(email_message_123)` is a node, not a property upon a node.  Edges connect nodes.


#### How to build the KG
When forming edges for knowledge-graphs we want to use labels at KG creation time.  When the parser sees an email, it creates `(e:Email {Subject: '...', Date: '...', Has_attachments: boolean, })`.  When it sees a sender, it creates `(p:Person {email: 'alice@example.com'})`.  Labels are just tags you stamp on nodes when you make them. `CREATE (e:Email {...})`, where `:Email` is the label. 

To recap, in my KG creation I do `email_message_id_123, EMAIL_WAS_SENT_BY_PERSON, alice@example.com`, and `email_message_id_123, EMAIL_IS_A_REPLY_TO_EMAIL, email-message_id_999`, and `email_message_id_999, EMAIL_WAS_SENT_BY_PERSON, bob@123.com`.  So to answer the prompt query as "Show me all the reply emails sent from bob@123.com to alice@999.com", we trace the path.  "Fred sent email 999, Alice replied to 999 with 123.", query with: 

```
MATCH (fred:Person)<-[:EMAIL_WAS_SENT_BY_PERSON]-(original:Email)<-[:EMAIL_IS_A_REPLY_TO_EMAIL]-(reply:Email)-[:EMAIL_WAS_SENT_BY_PERSON]->(alice:Person) ;
WHERE fred.email = 'fred@binom.com' AND alice.email = 'alice@example.com'; RETURN reply ;
```
whereby you are walking backwards from Alice's reply to the original, and then confirming that Fred sent it. `original` is just a variable name for the node matched by the `:Email` label in that position ; it is the email sent by Fred, which Alice replied to.  The patten says: find a node (labeled Email) that has a `EMAIL_WAS_SENT_BY_PERSON` relationship to `fred`, and call that node the `original` message.

Node2Vec is transductive, whereby it will learn one vector per *existing* node via a biased random walk through our DAG.  It does random strolls through our email graph, collecting thousands of sequences.  Then Word2Vec notices patterns appearing within these sequences, and their frequency, assigning similar vectors to things that keep showing up near to each other.  It is not useful for our use case, as chains of (hopefully) unique `original_message_id`s such as [id23432, id452423, id87873, id871123] will not repeat, nor will edges between email addresses and unique message ids. 

GraphSAGE would learn *aggregate functions* instead of node-specific vectors. When a new vector arrives we run the learnt aggregator upon its neighbours, to get a vector without rebuilding KG all over again.  Although this would be good for pipelines where cohorts grow incrementally, it would not be able to deal with DSR requests, so I reject its use.

We want to have structural metadata, including the filename of attachments, their MIME type, size, and attachment_id, within the KG, which will report deterministically facts about "what exists".  We will not extract text content from attachments within RAG, because there would be technical difficulties if attachments are not readily parseable, and this level of granularity is too much, I say, and would populate our search data with random crap from the non-parseability, or non-standard parseability, of myriad, potentially password-protected, attachment files from sent emails.  By avoiding this level of absurd granularity, we don't have to worry about whether the email contains a binary, or non-binary, attachment, as a data-level concern.  Look.  This whole project was supposed to be a data curation program for the text content and metadata from an MBOX.  There are myriad projects out there which are all about AI examining multiple data formats, and parsing them.  These projects will add a lot of latency time to the AI inference prompt when we use it.  Therefore I reject this idea as a waste of time, and and waste of effort. The `has_attachment` metadata on any node in KG, should link from the `internal_id` to the `has_attachment` field.  So, if the query pattern is "Find attachments pertaining to emails about finances", for a valid hyrid query, we want KG to filter out those `internal_id`s which have email attachments associated with them, and then we pass those `internal_id`s to RAG, for RAG to semantically search.  Note that KG passes its metadata (as `internal_id`, `original_message_id`, `references`, `from`, `thread_id`, `timestamp`, `subject`, `has_attachment`, and `attachments`) to RAG, so that RAG can reference this metadata (such as `attachments[0].unique_attachment_id`) with or without performing a semantic search upon the content of the email body. KG is a structural filter. RAG is a semantic filter. I find the idea of RAG to be referencing and accessing the metadata pertaining to the attachments to be a clean way to work, because we don't need to worry about KG having the opportunity to do so.  If we were to only ever need to "list attachments of this email", then we could `CREATE (e.Email {Subject: "Hello", Date: datetime(), Has_attachments: true, Attachments: ["file.pdf", "img.png"]})`, but we may wish to enable the user to query *across* emails, in such a prompt as "find all the pdfs Bob sent", in which case attachments should be separate nodes with properties like `filename`, `unique_attachment_id`, `attachment_size`, and `attachment_content_type`.  These attachment nodes should be separate nodes `(a:Attachment)-[:BELONGS_T0]->(email)` which first can be created (with associated properties) like any other node:
```cypher
CREATE (a:Attachment {
  unique_attachment_id: 'att-abc-123',
  filename: 'report.pdf',
  attachment_size: 204800,
  attachment_content_type: 'application/pdf'
})
```
Secondly, we link to the parent email:
```cypher
MATCH (e.Email {Message_ID: 'msg-123'})
CREATE (a:Attachment {
  unique_attachment_id: 'att-abc-123',
  filename: 'report.pdf',
  attachment_size: 204800,
  attachment_content_type: 'application/pdf'
})-[:ATTACHMENT_BELONGS_TO_THE_EMAIL]->(e)
```
Now you can query: "all pdfs larger than 1MB", or "emails with attachments of type image/png", or "who sent the most spreadsheets?". These traversals are impossible with flat array properties.  Cypher is the query language for neo4j. When creating KG from scratch (which is necessary to remove DSRs) we will need to recreate our attachment nodes from a blank canvass and link them to the parent node of each.

When new corpora of emails arrive and we wish to add them to KG, without enacting any DSRs, it is not necessary to recreate/rebuild the whole KG from scratch.  We can prevent deduplicates when we reparse by doing
```cypher
MATCH (e.Email {Message_ID: 'msg-123'})
MERGE (a.Attachment {unique_attachment_id: 'att-abc-123'})
SET a.filename = 'report.pdf',
    a.attachment_size = 204800,
    a.attachment_content_type = 'application.pdf'
MERGE (a)[:ATTACHMENT_BELONGS_TO_THE_EMAIL]->(e)
```
MERGE is an idempotent upsert : it won't duplicate attachment nodes if the same attachment is already with KG. An idempotent operation will produce the same result no matter how many times it is applied, preventing unintended side-effects when repeated.

Of course filename collisions can occur on the backend storage. We solve this problem by using the `unique_attachment_id` as the storage path, not the filename.  We can store the file as `/attachments/att-abc-123`.  Now if two emails have an attachment named `report.pdf`, the different ids lead to different paths, and no collision.  The ID is your filesystem key ; the filename is just metadata you display back to the user.  MIME `Content-Disposition` filenames are user-controlled and can be identical, duplicate, or malicious. We never trust them in storage paths. MIME `Content-Disposition` is a MIME header on each email part that informs the email client how this part should be treated.  It has two values: `inline` informs the client to render it within the message body (inline images, HTML text), whereas `attachment` means show it as a separate downloadable file.  It usually carries a `filename` parameter, e.g. `Content-Disposition: attachment; filename="report.pdf"`, which is the *suggested* display name. That filename is user-controlled, and can be duplicated across emails, or be missing entirely.  Every leaf in the MIME tree is a "part". An "attachment" is a specific kind of part: one where the Content-Type is not `text/*` and/or the Content-Disposition is `attachment` or `inline`.

#### Why KG *needs* the windowing from the email threads.

Without windowing by thread_id, the main unavoidable danger to the creation of my knowledge-graphs, is that the reply-to edges may cross arbitrary batch boundaries, and become missed.  This would lose context for "who replied to whom, and when" : which is the whole purpose of KG.  Batch boundaries are artificial cuts in your data stream.  If I have windows of size 30, from the same thread of 200 emails, *without* any overlap between these windows for KG creation, then E30 replies to E29, which is captured, but when E31 replies to E30, this may result in a broken edge, because E30 and E31, which are within different windows, are processed independently. E30 lands in batch 1, and E31 in batch 2. There is no guarantee of the order in which these batches are started or completed, asynchronously. If we did omit the window-overlap to the KG creation, then our reply chain would become 6 disconnected subgraphs, instead of one 200-thread.  This absence of overlap would prevent edge continuity in KG.  This scenario must be avoided by using the windowing of email threads. We already have the metadata for this from the digest stage of our data curation. 

## So what exactly *are* we doing within "mbox_pre-parser.rb"?
We are:
- 1. **Parse the mbox file**: We split on "From" lines (the mbox separator) and collect raw message strings.
- 2. **Filter content and detach attachments**: Detach and store all attachments.  TO DO. implement this.
Then for each email we:
- 3. **Extract Message_ID**: Extract from the email header.  Or we synthesize 256 hash if it is missing.
- 4. **Extract and clean body**: For multipart, prefer text/plain part; decode with charset detection (explicit header OR charlock_holmes OR UTF-8 fallback).  TO DO. allow quoted blocks which are currently being removed stripped (">" lines, "On...wrote:") so that LoRA can understand these. Also necessary for RAG and KG..
- 5. **Filter oversized emails**: Drop emails > 16,000 chars (LoRA 8k token budget).
- 6. **Generate internal_id**: SHA256(Message-ID + body hash) for collision-proof primary key.
- 7. **Deduplicate and track collisions**: Skip exact internal_id matches ; log Message-ID collisions (same ID, different content) to triage file, but keep both versions.
- 8. **Derive thread_id**: From: References[0] ***or*** In-Reply-To ***or*** normalized subject hash ***or*** self Message-ID.
- 9. **Stamp the cohort_id**: From: Override flag ***or*** Date header ***or*** file mtime. The cohort_id is of the format as 'YYYY-MM".
- 10. **Extract received timestamp**: From: Date header ***or*** the first Received header within the email body (as read from top downwards) ***or*** file mtime(ISO 8601).
- 11. **Write output**: Single JSON file (if --output flag is used) or sharded JSONL (part-NNNNN.jsonl, default 1000 msgs/shard).
- 12. **Summary stats**: Counts of binary/oversized/duplicate/collision/processed, unique threads, cohorts.  output this visually to STDOUT and also write collision data to a collision_triage file

TO DO implement stage 12 (collision_triage file containing internal_ids and original_message_ids of collisions).

## The overall architecture.
* We want to keep a record of what mboxes we have put in to our pipeline, and only process the newer ones.
* We want what we have put in to our pipeline to sit apart from what is processed within this pipeline, further down the line.  This "admission section" may be subject to regular backups. Not only do we want our raw mboxes and a record of them to be located here, but we also wish for a generic record of what DSRs have been made (though not fine-grained upon every email) to be recorded also.

### How to input mboxes into mboxMinerva backend.
When a new corpus (or corpora) of emails arrive (in the form of one mbox, or several mboxes), from a readable location on the storage backend, we want a function called "bin/input_mbox.rb" to put this mbox, or these mboxes, to a storage location upon the backend (the host, in our case) with a unique path. Instead of changing the name of the mbox file (which may cause the the user some confusion) we ought to assign each mbox to its own unique directory name.  This should be accomplishable via assignment of a timestamp to the directory name in the case of a single mbox (i.e. `./raw_mbox_files/until_<timestamp>_00001/myEmails.mbox`), and a unique directory name in the case of the "bin/input_mbox.rb" being run with multiple arguments.  For example, if we run `input_mbox.rb /path/to/multiple/mboxes/**/*` (recurses one level deep into subdirectories), or if we run `find /path/to/multiple/mboxes -type f -exec ./input_mbox.rb {} +` (which collects as many filenames as possible recursively to one single `input_mbox.rb` invocation), we want the directory names of the paths to each mbox file to be unique, (i.e. `./raw_mbox_files/until_<timestamp>_00001/myEmails.mbox`, and `./raw_mbox_files/until_<timestamp>_00002/someMoreEmails.mbox`). Thus by having unique directory names, we can avoid a path collision if the filenames of the mboxes are the same.

We also want to have a "manifest_file_of_inputted_mboxes.jsonl" containing these paths in association with the SHA256 hexdigest for each of these inputted mboxes.  We will use the JSONL format as:
```jsonl
{"path":"./until_2026-03-24T18:47:00Z_00002/a.mbox","sha256":"a1b2c3...","size":1048576,"file_added_at":"2026-03-24T18:47:00Z"}
```

TO DO implement "bin/input_mbox.rb" in this way. I want "bin/input_mbox.rb" *not* to alter, or even read, the "manifest_file_of_inputted_mboxes.jsonl", because this job is reserved for "bin/mbox_pre-parser.rb", which will update this manifest file *after* "bin/mbox_pre-parser.rb" has processed it.  This way we are keeping a record of what got put in to the pipeline immediately *after* it has been putten in.  "bin/mbox_pre-parser.rb" will only process mboxes which have *not* already been recorded within the manifest file as "manifest_file_of_inputted_mboxes.jsonl".

I may want this file as "manifest_file_of_inputted_mboxes.jsonl" to be append_only within the Host operating system, via `chattr +a manifest_file_of_inputted_mboxes.jsonl`, which works if we have bind-mounted the Host directory into the Container. Works on ext4, not on overlayfs (Docker containers). Alpine needs `e2fsprogs` for `chattr`. **But** the container can also run `chattr -i` and `chattr -a` to undo it, so only gives a protection against accidents, not a compromised container process.

### The "generic_DSR_record_manifest.jsonl" file output by "bin/dsr_change.rb".
I also want to have an immutable (append-to only) "generic_DSR_record_manifest.jsonl" file, within the same directory as the "manifest_file_of_inputted_mboxes.jsonl" (in this case `./raw_mbox_files`) which is of the format as:
```jsonl
{
  "dsr_id": "dsr-2026-00042",
  "dsr": "delete",
  "email_of_dsr": "bob@x.com",
  "requestor_type": "data_subject",
  "jurisdiction": "GDPR",
  "requested_at": "2026-03-20T10:00:00Z",
  "processed_by": "admin_alice",
  "completed_at": "2026-03-24T18:00:00Z",
  "confirmation_sent_at": "2026-03-24T18:05:00Z",
  "confirmation_sent_to": "BobSmith@456.com",
  "reason": "user_request",
  "comments": "Requested via support ticket #12345"
}
```
The useful fields are : "dsr_id" for cross-referencing, "processed_by" for audit trails, "completed_at" to prove you honored the 30-day GDPR deadline, "jurisdiction" if you ever deal with GDPR vs CCPA vs other regimes. "confirmation_sent" is often legally required : you must tell the subject you complied. The rest is nice to have depending on how much audit pain you want to avoid later. In a different framework, "scope" may be required to distinguish "delete my account" from "delete this one email", but as we are not dealing with accounts, and only emails, the abscence of a "scope" field is tacitly understood to mean `"scope": "email_only"`.

Thus our directory listing of `./raw_mbox_files` may look like: 
```bash
-rw-rw-r--   1 dmr104 dmr104   9728 Mar 11 14:33 DSR_generic_record.jsonl
-rw-rw-r--   1 dmr104 dmr104  27965 Jan 15 05:23 manifest_file_of_inputted_mboxes.jsonl
drwxrwxr-x   2 dmr104 dmr104   4096 Nov  9 12:42 until_2026-03-24T18:47:00Z_00002/a.mbox
```

TO DO 

Implement this DSR immutable manifest being output from a "bin/dsr_change.rb" file which will incorporate the command argument "access" and "delete" well ; "access" will "give the user all data we have upon him/her", and "delete" will add an entry to the "generic_DSR_record_manifest.jsonl". The "dsr-id" will be incremented automatically, as will "completed_at" be calculated automatically. "bin/dsr_change.rb" will require the options as `--email_of_dsr "bob@x.com" --requested_at "2026-03-20T10:00:00Z" --processed_by: "admin_alice" --confirmation_sent_to "BobSmith@456.com" --reason: "user request", --comments: "Requested via support ticket #12345"`.  The option as `--confirmation_sent_at: "2026-03-24T18:05:00Z"` will be optional.  This is to faciliate the possiblity that an email was manually set to BobSmith@456.com, whereas if this option is omitted, then mboxMinerva should automatically send him an email while filling in the "confirmation_sent_at": "2026-03-24T18:05:00Z" field within "generic_DSR_record_manifest.jsonl" automatically. 

TO DO.  Implement this logging facility. post record of tombstones to logs/tombstones.jsonl with who/what + timestamp + reason ; audit logs to logs/audit.jsonl recording each attempt to train LoRA with a record of keys (who/what) within the tombstones which apply to the training session, i.e. the X,Y,Z within the audit.jsonl reference the same key identity (who/what) within the tombstones.jsonl.  check whether bin/dsr_delete actually writes these tombstone records.  

Implement a way to query the jsonl data structure of "generic_DSR_record_manifest.jsonl", via "bin/dsr_change.rb list", which will list an output on STDOUT which includes 
```txt
DSR deletion request by <email> at <timestamp>
DSR access request by <email> at <timestamp>   
``` 
where "<timestamp>" is in a human readable form ; while `bin/dsr_change.rb list -v` produces
```text
DSR deletion request by <email> at <timestamp> with the reason as : <reason> ; and the comment as <comment>
DSR access request by <email> at <timestamp> with the reason as : <reason> ; and the comment as <comment>
```
while `bin/dsr_change.rb list -vv` produces
```jsonl
{
  "dsr_id": "dsr-2026-00042",
  "dsr": "delete",
  "email_of_dsr": "bob@x.com",
  "requestor_type": "data_subject",
  "jurisdiction": "GDPR",
  "requested_at": "2026-03-20T10:00:00Z",
  "processed_by": "admin_alice",
  "completed_at": "2026-03-24T18:00:00Z",
  "confirmation_sent_at": "2026-03-24T18:05:00Z",
  "confirmation_sent_to": "BobSmith@456.com",
  "reason": "user_request",
  "comments": "Requested via support ticket #12345"
}
```
With an --output option as `bin/dsr_change.rb list --output ./myDSRlog` we will output to a file instead of the default STDOUT.  

We want `bin/dsr_change.rb --input "another_DSR_manifest.jsonl` to read from a different DSR manifest file, in order to infer that 
```
"This particular LoRA (reference name) was trained after DSR removed X, Y, Z", 
```

We also want to have a `bin/dsr_change search --email bob@456.com` to produce output just relating to this user's email address.

END_OF_TO_DO

TO DO 
Remember to save a copy of the "generic_DSR_record_manifest.jsonl", with a unique name, in the same directory as where the new LoRA layer will reside, so we can query it to infer "This particular LoRA (reference name) was trained after DSR removed X, Y, Z", although the output from "bin/dsr_change.rb" won't be significantly different in appearance than before.

### "bin/dsr_processor.rb" outputs the dsr immutable manifest file as "expanded_DSR.jsonl"
This file contains the "internal_id"s which are to be filtered and omitted from LoRA training, RAG, and KG.  This file MUST have an "original_message_id" associated with the "internal_id" so that KG can do its KG creation (from "train.jsonl", "val.jsonl", and "test.jsonl") using the "original_message_id"s (which also appear in "references") as nodes, and yet return the "internal_id" of a relevant hit during KG retrieval.  KG will omit those nodes which are tombstoned within "expanded_DSR.jsonl" : KG will not create nodes with these tombstoned "original_message_id"s, hence the associated "internal_id" will not be returned to RAG to be searched semantically, and RAG will not contain these email bodies associated with these tombstoned "internal_id"s anyway.  When KG creation uses "references" (previously extracted from the "References:" email header) it omits the node as "original_message_id"  from within this list of "references", which was associated with a particular "internal_id" within "expanded_DSR.jsonl", and it also omits to create a node with this "original_message_id" which is "in-reply-to" this particular "reference" value.  Both ends (nodes) are not created within KG. Obviously to omit creation of the latter is easy : the node is skipped when a particular "internal_id" from "train.jsonl", "val.jsonl", or "test.jsonl" matches that from within "expanded_DSR.jsonl". But as the "references" values are "original_message_id"s (not "internal_id"s), each of the "references" values will need to be compared to the "original_message_id" values contained within the "expanded_DSR.jsonl" in order to decide whether to omit the creation of this particular node within KG creation.  A Message-ID collision is where two separate email bodies (perhaps sent years, or decades, apart) share the same Message-ID (which is a field within the email header). It is a rare event, which hopefully should not occur, but it might do so.  If, and when, it does occur, by our prior algorithmic logic (within "bin/mbox_pre-parser.rb"), the "internal_id"s of these two messages, which collide upon the Message-IDs, will be different. So. A Message-ID collision will have two Message-IDs the same : that is, the "original_message_id"s will be the same.  This will be bad for KG creation as the "original_message_id" is used as a node within it.  Is there a defensive procedure we could use to guard against this case and scenario?  Well yes. We already have a "collision_triage" file which was output from "bin/mbox_pre-parser.rb" which contains the offending "original_message_id"s. So we can utilize this information within the KG creation algorithm in the following way.  If the node we are creating from the data within "train.jsonl", "val.jsonl", or "test.jsonl" has an "original_message_id" which is offending, then we utilize the "internal_id" in this node creation instead.  This applies to both scanning the values within "references" to create a node (References[0]->non-offending_message_id) and also it applies to the creation of a node extrapolated from the "in-reply-to" field (offending_message_id->References[0]).

### Shard file output from "bin/mbox_pre-parser.rb"
These have ***no*** record of DSRs. They are fat : they contain the email body and *all* the metadata which is extracted from the mbox, which was deemed relevant.

### "bin/splitter.rb" outputs immutable manifest file as "assignments.jsonl"
This file as "assignments.jsonl" contains ***no*** windowing, and contains ***no*** DSR records. It MUST contain metadata as "internal_id" and its "thread_id". All other metadata to be used within KG creation is extracted from the shard files, by looking up the "internal_id" within these shard files.

### What does "bin/window_maker.rb" do?
This reads from "assignments.jsonl", filtering out all DSRs from "expanded_DSR.jsonl", outputting the (optionally) windowed pool files "train.jsonl", "val.jsonl", or "test.jsonl" from "assignments.jsonl".  

### LoRA training.
The "internal_id"s from "expanded_DSR.jsonl" are filtered from those from "assignments.jsonl", and the email bodies with these ids are ommitted from pre-LorA and LoRA training.

### RAG chunking.
I will omit the email-bodies with "internal_id"s from "expanded_DSR.jsonl", by filtering these from those from "assignments.jsonl" when I do chunking for RAG.  Thus, the email-bodies of these DSR-ed "internal_id"s won't be able to become retrieved, as they will not be present within the embedded database which RAG uses.

### Synopsis of architecture.
The immutable manifest file as "expanded_DSR.jsonl" incorporates the DSRs, and "bin/window_maker.rb" filters these while reading "assignments.jsonl".  The entries within "expanded_DSR.jsonl" stay intact, and you get an audit trail for free.

TO DO. Implement a "bin/dsr_audit" command such that `bin/dsr_audit ids --email bob@456.com` will list all the "internal_id"s which have pertained to this email address, while `bin/dsr_audit ids --email bob@456.com -v` will list all the metadata, and `bin/dsr_audit ids --email bob@456.com -vv` will list all the metadata *and* the email-bodies. 

I want LoRA, RAG, and KG to omit DSRs. So I ensure that "bin/splitter.rb" outputs a manifest file which does *not* include windowing (as we seek to avoid baking overlapping windows into an immutable artifact file where they don't belong).  Then I can read from the manifest file to get "skinny" references (metadata) in order to read email-bodies from shard file for both LoRA and RAG, but for KG I will need windowing, so I will facilitate windowing from the manifest file to pool files as a separate concern (called "bin/window_pools.rb"), and use all of these pool files (train/val/test) for the creation of KG (Knowledge-graph). KG will also need more metadata than the "skinny" manifest file and pool files possesses, so I will these pool files to gain metadata (internal_ids) in order to get this extra metadata from the shard files (output from "bin/mbox_pre-parser.rb").  Thus our manifest file is as our skinny index + DSR tombstones, our shards are as our content store, and windowing is defered for KG pool generation.  This keeps our concerns clean.

TO DO.  ensure that the immutable manifest files "assignments.json" and "expanded_DSR.jsonl" are append-only.  Have skinny manifest file "assignments.jsonl" (output from "bin/splitter.rb") and "expanded_DSR.jsonl" as a double source of truth for DSR filtering, so that LoRA and RAG can be pulling bodies on demand from shards, whereas and KG gets its own windowed pool files (output from "bin/window_maker.rb").

## So what exactly *are* we doing within "splitter.rb"?
- 1. Parse CLI options (seed, window-size, pin, exclude, materialize).
- 2. Load existing manifest (assignments.json) if present.
- 3. Load JSONL/JSON emails from input path.
- 4. Apply exclusion list filter, in order to later apply data subject requests to the Knowledge-Graph.  
- 5. Apply cohort pin filter (cohort_id <= pin).
- 6. Group emails by thread_id.
- 7. Assign split per thread via seeded SHA256 hash (0-79 train, 80-89 val, 90-99 test).
- 8. Inherit split from existing manifest for known threads (incremental mode).
- 9. Optionally window long threads into overlapping chunks.
- 10. Save the updated manifest.
- 11. Materialize requested splits to "train.jsonl", "val.jsonl", "test.jsonl".  These files are required for KG creation, but not RAG creation.  They are not useful for LoRA training.
- 12. Print summary stats.

## Using --window-size n
At ingest stage, the shard files output from "bin/mbox_pre-parser.rb" have *no* segment-awareness (they are not windowed) ; among other things, "bin/mbox_pre-parser.rb" creates an internal_id, comprising a hash of the email (message_id + email_body), enforcing that this internal_id must be unique, and it also prevents exact duplications entering the shard files.

When "bin/splitter.rb" reads these shard files by `Dir.glob("*.{json,jsonl}")`, it would be pointless for it to group *all* loaded messages by thread_id, because the overwhelming majority of these shard files will have already been processed by "bin/spliter.rb" resulting in their inclusion within the immutable manifest file as "assignments.jsonl".  So what will happen instead, is that within the same directory as the shard files, we will also have "shard_splitter_manifest" file which will indicate which of these shard files will have already been processed, and so we simply process those newer files which have not already been indicated as having been processed.

TO DO.  Change "bin/splitter.rb" so that it will not output any train/val/test pool files at all, and make sure that it creates or read from and amends the "shard_splitter_manifest" file so that newer complete shard files get processed and recorded, while older already processed files are bypassed.  

If the pre-parser splits a long thread into separate shard files, and then the `--window-size N` option to "bin/window_maker.rb" is used ; for example, the pre-parser operates upon a mega-thread containing 2687 email messages ; then, after the pre-parser has output 3 segments/chunks of 1000 rows, 1000 rows, and 687 rows ; then, as all these messages share the same thread_id, if I issue `window_maker.rb --window-size 40 --window-overlap 10`, "bin/window_maker.rb" will re-assemble these messages into one 2687-message thread, and it will window with stride length of 30 (40 minus 10), yielding windows 0-39, 30-69, 60-99... up through 89 windows, which *all* inherit the same deterministic split from the hash of the parent thread_id, with the last window (with the window_id=88, due to the window_idx variable being zero based), containing the final 17 messages. Recall that these shards, which were output from "bin/mbox_pre-parser.rb", are not "skinny" : they contain rows which are containing the emails' message bodies too. This makes them fat. The pre-parser's sharding is purely concerned with file-size. It is just disk I/O (filesystem input/output) logistics.  All semantic windowing occurs within "bin/splitter.rb". The pre-parser's output shards are just raw data structure chunks assembled from the MBOX, while the windows which splitter creates are semantic context metadata slices assembled for the time when the creation of the KG (Knowledge-graph) will occur.

## Non-dynamic (static) window-sizing
**`--window-size N` is applied uniformly to all threads regardless of their length.** There is no dynamic adaptation.  A 5-message thread with `--window-size 100` simply produces one undersized window containing all 5 messages. The flag does not skip, expand, or contract, based on thread size.  Why is this a design decision?  Because using dynamic window-sizing would be an example of solving a non-problem.  The size of these being static does not hurt the creation of Knowledge-Graph, as this is irrelevant to graph integrity.  Static sizing with overlap guarantees edge capture.  Window [1-30], and [26-55] share 5 emails : any edge between two nodes (email-123, EMAIL_WAS_SENT_BY_PERSON, alice@example.com) from E28->E29 exists in *both* windows. The KG pass sees the complete edge, regardless of which window processed it.  Static size just means predictable memory/batch costs.  Overlap does the continuity work.  What *would* hurt would be no overlap (missing edges), or having lots of windows smaller than the typical reply depth, whereby tiny windows means more batches to process (more overhead) during KG creation, not KG traversal.

Very short threads already become single complete windows (semantically ideal), and long threads ideally already get windowed into multiple overlapping windows. Dynamic sizing would add code complexity to optimize something that the KG creation framework already handles via its logic padding down gracefully, so the ROI (return on investment) is near to zero, rather than actually harmful. The real goal of windowing is to cap context for KG creation (with overlap between windows) for long threads, not to stretch out short ones. Short windows just work, as do threads shorter than window-size.

## Split Inheritance
All windows derived from a single thread inherit the **same deterministic split** (train/val/test) based on the parent `thread_id` hash. This prevents data leakage. You'll never have window 0 of a thread in "train" and window 1 in "val".

### Relationship to Pre-Parser Sharding

| Layer | Tool | Purpose |
|-------|------|---------|
| **Output sharding** | `mbox_pre-parser.rb` | I/O logistics. It splits large output into manageable files (default 1000 rows/shard) |
| **Semantic windowing** | `splitter.rb --window-size N` | This is a training concern. It chunks threads to fit a transformer context window |

## How will new batches of emails arriving not result in previous shards becoming overwritten?
By default "mbox_pre-parser.rb" resets the filename index to 1 for every run, so it *will* overwrite the file as "part-00001.jsonl" if you point it at the same folder, but will prevent you from doing this unless you use the --force option, and even then it will warn you about this unless you use the --yes option also.  You should output each new batch to a unique subdirectory (e.g. `--output my_project/pre_parsed/2026-01-05`) so that your library grows without collisions, while "bin/splitter.rb" still loads everything via its input glob ; so `ruby mbox_pre-parser.rb my_project/emails/2026-01-01/ --output-dir my_project/pre_parsed/until_2026-01-01/` and `ruby mbox_pre-parser.rb my_project/emails/2026-01-15/ --output-dir my_project/pre_parsed/until_2026-01-15/` will both be read by "bin/splitter.rb" by the code
```ruby
pattern = File.join(input_path, '**', '*.{json,jsonl}')
files = Dir.glob(pattern)
``` 
when we issue `ruby splitter.rb --input my_project/emails/`

### CLI Optimization (`--force` and `--yes` to "mbox_pre-parser.rb")
For integration into CI/CD or automated pipelines:
- `--force`: This will bypass safety checks when the output directory or file already exists, performing a surgical deletion of existing `*.json` and `*.jsonl` files before starting.
- `--yes`: Will auto-approves prompts (such as confirming the deletion of thousands of files), enabling non-interactive execution.  ***Use with caution!!***

## Is it possible that we can ever have a Message-ID collision within a very large (20 years) inbox?
RFC 2822 says that these should be "globally unique", but upon an historical mbox (prior to modern Mail Transfer Agents [MTA]s using MD5/UUID-based generation) dupes *can* occur from broken clients (old Outlook Express, some PHP mailers, misconfigured MTAs that rewrite the Message-IDs) leading to the same Message-ID but with completely different content ending up within the same inbox. More relevantly, a more common issue is *missing* Message-IDs.  

## How could we have implemented the removal of email message duplications naively in a way which will not detect Message-ID collisions?
During, and prior, to this process (i.e. prior to fuzzy dedupe), we could have already issued a `cat original.mbox | formail -D 50000000 .msgid.cache -s cat > unique.mbox` to generate a "unique.mbox" by using `formail`, and this will remove exact duplicates across the entire mbox (across all threads). It is purely a "Message-ID lookup" that doesn't care about the surrounding context.  It will *not* detect Message-ID collisions. Neither will it detect missing Message-IDs.

### How would this have been naive?
It is not thorough enough.  We want to compare emails by examing the hashes of the email body too in order to remove exact dedupes because, if within an older history of emails a Message-ID collision *has* occurred, then we don't want to omit the inclusion of the bodies of email messages blindly when the email contents may well be very relevant.  

### So what else could we have done then in an ersatz manner?
We could have piped through a custom script which catches true collisions, whereby both Message_IDs are identical, but the email body (and thus the hash of) is not, and this inferior script could have included both messages for output instead of silently dropping one at ingest time.

Since we are already parsing the mbox within "mbox_pre-parser.rb", we could have built the association in RAM (read only memory) between the Message-ID and the body_sha256 index there.  When a duplicate Message-ID were discovered, we could have compared the hashes, and if these body_sha256 hashes *were* identitical, then we would have known that this is was an exact duplicate ; but if these *were not*, then we, alternatively, would have known that a Message-ID collision has occured, and that these *should not* have been treated as exact duplicates.  This logic would have been for both logging a triage file outlining the fact that this collision has occurred ; and, also, for the decision-making process in deciding *not* to reproduce exact duplicates in the output file, or output shard files, from "mbox_pre-parser.rb", but otherwise to write the metadata from each email entity into this output where a collision has not occured upon the Message-ID (a rare event).

## Tell me about what we are *really* doing about removing exact duplicates.
As we don't want to treat our original Message-ID as an immutable "Rosetta Stone" for threading (even where these ID collision occur), so we must not use it as our primary key for the downstream processing ("bin/splitter.rb") and the immutable manifest.  Instead we create a synthetic `internal_id = sha256(message_id + body_hash)` which *is* deterministic *and* unique, to use as the primary key.  This way we still retain the ability to make connections within Knowledge-Graph creation, between Message-IDs, via their In-reply-to or References headers via thie metadata, and yet no data is ever silently overwritten by a collision.  This means that *every* row within the immutable manifest will now have an internal_id metadata, in order to conform with schema consistency ; and the 99.99% of non-collision cases, it (the internal_id) is still unique and deterministic, without the need for conditional logic querying whether to use internal_id or message_id downstream ; and yet by the collision scenario, it becomes unremarkable because the formula already handled it.  This is quite a clever way to work. Because internal_ids are deduplicated during the ingest phase, we won't be overfitting this data during training LoRA when a message collision has occurred.

### Explain this again to me.
We should record the "key" within our shard outputs from `mbox_pre-parser.rb` (and subsequently our manifest file) as the "internal_id', which comprises of a hash of the message_id concatenated with the raw (not yet decribbed) email body. This way, if the message id is not missing, this hash will confer the ability to detect the difference between an exact duplication and an email collision.

## What are cribs?
Cribs are certain sign-offs, and other common repetitive patterns, appearing within emails at certain predictable places within the email body text, and also taken out of place.  For example, if Hans always signs off with his address, then this crib will appear both in the set as "train", and the set as "val", and the set as "test", every time an email from Hans appears in these sets, albeit on separate email threads. This would be contamination of data between sets.

In reality we will *not* be creating a boiler_plate dictionary at **ingest** time via an AI inference model or via standard regexps.  Instead we will use an AI to do so just prior than the time of training LoRA (the pre-LoRA training stage).

## I am worried about boilerplate code appearing within the emails (such as email signatures), getting put into all three sets : "train", "val" and "test".  This *will* happen. How can I guard against it by stripping emails of all repetitive sign-offs, greeting sign-ins, and/or boilerplates?
You could mistakenly attempt a three-pronged defence at the **ingest** time (which we will ***NOT*** be doing here at all in favour of doing it at the time of **pre-LoRA training** (prior than the training to the LoRA adapters), in which you might:  
- 1. Strip RFC 3676 sig blocks (everything after "-- \n")
- 2. Run frequency analysis during ingest to build a boilerplate_dictionary (anything appearing verbatim in >N% of threads is template cruft).
- 3. Make "mbox_pre-parser.rb" default to removing (via regexps) common patterns appearing within the boilerplate dictionary (such as "Best regards", "Sent from my iPhone", legal disclaimers, etc).

### Would "mbox_pre-parser.rb" utilize the boilerplate_dictionary previously created?
If the concept was not flawed, that would be a design, at **ingest** time, involving a two-pass workflow, where pass 1 uses an AI model (called "weak supervision") to build the boilerplate_dictionary, scanning your corpus (body of email messages), and it would emit a JSONL file of high-frequency text blocks (such as those which have a configurable threshold of say appearing in >5% of threads).  Then pass 2 would load that current dictionary, and excise matches (alongside hardcoded RFC 3676 sig-block regexp and the usual "Sent from my iPhone" suspects), before subsequent processing.  

### Why we don't perform this (hypothetical) crib removal at ingest time.
We don't do this (and I mention this as a dead-end in terms of a hypothetical proof of concept which failed) because: 
- 1. We would, unfortunately, be required to duplicate the data from within the shard files output from "bin/mbox_pre-parser.rb", in order to process further this version of the data (email bodiesv with the cribs excised).  This data duplication would kind of be a poor design decision, because it breaks the DRY (don't repeat yourself) principle of data computation in general.
- 2. If would be very difficult without using an AI inference time model (like GPT-4, Claude, Deepseek) to non-manually decide what is to be considered as a crib or boilerplate, within a corpus of 20 years of emails.  It would be too much work to manually sample, and to enable a human to decide what is a crib, as humans are prone to tiredness and human error, and differences of opinion. Thus hardcoding common patterns for what is to be considered as a crib, would be debatable and brittle.  

## So what do we want to do them?
Instead, we *do* want to automate this boilerplate_dictionary creation at **pre-LoRA training** time, which is *after* **ingest** time ("bin/mbox_pre-parser.rb"), and after **digest** time ("bin/splitter.rb"), by using an inferrence AI model ("weak supervision"), with possibly another model to supervise that it has not missed anything.  In particular, if somebody (a user) copies the boilerplate text and injects it into the middle of an email, then we still subsequently want a script to remove this boilerplate (which might well contain personally identifiable information), replacing it by stable placeholders (e.g. [USER_NAME], [PHONE_NUMBER]). This would maintain the structural utility of the email for training, while severing the link to the actual individual. 

***IMPORTANT!!!***

- It is highly recommended that this boiler_plate dictionary creation (at LoRA adapter training time) ought to be by an llm model ***hosted locally*** (at the inference time of this llm).  This way you can guarantee that no PII (personally identifiable information) has been sent to the cloud at all, and therefore that no cloud model has retained your prompt, or response data, containing any PII. The same applies to any AI model involved in the process of PII scrubbing.

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

This not labelling.  This is a way to process the data, in order to make it such that ML (machine learning) can train upon it.  Note that we will keep the ">" (and some multiples of it appearing) in our Alpaca format.  

Most LoRA tools (axolotl, unsloth, etc.) accept the Alpaca format natively which is a JSONL structure as something like
```jsonl
{"instruction": "Write a haiku about IRC chat.", "input":"", "output": "Nicknames flicker fast,\nScroll of jokes and late-night code-\nPings fade into dawn."}
```

Modern trainers like Unsloth and Axolotl allow Alpaca to have four fields : "instruction" (task), "input" (extra context, can be empty), "output" (response), plus optional "system" and an optional "history".  

"instruction" is a static string template you define to guide the model's behaviour, whereas "input" and "output" receive their values from dynamic variables which contain your specific email snippets.

So we may keep "system" as a static persona (e.g. "You are a professional assistant") ; "instruction" as something like, "Draft a professional reply to the following email", or "Summarize the following thread" ; and we will include the previous message within "history", and the quoted text (from the reply email) in "input", and your actual reply (from the reply email) in "output". The actual reply to the input comes from the non-quoted part of the reply email, and I need to include this "output" to train the model upon the "input". The non-quoted part of the email becomes the "output" field. The "instruction", and "input", serve together as the prompt context.  


The "instruction" is the *task description* telling the model what to do (a directive like, "Reply to this quoted portion professionally), while "output" is the *actual email text that got written* within the reply.  


Think of "instruction" (the *task desciption*) with the "input" (the additional information) as the **prompt**, and "output" as the target completion that the model is being trained to generate. 

A specific issue is that within the original email there may be a lot more "instruction" as the *task desciption* (say 25 lines of it) than the quoted text within the "input" field from reply email (say 2 lines of it). In this case we ought to use the quoted portion of the reply message as your "input", *and* the full original of the previous message which this reply email is a reply to as our "history" (the *additional information*), so that that both the quoted fragment of the reply email *and* the "history" will be the true **prompt** that the model should learn to respond to, where the unquoted part of the reply email is our "output" for LoRA to learn . The unquoted parts within the previous email provide the context which drives the decisions (what we the model has read). The model ought to learn and emulation of human reasoning style without conflating "stuff it has read" with "stuff it directly responds to". Okay?

The reply is a response to what the replier chose to engage with.

## When I combine the original email and the quoted part of the present email, should I strip >+ quote marks?
We should keep the ">" quote marks, as LLMs recognize them as standard markers for conversational history ; whereas stripping them can make the model confuse who said what.  You should normalize messy nesting (like ">>>") to keep the context clean.

### Explain more about how to normalize messy nesting.
We ought to standardize inconsistent quoting.  Emails often have formats like "> > >" with spaces ; ">>>" without ; or random indentations.  We must collapse these to consistent "> " per nesting level (one "> " = original, "> > " = reply-to-reply), and trim excessive depth beyond 2-3 levels, because ancient context rarely helps the model learn.

## Within the "input" field, can I have multiple quote blocks and responses to that previous email?
That is the question! Email replies often interleave multiple quote blocks and responses, and you naturally would wish to interleave this, and not repeat the previous email, for each repetition. This is in order not to break the DRY (don't repeat yourself) principle in data structures.  There appears to be 2 methods within the AI industry currently of doing this.  One is called ShareGPT and the other is called ChatML.  I don't think that either are programmatically viable in terms of data curation, so I will break the DRY principle on this occasion.  

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
- 3. Would it be as effective at ML than repeating the previous email within the "history" field would be for each (latest) reply-to quotation "innput" field, taken from within the present email, in association with the most recent unquoted text from the present email : as the value of the "output" field?
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

## A proposal
I was thinking about, at pre-LoRA training time (not at ingest time, nor at digest time), a boilerplate file created (via "weak supervision") which contains stats about cribs (email signoffs, PIIs, "many thanks", etc.) so that state (pertaining to these cribs) can be retained between training runs (not regenerated totally each training time of LoRA). Then do a simHash on the email_body after crib removal, keeping a record of each simHash for each email_body (after crib substitution by intelligible placeholders and >+ removals). 

Now we have the data to do the inspecting of the Hamming distance between emails.  This is done so that we can ignore both cribs and duplicates *between* threads, for Alpaca and ML, so that downstream training of LoRA can ignore verbatim content (or near-verbatim content) which was copied between email threads. This, hence, will hopefully assist towards prevention of contamination between our sets/pools.  Stripping boilerplate before simhash means we are comparing actual content semantics, not just shared label signatures ;  though we need to make sure that our simhash Hamming distance threshold is correctly tuned on, because the "correct" cutoff varies wildly by domain (emails can be legitimately similar without being duplicates). Contamination is primarily about **verbatim or near-verbatim overlap**, not semantic similarity, i.e. not upon *content meaning* but upon *verbatim content*.  We don't want the model memorizing exact text from "train" that appears in "val", artifically inflating your metrics.  The same applies to exact text from "train" appearing both in "train" and within "test". 

## Why I ought not to do simHash Hamming (fuzzy) dedupe *within* an email thread.
Because the first email might be 
```txt
printg('Hello')
```
whereas the reply might be 
```txt
printf('Hello')
```
Intra-thread similarity is a *signal* (corrections, refinements, quoted context).  But if this is the exclusive email content *between* threads then we *do* wish to filter it both to avoid dataset pollution, and to avoid repetition of verbatim text within a sets ; i.e. between "train" and "val" and between "train" and "test". Inter-thread is noise. Our dedupe should only compare emails across different thread_ids, treating each thread as a conversational unit where internal redundancy is intentional and meaningful.

## How would this dictionary accrue newer signatures from newer users whose messages are arriving in newer email batches? Do we need a dictionary mutable manifest file like a JSON structure?  
A mutable "boilerplate_dict.json" makes sense. This file ought to be able to evolve over time.

TO DO.  Implement this.

## And how would we treat two near-signatures, for example "with love from George" and "with love from Jorge"?
You would store *templatized* patterns (regex or slot-based like `"with love from {NAME}"`) rather than verbatim strings, or regex "with love from \w+", as I don't want to fill the boilerplate crib data file with "with love from George", *and* with "with love from Jorge".  We are specifying within our boilerplate crib file (potentially a JSON file) that both are the same, and are to be omitted from the next stages of fuzzy dedupe (simhash Hamming distance) between threads, and hence between sets, prior to the subsequent Alpaca format creation.  Fuzzy dedupe between threads is intended to be a protection against a scenario where a user copies text from one thread to another thread, and thereby might contaminate the sets.  

## Advise me how to set score levels for my fuzzy deduplication of email messages. Do I vary the input level that the mbox_pre-parser.rb dedupes upon?
You should vary the threshold mbox_pre-parser.rb uses would use for the deduplication via a hypothetical `--simhash-threshold` input option.  It defaults to 3.  A higher number (e.g. 5 to 7) will catch more similarly looking variants, while a lower number (1 to 2) is safer to avoid false-positive deletions of legimate short replies like "Thank you" or "Okay", which I suspect are not very useful for AI training.  


## Advise me how to set score levels for my fuzzy deduplication of email messages between threads. How do I vary the input level whcih the "bin/contamination_guard.rb" fuzzy dedupes upon?

If the same message was sent twice with different Message-IDs (common in cross-postings or resends within a thread),  `bin/mbox_pre-parser.rb` will miss them, and this is where our simHash-based deduplication in `bin/contamination_guard.rb` provides the necessary safety net at pre-LoRA training time, not at digest, nor at ingest time.

We want to do this prior to the actual LoRA training time (training of the LoRA adapters), *not* at ingest time, because at ingest time, "bin/mbox_pre-parser.rb" has no semantic concept of email threads, and we *don't* wish to drop either of or both of two similar (Hamming distance) messages from *within* any thread because these messages, although appearing similar, may contain crucial amendments in a code-rich email (even by as little as a character, or a few characters).  Think of an email containing "My code is `printg "hello world"`", to which the response is "Typo dude. Use `printf "Hello world"`". 

To catch near-duplicates prior to LoRA training time *between* threads, not *within* threads, the "bin/contamination_guard.rb" bakes in its own version of simhash.
- **Logic**: It generates a 64-bit fingerprint of message bodies and compares them using Hamming distance.
- **Sensitivity**: Controlled by `--threshold FLOAT` (default: 0.7). A lower threshold is more strict (requiring closer similarity to trigger a drop), while a higher threshold catches more distantly related variations. The easiest contents to catch will be legitimate short replies such as "Thank you", or "Okay", which I suspect are not very useful for AI training.
- **Performance**: We are comparing a constant number of buckets in one set against a constant number of buckets in another set, thus the two numbers mulitplied by each other is O(constant), or O(1) time.


## What are we *will* doing at pre-LoRA training time (i.e. not within "mbox_pre-parser.rb") shall be:

- i. Creating a boiler_plate dictionary of cribs and repeated patterns from our email bodies by using a weak supervision llm inference, not frequency analysis.
- ii. Dynamically removing cribs and boilerplate duplications from the email_body (the result to be kept in RAM) before fingerprinting this modified email_body (with the cribs excised) using simHash for fuzzy dedupe. 
- iii. Performing fuzzy deduplication on these fingerprints, so that the creation of the Alpaca format, pertaining to inter-thread messages which are too near to each other in content, doesn't happen. This would have been done to avoid training upon absurd messages like "thankyou" or "cheers", and so that similar messages won't appear both in the "train" and "val" sets, nor in "train" and "test". Note that this has nothing to do with the metadata that gets put into the manifest file.

We will *NOT* be doing any of this at the ingest time (in favour of doing it at pre-LoRA training time), because within such a failed, and rejected, proof of concept as doing it at ingest time, we would have used "fuzzy dedupe" in fingerprints at the pre-parser stage, after crib removal, in order to *not* include these similar messages within the JSONL output shard files from "mbox_pre-parser.rb" ; and hence the metadata for these similar messages would not be able to have gotten put into the manifest file!  We reject this approach because:

* The pre-LoRA training stage will involve the creation or amendment to a JSON-based pattern crib, in order to use boilerplate stripping (done via an llm weak supervision at inference time), so that we can do simhash fingerprinting on all email bodies which have had their cribs dynamically excised, and replaced by placeholders, in order to perform inter-thread simhash filtering, while keeping the intra-thread signal clean for the Alpaca format output.
* We do all this at pre-LoRA training stage, rather than the pre-processing stage (ingest), or the manifest creation stage (digest), because (a) the train/val/test split must happen at ingest time upon stable, content-unmodified data, so that, at pre-LoRA training time, we can generate Alpaca formats with various pattern cribs dynamically removed, without invalidating the split manifest, (b) boilerplate patterns are successively discovered during the inspection done to the email bodies, so baking them in to pre-processing would create a rebuild-everything loop, and (c) inter-thread simhash filtering is semantically a curation decision (deciding what is "too similar"), and we want it tunable independently of the immutable shards, which are output from "mbox_pre-parser.rb".
* We *now* have the right separation of concerns to avoid the "Oh no. I have to rebuild everything" trap that kills so many ML data projects.

## An astute observation.
I have an observation whereby the problem is the following.  
- The problem. The context of the location of the crib within the email is paramount.  If we blithely and blindly remove "love from" from the sentence mid-email as "Russia's latest aggression comes with love from Vlladimir Putin" then this sentence becomes "de-cribbed" to become "Russia's latest agression comes with Vlladimir Putin" where the crib was not actually a crib.  This is not what we want to do.
- The proposed solution. Either our crib patterns within the boilderplate crib file need positional anchors (e.g. "appears within last N lines", or is preceded by a signature delimiter) or they require stuctural content like "followed by {NAME}" in order to disambiguate sign-off boilerplate from legitimate text ; or, more usefully, we use an AI LLM at inference time (weak supervision) to decide what is a crib and what is not.  Another weak supervisor LLM can supervise the original llm in order to be doubly certain.

# Why we don't perform intra-thread fuzzy dedupe (after crib removal) at curation time.
If we would perform intra-thread fuzzy dedupe (after crib removal) at pre-LoRA training time, then two emails with similar content, but within the same thread, will be fuzzy deduped.  This is especially relevant where you are training the LoRA adapters upon code-rich emails.  For example, if a correction to the verbatim code contained within an email was made, then this crucial correction might involve only a few characters, but, by fuzzy dedupe these emails would be very similar in terms of Hamming distance, and one, or both, would be blocked.  We don't want this at all, as we *need* this original context, and the response to it (the content which this response was a response to, and the response itself), eventually within the same thread, and thus within the same set (e.g. say, "train") in order for ML (machine learning) to happen, i.e. we don't wish to drop either emails from the content which is being read from the JSONL shards which were output from "bin/mbox_pre-parser.rb" if those contents are within the *same* email thread.  

We *will* eventually desire to do a test of Hamming distance between emails between "train" and "val" at training time (and "train" and "test"), to protect us against the case whereby some clever user, whether by accident or design, has copied a load of text between threads which would otherwise (without Jaccard and fuzzy dedupe between sets) impair our model's ability to make generalisations instead of regurgitation, after this content had randomly, but deterministically, gotten positioned in both "train" and "val", or in "train" and "test" via the 80/10/10 probability ratio.  This would be contamination and would impair ML.

# Why we *do* train upon '> ' characters when we create our Alpaca format output at the end of the Curation stage.
We must not remove the quoted text of 3 times "> " or fewer "> "s, (i.e. "> > > " or less) from each email body which contains quotes from previous messages within this thread, at pre-LoRA training time, because the model may need these to learn ; but our model can't train upon quoted text which contains 4 or more "> ", (i.e. more than quotes within quotes within quotes) as this might confuse it. 

We must not censor this data content duplication intra-thread, because doing so would break our model's ability to learn associations between concepts. So, we must remove 4 or more levels of quoted text at pre-LoRA traing time, outputting the stripped version to the relevant part of the data Alpaca data structure format. After we have done this, we also trim trailing white space from the end of each line within the email body in our attempt to avoid hallucinations.  We wish to keep the whitespace at the beginning of, and within, the middle of each line as this may be beneficial to the model learning syntax.

TO DO.  IMPLEMENT THIS.

# Why we don't ignore this duplication of data from a previous email, which is being quoted within the present one.
We would be mistaken to think that we ought to ignore quoted text within reply-to emails, or that we ought to do this in order to remove "noise", and to remove duplication : quoted text is often a repetition of information from earlier within an email thread. If we don't imply this "context" within the "input" field, taken from the present email as the text quoted (by using "> ") from the previous email, of which this present one is as an "In-Reply-To" (which is a field taken from the email header for metadata for RAG), then this can distort the model's understanding, and also waste computational resources. 

## What is meant by simHash fingerprinting within "bin/contamination_guard.rb"?
In this context, "fingerprinting" is the process of turning a long email body into a compact, mathematical signature, so that the system can instantly compare two messages for similarity, without performing slow word-for-word text matching. It is how we detect "near-duplicates", and do cross-split contamination guarding. SimHash generates a 64-bit "fingerprint" for text, where similar documents produce similar fingerprints. Unlike MD5/SHA, small changes result in small hash differences, allowing fuzzy matching via Hamming distance (count of differing bits). For fuzzy deduplication we may use the rubygem as simhash2.

## What is "bin/contamination_guard.rb" for?
`contamination_guard.rb` is a post-materialization audit tool that catches data leakage across inter-thread splits, and thus across your train/val/test splits. At pre-LoRA training time, after we have done previously dynamic boilerplate ceation of the cribs within the emails, and have done dynamic crib removal from these emails, `contamination_guard.rb` fingerprints each record using both k-shingles (Jaccard similarity) and a hand-rolled SHA256-based SimHash (Hamming distance), either facilitating :

* 1. By default, no local-sensitivity, which will subsequently require an inspection of O(n²) pairwise comparisons across splits to find near-duplicates that slipped past the thread_id hashing (e.g., forwarded emails, templates, copy-pasted content in unrelated threads). 
* 2. With local-sensitivity, whereby each fingerprint is bucketed into bands : so that we will only compare decribbed email bodies that land within the same bucket.  For n decribbed email bodies, the time taken to put each into a bucket is O(n), and to compare the items within the same bucket is near to O(1) per bucket if the number of buckets has been tuned correctly. We need to compare every bucket in train against every bucket in val, and every bucket in train with every bucket in test, and every bucket in val with every bucket in test. 

In both cases, if contamination between sets is found, `contamination_guard.rb` applies a quarantine policy (nuke test/val items, nuke both sides, or flag for coassignment) and outputs an exclusion_ids.txt for downstream filtering, failing the pipeline if contamination exceeds 1%. Worth noting: it rolls its own simhash() function.

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

TO DO, facilitate the rebuilding of KG, and RAG embeddings within the vector DB every retrain done to LoRA.  Also facilitate the possible rebuilding of KG and RAG independently of a retrain of LoRA.