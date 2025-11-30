# Dockerfile

### Building from the Dockerfile
There is a Dockerfile at docker/Dockerfile which will create a docker image with the most recent updates to it.

To do this manually, from the repo base directory run 

`podman build --layers -t ruby:local-patched -f docker/Dockerfile .`

### Adding to the config.toml of the gitlab-runner pod
Then go to `~/.local/share/containers/storage/volumes/gitlab-runner-config/_data/config.toml` and edit the file to include the following
```toml
[[runners]]
  [runners.docker]
    pull_policy = ["if-not-present"]
    allowed_pull_policies: ["always", "if-not-present", "never"]
```
This will configure gitlab to use local images

## Optional pushing to ghcr
### Obtaining classic PAT from ghcr
Observe that in .gitlab-ci.yml we refer to the image which has been built through the Dockerfile, and we do so locally: which means that this image is a local one.  Note that this solution is probably not what you want in a production environment, where you ought to push your image which is tagged uniquely and immutably, e.g. ("app:1.2.3_\<SHA\>") to a private container repository from the dev environment, and then pull it into your production one.  To achieve this in practice by pushing to github container registry, I first needed to obtain a personal access token to push to this regisry.  So, I logged into github.  I navigated to Developer Settings (click profile picture -> Settings -> Developer Settings).  I created a new classic PAT (Personal access token) with scope *write:packages* to enable download and upload of container images to ghcr (github container registry).

### The OpenBao UI (The Wiring)
I logged in to *OpenBao* web interface as root (although in a working company/corporation this would probably be as an admin instead), and I did:
#### A. Create the Secret (Where the GitHub Token lives)
1.  Click **Secrets** (top navigation).
2.  If you don't have a KV engine yet: Click **Enable new engine** → **KV** → Path: `secret/` → **Enable Engine**.
3.  Click on `secret/`.
4.  Click **Create secret**.
    *   **Path for this secret:** `github-creds`
    *   **Secret data:**
        *   **Key:** `pat`
        *   **Value:** `ghp_YourGitHubPersonalAccessToken...`
5.  Click **Save**.

#### B. Create a Policy (Allowing access to that secret)
1.  Click **Policies** (top navigation).
2.  Click **Create ACL policy**.
    *   **Name:** `gitlab-dev-policy`
    *   **Policy:** Paste this HCL:
        ```hcl
        path "secret/data/github-creds/*" {
          capabilities = ["read"]
        }
        path "secret/metadata/github-creds/*" {
          capabilities = ["list"]
        }
        ```
3.  Click **Create policy**.

#### C. Enable & Configure JWT Auth
1.  Click **Access** (top navigation) → **Auth Methods**.
2.  Click **Enable new method** → Select **JWT/OIDC** → leave path as `jwt/` → **Enable Method**.
3.  Click on the newly created `jwt/` method.
4.  Click **Configure** (tab).
    *   **OIDC Discovery URL:** `https://your-gitlab-domain.com` (Must be reachable by OpenBao). I used `http://192.168.1.168:8080`. This tells OpenBao to connect to GitLab's well-known generic public endpoint, download the current public keys, and use them to verify the signature on the JWT, which only carries a key ID (`kid`) which is a pointer informing openbao to use a particular public key from the issuer's set.  
    *   **Zero Trust/Security:** Ensure **Default Role** is empty (deny by default).
    *   **Bound issuer:** I used `http://192.168.1.168:8080`
    *   **Advanced Settings (optional but recommended):** slightly confusingly hidden, but usually you usually leave "OIDC Client ID" empty for GitLab unless you configured a specific app.
5.  Click **Save**.

#### D. Create the Role (The "Who is allowed" rule)
Remain in the `jwt/` method screen.
1.  Click **Create role** (or "Roles" tab → Create).
    *   **Name:** `gitlab-dev-runner-role`
    *   **Type:** `jwt`
    *   **Bound Audiences:** `my-super-secure-app-id` (Must match the `aud:` in your GitLab CI file exactly).
    *   **User Claim:** `sub` (or `user_login` or `project_path` - this keys the internal identity).
    *   **Groups Claim:** `project_path` (Useful for logging).
    *   **Token Policies:** Select `gitlab-dev-policy` (the policy from Step B).
    *   **(CRITICAL) Bound Claims:** (This locks it to YOUR repo).
        *   Click "Edit" or "Add Claim".
        *   Key: `project_id` -> Value: `123` (Found in your GitLab Project Overview).
        *   *Alternatively:* Key: `project_path` -> Value: `my-group/my-project`.
        *   By choosing `sub` in development, this tells OpenBao to use the JWT's subject claim as the caller's identity so that whatever is within `sub` becomes the principle name OpenBao uses for identity and policy decisions.
2.  Click **Save**.

If this works for you then great.  But I found that the **Roles** tab was missing under **Access** -> **Auth Methods** -> **jwt** -> **Roles**.  So I recursed to using `podman exec -it systemd-openbao /bin/sh` and then `bao login <root password>` and then I created a role called **"gitlab-dev"** by doing `bao write auth/jwt/role/gitlab-dev-runner-role role_type=jwt user_claim=sub bound_audiences="my-super-secure-app-id" bound_issuer="http://192.168.1.168:8080" policies="gitlab-dev-policy"`

Useful commands are `bao auth list` and `bao auth enable jwt`.

## .gitlab-ci.yml
My .gitlab-ci.yml at this stage looks like:
```yaml
stages:
  - build_infra
  - app_test

variables:
  # Disable per-build isolation so that we can see the previous images on the host
  FF_NETWORK_PER_BUILD: "false"
  VAULT_ADDR: "http://192.168.1.168:8200"

# secret_fetcher (the gitlab-runner will spin up separate job containers on the host using a podman executor, so we NEED an image for those job containers "alpine:latest")
.secret_fetcher:
  image: openbao/openbao:latest # Gives us the `bao` command
  id_tokens:
    # This generates the JWT. 
    BAO_VAULT_ID:
      aud: "my-super-secure-app-id"  # The 'aud' MUST match OpenBao's 'bound-audiences'

  script: 
    - echo "Authentifying to OpenBao..."

    # 1. Login to OpenBao
    # We send the variable $BAO_VAULT_ID to OpenBao via **`id_tokens`** which is a signed JWT embedding with aud (audience).
    - export VAULT_TOKEN=$(vault write -field=token auth/jwt/login role=$VAULT_ROLE jwt=$BAO_VAULT_ID)
    - "echo \"I have the VAULT_TOKEN! It is ${GHCR_CREDS_DEV:0:3}***\""

    # 2. Fetch the secret
    - "echo \"Fetching secrets from $PATH_OF_SECRET\""
    - GHCR_CREDS_DEV=$(vault kv get -mount=secret $PATH_OF_SECRET)
    - "echo \"I have the secret!\""
# EXTRACT ghcr secret
ghcr_dev:
  extends: .secret_fetcher
  stage: build_infra
  variables:
    PATH_OF_SECRET: "github-creds"   # This must match the name of our secret with OpenBao's secret engine.
    VAULT_ROLE: "gitlab-dev-runner-role"

# JOB 1: The Builder
# Usage: Builds the image ONLY if you touch files in 'docker/'
rebuild_ruby_base:
  stage: build_infra
  # Use generic docker client; it talks to your mapped /var/run/docker.sock (podman)
  image: docker:cli
  variables:
    # Disable TLS since we are talking to a local Unix socket
    DOCKER_TLS_CERTDIR: ""
  script:
    - echo "Detected changes in build context. Rebuilding base image on Host..."
    # This 'docker build' actually runs on the HOST machine because of the socket mapping.
    # It updates the 'ruby:local-patched' tag in the host's storage.
    - podman build --layers -t ruby:local-patched -f docker/Dockerfile .
  rules:
    # CONDITION: Only run if these files change in the commit/MR
    - if: '$CI_COMMIT_BRANCH == "main"'
      changes:
        - docker/Dockerfile
        - docker/**/*
    # FALLBACK: Allow manual triggering in the UI if you ever need to force a rebuild (e.g. clean host)
      when: manual                # <--- You must click "Play" in the UI.
      allow_failure: false        # The pipeline blocks here until you tell it to proceed.

# JOB 2: The Consumer
# Usage: Runs your actual tests using the image from Job 1
run_tests:
  stage: app_test
  # Because of pull_policy = ["if-not-present"], the Runner looks for this tag
  # on the host first. If Job 1 ran, it sees the new one. If Job 1 skipped, it sees the old one.
  image: 
     name: ruby:local-patched
  script:
    - ruby -v
    - echo "Running tests in the custom container..."
```

## How `podman push ...` works

To put things into perspective and to manually test,

`podman login -u <github_user_or organization_name> -p <github_Personal_authentification_token> ghcr.io`

will log podman in to ghcr.io; and 

`podman push ruby:local-patched ghcr.io/<gh_user_name>/ruby:remote-patched`

will push the image which our pipeline ought to have already built.

## Automated pushing

Our task now is to automate the task of pushing to the github container repository.


