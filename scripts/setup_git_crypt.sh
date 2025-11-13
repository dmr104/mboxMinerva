#!/usr/bin/env bash
# First-time setup: Initialize git-crypt and export key.
#
# Usage:
#   ./scripts/setup_git_crypt.sh
#
# Output:
#   - .git-crypt-key (store in password manager + CI secret)
#   - .gitattributes (committed with vault/** filter)

set -euo pipefail

echo "=== mboxMinerva: git-crypt setup ==="

# Check if git-crypt is installed
if ! command -v git-crypt &>/dev/null; then
  echo "ERROR: git-crypt not found. Install via:"
  echo "  Debian/Ubuntu: sudo apt-get install git-crypt"
  echo "  macOS:         brew install git-crypt"
  exit 1
fi

# Initialize git-crypt
if [[ -d .git-crypt ]]; then
  echo "✓ git-crypt already initialized"
else
  git-crypt init
  echo "✓ git-crypt initialized"
fi

# Export key
if [[ -f .git-crypt-key ]]; then
  echo "✓ .git-crypt-key already exists"
else
  git-crypt export-key .git-crypt-key
  echo "✓ Key exported to .git-crypt-key"
fi

# Ensure .gitattributes exists
if [[ ! -f .gitattributes ]]; then
  cat > .gitattributes <<'EOF'
# Enforce git-crypt encryption for vault/ (PII pseudonym mappings)
vault/** filter=git-crypt diff=git-crypt

# Prevent accidental commits of sensitive patterns
*.key filter=git-crypt diff=git-crypt
*.pem filter=git-crypt diff=git-crypt
*_secrets.yml filter=git-crypt diff=git-crypt
EOF
  git add .gitattributes
  echo "✓ .gitattributes created (commit it)"
fi

# Create vault/ directory
mkdir -p vault/
echo "unlocked" > vault/.unlock_check
git add vault/.unlock_check

echo ""
echo "=== NEXT STEPS ==="
echo "1. Store .git-crypt-key securely (password manager)"
echo "2. Add to CI/CD as GIT_CRYPT_KEY_BASE64:"
echo "     base64 -w0 .git-crypt-key"
echo "3. Collaborators unlock via:"
echo "     git-crypt unlock .git-crypt-key"
echo "4. Commit .gitattributes:"
echo "     git commit -m 'Add git-crypt vault encryption'"
