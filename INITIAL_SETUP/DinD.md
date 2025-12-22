# Docker in docker setup
It might be thought that we are now faced with the catch-22 chicken-and-egg problem whereby the image which we wish to pull in this job requires an auth, but auth can only be read after the image is pulled, and that ought to use docker-in-docker (DinD) with a docker-cli as the job image (public, no auth needed), and with docker-dind as a service.  But this is not necessary. I wish that that gitlab facilitated auth prior to and upon the image that is pulled, yet they don't; and still I don't want to use a CI variable because this would defy our methodology of storing the github_PAT in the token vault.

Because in the gitlab Runner's config.toml, we have already mounted rootless Podman's socket: `"/run/user/1000/podman/podman.sock:/var/run/docker.sock"`, if we try to run DinD (docker in docker) the latter wants to create a daemon at `/var/run/docker.sock` and fails; but if we remove this line from the config any other job which is not DinD will fail.  So the fix would be to add a *second* `[[runners]]` entry in the config.toml with a unique tag (e.g. `tags = ["dind"]`) with *no* socket binding.  The way to achieve this would be done by creating a new runner entry in the Gitlab UI to generate a fresh, unique token for this specific "dind" runner, and then running `gitlab-runner register` pasting in this token.

Admin -> CI/CD -> Runners -> create new runner -> tags "dind" -> copy the token

## But, ...

None of this is necessary, however, as socket-mounting doesn't block auth at all.  The `docker login` will still work as credentials are stored client-side in `root/.docker/config.json` inside the job container, and the docker-cli sends these with every pull request through the socket. DinDwas never *required* for private registry auth. It just isolates the daemon.  Socket-mounting shares the Host's Podman daemon whereby auth still works per-container.
