## Introduction to relection
Okay. It is time to reflect upon the latter stages and problems I encountered in setting up my Guests.

## I needed two separate bundle config files.
Why was this?  Because one of them (the standard one at `.bundle/config`) was for the Host.

The other (at `.bungle/config) was for the Guests.

You may be away that the contents of our Host config file are
```ini
BUNDLE_PATH: "vendor/bundle"
```
This is so that our gems get installed at this location within the local repo on the Host of mboxMinerva

Be aware now that the contents of our Guest config (`.bundle/config`) are
```ini
BUNDLE_PATH: "/bundle"
```
such that within the Guest invoked by the Job Container as `get_ruby_image_and_test:` the Guest should look up the Gems at this location.

To facilitate this we also need to have
```dockerfile
ENV BUNDLE_PATH=/bundle

# We also want ruby's runtime within the Container to only look there/
ENV GEM_PATH=/bundle

# We want the config file within the .bungle directory within our mboxMinerva repo to specify the path as /bundle so 
# that the Container will find its gems
ENV BUNDLE_APP_CONFIG=/mboxMinerva/.bungle
```

## What happens when we build?
```dockerfile
# Prepare App Directory
WORKDIR /mboxMinerva

# We are copying from the Host to /mboxMinerva here
COPY Gemfile Gemfile.lock ./

# Install Ruby Dependencies
RUN bundle install
```

## Be careful about older podman images
For a long period of time I got my knickers in a twist by not understanding that the older podman images of our ruby build contain layers, and that to get a newer image to be pulled by `get_ruby_image_and_test:` it was necessary to delete the image id of the older ones using
```bash
podman rmi image_id
```
or 
```bash
podman rmi -f image_id
```
if that image_id was associated with a bunch of other tags. 

I don't pretend to truly understand what is going on with podman in terms of layering.  Suffice to say, the changes I was making to the build were not being reflected in what got subsequently pulled after that build.  During this time, I tried many things, including adding a ` - docker buildx prune -af` to `rebuild_ruby_base:`, and changing tags to something more friendly, and the label from `remote-patched` to `latest`.  I also reverted to copying the complete build stages from the dockerfile which built `ruby:3.4.7-slim` (with the included licence) so that my newer (debatably improved) dockerfile now takes much longer to build but allows me to set these variables as `BUNDLE_PATH`, `GEM_PATH`, and `BUNDLE_APP_CONFIG` to my own bidding without relying upon the defaults.  I may keep this as it is, as great accidents can happen as though with a proper purpose. I consider it didactic for the reader too. 

# Here is my Dockerfile.ruby-mboxMinerva
```dockerfile
# Dockerfile for mboxMinerva
# -----------------------------------------------------------------------------
# mboxMinerva CI/CD Container - Ruby 3.4.8 (Debian Bookworm)
# -----------------------------------------------------------------------------

# The following licence applies to the copied code.
#
# Copyright (C) 2014 Docker, Inc. All rights reserved.

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.

# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

# The following code is copied from https://github.com/docker-library/ruby/blob/master/3.4/slim-bookworm/Dockerfile
# When you see "# END OF COPIED CODE" the extract by which this code is copied from will have ended
FROM debian:bookworm-slim

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates \
	; \
	rm -rf /var/lib/apt/lists/*

# skip installing gem documentation with `gem install`/`gem update`
RUN set -eux; \
	mkdir -p /usr/local/etc; \
	echo 'gem: --no-document' >> /usr/local/etc/gemrc

ENV LANG C.UTF-8

# https://www.ruby-lang.org/en/news/2025/12/17/ruby-3-4-8-released/
ENV RUBY_VERSION 3.4.8
ENV RUBY_DOWNLOAD_URL https://cache.ruby-lang.org/pub/ruby/3.4/ruby-3.4.8.tar.xz
ENV RUBY_DOWNLOAD_SHA256 53a8ec71111449cbbd42224d8d27c493fa6ded228636731051c48604d4255d68

# some of ruby's build scripts are written in ruby
#   we purge system ruby later to make sure our final image uses what we just built
RUN set -eux; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		dpkg-dev \
		libgdbm-dev \
		ruby \
		autoconf \
		bzip2 \
		g++ \
		gcc \
		libbz2-dev \
		libffi-dev \
		libgdbm-compat-dev \
		libglib2.0-dev \
		libgmp-dev \
		libncurses-dev \
		libssl-dev \
		libxml2-dev \
		libxslt-dev \
		libyaml-dev \
		make \
		wget \
		xz-utils \
		zlib1g-dev \
	; \
	\
	rustArch=; \
	dpkgArch="$(dpkg --print-architecture)"; \
	case "$dpkgArch" in \
		'amd64') rustArch='x86_64-unknown-linux-gnu'; rustupUrl='https://static.rust-lang.org/rustup/archive/1.28.2/x86_64-unknown-linux-gnu/rustup-init'; rustupSha256='20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c' ;; \
		'arm64') rustArch='aarch64-unknown-linux-gnu'; rustupUrl='https://static.rust-lang.org/rustup/archive/1.28.2/aarch64-unknown-linux-gnu/rustup-init'; rustupSha256='e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c' ;; \
	esac; \
	\
	if [ -n "$rustArch" ]; then \
		mkdir -p /tmp/rust; \
		\
		wget -O /tmp/rust/rustup-init "$rustupUrl"; \
		echo "$rustupSha256 */tmp/rust/rustup-init" | sha256sum --check --strict; \
		chmod +x /tmp/rust/rustup-init; \
		\
		export RUSTUP_HOME='/tmp/rust/rustup' CARGO_HOME='/tmp/rust/cargo'; \
		export PATH="$CARGO_HOME/bin:$PATH"; \
		/tmp/rust/rustup-init -y --no-modify-path --profile minimal --default-toolchain '1.91.1' --default-host "$rustArch"; \
		\
		rustc --version; \
		cargo --version; \
	fi; \
	\
	wget -O ruby.tar.xz "$RUBY_DOWNLOAD_URL"; \
	echo "$RUBY_DOWNLOAD_SHA256 *ruby.tar.xz" | sha256sum --check --strict; \
	\
	mkdir -p /usr/src/ruby; \
	tar -xJf ruby.tar.xz -C /usr/src/ruby --strip-components=1; \
	rm ruby.tar.xz; \
	\
	cd /usr/src/ruby; \
	\
	autoconf; \
	gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
	./configure \
		--build="$gnuArch" \
		--disable-install-doc \
		--enable-shared \
		${rustArch:+--enable-yjit} \
	; \
	make -j "$(nproc)"; \
	make install; \
	\
	rm -rf /tmp/rust; \
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark > /dev/null; \
	find /usr/local -type f -executable -not \( -name '*tkinter*' \) -exec ldd '{}' ';' \
		| awk '/=>/ { so = $(NF-1); if (index(so, "/usr/local/") == 1) { next }; gsub("^/(usr/)?", "", so); printf "*%s\n", so }' \
		| sort -u \
		| xargs -r dpkg-query --search \
# https://manpages.debian.org/bookworm/dpkg/dpkg-query.1.en.html#S (we ignore diversions and it'll be really unusual for more than one package to provide any given .so file)
		| awk 'sub(":$", "", $1) { print $1 }' \
		| sort -u \
		| xargs -r apt-mark manual \
	; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*; \
	\
	cd /; \
	rm -r /usr/src/ruby; \
# verify we have no "ruby" packages installed
	if dpkg -l | grep -i ruby; then exit 1; fi; \
	[ "$(command -v ruby)" = '/usr/local/bin/ruby' ]; \
# rough smoke test
	ruby --version; \
	gem --version; \
	bundle --version

# END OF COPIED CODE

### The following code is for mboxMinerva

ARG GIT_COMMIT=unknown
ENV GIT_COMMIT=${GIT_COMMIT}

# 1. Install System Dependencies
#    - git: Missing from slim, needed for gemspecs and git-crypt
#    - build-essential: Needed for compiling pg and simhash native extensions
#    - libpq-dev: Needed for pg header files
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    libicu-dev \
    libpq-dev \
    gnupg \
    libyaml-dev \
    pkg-config \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# 2. Prepare App Directory
WORKDIR /mboxMinerva

# 3. Set Environment variables
ENV BUNDLE_PATH=/bundle

# We also want ruby's runtime within the Container to only look there/
ENV GEM_PATH=/bundle

# We want the config file within the .bungle directory within our mboxMinerva repo to specify the path as /bundle so 
# that the Container will find its gems
ENV BUNDLE_APP_CONFIG=/mboxMinerva/.bungle

# 4. Dependency Layer Caching
# We are copying from the Host to /mboxMinerva here
COPY Gemfile Gemfile.lock ./

# 5. Install Ruby Dependencies
RUN bundle install

# 6. Runtime Configuration
#    We DO NOT copy source code here (./lib, ./bin).
#    It is bind-mounted at runtime on the gitlab-runner: podman run -v /home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva ...
CMD ["/bin/bash"]
```

# Here is my .gitlab-ci.yml file
```yml
# .gitlab-ci.yml — mboxMinerva CI/CD Pipeline

default:
  tags: ["main"]

stages:
  - build_infra
  - pull_infra_and_test
  - app_test
  - deploy

variables:
  GH_USER_NAME: "dmr104"
  CONTAINER_REGISTRY: "ghcr.io"
  TAG_IMMUTABLE: $CI_COMMIT_SHORT_SHA
  DOCKER_TLS_CERTDIR: ""  # Disables TLS since we are talking to a local Unix socket
  REPO_ROOT: "/home/dmr104/ruby_projects/mboxMinerva"
  MBOX_DIR: "/home/dmr104/ruby_projects/Mail_mbox"
  LOGS_DIR: "/home/dmr104/ruby_projects/minerva-cache/logs"
  PRE_PARSED_DIR: "/home/dmr104/ruby_projects/minerva-cache/mbox_pre-parsed"
  METADATA_DIR: "/home/dmr104/ruby_projects/minerva-cache/metadata"

# The gitlab-runner will spin up separate job containers on the host using a podman executor, so we NEED an image 
# for those job containers "openbao/openbao:latest" which by default will come from docker.io registry.
.secret_fetcher:
  image: openbao/openbao:latest # Gives us the `bao` command
  variables:
    PATH_OF_SECRET: "github-creds"   # This must match the name of our secret with OpenBao's secret engine.
    VAULT_ROLE: "gitlab-dev-runner-role" # See ./INITIAL_SETUP/Docker_image.md ### The OpenBao UI (The Wiring) #### D. Create the Role (The "Who is allowed" rule)
    BAO_ADDR: "http://192.168.1.168:8200" # Specfies the API address to the bao command
  id_tokens:
    # This generates the JWT. 
    BAO_VAULT_ID:
      aud: "my-super-secure-app-id"  # The 'aud' MUST match OpenBao's 'bound-audiences'

  script: 
    - echo "Authentifying to OpenBao..."

    # 1. Login to OpenBao
    # We send the variable $BAO_VAULT_ID to OpenBao via id tokens: which is a signed JWT embedding with aud (audience).
    - echo "Vault role is $VAULT_ROLE"
    - export VAULT_TOKEN="${VAULT_TOKEN:-$(bao write -field=token auth/jwt/login role=$VAULT_ROLE jwt=$BAO_VAULT_ID)}"
    - echo "I have the VAULT_TOKEN! It is $(echo "${VAULT_TOKEN}" | cut -c 1-5)xxx"

    # 2. Fetch the GHCR_PAT secret.
    - echo "Fetching secrets from ${PATH_OF_SECRET}"
    - export GHCR_PAT=$(bao kv get -mount=secret/data -field=pat2 $PATH_OF_SECRET)
    - echo "I have the secret! It is $(echo "${GHCR_PAT}" | cut -c 1-5)xxx"

# JOB 1.1: A Builder
# Usage: Builds the image ONLY if you touch the file 'docker/Dockerfile.ruby-mboxMinerva'
rebuild_ruby_base:
  extends: .secret_fetcher  # <--- Pulls in variables from .secret_fetcher
  stage: build_infra
    # Inherits the `openbao/openbao:latest` image from .secret_fetcher (so that `bao` auth tool is native). 
  before_script: 
    # Install the docker client utility on top of openbao (`apk add --no-cache docker-cli`), so that the image will be able to 
    # talk to our /var/run/docker.sock (podman) in the GitLab Runner which is mapped to $XDG_RUNTIME_DIR"/podman/podman.sock in 
    # the Host (see INITIAL_SETUP/Gitlab.sh)
    - apk add --no-cache docker-cli docker-cli-buildx
  script:
    # Step 1: Run the inherited secret_fetcher script to get GHCR_PAT
    - !reference [.secret_fetcher, script]  # <---  Pulls in script from .secret_fetcher

    # Step 2. Clear the vault token (good hygiene)
    - unset VAULT_TOKEN
    - echo "I have the GHCR_PAT! It is $(echo "${GHCR_PAT}" | cut -c 1-5)xxx"

    # Step 3. Build and tag
    - echo "Detected changes in build context. Rebuilding base image on Host..."
    # This 'docker build' actually runs on the HOST machine because of the socket mapping.
    # It updates the 'ruby:local-patched' tag in the host's storage.
    - docker buildx prune -af
    - docker buildx build --no-cache --progress=plain --build-arg GIT_COMMIT=$(git rev-parse HEAD) --load --pull -t my_ruby_build -f docker/Dockerfile.ruby-mboxMinerva . 
    - echo "Have built ruby image from Dockerfile" 
    - docker tag my_ruby_build "$CONTAINER_REGISTRY/$GH_USER_NAME"/ruby:"$TAG_IMMUTABLE" 
    - docker tag my_ruby_build "$CONTAINER_REGISTRY/$GH_USER_NAME"/ruby:latest

    # Step 4. Auth and push to GHCR
    - "echo \"Authentifying to ${CONTAINER_REGISTRY}\"" 
    - echo "$GHCR_PAT" | docker login $CONTAINER_REGISTRY -u $GH_USER_NAME --password-stdin 
    - "echo \"Authentified via docker to ${CONTAINER_REGISTRY}\"" 
    - "echo \"Pushing my_ruby_build to ${CONTAINER_REGISTRY}\"" 
    - docker push "$CONTAINER_REGISTRY"/"$GH_USER_NAME"/ruby:"$TAG_IMMUTABLE" 
    - docker push "$CONTAINER_REGISTRY"/"$GH_USER_NAME"/ruby:latest 
  rules:
    # CONDITION: Only run if these files change in the commit/MR
    # 1. If the Dockerfile changes, run automatically (on_success)
    - if: '$CI_COMMIT_BRANCH == "main"'
      changes:
        - docker/Dockerfile.ruby-mboxMinerva
      when: on_success
    # 2. FALLBACK: Allow manual triggering in the UI if you ever need to force a rebuild (e.g. clean host)
    - when: manual                # <--- You must click "Play" in the UI.
      allow_failure: true        # The pipeline continues running even if the manual job is not run

# JOB 1.2: Another Builder
# Usage: Builds the image ONLY if you touch the file 'docker/Dockerfile.openbao-docker'
build_openbao_docker:
  extends: .secret_fetcher  # <--- Pulls in variables from .secret_fetcher
  stage: build_infra
    # Inherits the `openbao/openbao:latest` image from .secret_fetcher (so that `bao` auth tool is native). 
  before_script: 
    # Install the docker client utility on top of openbao (`apk add --no-cache docker-cli`), so that the image will be able to 
    # talk to our /var/run/docker.sock (podman) in the GitLab Runner which is mapped to $XDG_RUNTIME_DIR"/podman/podman.sock in 
    # the Host (see INITIAL_SETUP/Gitlab.sh)
    - apk add --no-cache docker-cli docker-cli-buildx
    # We have hereby pre-installed the docker client utility on top of openbao (`apk add --no-cache docker-cli`), so that the image will 
    # be able to talk to our /var/run/docker.sock (podman) in the GitLab Runner which is mapped to $XDG_RUNTIME_DIR"/podman/podman.sock 
    # in the Host (see INITIAL_SETUP/Gitlab.sh)
  script:
    # Step 1: Run the inherited secret_fetcher script to get GHCR_PAT
    - !reference [.secret_fetcher, script]  # <---  Pulls in script from .secret_fetcher

    # Step 2. Clear the vault token (good hygiene)
    - unset VAULT_TOKEN
    - echo "I have the GHCR_PAT! It is $(echo "${GHCR_PAT}" | cut -c 1-5)xxx"

    # Step 3. Build and tag
    - echo "Detected changes in build context. Rebuilding base image on Host..."
    # This 'docker build' actually runs on the HOST machine because of the socket mapping.
    # It updates the 'openbao-docker:local-patched' tag in the host's storage.
    - docker buildx prune -af
    - docker buildx build --build-arg GIT_COMMIT=$(git rev-parse HEAD) --load --pull -t my_openbao_docker_build -f docker/Dockerfile.openbao-docker . 
    - echo "Have built openbao-docker image from Dockerfile" 
    - docker tag my_openbao_docker_build "$CONTAINER_REGISTRY/$GH_USER_NAME"/openbao-docker:"$TAG_IMMUTABLE" 
    - docker tag my_openbao_docker_build "$CONTAINER_REGISTRY/$GH_USER_NAME"/openbao-docker:remote-patched

    # Step 4. Auth and push to GHCR
    - "echo \"Authentifying to ${CONTAINER_REGISTRY}\"" 
    - echo "$GHCR_PAT" | docker login $CONTAINER_REGISTRY -u $GH_USER_NAME --password-stdin 
    - "echo \"Authentified via docker to ${CONTAINER_REGISTRY}\"" 
    - "echo \"Pushing my_openbao_docker_build to ${CONTAINER_REGISTRY}\"" 
    - docker push "$CONTAINER_REGISTRY"/"$GH_USER_NAME"/openbao-docker:"$TAG_IMMUTABLE" 
    - docker push "$CONTAINER_REGISTRY"/"$GH_USER_NAME"/openbao-docker:remote-patched 
  rules:
    # CONDITION: Only run if these files change in the commit/MR
    # 1. If the Dockerfile changes, run automatically (on_success)
    - if: '$CI_COMMIT_BRANCH == "main"'
      changes:
        - docker/Dockerfile.openbao-docker
      when: on_success
    # 2. FALLBACK: Allow manual triggering in the UI if you ever need to force a rebuild (e.g. clean host)
    - when: manual                # <--- You must click "Play" in the UI.
      allow_failure: true        # The pipeline continues running even if the manual job is not run

# JOB 2: The Consumer
# Usage: Runs your actual tests using the image from Job 1

get_ruby_image_and_test:
  extends: .secret_fetcher  # <--- Pulls in variables from .secret_fetcher
  stage: pull_infra_and_test
  image:
    name: ${CONTAINER_REGISTRY}/${GH_USER_NAME}/openbao-docker:remote-patched 
  variables:
    PRIVATE_RUBY_GH_IMAGE: ${CONTAINER_REGISTRY}/${GH_USER_NAME}/ruby:latest
  before_script:
    # Run the inherited secret_fetcher script to get GHCR_PAT
    - !reference [.secret_fetcher, script]  # <---  Pulls in script from .secret_fetcher

    - echo "Authentifying to OpenBao..."

    # Clear the vault token (good hygiene)
    - unset VAULT_TOKEN
    - echo "I have the GHCR_PAT! It is $(echo "${GHCR_PAT}" | cut -c 1-5)xxx"

    # Authenticate to GHCR using the Vault-fetched PAT
    # GHCR_PAT comes from .secret_fetcher
    - "echo \"Authentifying to ${CONTAINER_REGISTRY}\""     
    - echo "$GHCR_PAT" | docker login $CONTAINER_REGISTRY -u $GH_USER_NAME --password-stdin

    - echo "${PRIVATE_RUBY_GH_IMAGE}"
    - ls -la /var/run/docker.sock || echo "Socket missing!"
    - id
    # Pull your private image
    - docker pull ${PRIVATE_RUBY_GH_IMAGE}
    - docker image inspect ${PRIVATE_RUBY_GH_IMAGE}
  script:
    # (run multiple commands in same container)
    - echo "${PRIVATE_RUBY_GH_IMAGE}"
    - |
      docker run --pull always --rm -v "$MBOX_DIR":/Mail_mbox:ro -v "$LOGS_DIR":/logs:rw -v "$PRE_PARSED_DIR":/mbox_pre-parsed -v "$REPO_ROOT":/mboxMinerva:ro -w /mboxMinerva/bin "$PRIVATE_RUBY_GH_IMAGE" sh -c "
        bundle config
        bundle list
        bundle exec ruby -v
        echo \"Running tests in the custom container...\"
        bundle exec ruby mbox_pre-parser.rb /Mail_mbox/ntg-context.mbox --triage-file /logs/collisions.log --output-dir /mbox_pre-parsed
        echo \"completed pre-parse of mbox...\"
      "

.deploy_template:
  variables:
    USE_TAG: "912ab15f"
  image: "${CONTAINER_REGISTRY}/${GH_USER_NAME}/ruby:${USE_TAG}"
  script:
    - echo "Deploying image ${CONTAINER_REGISTRY}/${GH_USER_NAME}/ruby:${USE_TAG}"
    - "echo \"Targeting environment: ${TARGET_ENV}\""
    # - ./deploy_script.sh --env $TARGET_ENV --tag $CI_COMMIT_SHORT_SHA

# DEV Job: Inherits logic, set ENV to 'staging', runs Automatically
deploy_dev:
  extends: .deploy_template
  stage: deploy
  variables:
    TARGET_ENV: "staging"  # <--- The "Flag" is hardcoded here
  environment:
    name: staging
    # url: https://dev.example.com
  rules:
    - if: $CI_COMMIT_BRANCH == "main"

deploy_prod:
  extends: .deploy_template
  stage: deploy
  variables:
    TARGET_ENV: "production"  # <--- The "Flag" is hardcoded here
  environment:
    name: production
    # url: https://example.com
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual  # <--- The safety gate
```