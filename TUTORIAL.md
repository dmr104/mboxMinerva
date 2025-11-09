# Tutorial: 

1) Install and init keys: brew/apt install git-crypt && gpg --full-generate-key; 

2) In repo: git-crypt init && gpg --list-keys and git-crypt add-gpg-user <KEYID>; 

3) Protect the vault dir: echo 'vault/** filter=git-crypt diff=git-crypt' >> .gitattributes && git add .gitattributes; 

4) Create structure: mkdir -p vault/{maps,keys,logs} && touch vault/.keep && printf 'Encrypted via git-crypt; unlock to view.\n' > vault/README.md; 

5) Commit once: git add vault && git commit -m 'Add encrypted vault/'; 

6) Usage - lock/unlock: git-crypt lock (re-lock if needed) and git-crypt unlock (requires your GPG key) before editing vault/; 

7) Share access: git-crypt add-gpg-user <COLLEAGUE_KEYID> (or export a symmetric key: git-crypt export-key vault/git-crypt-key and recipient runs git-crypt unlock < vault/git-crypt-key); 

8) CI: store exported key as a secret file and run git-crypt unlock -F $CI_SECRET_PATH before tests/build, then rm the key; 

9) Verify: git-crypt status and git check-attr filter -- vault/somefile confirm encryption; 

10) Rules: keep GPG private key backed up, never commit secrets outside vault/, and ensure .gitattributes is in every branch before adding vault/ files to avoid plaintext landing in history.