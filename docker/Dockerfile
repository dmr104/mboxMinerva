# Dockerfile for mboxMinerva
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
