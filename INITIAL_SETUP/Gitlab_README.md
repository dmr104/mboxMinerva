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

The following steps will generate configuration information within `~/.local/share/containers/storage/volumes/gitlab-runner-config/_data/config.toml`.

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
    *   *Correct Answer:* `http://gitlab:8080` (If you can use the **container name** of your GitLab server; Podman resolves this name over the shared network presumably if aardvark-dns is installed: which, as it was not available on deepin apt package manager on my system, I resorted to doing `http://192.168.1.168:8080` where this was the internal ip of my network card).
2.  **Enter the registration token:**
    *   Paste the `glrt-...` token you copied earlier.
3.  **Enter a description:** `podman-runner` (aesthetic only).
4.  **Enter tags:** `docker` (this is optional - your job tags configured under gitlab-runner must match the job tags you put under `tags:` in each .gitlab-ci.yml job, or that job will never be picked up by that runner). You might choose tags: [podman, rootless].  Take your pick. 
5.  **Enter optional maintenance note:** (Skip).
6.  **Enter an executor:**
    *   **`docker`** (This is the one you want. It means "When I get a job, create a *new* throwaway container to run it").
7.  **Enter the default Docker image:**
    *   `ruby:3.3` (or `alpine:latest`). This is the fallback image if your `.gitlab-ci.yml` doesn't specify one.

### Why is this manual?
Because the Runner needs to generate cryptographic keys to talk to the Server securelessly. You only do this **once**. After this, the `config.toml` is saved in your `gitlab-runner-config` volume, and the Runner will auto-connect on every restart.

## Caution.
Be careful not to register your Runner more than once, as each time you do will create an addition [[runners]] section within your `config.toml` file, each superceding the previous.

## Useful commands
* `podman exec -it gitlab-runner gitlab-runner list` will display (any) tags set up for gitlab-runner plus other info

## How to tell self-hosted gitlab about the existence of a local git repo
I already have an up-to-date checked-out git clone on my local machine from github.  What I would like to do is to set another remote to push to the local self-hosted GitLab.  How do I achieve this?

#### What is oauth2?  

In this context, `oauth2` is a type of username that GitLab expects when you authentify over HTTP with a personal access token, which is a long string which is to be used as the password. So `http://oauth2:YOUR_TOKEN@host/namespace/repo.git` tells Git to log in.  

You can create the token on GitLab via **User Settings** -> **Access Tokens** -> **scopes: `write_repository`. The API box is to grant full access to GitLab's REST API, which is not needed for just `git push`.  I selected visbility level as `Private`.

As I was logged in to github as root I did `git remote add http://oauth2:MY_PERSONAL_ACCESS_TOKEN@localhost:8080/root/minerva.git`
