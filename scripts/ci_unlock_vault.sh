#!/usr/bin/env bash
# CI helper: Unlock git-crypt vault using secret key from CI variable.
#
# Usage (GitLab CI):
#   GIT_CRYPT_KEY_BASE64=$GIT_CRYPT_KEY_BASE64 ./scripts/ci_unlock_vault.sh
#
# Prerequisites:
#   - Set CI/CD variable GIT_CRYPT_KEY_BASE64 (masked, protected)
#   - Generate via: base64 -w0 .git-crypt-key

set -euo pipefail

if [[ -z "${GIT_CRYPT_KEY_BASE64:-}" ]]; then
  echo "ERROR: GIT_CRYPT_KEY_BASE64 not set. Configure in CI/CD settings." >&2
  exit 1
fi

# Decode key to temp file (secure tmpfs)
KEY_FILE=$(mktemp)
trap "rm -f $KEY_FILE" EXIT
echo "$GIT_CRYPT_KEY_BASE64" | base64 -d > "$KEY_FILE"

# Unlock vault
git-crypt unlock "$KEY_FILE"
echo "✓ vault/ unlocked successfully"

# Verify unlock
if [[ ! -d vault/ ]]; then
  echo "WARN: vault/ does not exist yet (first run?)"
  exit 0
fi

# Check sentinel
ruby -e "
require_relative 'lib/vault_guard'
VaultGuard.ensure_unlocked!(vault_dir: 'vault/')
puts '✓ Vault unlock verified'
"