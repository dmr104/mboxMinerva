# Dockerfile

There is a Dockerfile at docker-images/ruby-base/Dockerfile which will create a docker image with the most recent updates to it.

To do this manually, from the repo base directory run 

`podman build --layers -t ruby:local-patched -f docker/Dockerfile .`

Then go to `~/.local/share/containers/storage/volumes/gitlab-runner-config/_data/config.toml` and edit the file to include the following
```toml
[[runners]]
  [runners.docker]
    pull_policy = ["if-not-present"]
    allowed_pull_policies: ["always", "if-not-present", "never"]
```
This will configure gitlab to use local images

Observe that in .gitlab-ci.yml we refer to this image, which is a local one.  Note that this solution is probably not what you want in a production environment, where you ought to push your image (which is tagged uniquely and immutably, e.g. "app:1.2.3_\<SHA\>") to a private container repository from the dev environment and the pull it into your production one. 

