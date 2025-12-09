# Vault Encryption with git-crypt

## Overview

mboxMinerva stores PII pseudonym mappings in `vault/` (email→REDACTED_xyz).
**All vault files are encrypted at rest via git-crypt** to prevent accidental
plaintext commits.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│ git-crypt init  │  One-time setup: generates symmetric key                                         
└────────┬───────────────────────────────────────────────────┘
         │
         v
┌─────────────────────────────────────────────────────────────┐
│ .gitattributes: vault/** filter=git-crypt diff=git-crypt   
│   → All vault/ files encrypted on `git add`                
└────────┬────────────────────────────────────────────────────┘
         │
         v
┌─────────────────────────────────────────────────────────────┐
│ VaultGuard.ensure_unlocked! (lib/vault_guard.rb)            
│   → Enforces unlock before PIIScrubber / DSRHelpers I/O     
│   → Writes sentinel, checks for binary garbage              
│   → Raises if locked (prevents corruption)                  
└────────┬────────────────────────────────────────────────────┘
         │
         v
┌─────────────────────────────────────────────────────────────┐
│ CI/CD: scripts/ci_unlock_vault.sh                           
│   → Decodes GIT_CRYPT_KEY_BASE64 secret                     
│   → Runs `git-crypt unlock` before tests                                                            │
└─────────────────────────────────────────────────────────────┘
```

## Setup (First Time)

```bash
# 1. Install git-crypt
sudo apt-get install git-crypt  # Debian/Ubuntu
brew install git-crypt          # macOS

# 2. Run setup script
./scripts/setup_git_crypt.sh

# 3. Store .git-crypt-key securely (password manager)
# 4. Add to CI/CD as GIT_CRYPT_KEY_BASE64 (masked, protected):
base64 -w0 .git-crypt-key

# 5. Commit .gitattributes
git add .gitattributes vault/.unlock_check
git commit -m "Add git-crypt vault encryption"
```

## Collaborator Onboarding

```bash
# Obtain .git-crypt-key from team lead (secure channel)
git-crypt unlock /path/to/.git-crypt-key

# Verify unlock
ruby -e "require_relative 'lib/vault_guard'; VaultGuard.ensure_unlocked!"
```

## CI/CD Integration

Add to `.gitlab-ci.yml`:

```yaml
variables:
  GIT_CRYPT_UNLOCK: "true"

before_script:
  - apt-get update -qq && apt-get install -y -qq git-crypt
  - ./scripts/ci_unlock_vault.sh
```

**CI Secret**: Set `GIT_CRYPT_KEY_BASE64` in GitLab CI/CD Settings →
Variables (masked + protected branches only).

## Security Properties

| Threat | Mitigation |
|--------|-----------|
| Plaintext vault commit | git-crypt encrypts on `git add` (transparent) |
| Locked vault corruption | VaultGuard fails before write |
| Key leak in CI logs | Key decoded to tmpfs, deleted after unlock |
| Unauthorized access | Protected branch + masked CI variable |
| Forgotten unlock | All PII tools call `VaultGuard.ensure_unlocked!` |

## Threat Model

**In Scope**:
- Accidental plaintext commit of vault/ (MITIGATED: git-crypt auto-encrypts)
- CI pipeline accessing vault (MITIGATED: unlock script + secret)
- Corrupted vault from write-while-locked (MITIGATED: VaultGuard sentinel check)

**Out of Scope** (manual operational security):
- .git-crypt-key stored unencrypted on disk (use password manager)
- Compromised developer machine (full disk encryption recommended)
- Vault access by unauthorized collaborators (GPG multi-user mode available but not configured)

## Troubleshooting

### Error: "vault/ is LOCKED"
```bash
git-crypt unlock .git-crypt-key
ruby -e "require_relative 'lib/vault_guard'; VaultGuard.ensure_unlocked!"
```

### Error: "git-crypt not initialized"
```bash
./scripts/setup_git_crypt.sh
```

### CI Error: "GIT_CRYPT_KEY_BASE64 not set"
1. Generate: `base64 -w0 .git-crypt-key`
2. GitLab: Settings → CI/CD → Variables → Add variable
   - Key: `GIT_CRYPT_KEY_BASE64`
   - Value: (paste base64 output)
   - Flags: ✓ Masked, ✓ Protected

### Verify Encryption on Disk
```bash
# Lock vault (simulate fresh clone)
git-crypt lock

# Check raw file (should be binary garbage)
file vault/email_map.json  # → "data"
hexdump -C vault/email_map.json | head  # → binary blob

# Unlock
git-crypt unlock .git-crypt-key
cat vault/email_map.json  # → readable JSON
```

## References

- git-crypt docs: https://github.com/AGWA/git-crypt
- Threat model: docs/data_safety.md
- VaultGuard implementation: lib/vault_guard.rb
