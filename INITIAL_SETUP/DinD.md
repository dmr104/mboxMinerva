# Docker in docker setup

I wish that gitlab facilitated auth prior to, and upon, the image that is pulled, yet they don't; and still I don't want to use a CI variable because this would defy our methodology of storing the github_PAT in the token vault.

It might be thought that we are now faced with the catch-22 chicken-and-egg problem whereby the image which we wish to pull in this job requires an auth, but auth can only be read after the image is pulled, and that we ought to use docker-in-docker (DinD) with a docker-cli as the job image (public, no auth needed), and with docker-dind as a service.  But this is not necessary.  None of this is necessary because socket-mounting doesn't block auth at all. DinD was never *required* for private registry auth. It just isolates the daemon.  Socket-mounting shares the Host's Podman daemon whereby auth still works per-container.  In our case, **Host Podman** is the one true daemon, which is parent to all, and which has spawned the `gitlab-runner` **Runner Manager** container which *asks Host Podman via the socket* to spawn Job Containers (which are siblings to the Runner Manager).  With socket mounting, everyone talks to **Host Podman**, and shares its cache.  If DinD would be used (which we are not doing) then this DinD would add another sibling (a docker:dind **service container**) running as its own isolated daemon which runs a *second* Docker daemon inside of it, and the docker:cli Job Containers (which have also been spawned by **Host Podman**) would talk to this *inner* daemon (which is within the docker:dind service) via tcp://docker:2376, not the outer Docker daemon, such that all images either built or pulled exist only within that ephemeral dind service container's storage.

## But, ...

Because in the gitlab Runner's config.toml, we have already mounted Podman's socket rootlessly as our user (from the Host's point of view): `"/run/user/1000/podman/podman.sock:/var/run/docker.sock"`, if we try to run DinD (docker in docker) the latter (outer level docker) wants to create a daemon at `/var/run/docker.sock` and fails, because this outer level docker is running as root (from the CI job Container's point of view) and this is not compatible with the user Podman Runner Manager (your `gitlab-runner` container) from the Host's point of view; but if we remove this line from the config, then ***any*** other job which is not DinD will fail.  

## The fix, ...

So the fix should be to add a *second* `[[runners]]` entry in the config.toml with a unique tag (e.g. `tags = ["dind"]`) with *no* socket binding.  The way to achieve this should be done by creating a new runner entry in the Gitlab UI to generate a fresh, unique token for this specific "dind" runner, and then running `gitlab-runner register` pasting in this token.

Admin -> CI/CD -> Runners -> create new runner -> tags "dind" -> copy the token

# Auxiliary runner setup

I will change the tag from "dind" to "aux1" now that we are no longer using docker-in-docker.

I have run `podman exec -it gitlab-runner gitlab-runner register` registering the token I have copied when creating the new git runner within the podman Runner Container (with the tag "aux1"), and I have specified the url as: `http://192.168.1.168:8080`.

Special things to pay attention to within .gitlab-ci.yml is the variable:

- DOCKER_HOST: "unix:///var/run/docker.sock"

We will map this Container socket to the regular `/run/user/1000/podman/podman.sock:/var/run/docker.sock` in our Runner `config.toml`.

My .gitlab-ci.yml now looks like
```yaml
# .gitlab-ci.yml — mboxMinerva CI/CD Pipeline

stages:
  - build_infra
  - pull_infra_and_test
  - app_test
  - deploy

variables:
  # Disable per-build isolation so that we can see the previous images on the host
  FF_NETWORK_PER_BUILD: "false"
  VAULT_ADDR: "http://192.168.1.168:8200"
  GH_USER_NAME: "dmr104"
  CONTAINER_REGISTRY: "ghcr.io"
  TAG_IMMUTABLE: $CI_COMMIT_SHORT_SHA

# secret_fetcher (the gitlab-runner will spin up separate job containers on the host using a podman executor, so we NEED an image for those job containers "alpine:latest" which by default will come from docker.io registry)
.secret_fetcher:
  image: openbao/openbao:latest # Gives us the `bao` command
  variables:
    PATH_OF_SECRET: "github-creds"   # This must match the name of our secret with OpenBao's secret engine.
    VAULT_ROLE: "gitlab-dev-runner-role"
  id_tokens:
    # This generates the JWT. 
    BAO_VAULT_ID:
      aud: "my-super-secure-app-id"  # The 'aud' MUST match OpenBao's 'bound-audiences'

  script: 
    - echo "Authentifying to OpenBao..."

    # 1. Login to OpenBao
    # We send the variable $BAO_VAULT_ID to OpenBao via **`id_tokens`** which is a signed JWT embedding with aud (audience).
    - echo "Vault role is $VAULT_ROLE"
    - export VAULT_TOKEN=$(bao write -field=token auth/jwt/login role=$VAULT_ROLE jwt=$BAO_VAULT_ID)
    - echo "I have the VAULT_TOKEN! It is $(echo "${VAULT_TOKEN}" | cut -c 1-3)xxx"

    # 2. Fetch the GHCR_PAT secret.
    - echo "Fetching secrets from ${PATH_OF_SECRET}"
    - export GHCR_PAT=$(bao kv get -mount=secret -field=pat $PATH_OF_SECRET)
    - echo "I have the secret! It is $(echo "${GHCR_PAT}" | cut -c 1-3)xxx"

# JOB 1: The Builder
# Usage: Builds the image ONLY if you touch files in 'docker/'
rebuild_ruby_base:
  extends: .secret_fetcher  # <--- Pulls in variables from .secret_fetcher
  stage: build_infra
    # Inherits the `openbao/openbao:latest` image from .secret_fetcher (so that `bao` auth tool is native). 
  variables:
    # Disable TLS since we are talking to a local Unix socket
    DOCKER_TLS_CERTDIR: ""
  before_script: 
    # Install the docker client utility on top of openbao (`apk add --no-cache docker-cli`), so that the image will be able to talk to our /var/run/docker.sock (podman) in the GitLab Runner which is mapped to $XDG_RUNTIME_DIR"/podman/podman.sock in the Host (see INITIAL_SETUP/Gitlab.sh)
    - apk add --no-cache docker-cli docker-cli-buildx
  script:
    # Step 1: Run the inherited secret_fetcher script to get GHCR_PAT
    - !reference [.secret_fetcher, script]  # <---  Pulls in script from .secret_fetcher

    # Step 2. Clear the vault token (good hygiene)
    - unset VAULT_TOKEN
    - echo "I have the GHCR_PAT! It is $(echo "{$GHCR_PAT}" | cut -c 1-3)xxx"

    # Step 3. Build and tag
    - echo "Detected changes in build context. Rebuilding base image on Host..."
    # This 'docker build' actually runs on the HOST machine because of the socket mapping.
    # It updates the 'ruby:local-patched' tag in the host's storage.
    - docker buildx build --load --pull -t ruby:local-patched -f docker/Dockerfile . 
    - echo "Have built ruby image from Dockerfile" 
    - docker tag ruby:local-patched "$CONTAINER_REGISTRY/$GH_USER_NAME"/ruby:"$TAG_IMMUTABLE" 
    - docker tag ruby:local-patched "$CONTAINER_REGISTRY/$GH_USER_NAME"/ruby:remote-patched

    # Step 4. Auth and push to GHCR
    - "echo \"Authentifying to ${CONTAINER_REGISTRY}\"" 
    - echo "$GHCR_PAT" | docker login $CONTAINER_REGISTRY -u $GH_USER_NAME --password-stdin 
    - "echo \"Authentified via docker to ${CONTAINER_REGISTRY}\"" 
    - "echo \"Pushing ruby:local-patched to ${CONTAINER_REGISTRY}\"" 
    - docker push "$CONTAINER_REGISTRY"/"$GH_USER_NAME"/ruby:"$TAG_IMMUTABLE" 
    - docker push "$CONTAINER_REGISTRY"/"$GH_USER_NAME"/ruby:remote-patched 
  rules:
    # CONDITION: Only run if these files change in the commit/MR
    - if: '$CI_COMMIT_BRANCH == "main"'
      changes:
        - docker/Dockerfile
        - docker/**/*
    # FALLBACK: Allow manual triggering in the UI if you ever need to force a rebuild (e.g. clean host)
      when: manual                # <--- You must click "Play" in the UI.
    #  allow_failure: false        # The pipeline blocks here until you tell it to proceed.

# JOB 2: The Consumer
# Usage: Runs your actual tests using the image from Job 1
# Base DinD configuration
.docker_cli_base:
  image: docker:24.0.5-cli
  variables:
    # Tell docker CLI where to find the daemon
    DOCKER_HOST: "unix:///var/run/docker.sock"

get_ruby_image_and_test:
  tags: ["aux1"]
  variables:
    PRIVATE_GH_IMAGE: ${CONTAINER_REGISTRY}/${GH_USER_NAME}/ruby:remote-patched
  extends: 
  - .secret_fetcher
  - .docker_cli_base 
  stage: pull_infra_and_test
  before_script:
    # Install bao dependencies
    - wget -qO- https://github.com/openbao/openbao/releases/download/v2.4.4/bao_2.4.4_Linux_x86_64.tar.gz | tar xz -C /usr/local/bin
    
    - !reference [.secret_fetcher, script]  # <---  Pulls in script from .secret_fetcher

    # Clear the vault token (good hygiene)
    - unset VAULT_TOKEN
    - echo "I have the GHCR_PAT! It is $(echo "${GHCR_PAT}" | cut -c 1-3)xxx"

    # Wait for DinD to be ready (important!)
    - |
      echo "Waiting for Docker daemon..."
      for i in $(seq 1 30); do
        docker info >/dev/null 2>&1 && break
        echo "Attempt $i: Docker not ready yet..."
        sleep 1
      done
    # Authenticate to GHCR using the Vault-fetched PAT
    # GHCR_PAT comes from .secret_fetcher
    - "echo \"Authentifying to ${CONTAINER_REGISTRY}\""     
    - echo "$GHCR_PAT" | docker login $CONTAINER_REGISTRY -u $GH_USER_NAME --password-stdin

    - echo "${PRIVATE_GH_IMAGE}"
    - ls -la /var/run/docker.sock || echo "Socket missing!"
    - id
    # Pull your private image
    - docker pull ${PRIVATE_GH_IMAGE}
  script:
    # (run multiple commands in same container)
    - |
      docker run --rm -w /app "$PRIVATE_GH_IMAGE" sh -c "
        ruby -v
        echo "Running tests in the custom container..."
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

My `~/.local/share/containers/storage/volumes/gitlab-runner-config/_data/config.toml` looks like
```
concurrent = 1
check_interval = 0
connection_max_age = "15m0s"
shutdown_timeout = 0

[session_server]
  session_timeout = 1800

[[runners]]
  name = "podman-runner"
  url = "http://192.168.1.168:8080"
  id = 4
  token = "glrt-r-CVcnRNwjC9IGfFOUynMW86MQp0OjEKdToxCw.01.1214s0uvq"
  token_obtained_at = 2025-11-20T17:11:05Z
  token_expires_at = 0001-01-01T00:00:00Z
  executor = "docker"
  [runners.cache]
    MaxUploadedArchiveSize = 0
    [runners.cache.s3]
    [runners.cache.gcs]
    [runners.cache.azure]
  [runners.docker]
    network_mode = "host"
    tls_verify = false
    image = "alpine:latest"
    privileged = false
    disable_entrypoint_overwrite = false
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/run/user/1000/podman/podman.sock:/var/run/docker.sock", "/home/dmr104/ruby_projects/Mail_mbox:/mbox:ro", "/home/dmr104/ruby_projects/minerva-cache/email_crypt:/email_crypt:rw", "/home/dmr104/ruby_projects/mboxMinerva:/mboxMinerva:ro", "/home/dmr104/ruby_projects/minerva-cache/processed_data:/processed_data:rw", "/cache"]
    shm_size = 0
    network_mtu = 0

[[runners]]
  tags = ["aux1"]
  name = "auxiliary 1"
  url = "http://192.168.1.168:8080"
  id = 6
  token = "glrt-ZjR3qgNhTQ9Flx6H-tzsxm86MQp0OjEKdToxCw.01.120v97gt2"
  token_obtained_at = 2025-12-22T07:40:07Z
  token_expires_at = 0001-01-01T00:00:00Z
  executor = "docker"
  [runners.cache]
    MaxUploadedArchiveSize = 0
    [runners.cache.s3]
    [runners.cache.gcs]
    [runners.cache.azure]
  [runners.docker]
    network_mode = "host"
    tls_verify = false
    image = "alpine:latest"
    privileged = false
    disable_entrypoint_overwrite = false
    oom_kill_disable = false
    disable_cache = false
    volumes = ["/run/user/1000/podman/podman.sock:/var/run/docker.sock", "/cache"]
    shm_size = 0
    network_mtu = 0
```