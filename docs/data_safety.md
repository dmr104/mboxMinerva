# Data Safety & Privacy Policy

## Overview
This document outlines how mboxMinerva handles personally identifiable information (PII) and sensitive data during email archive processing, model training, and RAG deployment.

## PII Inventory

### What PII Does mboxMinerva Process?
- **Email addresses**: Sender, recipient, CC, BCC fields
- **Names**: Extracted from display names and signatures
- **Phone numbers**: In email bodies and signatures
- **Physical addresses**: Mentioned in email content
- **IP addresses**: Email headers (X-Originating-IP, Received)
- **Device IDs**: Email client user agents
- **Account credentials**: Potentially in forwarded/quoted messages

### What We DON'T Collect
- Raw mbox files are processed locally; no data sent to third parties
- No telemetry or analytics beyond local logs

## Data Processing Pipeline

### 1. Ingestion (PII Scrubbing)
**Tool**: `lib/pii_scrubber.rb`

**What it does**:
- Pseudonymizes email addresses with deterministic hashing (e.g., `john@example.com` → `user_a3f8b2c1@example.com`)
- Redacts phone numbers, SSNs, credit cards (`<PHONE>`, `<SSN>`, `<CREDIT_CARD>`)
- Hashes IP addresses to RFC1918 private ranges

**Reversibility**:
- Pseudonym map stored separately in `crypt/pseudonym_map.json` (encrypted at rest)
- Original email addresses never enter training data

**Command**:
```bash
ruby lib/pii_scrubber.rb \
  --seed 42 \
  --deterministic \
  --save-map crypt/pseudonym_map.json \
  emails/raw.json emails/scrubbed.json
```

### 2. Training Data Preparation
**Input**: Scrubbed JSON → `splitter.rb` → train/val/test splits

**Guarantee**: Only scrubbed data enters `assignments.json` and split manifests

### 3. Model Training
**Risk**: Model memorization of PII fragments

**Mitigation**:
- Use LoRA fine-tuning (low-rank adapters) instead of full fine-tuning to reduce capacity for verbatim memorization
- Apply dropout (0.1) during training
- Monitor validation loss for overfitting

**Post-training audit**:
```bash
# Scan checkpoint for leaked PII patterns
grep -Eo '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b' models/checkpoint.bin
```

### 4. RAG Deployment
**Embedding storage**: Postgres+pgvector

**Access control**:
- Database credentials in `.env` (never committed)
- TLS for database connections
- Row-level security if multi-tenant

**Query logging**: Audit who searches what (for GDPR DSR compliance)

## Data Retention & Deletion

### How Long Do We Keep Data?
- **Raw mbox files**: User-managed (recommend deletion after scrubbing)
- **Scrubbed training data**: Retained indefinitely for reproducibility
- **Pseudonym map**: Retained for DSR reversibility (encrypted)
- **Model checkpoints**: 90-day retention (overwrite after new checkpoints pass validation)

### Data Subject Requests (DSR)
**Right to Access**:
1. Search `crypt/pseudonym_map.json` for user's email
2. Reverse-lookup pseudonymized ID
3. Query manifest for affected splits

**Right to Deletion**:
1. Identify all pseudonyms for the email
2. Tombstone entries in manifest (mark as `deleted: true`)
3. Re-materialize splits excluding tombstoned IDs
4. Retrain model from scratch (incremental retraining insufficient)

## Threat Model

### Insider Threats
- **Mitigation**: Pseudonym map encrypted with passphrase (not in repo)
- Audit logs for manifest access

### Model Inversion Attacks
- **Risk**: Adversary queries model to reconstruct training data
- **Mitigation**: Rate-limit RAG queries, monitor for extraction patterns

### Data Leakage via Test Set
- **Mitigation**: Immutable splits prevent test contamination; split integrity tests enforce this

## Compliance Checklist

- [ ] PII scrubber runs on all ingested data
- [ ] Pseudonym map encrypted and access-controlled
- [ ] Split integrity tests pass (no cross-contamination)
- [ ] Model checkpoints scanned for leaked PII
- [ ] Retention policy documented and enforced
- [ ] DSR process tested (mock deletion request)
- [ ] RAG query logs auditable

## Secrets Management

### Never Commit
- `.env` files (database credentials, API keys)
- `crypt/pseudonym_map.json`
- Raw mbox files

### Use
- `git-crypt` or `sops` for encrypted secrets in CI/CD
- GitHub Secrets for workflow credentials

## Contact
For data safety questions or DSR requests: [your-email@example.com]