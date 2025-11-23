## This is an explanation about **[step 4]** of the *Gitlab.sh* file

[Step 4] is the **"Handshake"**—it couples your generic Runner container to your specific GitLab server. Without this, the Runner is just a hollow shell waiting for work but checking `gitlab.com` by default (or nothing at all).

Here is the exact breakdown of what is happening and how to do it:

### 1. The Prerequisite (The "Invite Code")
Before running the command, you need a **Registration Token** from your *running* GitLab container.
*   Open your local GitLab (e.g., `http://localhost:8080`).
*   Obtain the **root password** by running `podman exec -it gitlab bash -lc 'cat /etc/gitlab/initial_root_password'`
*   Log in as **root** pasting in the password copied in the previous step.
*   Go to Admin Area -> Settings -> General -> Sign-up restrictions and disable 'sign-up enabled' to prevent other people on the LAN from creating an account
*   Go to **Admin Area** (the building icon) → **CI/CD** → **Runners**.
*   Click **"New Instance Runner"**.
*   Tags: `docker`, `linux`. check "Run untagged".
*   Click **Create**.
*   **COPY the token** (it starts with `glrt-`).

Then, although I find that this is not always necessary, and you might skip this step; as we are using podman you *may* add the following to the file `~/.local/share/containers/storage/volumes/gitlab-runner-config/_data/config.yml`:
```toml
  [runners.feature_flags]
    FF_NETWORK_PER_BUILD = false
```

### 2. The Logic (The "Phone Call")
You cannot run this command on your *host machine*. You must run it *inside* the runner container so it saves the config to its own internal `config.toml`.

That's why we use `podman exec`:
*   `podman exec` = "Run a command inside a running container"
*   `-it` = "Interactive" (allow me to type)
*   `gitlab-runner` = The name of the container
*   `gitlab-runner register` = The actual command to run

### 3. The Execution
Run this on your host terminal:
```bash
podman exec -it gitlab-runner gitlab-runner register
```

### 4. The "Wizard" Answers (Crucial)
The command will ask you questions. Your answers matter because of **Container Networking**:

1.  **Enter the GitLab instance URL:**
    *   *Wrong Answer:* `http://localhost` (This refers to the *runner container itself*, not your PC).
    *   *Correct Answer:* `http://gitlab:8080` (Use the **container name** of your GitLab server; Podman resolves this name over the shared network presumably if aardvark-dns is installed: which, as it was not available on deepin apt package manager on my system, I resorted to doing `http://192.168.1.168:8080` where this was the internal ip of my network card).
2.  **Enter the registration token:**
    *   Paste the `glrt-...` token you copied earlier.
3.  **Enter a description:** `podman-runner` (aesthetic only).
4.  **Enter tags:** `docker` (must match your job tags).
5.  **Enter optional maintenance note:** (Skip).
6.  **Enter an executor:**
    *   **`docker`** (This is the one you want. It means "When I get a job, create a *new* throwaway container to run it").
7.  **Enter the default Docker image:**
    *   `ruby:3.3` (or `alpine:latest`). This is the fallback image if your `.gitlab-ci.yml` doesn't specify one.

### Why is this manual?
Because the Runner needs to generate cryptographic keys to talk to the Server securelessly. You only do this **once**. After this, the `config.toml` is saved in your `gitlab-runner-config` volume, and the Runner will auto-connect on every restart.

## Caution.
Be careful not to register your Runner more than once, as each time you do will create an addition [[runners]] section within your `config.toml` file, each superceding the previous.