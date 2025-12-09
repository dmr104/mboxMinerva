- [Note that we are implementing **none** of these concepts in out actual pipeline.  Therefore this markdown file is obsoleted and not relevant except to a completely different project. Note also that because of this, the following setups are untested, and are purely hypothetical ones.]

# Background info
- [The following paragraph is relevant as it has been implemented]

As I want to run all the ruby code that is within the Host repo (mboxMinerva) within a Container pipeline which runs many ephemeral Container jobs, I want the Dockerfile to use bundler to install all the gems which are required within this project.  The is the standard "Build once" pattern.  The Dockerfile accesses the Host repo via the "build context" (the `.` in  `podman build .` within the `.gitlab-ci.yml` file).  Within the Dockerfile we use the `COPY` instruction as in `COPY Gemfile Gemfile.lock ./` and `bundle install` *first* and then we **DON'T** copy the rest of the repo (the actual ruby code) as we don't want to create hundreds of github container images merely to test the ruby code each time it changes.  We, instead, want the Container pipeline to access the code from the Host repo and run it within a Job container within the Container CI (continuous integration) pipeline.  So we **DON'T** bake the repo code into the image for testing, but we **DO** map it *through* the Container using a **Bind Mount** (podman run -v /home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva:Z ...), which projects your live Host folder directly into the running Container so that the Container executes the latest edits instantly without a rebuild.

- [***All*** the following are paragraphs which are *not* relevant to mboxMinerva because they are *not* implemented within mboxMinerva as it is shipped]

The git-crypt binary ***does*** store state within a .git directory.  Specifically, `git-crypt init` when run in the working directory of the git repo on the Host generates a random symmetric key *internally* in `.git/git-crypt/keys`, which, of course, should be accessible within the Container due to a **Bind Mount**, the detail of which which was expatiated in the previous paragraph. 

We must stress that `git-crypt` doesn't encrypt a *directory* like a LUKS volume does, but it encrypts *files* based upon `.gitattributes`  The "crypt" or the "vault" is just a folder. 

In a scenario where we encrypt secrets in our mboxMinerva repo (which we are *not* doing here) there is absolutely **no runtime interplay** between git-crypt on the Host and git-crypt in the Job Container—they are functionally totally estranged strangers who share custody of a locked box but never speak to each other.

Think of it like this:

1.  **The Host:**
    *  **Role:** Sets up the system and *makes* the key.
    *  **Action:** Runs `git-crypt init` (creates the lock) and `git-crypt export-key` (copies the key for export).
    *  **Day-to-day:** When you commit files containing encrypted email addresses upon the Host, `git-crypt` silently encrypts them *before* they are passed on to GitLab. The Host pushes "gibberish" to GitLab.


2.  **The Container:**
    *   **Role:** Blindly consumes the encrypted content.
    *   **Action:** Starts with a repository full of "gibberish" (encrypted files). It knows nothing about the Host.
    *   **The Key Acquisition from our Token Vault:** It downloads the **Key** from OpenBao (which you uploaded there).
    *   **Runtime:** It runs `git-crypt unlock .git/git-crypt/keys` to turn the gibberish back into readable files for the build script.

**The catch:** If you run `docker build` *after* unlocking inside the pipeline, you are baking those now-plaintext secrets permanently into that container image.

On the Host you would be continually *decrypting* in order to edit files, and *encrypting* these encrypted files upon every commit with the *encryption* key; so the Host git-crypt must know (and hold) the *decryption* key to turn the gibberish in the repo back into cleartext every time you open, diff, or modify encrypted files.

You would also require to have a .gitattributes file in your root folder. Something like 
```ini
# Enforce git-crypt encryption for vault/ (PII pseudonym mappings)
# All files under vault/ are automatically encrypted when staged
vault/** filter=git-crypt diff=git-crypt
.gitattributes !filter !diff # Safety: never encrypt the attributes file

# Prevent accidental commits of sensitive patterns
*.key filter=git-crypt diff=git-crypt
*.pem filter=git-crypt diff=git-crypt
*_secrets.yml filter=git-crypt diff=git-crypt
```

Here is the end-to-end "Symmetric Key" workflow. This bypasses GPG complexity by treating the git-crypt key as a simple binary artifact you store in Vault.

### 1. Host Side: Create & Inject Key (One-Time Setup)
Run this within the working directory of the repo on your host. We **Base64 encode** the key because Openbao key-value secrets engine stores JSON text, and raw binary keys will corrupt the storage.

```bash
# 1. Initialize git-crypt (if not already done)
git-crypt init

# 2. Export the symmetric key to a file
git-crypt export-key minerva-master.key

# 3. Base64 encode it so it fits safely in Vault (keeps it one long string)
base64 -w 0 minerva-master.key > minerva-master.key.b64

# 4. Inject into OpenBao container (piping stdin to avoid file mounts)
cat minerva-master.key.b64 | \
  podman exec -i system-openbao \
  bao kv put -mount=secret minerva/ci-keys git_crypt_key=-

# (Clean up local key files if you want, but KEEP A BACKUP somewhere safe!)
rm minerva-master.key minerva-master.key.b64
```

---

### 2. CI/CD Side: Fetch, Decode & Unlock
In your `.gitlab-ci.yml`, you pull the string, turn it back into a binary file, and unlock the repo.

```yaml
scrub_data:
  image: ruby:remote-patched # Must have openbao AND git-crypt installed
  script:
    # --- Step 1: Login to Vault (OIDC/JWT) ---
    - export VAULT_TOKEN="$(bao write -field=token auth/jwt/login role=my-role jwt=$CI_JOB_JWT)"

    # --- Step 2: Fetch & Decode the Key ---
    # Fetch the Base64 string (-field=git_crypt_key matches the key we set above)
    - export KEY_B64="$(bao kv get -mount=secret -field=git_crypt_key minerva/ci-keys)"
    
    # Decode it back to binary on disk
    - echo "$KEY_B64" | base64 -d > /tmp/ci-unlock.key

    # --- Step 3: Unlock the Repo ---
    # This transparently decrypts any .git-crypt encrypted files in the checkout
    - git-crypt unlock /tmp/ci-unlock.key
    - rm /tmp/ci-unlock.key # Clean up strict key immediately

    # --- Step 4: Execute Logic ---
    # The repo is now "open". Scripts can read encrypted files (like salt/seeds) normally.
    - ./scripts/scrub_emails.rb
```

# **1. The Missing Tools (Crucial Fix)**
Our `ruby:remote-patched` image is based on `ruby:slim`, which is Debian-based but minimal. It does **not** have `git`, `git-crypt`, or `gnupg` installed, so your plan will fail instantly with `command not found` if these are not installed.

**the fix:** Update `docker/Dockerfile`:
```dockerfile
RUN apt-get update && apt-get install -y git git-crypt gnupg && apt-get clean ...
```

# **2. Injecting the Mbox from Host to Container**
Since your `run_tests` job uses the **Docker Executor** (manifested by `image:`), the container runs isolated. You cannot "mount" a host file from `.gitlab-ci.yml` unless the **Runner Admin** configured it in `config.toml`.
**fix:** Edit `/etc/gitlab-runner/config.toml` (or wherever your runner lives) to bind the host mbox:
```toml
[[runners]]
  [runners.docker]
    volumes = ["/run/user/1000/podman/podman.sock:/var/run/docker.sock", "/path/to/host/mbox:/opt/mbox:ro", "/home/dmr104/ruby_projects/minerva-cache:/cache:rw"] # :ro = read-only, :rw = read-write
```
* e.g. I had `/home/dmr104/ruby_projects/Mail_mbox` as my `/path/to/host/mbox`. (Without this, your container cannot see the host's `/path/to/host/mbox`; passing it as an Artifact is presumably too slow/large.)*

`/cache` in that list is just an **anonymous volume** (it lives and dies with the job container, or gets lost in the ether). To get a **Host Directory Backend** (persistent storage on your physical machine), you don't change the `podman run` command that *starts* the runner—you obtain it by editing the runner's `config.toml`.  

**Why not use `podman run` to map `/cache` within the container to the host?**
The `podman run` command starts the *Runner Manager*. The `config.toml` tells that Manager how to spawn *Job Containers*. The `volumes` setting instructs the Manager to "Mount `/home/dmr104/...` from the Host into every Job Container at `/cache`."

You need to map a real directory on your host to the container's `/cache`.

** Create the directory on your Host:**
```bash
mkdir -p /home/dmr104/ruby_projects/minerva-cache
```

** Remember to regenerate you gitlab-runner container **
```bash
podman stop gitlab-runner
cd /path/to/mboxMinerva/INITIAL_SETUP/Gitlab.sh
./Gitlab.sh
```

(Note: If you are using Rootless Podman, ensure `/home/dmr104/ruby_projects/minerva-cache` is owned by the user running the Podman daemon, or use `:Z` if SELinux complains, e.g., `...:/cache:rw,Z`.)

# TO REPEAT -- Symmetric Key Workflow for git-crypt with OpenBao ("Easy Mode")

This approach bypasses GPG entirely. You generate a single binary keyfile (like a password file) that unlocks the repo. It is simpler but harder to rotate if leaked (you'd need to re-encrypt the repo).

*   **Host:** `git-crypt export-key ./ci-key` -> Upload `./ci-key` content to Vault (base64 encoded).
*   **CI:** Fetch -> Decode -> `git-crypt unlock /path/to/key`.

### Phase A: Host (One-Time Setup)

**Goal:** Generate the master key and store it safely in OpenBao.

1.  **Generate & Export the Key:**
    If you haven't initialized git-crypt yet:
    ```bash
    git-crypt init
    ```
    Now export the symmetric key to a file:
    ```bash
    # This creates a binary file 'git-crypt-key.bin'
    git-crypt export-key git-crypt-key.bin
    ```

2.  **Base64 Encode for Vault Storage:**
    Since Vault KV stores text strings and the key is binary, we must encode it.
    ```bash
    # Linux (base64 -w0 prevents newlines)
    base64 -w0 git-crypt-key.bin > git-crypt-key.b64
    
    # macOS
    base64 -i git-crypt-key.bin -o git-crypt-key.b64
    ```

3.  **Push to OpenBao:**
    Store the encoded string.
    ```bash
    # Assuming you are logged into bao
    bao kv put -mount=secret git-crypt-key key=@git-crypt-key.b64
    # This assumes that bao is running non-containerized on the host.  Adjust the command with `base64 -w -0 git-crypt-key.b64 | podman exec -i system-openbao bao kv put -mount=secret minerva/gpg private=-` as is necessary. 
    ```

4.  **Cleanup:**
    **DELETE `git-crypt-key.bin` and `git-crypt-key.b64` from your local disk immediately.** If you lose this key, you lose the data. (Ideally, keep a backup in a secure offline password manager like KeePass or 1Password, not on your desktop).


---

### Phase B: Container / CI (Runtime)

**Goal:** Fetch the string, decode it back to a binary file, and unlock the repo.

**Updated `.gitlab-ci.yml` Logic:**

```yaml
# Inside your job script:

# 1. Fetch the Base64 string from Vault
- export GIT_CRYPT_KEY_B64=$(bao kv get -mount=secret -field=key git-crypt-key)

# 2. Decode it back to a binary file
- echo "$GIT_CRYPT_KEY_B64" | base64 -d > /tmp/git-crypt-key.bin

# 3. Unlock the repo using the keyfile
- git-crypt unlock /tmp/git-crypt-key.bin

# 4. (Optional) Cleanup safely
- rm /tmp/git-crypt-key.bin
```

### Why this is simpler?
*   No `gpg --import` within the container.
*   No trusting specific GPG identities.

# Alternatively, using gpg for git-crypt with OpenBao ("Zero-trust Mode")

In this approach you treat the CI environment as an ephemeral client that needs to obtains its identity from your central authority (OpenBao) at runtime.

So the procedure (which we are not doing here) whereby we encrypt secrets in our mboxMinerva repo *would be*:

1.  **On the HOST:** 
    *   You need to use `git-crypt init` here **ONCE** to *configure the lock*. You effectively say, "I trust the Key `Minerva_Bot_Public_Key` to open this the email addresses vault." You run `git-crypt add-gpg-user...` here to update the this crypt's metadata, which you then commit and push.
2.  **In the CONTAINER:** 
    *   You need to use `git-crypt` here **EVERY RUN** to *use the key*. The pipeline CI job pulls the private key from our token vault (Openbao), imports it to the job Container, and runs `git-crypt unlock` to actually read the files.

### Phase A: Host (One-Time Setup)
Create a dedicated "Minerva CI" identity (don't use your personal key to avoid exposing your main identity to the build server).

```bash
# 1. Generate a new key (use a distinct name like "Minerva Bot")
gpg --full-generate-key

# 2. Get the Long ID (e.g., AABBCCDDEEFF1234)
gpg --list-secret-keys --keyid-format LONG

# 3. Export Private Key (Armored) to a file
gpg --armor --export-secret-keys AABBCCDDEEFF1234 > minerva-ci.asc

# 4. Upload to OpenBao (File -> KV Secret)
# Note: Use '@' to tell Bao to read from file
# This assumes that bao is running non-containerized on the host.  Adjust the command with `cat minerva-ci.asc | podman exec -i system-openbao kv bao put -mount=secret minerva/gpg private=-` as is necessary 
bao kv put -mount=secret minerva/gpg private=@minerva-ci.asc

# 5. Initialize git-crypt with this user locally
git-crypt add-gpg-user AABBCCDDEEFF1234
```

### Phase B: CI (Runtime Decryption)
In your `.gitlab-ci.yml`, you fetch it and pipe it straight into GPG.

```yaml
# In your script block:
- echo "Importing GPG key..."
# Retrieve the ASCII armor block
- export GPG_KEY_CONTENT=$(bao kv get -mount=secret -field=private minerva/gpg)
# Import it
- echo "$GPG_KEY_CONTENT" | gpg --batch --import
# Unlock the repo
- git-crypt unlock
```

# **3. The "Regenerate Flag" & Cache Logic**
You want a switch to nuke the cache? GitLab CI restores the cache **after** cloning the repo but **before** the script runs.
**fix:** Use a variable default and a `bash` check to wipe the cached directory if the flag is set.

Here is the implementation for the `.gitlab-ci.yml`, which says: for every job container of this job, take `./crypt/` from the job's workspace, -- which is synced to the shared cache between pipelines (see `config.toml` of gitlab-runner).

```yaml
# Add this variable at the top or in the job
variables:
  REGENERATE_CRYPT: "false" # Default: use cache. Run pipeline manually with "true" to force refresh.

run_tests:
  stage: app_test
  image: "${CONTAINER_REGISTRY}/${GH_USER_NAME}/ruby:remote-patched"
  # Define what to cache. This persists path 'crypt/' between runs.
  cache:
    key: "consumer-crypt-storage"
    paths:
      - crypt/
  script:
    # 1. The Toggle Logic
    - if [ "$REGENERATE_CRYPT" == "true" ]; then echo "🛑 FORCING CRYPT REGENERATION: Wiping cached   crypt..."; rm -rf crypt/*; fi
    
    # 2. Check/Init Logic
    - |
      if [ -f "crypt/.unlocked" ]; then
        echo "✅ Vault is already cached and unlocked."
      else
        echo "🔓 Unlocking git-crypt..."
        # Import key from CI Variable (GPG_PRIVATE_KEY)
        echo "$GPG_PRIVATE_KEY" | base64 -d | gpg --import --batch --no-tty
        git-crypt unlock
        touch crypt/.unlocked # Mark as success for next time
      fi

    # 3. Use the injected mbox (Must be mounted via config.toml!)
    - echo "Processing mbox from /opt/mbox..."
    - ls -l /opt/mbox
```



---
### **Verdict:** Stick to **GPG** if you plan to have other human contributors (easier to manage access revocation). Use **Symmetric** if this is purely for the robot.

### Note again that ***ALL*** of this markdown file was purely *hypothethical* and that **NONE** of it is used in the actual mboxMinerva code as it is shipped.  I only include it as a matter of interest for an application of a **different** project with a **different architecture** than mboxMinerva ships with.