## Background
If you have been following the steps so far, you should have a podman Container called gitlab-runner which is registered with Gitlab omnibus (user interface) Container, and which will run the CI pipeline upon every `git commit` and `git push` to the Gitlab omnibus Container.  This is all well and good, but I don't really want to git commit **every** time I make some changes which I want to be tested.  Ideally, I want to have a way to test the code of a Job in a fresh container which will read its Job instructions from the `.gitlab-ci.yml` file in our repo, which it will have access to in so far as it will have access to all of the codebase within our Host repo.  

How do we achieve this?

Well, we want some way to create and to have new Job Containers which are **manually created** ones which know nothing about, and which are completely separate to, and independent than, the **automated Job Containers** which are created by the GitLab Runner whenever the pipeline which is triggered only by a `git push`, runs.  Recall that we are pushing to GitLab omnibus Container (which acts as the "brain") and it is the registered GitLab Runner (which acts as the "muscle") which acts upon this `git push` by implementing a Pipeline.

So how do we achieve the implementation of these **manually created specific Job Containers**?

So if I merely start a Container via `podman run...`, then let us say that this is my **manual dev Job Container**, and is called "testing".  This Container will have nothing to do with my `.gitlab-ci.yml` file as things stand currently, but we want that it ought to be able to see it.  I am attempting to automate using my `.gitlab-ci.yml` file; so is there any way to prototype the use of this file **before** I `git commit` and `git push`, so that I don't have to `git push` merely to test it out each time?

Well yes, there is.  It is called....

# **gitlab-ci-local**
This a third-party tool which runs on the Host, and which parses your YAML from `.gitlab-ci.yml` and launches local Containers that mount the Host mboxMinerva repo.

To do this:
1.  **Install it on Host** (if you have Node.js: `npm install gitlab-ci-local`, from the root directory of "mboxMinerva", or download the binary from GitHub if not).
2.  **Run it**: `cd /path/to/mboxMinerva` on the Host, then type `npx gitlab-ci-local --list-all` to examine, and `npx gitlab-ci-local --network host --variable VAULT_TOKEN="$ROOT_TOKEN" --volume /run/user/1000/podman/podman.sock:/var/run/docker.sock` to run it.

For this command to work you will need to have first issued an `export ROOT_TOKEN=$(podman exec systemd-openbao bao login -token-only token=MY_REDACTED_ROOT_TOKEN)`.

Note that in a gitlab-ci-local run of our Job Container which invokes our helper called `.secret_fetcher:` (from `.gitlab-ci-local.md`) the variable called VAULT_TOKEN won't see the environment variable by the same name.  This is to be expected: the Job Container *cannot* see the environment variables from the Host.  Please note also that the variable as VAULT_TOKEN *has to be called* the name as VAULT_TOKEN within this helper as .secret_fetcher and that if you call it any other name then anything further which is requiring it to be called VAULT_TOKEN will fail.  Note also that within a gitlab-ci-local run (i.e. outside of the gitlab CI pipeline) we *cannot* rely upon the asymmetric trust between gitlab omnibus and the openbao token vault to exchange keys to get this token (which I have as the root token within my dev environment) so we *must* inject the variable as VAULT_TOKEN (which I do from and after creating an environment variable called ROOT_TOKEN) manually when the command as `gitlab-ci-local` is invoked. Here when the gitlab-ci-local is run we have a variable name collision, and the YAML-defined variable takes precedence and copies over anything of the same name.  This will result in an error when we are running gitlab-ci-local because its environment will not have access to the root token to gain access to OpenBao:
```
rebuild_ruby_base > Error writing data to auth/jwt/login: Error making API request.
rebuild_ruby_base > 
rebuild_ruby_base > URL: PUT http://192.168.1.168:8200/v1/auth/jwt/login
rebuild_ruby_base > Code: 400. Errors:
rebuild_ruby_base > 
rebuild_ruby_base > * missing token
```
If you have understood this, you will also understand that the variable as VAULT_TOKEN injected into th `gitlab-ci-local` command will not be fallen back upon, but overwritten.  So within our .gitlab-ci.yml file we shall set the variable VAULT_TOKEN only if VAULT_TOKEN is not already set.
We do this in the following manner:
```yaml
export VAULT_TOKEN="${VAULT_TOKEN:-$(bao write -field=token auth/jwt/login role=$VAULT_ROLE jwt=$BAO_VAULT_ID)}"
```
We also have had to set (in order that https://127.0.0.1:8200 won't return an http response):
```yaml
  variables:
    BAO_ADDR: "http://192.168.1.168:8200" # Specfies the API address to the bao command 
```

Note that we are using our root token here within development. There are other methods available though, like token auth or approle.  The first is the simplest where you can either use the root token directly (bad for prod), or create child tokens via `bao token -create -policy=mypolicy -ttl=1h`, or more commonly just consume tokens which have be *produced by* other auth methods (AppRole, JWT, etc).  For the latter, approle uses a role_id + secret_id pair where you'd first create an approle with `bao write auth/approle/role/local-dev policies=your-policy` to get a token.  You can fetch the role_id with `auth/approle/role/local-dev/role-id` and the secret_id with `auth/approle/role/local-dev/secret-id`.  You would obtain a token via `bao write auth/approle/login role_id=X secret_id=Y` and then use this token to subsequently obtain longer-term variables which are stored within openbao.

3.  **Result**: It reads your local `.gitlab-ci.yml`, starts containers via Podman, runs the scripts, and prints the output to your terminal: all without a single `git push`.

Can I run a specific Job only using gitlab-ci-local?

Yes, you can. Run `gitlab-ci-local <job_name>` to run just that job, and you can add `--needs` if you also want to pull in and execute any upstream `needs:` dependencies automatically.

## How does this asymmetric trust thing work?
Well, Gitlab signs a JWT (the `CI_JOB_JWT` or `id_tokens`) with its private key. OpenBao was preconfigured with GitLab's JWKS URL or public key, so when your job calls `bao write auth/jwt/login`, OpenBao validates the signature against that public key without ever talking to GitLab directly.

# Speeding up the dev time.
Is there any way I can speed up the development time as it takes time to `apk add` every time I wish to run this job to test the script contained within get_ruby_image_and_test?  I am thinking of having an intermediate image cached which has `apk add --no-cache docker-cli docker-cli-buildx` already baked into it.  Answer.  This is feasible and readily doable.  We create another dockerfile called "Dockerfile.openbao-docker" which contains:
```
FROM openbao/openbao:latest

RUN apk add --no-cache docker-cli docker-cli-buildx
```
We automate the building of it (within .gitlab-ci.yml) and pushing of it to GHCR (Github Container registry), and then use this pre-baked image within the Job as get_ruby_image_and_test instead of the pre-baked image which lacks the docker commands. This way we will shave off the apk overhead by every run and only pay for it once when we are building that intermediate layer.

However this in turn will mean that we simply cannot just use the following within the get_ruby_image_and_test Job Container:
```yaml
get_ruby_image_and_test:
  stage: pull_infra_and_test
  image:
    name: ${CONTAINER_REGISTRY}/${GH_USER_NAME}/openbao-docker:remote-patched
  extends: .secret_fetcher
```
The reason why we cannot do this is because this image requires a github_PAT which is to be accessed by the .secret_fetcher.  If we try this it will result in a "Runner system failure", with an error message which unkindly dictates that the "job failed to pull image" and that it is "unable to retrieve the auth token" and that we are "unauthorised" with an "invalid username/password". Please note that this job may still run though if and when we invoke it through gitlab-ci-local because gitlab-ci-local may find the local cached image (see `podman images`) and skip the pull entirely, not to mention the possibility that your local docker/podman daemon may have already cached credentials from a previous `docker login ghcr.io` session in `~/.docker/config.json` on your Host machine. To guard against the possibility that gitlab-ci-local may find the local cached image, amend your command of invocation to use the `--pull-policy always` option, to become:
```
npx gitlab-ci-local --network host --variable VAULT_TOKEN="$ROOT_TOKEN" --volume /run/user/1000/podman/podman.sock:/var/run/docker.sock --pull-policy always get_ruby_image_and_test
```
This should help to assist towards avoiding false positives.

Now to address the issue whereby the "openbao-docker:remote-patched" requires the github_PAT, and .secret_fetcher which acquires this PAT (personal access token) cannot access the access token until the image that requires it has been pulled.  We could adopt the classic DooD (Docker-out-of-Docker) bootstrap pattern. Recall that DooD means that we are mounting a host's `/run/user/1000/podman/podman.sock:` or `${XDG_RUNTIME_DIR}/podman/podman.sock:` into the Job Container itself so that the Job can launch "sibling" Containers on the same host rather than trying to nest a full daemon inside itself. 

The bootstrap pattern we might use would be to start our Job with a public image that has docker CLI (command line interface) (like the image as `docker:cli`), and then use this docker CLI to pull the ***public*** (very important that it is public) image as "openbao-docker:remote-patched" which we will then use to do what is required to fetch the PAT (using the `.secret_fetcher` helper as "openbao-docker:remote-patched" has the `bao` command) and use this PAT to login to GHCR; and then finally pull the private ruby-based image for the actual work.  This is all done via the shared socket, requiring no `image:`-nesting.  

An example of `image:`-nesting which is *not* DinD is that of having a "builder" Job where you use `image: node:latest` to compile your app and *inside* that Job's script you run `docker build` via the Host socket.  The Node Container and the resulting app Container are siblings on the Host, not one inside the other's daemon.  

An example of `image:`-nesting which *is* DinD would be where we utilize `image: docker:cli` with `services: [docker:dind]` and `DOCKER_HOST: tcp://docker:2376`.  This way the Job Container talks over TCP to a *second* **inner** container running its own isolated daemon complete with separate image cache and storage.  The nested daemon is what makes it "in Docker", rather than "out of Docker".

## The following is what we are talking about
Just use a ***public*** image of our specially baked "openbao-docker".

In your GitHub profile or organizations **Packages** tab, click your image name, then **Package Settings** at the bottom right, and scroll down to the "Danger Zone" to hit "Change visibility" and make it public. In GHCR this now **public** package (docker container image) will now allow anonymous access and can be pulled without authentifying or signing in via the CLI. Under "Manage Actions access" I selected "write" as I want my github user account to be able to upload and download this package and read and write its metadata, but I don't really need my user to be able to grant read, write, or admin roles to other users for that "openbao-docker" container package.

## The following is a way to avoid using public containers at all 
The following is a bit ugly but it does work.  It is a way to implement a nested "openbao" within docker:cli in order to grab the credentials and pull our ***private*** ruby image. 

```yaml
scratch_ruby_image_and_test:
  stage: pull_infra_and_test
  image:
    name: docker:cli
  variables:
    VAULT_ADDR: "http://192.168.1.168:8200"
    PRIVATE_RUBY_GH_IMAGE: ${CONTAINER_REGISTRY}/${GH_USER_NAME}/ruby:remote-patched
    PATH_OF_SECRET: "github-creds"   # This must match the name of our secret with OpenBao's secret engine.
    VAULT_ROLE: "gitlab-dev-runner-role" # See ./INITIAL_SETUP/Docker_image.md ### The OpenBao UI (The Wiring) #### D. Create the Role (The "Who is allowed" rule)
  id_tokens:
    # This generates the JWT. 
    BAO_VAULT_ID:
      aud: "my-super-secure-app-id"  # The 'aud' MUST match OpenBao's 'bound-audiences'

  before_script:
    - docker pull openbao/openbao

    - echo "Authentifying to OpenBao..."

    # 1. Login to OpenBao
    # We send the variable $BAO_VAULT_ID to OpenBao via id tokens: which is a signed JWT embedding with aud (audience).
    - echo "Vault role is $VAULT_ROLE"
    - export VAULT_TOKEN="${VAULT_TOKEN:-$(docker run --rm -e VAULT_ADDR="$VAULT_ADDR" openbao/openbao bao write -field=token auth/jwt/login role=$VAULT_ROLE jwt="$BAO_VAULT_ID")}"
    - echo "I have the VAULT_TOKEN! It is $(echo "${VAULT_TOKEN}" | cut -c 1-5)xxx"

    # 2. Fetch the GHCR_PAT secret.
    - echo "Fetching secrets from ${PATH_OF_SECRET}"
    - export GHCR_PAT=$(docker run --rm -e VAULT_ADDR="$VAULT_ADDR" -e VAULT_TOKEN="$VAULT_TOKEN" openbao/openbao bao kv get -mount=secret/data -field=pat2 $PATH_OF_SECRET)
    - echo "I have the secret! It is $(echo "${GHCR_PAT}" | cut -c 1-5)xxx"

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
  script:
    # (run multiple commands in same container)
    - |
      docker run --rm -w /app "$PRIVATE_RUBY_GH_IMAGE" sh -c "
        ruby -v
        echo "Running tests in the custom container..."
      "
```
-----

# My .gitlab-ci.yml file so far looks like...
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
    - docker buildx build --load --pull -t ruby:local-patched -f docker/Dockerfile.ruby-mboxMinerva . 
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
    - docker buildx build --load --pull -t openbao-docker:local-patched -f docker/Dockerfile.openbao-docker . 
    - echo "Have built openbao-docker image from Dockerfile" 
    - docker tag openbao-docker:local-patched "$CONTAINER_REGISTRY/$GH_USER_NAME"/openbao-docker:"$TAG_IMMUTABLE" 
    - docker tag openbao-docker:local-patched "$CONTAINER_REGISTRY/$GH_USER_NAME"/openbao-docker:remote-patched

    # Step 4. Auth and push to GHCR
    - "echo \"Authentifying to ${CONTAINER_REGISTRY}\"" 
    - echo "$GHCR_PAT" | docker login $CONTAINER_REGISTRY -u $GH_USER_NAME --password-stdin 
    - "echo \"Authentified via docker to ${CONTAINER_REGISTRY}\"" 
    - "echo \"Pushing openbao-docker:local-patched to ${CONTAINER_REGISTRY}\"" 
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
    PRIVATE_RUBY_GH_IMAGE: ${CONTAINER_REGISTRY}/${GH_USER_NAME}/ruby:remote-patched
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
  script:
    # (run multiple commands in same container)
    - |
      docker run --rm -w /app "$PRIVATE_RUBY_GH_IMAGE" sh -c "
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