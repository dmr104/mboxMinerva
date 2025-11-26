#!/bin/bash
# GitLab + Runner on Rootless Podman (Defensive Dev Setup)
set -e

echo ">>> Checking environment..."

# 1. Network: Check existence before creating
if podman network exists systemd-gitlab_net; then
    echo " [OK] Network 'systemd-gitlab_net' already exists."
else
    echo " [..] Creating network 'systemd-gitlab_net'..."
    podman network create systemd-gitlab_net
fi

# 2. GitLab CE (Server)
CONTAINER_NAME="gitlab"
IMAGE="docker.io/gitlab/gitlab-ce:latest"

if podman container exists "$CONTAINER_NAME"; then
    if [ "$(podman container inspect -f '{{.State.Running}}' $CONTAINER_NAME)" == "true" ]; then
        echo " [OK] Container '$CONTAINER_NAME' is already running."
    else
        echo " [..] Container '$CONTAINER_NAME' exists but is stopped. Starting it..."
        podman start "$CONTAINER_NAME"
    fi
else
    echo " [..] Container '$CONTAINER_NAME' not found. Creating it..."
    # Ensure image is local before run to avoid timeouts/surprises, though run pulls automatically
    if ! podman image exists "$IMAGE"; then
        echo "      Pulling $IMAGE (this may take a while)..."
        podman pull "$IMAGE"
    fi
    
HOST_IP=$(hostname -I | awk '{print $1}')

    podman run -d \
      --name "$CONTAINER_NAME" \
      --network systemd-gitlab-net \
      --publish 8080:80 --publish 4443:443 --publish 2222:22 \
      --env GITLAB_OMNIBUS_CONFIG="external_url 'http://$HOST_IP:8080'; nginx['listen_port'] = 80; gitlab_rails['gitlab_shell_ssh_port'] = 2222; puma['port'] = 8081" \
      --volume gitlab-config:/etc/gitlab \
      --volume gitlab-logs:/var/log/gitlab \
      --volume gitlab-data:/var/opt/gitlab \
      "$IMAGE"
fi

# 3. GitLab Runner (Worker)
RUNNER_NAME="gitlab-runner"
RUNNER_IMAGE="docker.io/gitlab/gitlab-runner:latest"

if podman container exists "$RUNNER_NAME"; then
    if [ "$(podman container inspect -f '{{.State.Running}}' $RUNNER_NAME)" == "true" ]; then
        echo " [OK] Container '$RUNNER_NAME' is already running."
    else
        echo " [..] Container '$RUNNER_NAME' exists but is stopped. Starting it..."
        podman start "$RUNNER_NAME"
    fi
else
    echo " [..] Container '$RUNNER_NAME' not found. Creating it..."
    if ! podman image exists "$RUNNER_IMAGE"; then
        echo "      Pulling $RUNNER_IMAGE..."
        podman pull "$RUNNER_IMAGE"
    fi

    # Crucial: We mount the HOST's podman socket into the container as docker.sock
    podman run -d \
      --name "$RUNNER_NAME" \
      --network systemd-gitlab-net \
      --volume gitlab-runner-config:/etc/gitlab-runner \
      --volume $XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock \
      --security-opt label=disable \
      "$RUNNER_IMAGE"
fi

# 4. The handshake between gitlab-runner container and gitlab container.
echo ""
echo ">>> Setup complete."
echo "    Wait for GitLab to boot (check 'podman logs -f gitlab'), then go to:"
echo "    http://localhost:8080 -> Admin Area -> Runners -> New Instance Runner -> Copy Token"
echo ""
echo "    Register command (run manually once token is obtained):"
echo "    podman exec -it gitlab-runner gitlab-runner register \\"
echo "      --url 'http://<gitlab_or_ip_addr>:8080' \\"
echo "      --executor 'docker' \\"
echo "      --docker-image 'ruby:3.3' \\"
echo "      --description 'podman-runner' \\"
echo "      --docker-volumes \\"$XDG_RUNTIME_DIR/podman/podman.sock:/var/run/docker.sock\\""
