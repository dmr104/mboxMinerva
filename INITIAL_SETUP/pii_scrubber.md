# Review

Recall that in `./Gitlab.sh` we used the `--volume gitlab-runner-config:/etc/gitlab-runner` flag to `podman run` which creates a volume on the host at `/home/dmr104/.local/share/containers/storage/volumes/gitlab-runner-config/`

This `/etc/gitlab-runner`is the directory that holds the `config.toml` and the state of the Gitlab runner, whose contents control the runner's state across restart of the gitlab runner.

When you `podman stop` + `podman rm` + `podman run` then three things determine whether it "remembers" itself: (1)  **config.toml** holds your registered runner definitions (tokens, executor type, volumes directive, tags); (2) **runner credentials** (the runner Auth token from the one-off command `gitlab-runner register`) also live within `config.toml`; (3) **build caches** in `/builds` are ephemeral and are wiped per-job anyway.

So if `/etc/gitlab-runner` is bind-mounted with the Host, the new Container inherits the old identity instantly.  No re-registration is needed.  If it is *not* mounted then amnesia occurs and you must re-register the gitlab runner to the Gitlab omnibus container.  In case you have forgotten how we did this, we grabbed a registration token from the GitLab UI (**Admin Area** → **CI/CD** → **Runners**).  Then we ran `podman exec -it gitlab-runner gitlab-runner register`

# Our Setup
An Image created from a Dockerfile is the read-only blueprint created by implementing this Dockerfile.  A Container is a running or stopped instance of a Container created from that Image.  The Image itself is not a Container.

In GitLab CI there is not any such thing as the common misconception as a "pipeline container".  In GitLab CI if we use the Docker or Podman executor then every job runs in is own fresh "job Container".  If we use other executors (shell, SSH, etc) then these jobs are *not* implemented as Containers, but *are* processes on a Host. We are using Podman so all our jobs are containers.

The user wants to inject a host directory (`mbox`) to the inside of a Container created from the image `ruby:remote-patched`, and cache an "email crypt" from the `/email_crypt` directory within that Container to a storage backend (in our case upon the Host).  Please don't be alarmed to find that `/email_crypt` is not present within the gitlab-runner container if and when you run `podman exec -it gitlab-runner /bin/ls`.  This is because the the `/email_crypt` is only mounted and attached to **each** ephemeral *job* container (and to the host backend), not to the runner's own filesystem.

In our gitlab-runner's `config.toml` file we will map `"/home/dmr104/ruby_projects/minerva-cache/email_crypt:/email_crypt:rw"` so that the "email crypt" (an encrypted record of emails) is mapped between the Host and the Container.  

**Why not use `podman run -v ...` to map `/email_crypt` within the container to the host?**

**Answer:**  The `podman run` command starts the *Runner Manager*. `podman run -v ...` is an **ad-hoc override** for you to inject files during local development.
 

The `config.toml` is an **infrastructure policy** which instructs the GitLab Runner to **automatically** mount specific host resources into *every* single CI Container it spawns. The CI Container cannot mount host files after the Container has started.

The `config.toml` tells that Manager how to create *Job Containers*. The `volumes` setting within `config.toml` instructs the Manager to "Mount `/home/dmr104/ruby_projects/minerva-cache/email_crypt` from the Host into **every** Job Container at `/email_crypt`."

`/email_crypt` is an **anonymous volume** (it lives and dies with the job container). 

To get a **Host Directory Backend** (persistent storage on your physical machine), you don't change the `podman run` command that *starts* the runner, as this would only affect the one gitlab-runner Container you are starting, not the CI Containers (which are "siblings" not "children" to this gitlab-runner Container) and these "siblings" would not be able to "see" the `mboxMinerva` repo on the Host.  You MUST define that mount by editing the runner's `config.toml` so that the Runner knows how to attach it to every fresh sibling Job Container it creates.

Remember always that `podman stop` + `podman rm` + `podman run` are necessary if you are changing the specific volume flags of the Gitlab Runner Container itself, but if you are merely changing the `config.toml` file within this Runner Container then as GitLab Runner generally automatically reloads `config.toml` every few seconds, a `podman restart gitlab-runner` might only be necessary if this reload does not happen by itself. If this happens then on the Host do:
```bash
podman stop gitlab-runner
cd /path/to/mboxMinerva/INITIAL_SETUP
./Gitlab.sh
```

# What we are *really* doing...
Our scenario is that instead of using git-crypt **storage** encryption, we want to use **runtime-sanitization** (`/bin/pii_scrubber.rb`) upon **data**.  Here, we are **not** committing any PII data (raw or encrypted) into the mboxMinerva repo.  After unlocking the email crypt/vault which has been encrypted using a GPG keypair or symmetric key, we just run `pii_scrubber` within the Container, pulling the pseudonymization salt from Openbao (where it is stored) via the CI pipeline, and this salt is then used to scrub email addresses in a deterministic fashion, i.e. scrubbing PII (emails, IPs) from text using deterministic pseudonymization.

**The data flow**
1. **The secret key to git-crypt**: Lives in OpenBao.
2. **Injection**: You pass it to the Job Container via pulling it to an Environment variable.
3. **Unlock**: Your container entry point or Job script must run `gpg --symmetric` or `gpg --decrypt` using this Environment variable. 
4. **Run Scrubber**: run `bin/pii_scrubber.rb` which will proceed as the vault is clear.

# **1. Injecting the Mbox from Host to Container**
Since your `run_tests` job uses the **Docker Executor** (manifested by `image:`), the container runs isolated. You cannot "mount" a host file from `.gitlab-ci.yml` unless the **Runner Admin** configured it in `config.toml`.
**fix:** Edit `/etc/gitlab-runner/config.toml` (or wherever your runner lives) to bind the host mbox:
```toml
[[runners]]
  [runners.docker]
    volumes = ["/run/user/1000/podman/podman.sock:/var/run/docker.sock", "/path/to/host/mbox:/mbox:ro", "/home/dmr104/ruby_projects/minerva-cache/email_crypt:/email_crypt:rw"] # :ro = read-only, :rw = read-write
```
*e.g. I had `/home/dmr104/ruby_projects/Mail_mbox` as my `/path/to/host/mbox`. (Without this, your container cannot see the host's `/path/to/host/mbox`; passing it as an Artifact is too slow/large.)*

You need to map a real directory on your host to the container's `/email_crypt`.

**Create the directory on your Host:**
```bash
mkdir -p /home/dmr104/ruby_projects/minerva-cache
```

(Note: If you are using Rootless Podman, ensure `/home/dmr104/ruby_projects/minerva-cache` is owned by the user running the Podman daemon, or use `:Z` if SELinux complains, e.g., `...:/cache:rw,Z`.)

# **2. Storing the PII salt in Openbao**
Outside of my repo directory (in `/home/dmr104/ruby_projects`) I have a file called `email_crypt_secret_salt`.
# We inject into OpenBao container (piping stdin to avoid file mounts)
```bash
cat email_crypt_secret_salt | \
  podman exec -i system-openbao \
  bao kv put -mount=secret minerva/ci-keys git_crypt_key=-
```

# **3. Pulling the salt**
**Pulling the secret salt using CI for pseudonymized Runtime Encryption/Decryption**

In your `.gitlab-ci.yml`, you fetch it.

```yaml
# In your script block:
- echo "Importing secret salt..."
# Retrieve the SECRET SALT from Openbao
- export SECRET_SALT_CONTENT=$(bao kv get -mount=secret -field=private minerva/ci-keys)
```

# **4. Using the salt**
In your `.gitlab-ci.yml`,

```yaml
scrub_data:
  image: ruby:remote-patched # Must have openbao AND git-crypt installed
  script:
    # --- Step 1: Login to Vault (OIDC/JWT) ---
    - export VAULT_TOKEN="$(bao write -field=token auth/jwt/login role=my-role jwt=$CI_JOB_JWT)"

    # --- Step 2: Fetch & Decode the Key ---
    # Fetch the Base64 string (-field=git_crypt_key matches the key we set above)
    - export THE_SECRET_SALT="$(bao kv get -mount=secret -field=git_crypt_key minerva/ci-keys)"
    
    # --- Step 3: Pass it to a script in the Container---
    # This transparently decrypts any .git-crypt encrypted files via the ruby script. Something like
    # Batch mode (shards):
    - pii_scrubber --vault-dir vault --seed "${THE_SECRET_SALT}" --input-dir emails/ --output-dir emails_scrubbed/
    # or something like, 
    # Single-file/stdin mode:
    # -  cat input.txt | pii_scrubber --vault-dir vault --seed "${THE_SECRET_SALT}" > output.txt
    # or,
    # -  pii_scrubber --vault-dir vault --seed "${THE_SECRET_SALT}" file1.txt file2.txt > output.txt
```

# Reflection
As I want to run all the ruby code that is within the Host repo (mboxMinerva) within a Container pipeline which runs many ephemeral Container jobs, I want the Dockerfile to use bundler to install all the gems which are required within this project.  The is the standard "Build once" pattern.  The Dockerfile accesses the Host repo via the "build context" (the `.` in  `podman build .` within the `.gitlab-ci.yml` file).  Within the Dockerfile we use the `COPY` instruction as in `COPY Gemfile Gemfile.lock ./` and `bundle install` *first* and then we **DON'T** copy the rest of the repo (the actual ruby code) as we don't want to create hundreds of github container images merely to test the ruby code each time it changes.  We instead want the Container pipeline to access the code from the Host repo and run it within a Job container within the Container CI (continuous integration) pipeline.  So we **DON'T** bake the repo code into the image for testing, and we **DON'T** map it *through* the Container using an ad-hoc **Bind Mount** (podman run -v /home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva:Z ...), which would project your live Host repo folder directly into the running GitLab-Runner Container such that the CI sibling Job Containers wouldn't be able to "see" this Host repo folder.  What do we do then?  Well, we **DO** specify `/home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva` within the Runner's `config.toml` so that **each** Job executes the latest edits instantly without a rebuild.

**Do this:** Edit `/etc/gitlab-runner/config.toml` (or wherever your runner lives) to bind the host repo to **all** Job Containers:
```toml
[[runners]]
  [runners.docker]
    volumes = ["/run/user/1000/podman/podman.sock:/var/run/docker.sock", "/path/to/host/mbox:/mbox:ro", "/home/dmr104/ruby_projects/minerva-cache:/email_crypt:rw", "/home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva:ro" ] # :ro = read-only, :rw = read-write
```

Note that we are **bind mounting** the Host repo read-only because we do *not* want the Container writing to it in any way.

We treat the "crypt" or "vault" which stores our encrypted email hashes on the Container pipeline backend as "opaque GPG blobs".  On the Host we can generate a long-lived GPG keypair (or symmetric passphrase) and store this secret in OpenBao.  Within the CI we pull this secret and use it to unlock the gpg encrypted email crypt/vault.  We do **not** need git-crypt at all for four reasons:

- 1. git-crypt can only store encrypted files within a git directory.
- 2. We don't require git commits or tracking on the email vault.
- 3. It would be technically difficult to map a git repo in the Container backend to a directory on the Host.
- 4. We don't want to store *any* email data (encrypted or clear) in our main repo.

## Dockerfile now looks like:
```ini
# -----------------------------------------------------------------------------
# mboxMinerva CI/CD Container - Ruby 3.4.7 (Debian Trixie/Bookworm)
# -----------------------------------------------------------------------------
FROM docker.io/library/ruby:3.4.7-slim

# 1. Install System Dependencies
#    - git: Missing from slim, needed for gemspecs and git-crypt
#    - build-essential: Needed for compiling pg and simhash native extensions
#    - libpq-dev: Needed for pg header files
#    - git-crypt: C++ binary for unlocking secrets (NOT a gem)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    libpq-dev \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# 2. Prepare App Directory
WORKDIR /mboxMinerva

# 3. Dependency Layer Caching
#    Copy only the dependency manifests first.
#    This ensures 'bundle install' runs only when Gemfile changes, not code.
COPY Gemfile Gemfile.lock ./

# 4. Install Ruby Dependencies
RUN bundle install --jobs=4 --retry=3

# 5. Runtime Configuration
#    We DO NOT copy source code here (./lib, ./bin).
#    It is bind-mounted at runtime on the gitlab-runner: podman run -v /home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva ...
CMD ["/bin/bash"]
```

## Gemfile now looks like:
```ini
source 'https://rubygems.org'

# Ruby 3.4.7 (Oct 2025) Compatibility Set
# ---------------------------------------

# Core Email Parsing (Pinned for Thread safety)
gem 'mail', '~> 2.8'

# Database for RAG/Context (Requires libpq-dev in Dockerfile)
gem 'pg', '~> 1.5'

# Contamination Guard (SimHash/Jaccard)
gem 'simhash', '~> 0.1'

# Unbundled Gems (MANDATORY for Ruby 3.1+)
gem 'net-smtp', require: false
gem 'net-imap', require: false
gem 'net-pop', require: false
gem 'psych', '~> 5.1'

# Unbundled Gems (MANDATORY for Ruby 3.4+)
# Base64 and CSV are effectively "bundled" but best declared explicitly for Bundler
gem 'base64'
gem 'csv'
gem 'logger'
gem 'open3'
```

## Remember to do the following:
```bash
cd /path/to/mboxMinerva
bundle install
```

You may need to install required dependencies on your system in order to achieve the `bundle install` such as:
```bash
sudo apt install libyaml-dev
```

# Afterthoughts
We also need to achieve persistent storage on the Host **bind mounted** to a directory within the Container where our directories and files which the ruby scripts create are contained.  So we mount the persistent Host directory to a specific path inside the Container (e.g. `/processed_data`). and tell our ruby scripts via `.gitlab-ci.yml` to write to there.

# ***WARNING!!!***
***DO NOT*** create a mount which is over the build directory in your Job Container!!!  The **authoritative source of truth** which contains this build path is the environment variable as **`$CI_PROJECT_DIR`**, which is going to be `/builds/<group-or-user>/<project-name>`, let's say, `/builds/dmr104/mboxMinerva`.  This directory is "sacred ground" which is managed by the GitLab Runner.  If you bind mount a Host folder there:
1.  **Git Will Fail:** The Runner tries to `git clone`/`git clean` there; if it sees existing files from the Host, it will likely crash or—worse—**wipe your Host directory** to make room for a clean checkout.
2.  **Collisions:** If two jobs run at once, they will literally overwrite each other's source code in real-time.

## So do do the following instead:
Edit `/etc/gitlab-runner/config.toml` (or wherever your runner lives) to bind the host repo to **all** Job Containers:
```toml
[[runners]]
  [runners.docker]
    volumes = ["/run/user/1000/podman/podman.sock:/var/run/docker.sock", "/path/to/host/mbox:/mbox:ro", "/home/dmr104/ruby_projects/minerva-cache:/email_crypt:rw", "/home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva:ro", "/home/dmr104/ruby_projects/minerva-cache/processed_data:/processed_data:rw" ] # :ro = read-only, :rw = read-write
```

## What we have done...
**1. Updated Runner's `config.toml`**:
Mount the host storage to somewhere like `/mnt/persist`.  In my case I have mounted to `/home/dmr104/ruby_projects/minerva-cache/processed_data`
```toml
[[runners]]
  [runners.docker]
    # Map Host path <-> Container path (Read-Write)
    volumes = [
      "/path/to/mboxMinerva:/mboxMinerva:ro",      # Source code mirror (Safe/Read-Only)
      "/home/dmr104/ruby_projects/minerva-cache/processed_data:/processed_data:rw"           # WHERE YOU WANT OUTPUTS SAVED
    ]
```

**2. Updated `.gitlab-ci.yml`**:
Point your script to that neutral path.
```yaml
split_job:
  script:
    # Tell splitter to write to the permanent mount
    - bin/splitter.rb --output-dir /processed_data/split_output
```

Now, `split_output` appears instantly on your Host in `/home/dmr104/ruby_projects/minerva-cache/processed_data/split_output` and persists, without breaking the CI's git operations.
