# Openbao Readme

I use a token vault in development called [OpenBao](https://openbao.org).  

The purpose of this token vault is so that CI/CD (continuous integration / continuous deployment) can query this token vault for the tokens to use with Google Collab in order to facilitate smooth automation.  This way CI jobs can authentify to OpenBao with a master root token, pull secrets at runtime, and use those secrets to authentify to Collab.  This approach can also be used with, say authentifying to Github container registry also.

An alternative approach can be to just use a configuration table in a database, or a .env file which doesn't get put into the repo via its entry within .gitignore.  I reject both of these approaches as a token vault is the correct way to do things, and any potential customers are likely to be using one (either self-managed or cloud based) to facilitate a production environment security policy.  

Note that the scope of what I describe here is to set up the token vault within a development environment -- which is NOT production ready.  In particular, one system administrator having access to the root token might put too much trust into one person's hands.  An alternative approach is that an unseal key which generates this root token may be split into multiple shards whereby say three responsible individuals each possess one shard, all of which are needed to generate the unseal key to generate the root token to unseal/decrypt what data is stored and is necessary for OpenBao to be queried.

# What I did
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

However, Podman is running as a regular user, so instead of trying to greedily lock memory we tell OpenBao "It's okay, don't try to lock memory" by configuring `#Environment='BAO_LOCAL_CONFIG={"disable_mlock": true}'`, which uses the system call named `mlock`.  The rationale behind this approach is that if an attacker has physical access to your CI runner's hard drive such that he/she/they can read swap files, then you have a much bigger security problem than this.  Also the real problem is that as Podman, by default, is running as a regular user, it doesn't have permission to lock memory, and will crash if OpenBao attempt to do it with a "Permission Denied". Obviously this is undesirable and we seek to avoid it. In -dev mode the possibility of locking memory is disabled automatically.

The bao-data volume (on the host) might be stored, by default, at `~/.local/share/containers/storage/volumes/bao-data`


4.  **Obtain your root key and login to OpenBai via the (local) web interface:**
    ```bash
    systemctl --user status openbao.service
    ```
    then input the root token into http://http://127.0.0.1:8200
 
