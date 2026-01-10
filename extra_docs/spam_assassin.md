# SpamAssassin Batch Filtering Tutorial for Deepin Linux
## Cleaning an Existing mbox File Before ML Pipeline Ingestion

This tutorial shows how to filter spam and duplicates from a static mbox file
before feeding it to `mbox_pre-parser.rb`. No mail server integration required.

---

## 1. Installation

Deepin is Debian-based, so we use `apt`. You need:
- `spamassassin` - the filter engine
- `spamc` - fast client that talks to the daemon
- `procmail` - contains `formail`, the mbox splitter

```bash
sudo apt update
sudo apt install spamassassin spamc procmail
```

---

## 2. Configuration (Batch Mode)

You don't need a full mail server setup, but you DO need the SpamAssassin
daemon (`spamd`) running. Processing thousands of emails by spawning a new
Perl process per message is painfully slow; `spamd` keeps the engine in
memory and `spamc` queries it instantly.

### A. Download the latest spam signatures:
```bash
sudo sa-update
```

### B. Enable and start the service:
```bash
sudo systemctl enable spamassassin
sudo systemctl start spamassassin
```

### C. Verify it's running (should show spamd on port 783):
```bash
sudo ss -tlnp | grep 783
```

---

## 3. The Cleaning Pipeline

Two distinct operations: **Deduplication** then **Spam Tagging**.

### Step A: Deduplication

Before wasting CPU cycles on spam checks, remove exact duplicates using
`formail`. It maintains a Message-ID cache and drops repeats.

```bash
# -D creates/uses a cache file to track seen Message-IDs
# 50000000 = ~50MB cache buffer (handles large mboxes)
# Duplicates are silently dropped; unique messages pass through

cat original.mbox | formail -D 50000000 .msgid.cache -s cat > unique.mbox
```

### Step B: Spam Tagging

Pipe every message through SpamAssassin. The `-s` flag splits the mbox
into individual messages, `spamc` processes each one.

```bash
formail -s spamc < unique.mbox > tagged.mbox
```

**Performance note:** Expect 20-100 emails/second depending on CPU.
Test on a small chunk first:
```bash
head -5000 unique.mbox | formail -s spamc > test_tagged.mbox
```

---

## 4. Handling the Tagged Output

Your `tagged.mbox` now has spam messages marked with headers like:

```
X-Spam-Flag: YES
X-Spam-Status: Yes, score=15.4 required=5.0 ...
Subject: *****SPAM***** Buy cheap whatever...
```

### Option 1: Filter in mbox_pre-parser.rb (Recommended)

Feed `tagged.mbox` to your Ruby script and skip spam rows. This preserves
the data but excludes it from training. Add to your message loop:

```ruby
# Skip messages flagged as spam
if message.header['X-Spam-Flag'].to_s.upcase.include?("YES")
  puts "Skipping spam: #{message.message_id}"
  next
end
```

### Option 2: Hard Delete Before Parsing

Physically remove spam from the file to save disk space:

```bash
formail -s bash -c '
  cat > /tmp/cur_msg
  if ! grep -q "^X-Spam-Flag: YES" /tmp/cur_msg; then
    cat /tmp/cur_msg
  fi
' < tagged.mbox > clean.mbox
```

---

## 5. Quick Reference - Full Pipeline

```bash
# 1. Update signatures & start daemon
sudo sa-update
sudo systemctl start spamassassin

# 2. Deduplicate
cat original.mbox | formail -D 50000000 .msgid.cache -s cat > unique.mbox

# 3. Tag spam
formail -s spamc < unique.mbox > tagged.mbox

# 4. Either:
#    a) Feed tagged.mbox to mbox_pre-parser.rb with spam-skip logic, OR
#    b) Hard-delete spam to create clean.mbox first

# 5. Run your parser
ruby bin/mbox_pre-parser.rb --input tagged.mbox --output emails/
```

---

## Gotchas & Tips

1. **First run is slow** - SpamAssassin downloads and compiles rules on first
   `sa-update`. Subsequent runs are faster.

2. **Bayesian learning** - For better accuracy, train SA on known spam/ham:
   ```bash
   sa-learn --spam --mbox known_spam.mbox
   sa-learn --ham --mbox known_good.mbox
   ```

3. **Adjust threshold** - Default spam score threshold is 5.0. Edit
   `/etc/spamassassin/local.cf` to change:
   ```
   required_score 4.0
   ```

4. **Network tests** - SA uses DNS blocklists by default. If you're offline
   or behind a firewall, disable them in `/etc/spamassassin/local.cf`:
   ```
   skip_rbl_checks 1
   ```

5. **Memory usage** - `spamd` can be hungry. If you're on a constrained
   system, limit child processes in `/etc/default/spamassassin`:
   ```
   OPTIONS="--max-children 2"
   ```