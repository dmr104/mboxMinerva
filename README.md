# mboxMinerva

**Production-grade email archive LLM fine-tuning with immutable splits, PII safety, and RAG deployment**

[![License](https://img.shields.io/badge/license-All%20Rights%20Reserved-red.svg)](LICENSE)
- [INITIAL SETUP](./INITIAL_SETUP/README_FIRST.md)
- [Sales Pitch](./SALES_PITCH.md)
- [Technical details](./TECHNICAL.md)
- **Docs**: See `docs/` directory for extra AI-generated guides

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
## Contact

- **Business matters**: battleaxe.firebrand@gmail.com
- **GitHub Issues**: [dmr104/mboxMinerva/issues](https://github.com/dmr104/mboxMinerva/issues)

---

# Aims of this repo

This repo is an attempt to fine-tune an AI model based upon the contents of an mbox, and then implement RAG upon this mbox based upon utilizing this fine-tuned llm.

# Email CPT/RAG Pipeline: Immutable Split Architecture Tutorial

## Core Concepts

### ID Taxonomy

The system works with three types of stable identifiers:

- **Message-Id**: Unique email header (e.g., `<abc123@example.com>`)
- **thread_id**: Computed from conversation grouping (e.g., `thread_xyz`)

---

### Background information
* PII = personally identififable information
* RAG = retrieval augmentation generation
* RNG = a pseudorandom number generator initalized with a specific seed so the "random" sequence is
deterministic and repeatable.  The same seeds leads to the same shuffles/samples.  Different seeds 
cause different but reproducible runs. 
* BM25 = a lexical ranking function balancing term frequency saturation and document length normalization against inverse document frequency.
* IDF = inverse document frequency is the reciprocal of document frequency (how common a term is).  A rare term has a high IDF; a common term a low one.
* KG = knowledge graph.
* Vector DB = this database will store precomputed passage embeddings for ANN search.
* ANN = approximate nearest neighbour.
* DPR = dense passage retrieval.
* BGE = Beijing Academy of AI General Embedding : a family of text models. Unlike DPR's two BERT towers (one encoder for the question, and another for the passage), BGE is a *single* encoder shared between queries and passages, disambiguated by E5 instruction prefixes (`query:` / `passage:`).
* RRF = reciprocal rank fusion 

## Design Guarantees

✅ **Immutability**:  Neither the contents of the val set nor that of test set will contaminate the train set.  
✅ **Incrementability**:  We don't reprocess older mboxes when newer ones arrive.  
✅ **Thread integrity**: All messages in a thread share the same split   
✅ **Scalability**: Sharding handles I/O

---

## Overview

mboxMinerva enables **RAG and fine-tuning** with:
- **Thread-aware assignment** to encapsulate all the email messages from each email thread within its own set
- **PII scrubbing at later stages** when forming Alpaca sets, just prior to Alpaca set decontamination.
- **Data Subject Request (DSR) compliance** with export/delete tooling, prior to RAG building, and hence prior to data-set formation (Alpaca for fine-tuning)
- **RAG implementation** Vector DB, plus BM25, plus KG, with RRF upon their ranked outputs. 

---

## Why thread-level assignment?

**Leakage prevention**: If message A and message B are in the same conversation, training on A and testing on B violates independence. Thread-level assignment prevents this.

---

## What is a key-management service?
In practice, the crypt key lives in a KMS (hardware-backed key management service) or HSM (hardware security module), rather than in code or in configuration files.  A KMS is something like Amazon Web Service KMS, or Google Cloud Platform KMS; and a HSM is a tamper-resistent hardware box that protects those keys so they can be used (e.g. to decrypt the crypt without anyone ever seeing or exporting the raw secret).  For self-hosted runners the *real* crypt key lives in an external secret store, and GitLab injects only a short-lived masked secret into the runner at job runtime such that the key is never within the repo, and it won't be baked into Docker images, and is scoped to specific projects and environments, so that it only exists within RAM on that runner whilst the particular CI job is decrypting the crypt.

HashiCorps Vault (or Openbao) is a self-hosted secrets manager that acts as a locked safe for passwords, API keys, and encyption keys, giving you a central place to store them encrypted, and to fetch short-lived credentials at runtime instead of hardcoding them in configs or in GitLab.

On-premises KMS/HSM means that instead of storing your encryption keys in a public cloud, they stay logically and physically under your control via your organisation running its own key-management system and hardware security modules within *your* own data centre which will be managed still by a central locked-down service.

A hardened OS/Kubernetes secrets backend is basically "Vault-lite" in the sense that you store secrets in the Kubernetes store which runs atop of the underlying operating system which is running on your servers (typically a hardened Linux distro like Ubuntu, Debian, or RHEL).  You make sure that the secrets which are stored in the Kubernetes store are encrypted at rest, and you lock the read-access to a tiny set of service accounts, injecting them into jobs only at runtime via the environment variables (temporary key=value settings which are visible only to that running process) or ephemeral volumes  (temporary filesystem mounts that exist only while the container/pod is alive). Every user/service gets the *minimum* permissions they need and nothing more, so only a few well-defined identities are ever allowed to read or use the encyption key.  You lock down each server which is within your cluster by disabling unused services. You lock down ports (by using a firewall on each host), and you enforce strong authentification like SSH keys, or 2-factor authentification, or SSO (Single Sign-On) with identity providers, such that an attacker will need more than one stolen credential to break in.  With SSO, you log in once with a central identity provider (which is an infrastructure--which is an identity provider service like Okta, Azure AD, or Google Workspace) that checks your login (password, multi-factor authentification, etc) and validates your account, and then issues short-lived tokens trusted tokens that the other apps accept as proof of who you are.

In any case, whichever key management system you choose to use, the idea is that the crypt key will never live within images, repos, or on long-lived disks and thus would be very hard to exfiltrate even if a node becomes compromised. 

## Why we do *not* need git-crypt 
We do **not** need git-crypt at all for four reasons:

- 1. git-crypt can only store encrypted files within a git directory.
- 2. We don't require git commits or tracking on the email vault.
- 3. It would be technically difficult to map a git repo in any Job Container to a backend directory on the Host.
- 4. We don't want to store *any* email data (encrypted or clear) in our main repo.

If we were to store encrypted emails addresses within an email_crypt (which I do *not* implement) we would use `gpg` instead, and store these outside of the mboxMinerva repo.

We would thereby treat the "crypt" (which is our email "vault") which stores our encrypted email hashes on the Container pipeline backend as "opaque GPG blobs".  On the Host we could generate a long-lived GPG keypair (or symmetric passphrase) and store this secret in OpenBao.  Within the CI we could pull this secret and use it to unlock the gpg encrypted email_crypt (which is our vault of encrypted email hashes).  Depending upon the design decision we could do this either at a file level (each file that stores emails get encrypted), or at a granular level (whereby each encrypted email hash is stored one-by-one within a clear file).  In any case, it is unclear what benefit storing `gpg` hashes of each email (or even each email address) would achieve.  I include this within this document as it was a useful thought experiment which lead to this dead-end being eliminated from the design.

## SpamAssassin (SA)
SpamAssassin is a multi-layered scoring engine.  It combines regex pattern matching (sketchy phrases, ALL CAPS), Bayesian classification (trained of spam/ham corpora), DNS blocklists (known bad sender IPs), header forgery detection, and collaborative databases to assign cumulation points: pertaining to which if a threshold is crossed (default is 5.0) then this is marked as spam.

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
No.  SpamAssassin's Bayes engine actually ships "empty" and it won't even activate until you feed it 200 ham and 200 spam messages via sa-learn.  However the other non-Bayesian modules (like regexp rules, header checks, and DNS blocklists) *do* come with a massive, pre-weighted rulebook that works out of the box.

# Why I don't need this (hypothetical) SpamAssassin Integration
SpamAssassin integration is probably not worth the hassle because 
- 1. The mbox contains many years of historical emails so DNS blocklists and fingerprint databases won't be usful any more.
- 2. The Bayesian won't work out of the box unless I manually set it with 200 spam and ham.
- 3. The regexp pattern matching, for all I know, might lead to false positives.
- 4. Exact dedupe removals and fuzzy dedupe might be enough.

---
