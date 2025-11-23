# Dockerfile

There is a Dockerfile at docker-images/ruby-base/Dockerfile which will create a docker image with the most recent updates to it.

To do this manually, navigate to the directory which contains the file and run 

`podman build -t myruby:local-patched .`

Then go to `~/.local/share/containers/storage/volumes/gitlab-runner-config/_data/config.toml` and edit the file to include the following
```toml
[[runners]]
  [runners.docker]
    pull_policy = ["if-not-present"]
```
This will configure gitlab to use local images

Observe that in .gitlab-ci.yml we refer to this image

