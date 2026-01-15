# Review

Recall that in `./Gitlab.sh` we used the `--volume gitlab-runner-config:/etc/gitlab-runner` flag to `podman run` which creates a volume on the host at `/home/dmr104/.local/share/containers/storage/volumes/gitlab-runner-config/`

This `/etc/gitlab-runner`is the directory that holds the `config.toml` and the state of the Gitlab runner, whose contents control the runner's state across restart of the gitlab runner.

If you `podman stop` + `podman rm` + `podman run` then three things determine whether it "remembers" itself: 
- (1)  **config.toml** which holds your registered runner definitions (tokens, executor type, volumes directive, tags); 
- (2) **runner credentials** (the runner Auth token from the one-off command `gitlab-runner register`) also live within `config.toml`; 
- (3) **build caches** in `/builds` which are ephemeral and are wiped per-job anyway.

So if `/etc/gitlab-runner` is bind-mounted with the Host, the new Container inherits the old identity instantly.  No re-registration is needed.  If it is *not* mounted then amnesia occurs and you must re-register the gitlab runner to the Gitlab omnibus container.  In case you have forgotten how we did this, we grabbed a registration token from the GitLab UI (**Admin Area** → **CI/CD** → **Runners**).  Then we ran `podman exec -it gitlab-runner gitlab-runner register`

# Our Setup
An Image created from a Dockerfile is the read-only blueprint created by implementing this Dockerfile.  A Container is a running or stopped instance of a Container created from an Image.  The Image itself is not a Container.

In GitLab CI there is not any such thing as the common misconception as a "pipeline container".  In GitLab CI if we use the Docker or Podman executor then every job runs in is own fresh "Job Container".  If we use other executors (shell, SSH, etc) then these jobs are *not* implemented as Containers, but *are* processes on a Host. We are using Podman so all our jobs are Job Containers.

The user wants to inject a host directory (`~/ruby_projects/Mail_mbox`) to the inside of a Container created from the image `ruby:remote-patched`, and cache the "pre-processed mbox shards" from the `/mbox_pre-parsed` directory within that Job Container to a storage backend (in our case upon the Host at `~/ruby_projects/minerva-cache/mbox_pre-parsed`).  Please don't be alarmed to find that `/mbox_pre-parsed` is not present within the gitlab-runner container if and when you run `podman exec -it gitlab-runner /bin/ls`.  This is because the the `/mbox_pre-parsed` is only mounted and attached to **each** ephemeral *Job Container* (and therewith to the host backend), not to the runner's own filesystem.

In our gitlab-runner's `config.toml` file we will map `"/home/dmr104/ruby_projects/minerva-cache/mbox_pre-parsed:/mbox_pre-parsed:rw"` so that the directory with "pre-processed mbox shards" is mapped between the Host and the Job Container.  

**Why not use `podman run -v ...` to map `/mbox_pre-parsed` within the container to the host?**

**Answer:**  The `podman run` command starts the *Runner Manager*. `podman run -v ...` is an **ad-hoc override** for you to inject files during local development to the Runner Container *only*.  The Runner Container and the Job Containers are **siblings**, not parent-child, so volumes on the Runner don't inherit downwards.

The `config.toml` is an **infrastructure policy** which instructs the GitLab Runner to **automatically** mount specific host resources into *every* single CI Job Container which it spawns. These CI Job Containers cannot mount host files after the Container has started.

The Runner Manager is the long-lived process (your `gitlab-runner` container) that polls GitLab for work and orchestrates the lifecycle of ephemeral Job Containers.

The `config.toml` tells that Runner Manager how to create *Job Containers*. The `volumes` setting within `config.toml` instructs the Manager to "Mount `/home/dmr104/ruby_projects/minerva-cache/mbox_pre-parsed` from the Host into **every** Job Container at `/mbox_pre-parsed`."

`/mbox_pre-parsed` is an **anonymous volume** (it lives and dies with the job container). 

## Binding the mboxMinerva repo between these Job Containers and the Host

To get a **Host Directory Backend** (persistent storage on your physical machine) for the mboxMinerva repo (so that these Job Containers will be able to run the ruby code), you don't change the `podman run` command that *starts* the Runner, as this would only affect the one `gitlab-runner` Container you are starting, not the CI Job Containers (which are "siblings", not "children", to this gitlab-runner Container, and these "siblings" would not be able to "see" the `mboxMinerva` repo on the Host).  You *MUST* define that mount by editing the runner's `config.toml` so that the Runner knows how to attach it to every fresh sibling Job Container it creates in order that these Job Containers can use our ruby code which is within the repo as `mboxMinerva`.

Remember always that `podman stop` + `podman rm` + `podman run` are necessary if you are changing the specific volume flags of the Gitlab Runner Container itself; but if you are merely changing the `config.toml` file within this Runner Container, then as GitLab Runner generally automatically reloads `config.toml` every few seconds, a `podman restart gitlab-runner` might only be necessary if this reload does not happen by itself. If this happens then on the Host do:
```bash
podman stop gitlab-runner
cd /path/to/mboxMinerva/INITIAL_SETUP
./Gitlab.sh
```

# What we are *really* doing...

## **1. Injecting the Mbox from Host to Container**

You need to map a real directory on your host to the container's `/mbox_pre-parsed`.

You cannot "mount" a host file from `.gitlab-ci.yml` unless the **Runner Admin** configured it in `config.toml`. 
Edit `/etc/gitlab-runner/config.toml` (or wherever your runner lives) to bind the host mbox:
```toml
[[runners]]
  [runners.docker]
    volumes = ["/run/user/1000/podman/podman.sock:/var/run/docker.sock", "/path/to/host/mbox:/mbox:ro", "/home/dmr104/ruby_projects/minerva-cache/mbox_pre-parsed:/mbox_pre-parsed:rw"] # :ro = read-only, :rw = read-write
```

*e.g. I had `/home/dmr104/ruby_projects/Mail_mbox` as my `/path/to/host/mbox`. (Without this, your container cannot see the host's `/path/to/host/mbox`; passing it as an Artifact is too slow/large.)*

**Create the directory on your Host:**
```bash
mkdir -p /home/dmr104/ruby_projects/minerva-cache/mbox_pre-parsed
```

(Note: If you are using Rootless Podman, ensure `/home/dmr104/ruby_projects/minerva-cache/mbox_pre-parsed` is owned by the user running the Podman daemon, or use `:Z` if SELinux complains, e.g., `...:/cache:rw,Z`.)

## **2. Binding the host repo to *all* Job Containers (but ***not*** to sibling containers created via `docker run` within those Jobs)**

**Do this:** Edit `/etc/gitlab-runner/config.toml` (or wherever your runner lives) to bind the host repo to **all** Job Containers:
```toml
[[runners]]
  [runners.docker]
    volumes = ["/run/user/1000/podman/podman.sock:/var/run/docker.sock", "/path/to/host/mbox:/mbox:ro", "/home/dmr104/ruby_projects/minerva-cache/mbox_pre-parsed:/mbox_pre-parsed:rw", "/home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva:ro" ] # :ro = read-only, :rw = read-write
```
Note that this enables the Job Containers (and their script) to read the files within the mboxMinerva repo directly (thus enabling us to read Dockerfiles within these jobs, for example).  But, whence we spawn a sibling via `docker run` within such a Job Container, because we are using DooD (docker on top of docker), whereby the newly created container is talking to the Host daemon, the container newly created by `docker run` does not see inside of the Container which created it.  So we must respecify the host path path as `/home/dmr104/ruby_projects/mboxMinerva` within that `docker run -v` call.  We will do this as:
```yaml
  docker run --rm -v "$REPO_ROOT":/app:ro -w /app/bin "$PRIVATE_RUBY_GH_IMAGE" sh -c "
    ruby -v
    echo \"Running tests in the custom container...\"
    ruby mbox_pre-parser.rb /Mail_mbox/ntg-context.mbox --triage-file /logs/collisions.log --output-dir /mbox_pre-parsed
    echo \"completed pre-parse of mbox...\"
  "
```
(where $REPO_ROOT expands to `/home/dmr104/ruby_projects/mboxMinerva`)

# Afterthoughts
We also need to achieve persistent storage on the Host which is **bind mounted** to a directory within the Container where our directories and files which the ruby scripts create are contained.  So we mount the persistent Host directory to a specific path inside the Container (e.g. `/metadata`). and tell our ruby scripts via `.gitlab-ci.yml` to write to there.

# ***WARNING!!!***

***DO NOT*** create a mount which is over the build directory in your Job Container!!!  The **authoritative source of truth** which contains this build path is the environment variable as **`$CI_PROJECT_DIR`**, which is going to be `/builds/<group-or-user>/<project-name>`, let's say, `/builds/dmr104/mboxMinerva`.  This directory is "sacred ground" which is managed by the GitLab Runner.  If you bind mount a Host folder there:
1.  **Git Will Fail:** The Runner tries to `git clone`/`git clean` there; if it sees existing files from the Host, it will likely crash or—worse—**wipe your Host directory** to make room for a clean checkout.
2.  **Collisions:** If two jobs run at once, they will literally overwrite each other's source code in real-time.

## So do the following instead:
Edit `/etc/gitlab-runner/config.toml` (or wherever your runner lives) to bind the host repo to **all** Job Containers:
```toml
[[runners]]
  [runners.docker]
    volumes = ["/run/user/1000/podman/podman.sock:/var/run/docker.sock", "/path/to/host/mbox:/mbox:ro", "/home/dmr104/ruby_projects/minerva-cache/mbox_pre-parsed:/mbox_pre-parsed:rw", "/home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva:ro", "/home/dmr104/ruby_projects/minerva-cache/metadata:/metadata:rw" ] # :ro = read-only, :rw = read-write
```

## What we have just done...
**1. Updated Runner's `config.toml`**:
We have mounted the host storage to somewhere in the Job Containers like `/metadata`.  In my case, I have mounted to `/home/dmr104/ruby_projects/minerva-cache/metadata` on the Host to this place within the Jobs Containers.
```toml
[[runners]]
  [runners.docker]
    # Map Host path <-> Container path (Read-Write)
    volumes = [
      "/path/to/mboxMinerva:/mboxMinerva:ro",      # Source code mirror (Safe/Read-Only)
      "/home/dmr104/ruby_projects/minerva-cache/metadata:/metadata:rw"           # WHERE YOU WANT OUTPUTS SAVED
    ]
```

**2. Updated `.gitlab-ci.yml`**:
Point your script to that neutral path.
```yaml
  docker run --rm -v "$REPO_ROOT":/app:ro -w /app/bin "$PRIVATE_RUBY_GH_IMAGE" sh -c "
    ruby -v
    echo \"Running tests in the custom container...\"
    ruby mbox_pre-parser.rb /Mail_mbox/ntg-context.mbox --triage-file /logs/collisions.log --output-dir /mbox_pre-parsed
    echo \"completed pre-parse of mbox...\"
  "
```

`split_output` will now appear instantly on your Host in `/home/dmr104/ruby_projects/minerva-cache/metadata/split_output` and persist there, without breaking the CI's git operations.


# Reflection
As I want to run the ruby code that is within the Host repo (mboxMinerva) within a Container pipeline which runs many ephemeral Container jobs, I want the Dockerfile to use bundler to install all the gems which are required within this project.  The is the standard "Build once" pattern.  The Dockerfile accesses the Host repo via the "build context" (the `.` in  `docker buildx build --load --pull -t ruby:local-patched -f docker/Dockerfile .` within the `.gitlab-ci.yml` file).  Within the Dockerfile we use the `COPY` instruction as `COPY Gemfile Gemfile.lock ./`, and `bundle install` *first*, and then we **DON'T** copy the rest of the repo (the actual ruby code) as we don't want to create hundreds of github container images merely to test the ruby code each time it changes.  We instead want the CI Container pipeline to access the code from the Host repo and run it within Job containers within the Container CI (continuous integration) pipeline.  So we **DON'T** bake the repo code into the image for testing, and we **DON'T** map it *through* the Container using an ad-hoc **Bind Mount** (podman run -v /home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva:Z ...), which would project your live Host repo folder directly into the running GitLab-Runner Container such that the CI sibling Job Containers wouldn't be able to "see" this Host repo folder.  What do we do then?  Well, we **DO** specify `/home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva` within the Runner's `config.toml` so that **each** Job executes the latest edits instantly without a rebuild.


Note that we are **bind mounting** the Host repo read-only because we do *not* want the Container writing to it in any way.

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
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    libpq-dev \
    gnupg \
    libyaml-dev \
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
gem 'simhash2', '~> 0.0.4'

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

