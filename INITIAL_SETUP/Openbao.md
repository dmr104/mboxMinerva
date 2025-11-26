# Openbao Readme

I use a token vault in development called [OpenBao](https://openbao.org).  

The purpose of this token vault is so that CI/CD (continuous integration / continuous deployment) can query this token vault for the tokens to use with Google Collab in order to facilitate smooth automation.  This way CI jobs can authentify to OpenBao with a master root token, pull secrets at runtime, and use those secrets to authentify to Collab.  This approach can also be used with, say authentifying to Github container registry also.

An alternative approach can be to just use a configuration table in a database, or a .env file which doesn't get put into the repo via its entry within .gitignore.  I reject both of these approaches as a token vault is the correct way to do things, and any potential customers are likely to be using one (either self-managed or cloud based) to facilitate a production environment security policy.  

Note that the scope of what I describe here is to set up the token vault within a development environment -- which is NOT production ready.  In particular, one system administrator having access to the root token might put too much trust into one person's hands.  An alternative approach is that an unseal key which generates this root token may be split into multiple shards whereby say three responsible individuals each possess one shard, all of which are needed to generate the unseal key to generate the root token to unseal/decrypt what data is stored and is necessary for OpenBao to be queried.

## What I did
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

Note that if you are running a non-development server (i.e. without the -dev flag) then you may wish to explicitly disable the possibility that the OS swaps OpenBao's memory to the hard drive, as this might contain the unencrypted master keys, which for a docker container (a docker container runs as root) is done using the `--cap-add=IPC_LOCK` flag.  

However, Podman is running as a regular user, so instead of trying to greedily lock memory we tell OpenBao "It's okay, don't try to lock memory" by configuring `Environment='BAO_LOCAL_CONFIG={"disable_mlock": true}'`, which uses the system call named `mlock`.  The rationale behind this approach is that if an attacker has physical access to your CI runner's hard drive such that he/she/they can read swap files, then you have a much bigger security problem than this.  Also the real problem is that as Podman, by default, is running as a regular user, it doesn't have permission to lock memory, and will crash if OpenBao attempts to do it with a "Permission Denied". Obviously this is undesirable and we seek to avoid it. In -dev mode the possibility of locking memory is disabled automatically.

The bao-data volume (on the host) might be stored, by default, at `~/.local/share/containers/storage/volumes/bao-data`


4.  **Obtain your root key and login to OpenBai via the (local) web interface:**
    ```bash
    systemctl --user status openbao.service
    ```
    then input the root token into http://http://127.0.0.1:8200


## Production mode
Upon experimenting with the server in dev mode I discovered that I could not set up a role without the dev server crashing, and when the server was restarted it would lose the state of all my secrets requiring them to be manually input each time.  This is obviously undesirable when my goal was to query the token server from CI/CD to obtain secrets on an as-and-when needed basis.

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

I also needed to create the container for the quadlet file to ensure that we had a podman network bridge established with the name as `systemd-gitlab_net` which matches the name of the podman bridge in the file as `./Gitlab.sh`.  The command as `podman network ls` allows you to see these.

```ini
#~/.config/containers/systemd/gitlab_net.network
[Unit]
Description=Shared backend network for GitLab and Bao

#This gives us a DNS resolution name
DNSname=gitlab_net
```


#### Usage details.
The command `podman unshare chown -R 100:100 %h/.config/openbao/data` within the openbao.constainer is because within the openbao container, the entrypoint sees that it is running as root and it immediately drops the privileges of the process to the UID 100.  In the host, the podman may run with the host UID of 1000, and we need these to match; so this command takes all the directories recursively on the host and changes their ownership to host sub-UID 100099 which maps to UID 100 within the container.

If you mess up, and lose your keys, and need to `rm -rf ~/.config/openbao/data/` then simply do `podman unshare chown -R 0:0 data/` to restore the ownership on the host to UID 100.

Obviously, for a production environment we would not use the script file as `./Gitlab.sh` to start the gitlab and gitlab-runner containers.  In a production environment it is possible that you *might* wish to create podman quadlets to ensure that these services are always automatically enabled and running, but I will not create these here as within my environment (dev) I only wish to have the gitlab container running when I am working on this project.  Within a production environment I suppose that rundancy and backup servers have to be considered, and also policies regarding who has access to what secrets, how these are enforced, and what happens if by an accident, or by somebody leaving the company, a secret goes with them.  This secret should not become lost, it should be retrievable by another member of the team, and revokable by admin.  Whatever your company infrastructure design, I hope that these INITIAL_SETUP files have given you an opportunity to see what I have done within my dev environment to set things up between gitlab and the openbao, and that this will allow you and your team to quickly prototype this project for the management team to consider.

#### Problem resolution
A useful debugging command to run is `/usr/libexec/podman/quadlet -dryrun --user`