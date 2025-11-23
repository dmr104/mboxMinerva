# JupyterHub Extended Tutorial

## Table of Contents
1. [Introduction](#introduction)
2. [Architecture Overview](#architecture-overview)
3. [Installation Methods](#installation-methods)
4. [Basic Configuration](#basic-configuration)
5. [Authentication Setup](#authentication-setup)
6. [Spawner Options](#spawner-options)
7. [Security Best Practices](#security-best-practices)
8. [Example Configurations](#example-configurations)
9. [Troubleshooting](#troubleshooting)
10. [Advanced Topics](#advanced-topics)

---

## Introduction

JupyterHub is a multi-user server that manages and proxies individual Jupyter notebook instances for teams, classrooms, or organizations. It provides:

- Centralized user management and authentication
- Resource isolation and management
- Scalable deployment options
- Fine-grained access control
- Audit logging and monitoring

**Use Cases:**
- Educational institutions managing student notebook access
- Research teams sharing computational resources
- Development teams providing standardized notebook environments
- Cloud providers offering notebook-as-a-service

---

## Architecture Overview

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│                 │    │                  │    │                 │
│   User Browser  │◄──►│   JupyterHub     │◄──►│   Spawner       │
│                 │    │   (Proxy + API)  │    │   (Docker/K8s)  │
└─────────────────┘    └──────────────────┘    └─────────────────┘
                              │
                              ▼
                       ┌─────────────────┐
                       │                 │
                       │   Authenticator │
                       │                 │
                       └─────────────────┘
```

**Key Components:**
- **Proxy**: Routes user requests to appropriate notebook servers
- **Hub**: Manages user authentication, spawns notebook servers
- **Spawner**: Creates and manages individual notebook environments
- **Authenticator**: Handles user authentication against various backends

---

## Installation Methods

### 1. Basic pip Installation

```bash
# Create virtual environment
python3 -m venv jupyterhub-env
source jupyterhub-env/bin/activate

# Install JupyterHub
pip install jupyterhub

# Install configurable HTTP proxy (recommended)
npm install -g configurable-http-proxy

# Start JupyterHub
jupyterhub
```

### 2. Docker Installation

```bash
# Pull official JupyterHub image
docker pull jupyterhub/jupyterhub

# Create network
docker network create jupyterhub-network

# Run JupyterHub container
docker run -d --name jupyterhub \
  --network jupyterhub-network \
  -p 8000:8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  jupyterhub/jupyterhub jupyterhub
```

### 3. Kubernetes Installation

```yaml
# jupyterhub-namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: jupyterhub
---
# jupyterhub-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: jupyterhub-config
  namespace: jupyterhub
data:
  jupyterhub_config.py: |
    c.JupyterHub.ip = '0.0.0.0'
    c.JupyterHub.port = 8000
    c.JupyterHub.hub_ip = '0.0.0.0'
```

```bash
# Install using Helm
helm repo add jupyterhub https://jupyterhub.github.io/helm-chart/
helm repo update
helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  --namespace jupyterhub \
  --create-namespace
```

---

## Basic Configuration

### Creating jupyterhub_config.py

```python
# Basic configuration file
c = get_config()

# Hub configuration
c.JupyterHub.ip = '0.0.0.0'
c.JupyterHub.port = 8000
c.JupyterHub.hub_ip = '0.0.0.0'

# Database configuration
c.JupyterHub.db_url = 'sqlite:///jupyterhub.sqlite'

# Logging
c.Application.log_level = 'INFO'
c.JupyterHub.log_datefmt = '%Y-%m-%d %H:%M:%S'

# Admin users
c.Authenticator.admin_users = {'admin', 'jupyteradmin'}

# Cookie secret (generate with: openssl rand -hex 32)
c.JupyterHub.cookie_secret_file = '/srv/jupyterhub/cookie_secret'
```

### Generating Secrets

```bash
# Generate cookie secret
openssl rand -hex 32 > /srv/jupyterhub/cookie_secret
chmod 600 /srv/jupyterhub/cookie_secret

# Generate proxy auth token
openssl rand -hex 32 > /srv/jupyterhub/proxy_auth_token
chmod 600 /srv/jupyterhub/proxy_auth_token
```

---

## Authentication Setup

### 1. Local Authenticator (Default)

```python
c.JupyterHub.authenticator_class = 'jupyterhub.auth.LocalAuthenticator'
c.LocalAuthenticator.create_system_users = True
c.Authenticator.allowed_users = {'user1', 'user2', 'user3'}
```

### 2. OAuth Authentication (GitHub)

```python
c.JupyterHub.authenticator_class = 'oauthenticator.GitHubOAuthenticator'
c.GitHubOAuthenticator.client_id = 'your_github_client_id'
c.GitHubOAuthenticator.client_secret = 'your_github_client_secret'
c.GitHubOAuthenticator.oauth_callback_url = 'http://your-domain:8000/hub/oauth_callback'

# Restrict to GitHub organization
c.GitHubOAuthenticator.github_organization_whitelist = {'your-org'}
```

### 3. LDAP Authentication

```python
c.JupyterHub.authenticator_class = 'ldapauthenticator.LDAPAuthenticator'
c.LDAPAuthenticator.server_address = 'ldap.example.com'
c.LDAPAuthenticator.server_port = 636
c.LDAPAuthenticator.use_ssl = True
c.LDAPAuthenticator.bind_dn_template = 'uid={username},ou=users,dc=example,dc=com'
c.LDAPAuthenticator.user_search_base = 'ou=users,dc=example,dc=com'
c.LDAPAuthenticator.user_attribute = 'uid'
```

### 4. PAM Authentication

```python
c.JupyterHub.authenticator_class = 'jupyterhub.auth.PAMAuthenticator'
c.PAMAuthenticator.service = 'login'
c.PAMAuthenticator.open_sessions = False
```

---

## Spawner Options

### 1. Local Process Spawner (Default)

```python
c.JupyterHub.spawner_class = 'jupyterhub.spawner.LocalProcessSpawner'
c.LocalProcessSpawner.notebook_dir = '~/notebooks'
c.LocalProcessSpawner.default_url = '/lab'
c.LocalProcessSpawner.mem_limit = '2G'
c.LocalProcessSpawner.cpu_limit = 1
```

### 2. Docker Spawner

```python
# Install dockerspawner first
# pip install dockerspawner

c.JupyterHub.spawner_class = 'dockerspawner.DockerSpawner'
c.DockerSpawner.image = 'jupyter/scipy-notebook:latest'
c.DockerSpawner.remove = True
c.DockerSpawner.network_name = 'jupyterhub-network'
c.DockerSpawner.notebook_dir = '/home/jovyan/work'
c.DockerSpawner.volumes = {'jupyterhub-user-{username}': '/home/jovyan/work'}

# Resource limits
c.DockerSpawner.mem_limit = '1G'
c.DockerSpawner.cpu_limit = 1

# Environment variables
c.DockerSpawner.environment = {
    'JUPYTER_ENABLE_LAB': 'yes',
    'CHOWN_HOME': 'yes',
    'CHOWN_HOME_OPTS': '-R'
}
```

### 3. KubeSpawner (Kubernetes)

```python
# Install kubespawner first
# pip install kubespawner

c.JupyterHub.spawner_class = 'kubespawner.KubeSpawner'

# Pod configuration
c.KubeSpawner.image = 'jupyter/scipy-notebook:latest'
c.KubeSpawner.image_pull_policy = 'IfNotPresent'
c.KubeSpawner.namespace = 'jupyterhub'

# Resource requests and limits
c.KubeSpawner.cpu_guarantee = 0.5
c.KubeSpawner.cpu_limit = 2
c.KubeSpawner.mem_guarantee = '512M'
c.KubeSpawner.mem_limit = '2G'

# Storage
c.KubeSpawner.pvc_name_template = 'claim-{username}{servername}'
c.KubeSpawner.volume_mounts = [
    {
        'name': 'workspace',
        'mountPath': '/home/jovyan/work',
        'subPath': '{username}'
    }
]
```

---

## Security Best Practices

### 1. SSL/TLS Configuration

```python
# Enable SSL
c.JupyterHub.ssl_cert = '/etc/ssl/certs/jupyterhub.crt'
c.JupyterHub.ssl_key = '/etc/ssl/private/jupyterhub.key'

# Or use Let's Encrypt
c.JupyterHub.ssl_cert = '/etc/letsencrypt/live/your-domain/fullchain.pem'
c.JupyterHub.ssl_key = '/etc/letsencrypt/live/your-domain/privkey.pem'
```

### 2. User Isolation

```python
# Prevent users from accessing each other's servers
c.JupyterHub.allow_named_servers = False

# Limit concurrent servers per user
c.JupyterHub.concurrent_spawn_limit = 5

# Set timeout for idle servers
c.Spawner.http_timeout = 120
c.Spawner.start_timeout = 300
c.Spawner.poll_interval = 30
```

### 3. Resource Management

```python
# Global resource limits
c.JupyterHub.active_server_limit = 100

# Per-user resource limits
c.Spawner.mem_limit = '2G'
c.Spawner.cpu_limit = 2

# Cleanup services
c.JupyterHub.services = [
    {
        'name': 'cull-idle',
        'admin': True,
        'command': [sys.executable, '-m', 'jupyterhub_idle_culler',
                   '--timeout=3600', '--cull-every=300'],
    }
]
```

### 4. Access Control

```python
# Allowed users only
c.Authenticator.allowed_users = {'user1', 'user2', 'user3'}
c.Authenticator.blocked_users = {'blocked_user'}

# Group-based access
c.Authenticator.allowed_groups = {'jupyter-users'}

# Admin access
c.Authenticator.admin_users = {'admin', 'jupyteradmin'}
```

---

## Example Configurations

### 1. Small Team Setup (Docker)

```python
# docker-team-config.py
c = get_config()

# Basic setup
c.JupyterHub.ip = '0.0.0.0'
c.JupyterHub.port = 8000

# Authentication
c.JupyterHub.authenticator_class = 'oauthenticator.GitHubOAuthenticator'
c.GitHubOAuthenticator.client_id = 'your_client_id'
c.GitHubOAuthenticator.client_secret = 'your_client_secret'
c.GitHubOAuthenticator.github_organization_whitelist = {'your-org'}

# Docker spawner
c.JupyterHub.spawner_class = 'dockerspawner.DockerSpawner'
c.DockerSpawner.image = 'jupyter/datascience-notebook:latest'
c.DockerSpawner.remove = True
c.DockerSpawner.volumes = {
    'jupyterhub-user-{username}': '/home/jovyan/work'
}
c.DockerSpawner.mem_limit = '4G'
c.DockerSpawner.cpu_limit = 2

# SSL
c.JupyterHub.ssl_cert = '/etc/ssl/certs/jupyterhub.crt'
c.JupyterHub.ssl_key = '/etc/ssl/private/jupyterhub.key'

# Admin users
c.Authenticator.admin_users = {'admin-user'}
```

### 2. University Setup (LDAP + K8s)

```python
# university-config.py
c = get_config()

# LDAP authentication
c.JupyterHub.authenticator_class = 'ldapauthenticator.LDAPAuthenticator'
c.LDAPAuthenticator.server_address = 'ldap.university.edu'
c.LDAPAuthenticator.use_ssl = True
c.LDAPAuthenticator.bind_dn_template = 'uid={username},ou=students,dc=university,dc=edu'

# Kubernetes spawner
c.JupyterHub.spawner_class = 'kubespawner.KubeSpawner'
c.KubeSpawner.namespace = 'jupyterhub-students'
c.KubeSpawner.image = 'university/jupyter-student:latest'

# Resource limits per student
c.KubeSpawner.cpu_guarantee = 0.5
c.KubeSpawner.cpu_limit = 2
c.KubeSpawner.mem_guarantee = '1G'
c.KubeSpawner.mem_limit = '4G'

# Storage quotas
c.KubeSpawner.pvc_name_template = 'student-{username}'
c.KubeSpawner.storage_class = 'fast-ssd'
c.KubeSpawner.storage_capacity = '10G'

# Course-based access control
c.Authenticator.allowed_groups = {
    'cs101-students', 'math201-students', 'physics301-students'
}

# Idle culling
c.JupyterHub.services = [
    {
        'name': 'cull-idle',
        'admin': True,
        'command': [
            'python3', '-m', 'jupyterhub_idle_culler',
            '--timeout=7200',  # 2 hours
            '--cull-every=600',  # Check every 10 minutes
            '--max-age=86400'  # Max 24 hours
        ],
    }
]
```

### 3. Development Team Setup (OAuth + Docker)

```python
# dev-team-config.py
c = get_config()

# OAuth with GitLab
c.JupyterHub.authenticator_class = 'oauthenticator.GitLabOAuthenticator'
c.GitLabOAuthenticator.client_id = os.environ['GITLAB_CLIENT_ID']
c.GitLabOAuthenticator.client_secret = os.environ['GITLAB_CLIENT_SECRET']
c.GitLabOAuthenticator.gitlab_group_whitelist = {'dev-team', 'data-science'}

# Docker with custom image
c.JupyterHub.spawner_class = 'dockerspawner.DockerSpawner'
c.DockerSpawner.image = 'company/jupyter-dev:latest'
c.DockerSpawner.extra_create_kwargs = {
    'host_config': docker.utils.create_host_config(
        binds={'/opt/company/data': '/home/jovyan/data'},
        port_bindings={'8888/tcp': None}
    )
}

# Development tools pre-installed
c.DockerSpawner.environment = {
    'JUPYTER_ENABLE_LAB': 'yes',
    'GIT_AUTHOR_NAME': '{username}',
    'GIT_COMMITTER_NAME': '{username}'
}

# Shared workspace
c.DockerSpawner.volumes = {
    'jupyterhub-shared': '/home/jovyan/shared',
    'jupyterhub-user-{username}': '/home/jovyan/work'
}

# Higher limits for development
c.DockerSpawner.mem_limit = '8G'
c.DockerSpawner.cpu_limit = 4
```

---

## Troubleshooting

### Common Issues and Solutions

#### 1. Proxy Connection Errors

```bash
# Check if configurable-http-proxy is running
ps aux | grep configurable-http-proxy

# Restart proxy manually
configurable-http-proxy --ip=0.0.0.0 --port=8001 --api-ip=127.0.0.1 --api-port=8002

# Check proxy logs
journalctl -u jupyterhub -f
```

#### 2. Authentication Failures

```python
# Enable debug logging
c.Application.log_level = 'DEBUG'
c.Authenticator.debug = True

# Test authentication manually
python3 -c "
from jupyterhub.auth import LocalAuthenticator
auth = LocalAuthenticator()
print(auth.authenticate({'username': 'testuser', 'password': 'testpass'}))
"
```

#### 3. Spawner Timeout Issues

```python
# Increase timeouts
c.Spawner.start_timeout = 600  # 10 minutes
c.Spawner.http_timeout = 300    # 5 minutes

# Check system resources
c.Spawner.debug = True
```

#### 4. Docker Spawner Issues

```bash
# Check Docker daemon
docker info
docker ps

# Test Docker connectivity
docker run --rm jupyter/scipy-notebook:latest jupyter --version

# Check network
docker network ls
docker network inspect jupyterhub-network
```

#### 5. SSL Certificate Issues

```bash
# Test certificate
openssl s_server -cert jupyterhub.crt -key jupyterhub.key -accept 8443

# Verify certificate chain
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt jupyterhub.crt
```

### Debug Mode

```python
# Enable comprehensive debugging
c.Application.log_level = 'DEBUG'
c.JupyterHub.debug_proxy = True
c.Spawner.debug = True

# Log to file
c.Application.log_format = '[%(name)s]%(highlevelname)s %(message)s'
c.Application.log_datefmt = '%Y-%m-%d %H:%M:%S'
```

---

## Advanced Topics

### 1. Custom Authenticators

```python
# custom_auth.py
from jupyterhub.auth import Authenticator
from traitlets import Unicode

class CustomAuthenticator(Authenticator):
    api_url = Unicode('https://api.example.com/auth', config=True)
    
    async def authenticate(self, handler, data):
        username = data['username']
        password = data['password']
        
        # Call external API
        async with aiohttp.ClientSession() as session:
            async with session.post(
                self.api_url,
                json={'username': username, 'password': password}
            ) as response:
                if response.status == 200:
                    return {'name': username}
                return None

# Usage in config
c.JupyterHub.authenticator_class = 'custom_auth.CustomAuthenticator'
```

### 2. Custom Spawners

```python
# custom_spawner.py
from dockerspawner import DockerSpawner
from traitlets import Unicode

class CustomDockerSpawner(DockerSpawner):
    image_prefix = Unicode('company/jupyter-', config=True)
    
    def _image_default(self):
        return f"{self.image_prefix}{self.user.name}:latest"
    
    async def start(self):
        # Custom setup before start
        await self._pull_image()
        return await super().start()
    
    async def _pull_image(self):
        # Pull latest image for user
        if ':' not in self.image:
            self.image += ':latest'
        
        # Custom pull logic here
        pass

# Usage in config
c.JupyterHub.spawner_class = 'custom_spawner.CustomDockerSpawner'
```

### 3. Services and APIs

```python
# Add custom service
c.JupyterHub.services = [
    {
        'name': 'user-stats',
        'admin': True,
        'url': 'http://user-stats-service:8080',
        'command': ['python3', '/opt/user-stats/service.py'],
        'environment': {'API_TOKEN': 'your-api-token'}
    },
    {
        'name': 'resource-monitor',
        'url': 'http://resource-monitor:9000',
        'oauth_no_confirm': True,
        'oauth_client_id': 'resource-monitor-client'
    }
]
```

### 4. Hub-to-Spawner Communication

```python
# Enable REST API
c.JupyterHub.hub_connect_ip = 'jupyterhub'
c.JupyterHub.hub_connect_port = 8081

# Configure spawner communication
c.Spawner.hub_connect_ip = 'jupyterhub'
c.Spawner.hub_connect_port = 8081

# API tokens
c.JupyterHub.api_tokens = {
    'service-token-1': 'user-stats-service',
    'service-token-2': 'resource-monitor'
}
```

### 5. Performance Optimization

```python
# Connection pooling
c.JupyterHub.http_pool_connections = 20
c.JupyterHub.http_pool_maxsize = 20

# Async configuration
c.JupyterHub.tornado_settings = {
    'max_buffer_size': 536870912,  # 512MB
    'max_body_size': 536870912
}

# Database optimization
c.JupyterHub.db_url = 'postgresql://jupyterhub:password@db:5432/jupyterhub'
c.JupyterHub.db_pool_kwargs = {
    'max_overflow': 10,
    'pool_pre_ping': True,
    'pool_recycle': 3600
}
```

---

## Deployment Examples

### Systemd Service

```ini
# /etc/systemd/system/jupyterhub.service
[Unit]
Description=JupyterHub
After=network.target

[Service]
Type=simple
User=jupyterhub
Group=jupyterhub
WorkingDirectory=/opt/jupyterhub
Environment=PATH=/opt/jupyterhub/venv/bin
ExecStart=/opt/jupyterhub/venv/bin/jupyterhub -f /opt/jupyterhub/jupyterhub_config.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
# Enable and start
sudo systemctl enable jupyterhub
sudo systemctl start jupyterhub
sudo systemctl status jupyterhub
```

### Nginx Reverse Proxy

```nginx
# /etc/nginx/sites-available/jupyterhub
server {
    listen 80;
    server_name jupyter.example.com;
    return 301 https://$server_name$request_uri;
}

server {
    listen 443 ssl http2;
    server_name jupyter.example.com;

    ssl_certificate /etc/letsencrypt/live/jupyter.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/jupyter.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

---

## Monitoring and Maintenance

### Health Checks

```python
# Health check endpoint
c.JupyterHub.last_activity_interval = 300  # 5 minutes
c.JupyterHub.cleanup_servers = True
c.JupyterHub.cleanup_proxy = True

# Service health monitoring
c.JupyterHub.services = [
    {
        'name': 'health-checker',
        'admin': True,
        'command': ['python3', '-c', '''
import asyncio
import aiohttp
import time

async def health_check():
    while True:
        try:
            async with aiohttp