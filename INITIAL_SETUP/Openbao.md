# Openbao Readme

I use a token vault in development called [OpenBao](https://openbao.org).  

The purpose of this token vault is so that CI/CD (continuous integration / continuous deployment) can query this token vault for the tokens to use with Google Collab, github container registry, and others, all within my CI pipeline, in order to facilitate smooth automation.  This way CI jobs can authentify to OpenBao with a master root token, pull secrets at runtime, and use those secrets to authentify to Collab.  This approach can also be used with, say authentifying to Github container registry also.

An alternative approach can be to just use a configuration table in a database, or a .env file which doesn't get put into the repo via its entry within .gitignore.  I reject both of these approaches as a token vault is the correct way to do things, and any potential customers are likely to be using one (either self-managed or cloud based) to facilitate a production environment security policy. It also mimimises the scope for human adminstrative error, which is a security concern. We are putting no secrets into our repo at all. 

Note that the scope of what I describe here is to set up the token vault within a development environment -- which is NOT production ready.  In particular, one system administrator having access to the root token might put too much trust into one person's hands.  During `openbao operator init` you get both the unseal key(s) AND the initial root token. The unseal keys just decrypt the master key to unseal the vault, while the root token is your initial auth credential that you ought to revoke after creating proper policies and tokens.  The **master key** which decrypts all stored data, is encrypted/decrypted via the unseal keys, and is never revoked.  It is needed for unsealing.  What you *can* revoke is the **root token** (the superuser API credential).  After revoking the root token, you still need to unseal normally with your unseal keys, and then authentify via your configured methods (AppRole, JWT, etc) using tokens with proper policies.

An approach is that an unseal key which generates the master key may be split into multiple shards whereby say three responsible individuals each possess one shard, all of which are needed to generate the unseal key to generate the root token to unseal/decrypt what data is stored and is necessary for OpenBao to be queried.  Alternatively, it may be split into 5 shards, where only 3 are required simultaneously to unlock. 

Before revoking root you enable an auth method (Userpass, AppRole, ldap, etc) with policies attached.  Then users authentify via that method to get tokens.  Policies are just abstract rule definitions (permissions) which become attached to a token when you generate it.  The difference between policies attached to auth methods and policies attached to tokens is that although they are the same policies, they have different assignment points.  Auth methods (or their roles) say "anyone authentifying this way gets policies X, Y, Z", and those policies are then *copied onto* the generated token.  The token carries the actual runtime permissions.  The auth method is just the template which decides what to stamp on it. To reiterate, the auth method config infers "anyone who logs in in this way gets these policies"; and the token carries the result.  You can also create child tokens with *fewer* policies (never more) than the parent, or attach identity/entity policies that merge in at auth time -- but the auth method's `token_policies` is the baseline template which seeds every token minted through that path.

Note that we are installing and running `openbao` via a podman quadlet, thus the file as "./INITIAL_SETUP/Gitlab.sh" will not be starting any openbao podman service. In this repo the file as "./INITIAL_SETUP/Gitlab.sh" will be starting the "gitlab omnibus community edition" (the "brains" of gitlab) and also the gitlab-runner (its "muscle"). 

## Development mode (not very useful for CI)
I installed podman via the command line package manager.
Then I did `podman pull docker.io/openbao/openbao-ubi` 

### systemd user Podman Quadlet
1.  **Create the Quadlet file** at `~/.config/containers/systemd/openbao.container` (create the directory if missing):
    ```ini
    [Unit]
    Description=OpenBao Dev Server
    After=network-online.target

    [Container]
    Image=docker.io/openbao/openbao
    #Environment='BAO_LOCAL_CONFIG={"disable_mlock": true}'
    PublishPort=8200:8200
    Exec=server -dev
    Volume=bao-data:/openbao/file

    [Install]
    WantedBy=default.target
    ```

2.  **Reload to generate the service:**
    ```bash
    systemctl --user daemon-reload
    ```

3.  **Start it (the service name matches the filename):**
    ```bash
    systemctl --user enable --now openbao
    ```

Note that if you are running a non-development server (i.e. without the -dev flag) then you may wish to explicitly disable the possibility that the OS swaps OpenBao's memory to the hard drive, as this might contain the unencrypted master keys: which for a docker container (a docker container runs as root) is done using the `--cap-add=IPC_LOCK` flag.  

However, Podman is running as a regular user, so instead of trying to greedily lock memory we can tell OpenBao "It's okay, don't try to lock memory" by configuring `Environment='BAO_LOCAL_CONFIG={"disable_mlock": true}'`, which uses the system call named `mlock`.  The rationale behind this approach is that if an attacker has physical access to your CI runner's hard drive such that he/she/they can read swap files, then you have a much bigger security problem than this.  Also the real problem is that as Podman, by default, is running as a regular user, it doesn't have permission to lock memory, and will crash if OpenBao attempts to do it with a "Permission Denied". Obviously this is undesirable and we seek to avoid it. In -dev mode the possibility of locking memory is disabled automatically.

The bao-data volume (on the host) might be stored, by default, at `~/.local/share/containers/storage/volumes/bao-data`


4.  **Obtain your root key and login to OpenBao via the (local) web interface:**
    ```bash
    systemctl --user status openbao.service
    ```
    then input the root token into http://127.0.0.1:8200


## Production mode
Upon experimenting with the server in dev mode, I discovered that I could not set up a role without the dev server crashing, and when the server was restarted it would lose the state of all my secrets requiring them to be manually input each time.  This is obviously undesirable when my goal was to query the token server from CI/CD to obtain secrets on an as-and-when needed basis.

So I changed the quadlet file to: 
```ini
#~/.config/containers/systemd/openbao.container
[Service]
ExecStartPre=/bin/sh -c '/usr/bin/mkdir -p %h/.config/openbao/bao && \
/usr/bin/mkdir -p %h/.config/openbao/config && \
/usr/bin/mkdir -p %h/.config/openbao/data/core && { [ -f %h/.config/openbao/data/core/_keyring* ] || >> %h/.config/openbao/data/core/_keyring.temp; }'

ExecStartPre=/bin/sh -c '/usr/bin/podman unshare chown -R 100:100 %h/.config/openbao/data'

[Unit]
Description=OpenBao Secrete Manager (Production)
After=network-online.target
Wants=network-online.target

[Container]
Image=docker.io/openbao/openbao
Network=gitlab_net.network
Environment='BAO_LOCAL_CONFIG={"disable_mlock": true}'
Environment=BAO_ADDR="http://0.0.0.0:8200"
Environment=BAO_API_ADDR="http://127.0.0.1:8200"
PublishPort=8200:8200
Volume=%h/.config/openbao/bao:/bao:z
Volume=%h/.config/openbao/data:/bao/data:z
Volume=%h/.config/openbao/data/core:/bao/data/core:z
Volume=%h/.config/openbao/config/config.hcl:/etc/openbao/config.hcl:z
# Run in server mode
Exec=server -config=/etc/openbao/config.hcl

[Install]
WantedBy=default.target
```

(Note the command `[ -f %h/.config/openbao/data/core/_keyring* ] || >> %h/.config/openbao/data/core/_keyring.temp` might fail in many shells with a syntax error because the redirect has no command preceeding it; use `[ -f %h/.config/openbao/data/core/_keyring* ] || touch %h/.config/openbao/data/core/_keyring.temp` if this happens to you.)


### Usage details
The command `podman unshare chown -R 100:100 %h/.config/openbao/data` within the openbao.container is because within the openbao container, the entrypoint sees that it is running as root and it immediately drops the privileges of the process to the UID 100.  In the host, the podman may run with the host UID of 1000, and we need these to match; so this command takes all the directories recursively on the host and changes their ownership to host sub-UID 100099 which maps to UID 100 within the container.  To view this run `ls -la ~/.config/openbao/data`.

If you mess up, and lose your keys, and need to `rm -rf ~/.config/openbao/data/` then simply do `podman unshare chown -R 0:0 data/` to restore the ownership on the host to UID 100.

Obviously, for a production environment we would not use the script file as `./Gitlab.sh` to start the gitlab and gitlab-runner containers.  In a production environment it is possible that you *might* wish to create podman quadlets to ensure that these services are always automatically enabled and running, but I will not create these here as within my environment I only wish to have the gitlab container running when I am working on this project.  Within a production environment I suppose that rundancy and backup servers have to be considered, and also policies regarding who has access to what secrets, how these are enforced; and what happens if by an accident, or by somebody leaving the company, a secret goes with them.  This secret should not become lost, it should be retrievable by another member of the team, and revokable by admin.  Whatever your company infrastructure design, I hope that these INITIAL_SETUP files will have given you an opportunity to see what I have done within my dev environment to set things up between gitlab and the openbao, and that this will allow you and your team to quickly prototype this project for the management team to consider.

### The Network Bridge

I also needed to create the container for the quadlet file to ensure that we had a podman network bridge established with the name as `systemd-gitlab_net` which matches the name of the podman bridge in the file as `./Gitlab.sh`.  The command as `podman network ls` allows you to see these.

```ini
#~/.config/containers/systemd/gitlab_net.network
[Unit]
Description=Shared backend network for GitLab and Bao

#This gives us a DNS resolution name
DNSname=gitlab_net
```


### Problem resolution
A useful debugging command to run is `/usr/libexec/podman/quadlet -dryrun --user`

## Creating unseal and root keys.
A fresh bao starts **unitialized** (no auth exists yet); so we may run `podman exec -it systemd-openbao bao operator init -format=json > openbao_init_keys.json`, which requires NO root token or unseal tokens, but creates the root token and the unseal keys.  Keep this file `openbao_init_keys.json` very secure and safe, because if you lose it you will be crypographically locked out of the token vault.  THEN you unseal with the unseal keys.  THEN you auth with the root token.  

### If you ever wish to create a new root token
If you ever want a fresh root token you can run `podman exec -it systemd-openbao bao operator generate-root -init` to get a OTP (one-time password); then run `podman exec -it generate-root` repeatedly with each unseal key until the threshold is met (however many shards of the unseal keys are required to perform this task).  Then decode the encoded root token by using that OTP via the command `podman exec -it systemd-openbao bao operator generate-root -decode=<encoded_token> -otp=<your_otp>` which XORs (exclusively ORs in binary) the encoded token with the OTP giving the usable root roken.  This pathway is deliberately awkward to prevent casual root token minting.   