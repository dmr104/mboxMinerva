# Running Ruby in GitLab CI on Self-Hosted Runners
## A Beginner's Tutorial: Keep CI on GitLab, Use Colab Only for GPU/TPU

**Target Audience:** Engineers who want to run Ruby tests/pipelines on their own GitLab runner infrastructure, reserving Google Colab exclusively for GPU/TPU experiments.

---

## Table of Contents

1. [Overview & Philosophy](#overview--philosophy)
2. [Self-Hosted Runner Setup](#self-hosted-runner-setup)
3. [Basic .gitlab-ci.yml for Ruby](#basic-gitlab-ciyml-for-ruby)
4. [Advanced: Caching, Stages, and Environment Variables](#advanced-caching-stages-and-environment-variables)
5. [Docker vs Shell Executors](#docker-vs-shell-executors)
6. [When to Use Colab vs GitLab CI](#when-to-use-colab-vs-gitlab-ci)
7. [Complete Workflow Example](#complete-workflow-example)
8. [Troubleshooting](#troubleshooting)

---

## 1. Overview & Philosophy

**Core Principle:** GitLab CI is your **source of truth** for:
- Unit/integration tests
- Linting & static analysis
- Data processing pipelines (pre-parsing, splitting, contamination guards)
- Builds, deployments, and rollouts

**Google Colab** is your **ad-hoc GPU/TPU sandbox** for:
- Training large models (when your runner lacks GPUs)
- Quick experiments with heavy tensor operations
- Exploratory notebooks that need specialized hardware

**Never rely on Colab for CI/CD** — it's a manual viewer/notebook runner, not a build pipeline.

---

## 2. Self-Hosted Runner Setup

### Prerequisites
- A Linux VM or bare-metal server (Ubuntu 22.04 recommended)
- GitLab instance (self-hosted or gitlab.com)
- Root or sudo access

### Step 1: Install GitLab Runner

```bash
# Download and install the GitLab Runner binary (Linux x86_64)
curl -L "https://gitlab-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64" -o /usr/local/bin/gitlab-runner
chmod +x /usr/local/bin/gitlab-runner

# Create a GitLab Runner user
useradd --comment 'GitLab Runner' --create-home gitlab-runner --shell /bin/bash

# Install and start the service
gitlab-runner install --user=gitlab-runner --working-directory=/home/gitlab-runner
gitlab-runner start
```

### Step 2: Register the Runner

```bash
# Interactive registration
gitlab-runner register
```

You'll be prompted for:
- **GitLab instance URL:** `https://gitlab.com` (or your self-hosted URL)
- **Registration token:** Find this in your project's Settings → CI/CD → Runners → Specific runners
- **Description:** `my-ruby-runner`
- **Tags:** `ruby,shell` (optional, helps target specific jobs)
- **Executor:** Choose `docker` (recommended) or `shell` (see section 5)
- **Default Docker image:** `ruby:3.3` (if using Docker executor)

### Step 3: Verify

```bash
gitlab-runner list
# You should see your runner with status "alive"
```

In your GitLab project, go to **Settings → CI/CD → Runners** — your runner should appear under "Available specific runners."

---

## 3. Basic .gitlab-ci.yml for Ruby

Create `.gitlab-ci.yml` in your repository root:

```yaml
# Simple Ruby CI pipeline
image: ruby:3.3

stages:
  - test

before_script:
  - ruby -v
  - gem install bundler --no-document
  - bundle install --jobs=4 --retry=3

test_job:
  stage: test
  script:
    - bundle exec rake test
    # or: bundle exec rspec
    # or: ruby test/run_all.rb
  only:
    - main
    - merge_requests
```

**How it works:**
- `image: ruby:3.3` — Pulls the official Ruby 3.3 Docker image (if using Docker executor)
- `before_script` — Runs before each job (installs dependencies)
- `bundle install` — Installs gems from your `Gemfile`
- `bundle exec rake test` — Runs your test suite (adjust for your project)

**Push and watch:**
```bash
git add .gitlab-ci.yml
git commit -m "Add GitLab CI for Ruby tests"
git push
```

Visit **CI/CD → Pipelines** in GitLab to see your job run on your self-hosted runner.

---

## 4. Advanced: Caching, Stages, and Environment Variables

### Full-Featured .gitlab-ci.yml

```yaml
image: ruby:3.3

stages:
  - lint
  - test
  - build

variables:
  RAILS_ENV: test
  BUNDLE_PATH: vendor/bundle

cache:
  key: ${CI_COMMIT_REF_SLUG}
  paths:
    - vendor/bundle/

before_script:
  - ruby -v
  - gem install bundler --no-document
  - bundle config set --local path 'vendor/bundle'
  - bundle install --jobs=4 --retry=3

lint_job:
  stage: lint
  script:
    - bundle exec rubocop --parallel
  only:
    - merge_requests

test_unit:
  stage: test
  script:
    - bundle exec rake test
  coverage: '/\(\d+\.\d+\%\) covered/'
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage/coverage.xml

test_integration:
  stage: test
  script:
    - bundle exec rspec spec/integration/
  parallel: 3

build_gem:
  stage: build
  script:
    - gem build myproject.gemspec
  artifacts:
    paths:
      - "*.gem"
    expire_in: 1 week
  only:
    - tags
```

**Key Features:**

1. **Caching (`cache`)**: Speeds up pipelines by reusing `vendor/bundle/` across jobs
   - `key: ${CI_COMMIT_REF_SLUG}` — Separate cache per branch
   
2. **Stages**: Jobs in `lint` run before `test`, which run before `build`

3. **Variables**: Set environment variables (e.g., `RAILS_ENV: test`)

4. **Parallel execution**: `parallel: 3` runs the job 3 times concurrently (useful for sharded test suites)

5. **Artifacts**: Save build outputs (e.g., `.gem` files, coverage reports)

6. **Coverage parsing**: GitLab extracts coverage % from job logs

7. **Branch/tag filters**: 
   - `only: - merge_requests` — Run only on MRs
   - `only: - tags` — Run only when pushing Git tags

---

## 5. Docker vs Shell Executors

### Docker Executor (Recommended)

**Pros:**
- Clean, isolated environment for every job
- Easy to specify different images per job
- No leftover state between runs

**Cons:**
- Slightly slower startup (image pull)
- Requires Docker installed on runner host

**Setup:**
```bash
# Install Docker on your runner host
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
usermod -aG docker gitlab-runner
```

**Example job with custom image:**
```yaml
custom_image_job:
  image: ruby:3.2-alpine
  script:
    - bundle exec rake custom_task
```

### Shell Executor

**Pros:**
- Fastest startup (no container overhead)
- Direct access to host filesystem and tools

**Cons:**
- Jobs share the same environment (risk of pollution)
- Must manually install Ruby, Bundler, etc. on the runner host

**Setup:**
```bash
# On the runner host
apt-get update
apt-get install -y ruby-full build-essential
gem install bundler
```

**Example .gitlab-ci.yml (shell executor has no `image:` directive):**
```yaml
stages:
  - test

test_job:
  stage: test
  script:
    - ruby -v
    - bundle install
    - bundle exec rake test
  tags:
    - shell  # Ensures job runs only on shell-executor runners
```

---

## 6. When to Use Colab vs GitLab CI

| **Use Case**                          | **GitLab CI (Self-Hosted Runner)** | **Google Colab**                |
|---------------------------------------|------------------------------------|---------------------------------|
| Unit/integration tests                | ✅ Always                           | ❌ Never                         |
| Data pre-processing (mbox parsing)    | ✅ Yes                              | ❌ No                            |
| Linting, static analysis              | ✅ Yes                              | ❌ No                            |
| Train 7B model (QLoRA on 128GB GPU)   | ✅ If runner has GPU                | ✅ If runner lacks GPU           |
| Quick tensor experiment (needs GPU)   | ❌ Overkill                         | ✅ Perfect                       |
| Automated deployment                  | ✅ Always                           | ❌ Never                         |
| Notebook as documentation             | ✅ Store in repo, test in CI        | ✅ View/run manually             |

**Golden Rule:** If it needs to run automatically on every push/MR, put it in GitLab CI. If it's a one-off GPU experiment, use Colab (then bring the results back to Git).

---

## 7. Complete Workflow Example

### Scenario: mboxMinerva Data Pipeline

**Repository Structure:**
```
mboxMinerva/
├── .gitlab-ci.yml
├── Gemfile
├── Gemfile.lock
├── bin/
│   ├── mbox_pre_parser.rb
│   ├── pii_scrubber.rb
│   ├── splitter.rb
│   └── contamination_guard.rb
├── lib/
│   └── pii_scrubber.rb
├── test/
│   └── test_*.rb
└── notebooks/
    └── exploratory_analysis.ipynb
```

**`.gitlab-ci.yml`:**
```yaml
image: ruby:3.3

stages:
  - test
  - process
  - train

variables:
  BUNDLE_PATH: vendor/bundle

cache:
  key: ${CI_COMMIT_REF_SLUG}
  paths:
    - vendor/bundle/

before_script:
  - gem install bundler --no-document
  - bundle install --jobs=4 --retry=3

# Stage 1: Run unit tests on every commit
test_ruby:
  stage: test
  script:
    - bundle exec rake test
  coverage: '/\(\d+\.\d+\%\) covered/'

# Stage 2: Pre-process mbox files (monthly schedule or manual trigger)
parse_mbox:
  stage: process
  script:
    - mkdir -p emails/
    - bin/mbox_pre_parser.rb --input data/archive.mbox --output-dir emails/ --cohort 2025-01
  artifacts:
    paths:
      - emails/
    expire_in: 30 days
  only:
    - schedules
    - web  # manual trigger

scrub_pii:
  stage: process
  needs: [parse_mbox]
  script:
    - bin/pii_scrubber --vault-dir vault --seed 42 --input-dir emails/ --output-dir emails_scrubbed/
  artifacts:
    paths:
      - emails_scrubbed/
      - vault/
    expire_in: 30 days

split_data:
  stage: process
  needs: [scrub_pii]
  script:
    - bin/splitter.rb --manifest manifest.jsonl --pin 2025-01 --materialize all --output splits/
  artifacts:
    paths:
      - splits/
    expire_in: 30 days

contamination_check:
  stage: process
  needs: [split_data]
  script:
    - bin/contamination_guard.rb --manifest manifest.jsonl --output contamination_report.json --threshold 0.70
  artifacts:
    paths:
      - contamination_report.json
      - exclusion_ids.txt

# Stage 3: Train model (triggered after data processing completes)
# This job requires a GPU runner with 'gpu' tag
train_model:
  stage: train
  needs: [split_data, contamination_check]
  tags:
    - gpu
  script:
    - python scripts/train_qlora.py --train splits/train.jsonl --val splits/val.jsonl --output adapters/2025-01/
  artifacts:
    paths:
      - adapters/
    expire_in: 90 days
  only:
    - schedules
```

**Workflow:**

1. **Every push to `main` or MR:** Runs `test_ruby` on your self-hosted runner (no GPU needed)
2. **Monthly pipeline schedule:** Triggers `parse_mbox` → `scrub_pii` → `split_data` → `contamination_check` → `train_model`
3. **GPU job:** If your runner has a GPU (with `gpu` tag), GitLab CI runs training; otherwise, manually run training in Colab:
   ```python
   # In Colab notebook
   !git clone https://gitlab.com/yourorg/mboxminerva.git
   %cd mboxminerva
   !pip install -r requirements.txt
   !python scripts/train_qlora.py --train splits/train.jsonl --val splits/val.jsonl --output adapters/2025-01/
   # Download adapters/ and commit back to Git
   ```

---

## 8. Troubleshooting

### Runner Not Picking Up Jobs

**Symptom:** Pipeline stuck in "pending" state.

**Solution:**
- Check runner status: `gitlab-runner list`
- Verify tags match: If your job has `tags: [gpu]`, your runner must have the `gpu` tag
- Check executor: Shell executor jobs won't work if image is specified (remove `image:` or switch to Docker executor)

### Bundler Issues

**Symptom:** `Could not find gem 'xyz' in locally installed gems.`

**Solution:**
- Ensure `Gemfile.lock` is committed to Git
- Clear cache: Settings → CI/CD → Pipelines → Clear runner caches
- Force reinstall in job: `bundle install --force`

### Docker Permission Denied

**Symptom:** `Got permission denied while trying to connect to the Docker daemon socket`

**Solution:**
```bash
# On runner host
usermod -aG docker gitlab-runner
systemctl restart gitlab-runner
```

### Slow Pipelines

**Solutions:**
- Enable caching (see section 4)
- Use Docker layer caching: `gitlab-runner register ... --docker-pull-policy if-not-present`
- Parallelize jobs: Use `parallel:` or split stages
- Use local mirror of Rubygems: `bundle config mirror.https://rubygems.org https://your-mirror.example.com`

### Runner Disk Full

**Symptom:** `No space left on device`

**Solution:**
```bash
# Clean up old Docker images/containers
docker system prune -a -f

# Clear GitLab Runner build cache
rm -rf /home/gitlab-runner/builds/*
rm -rf /home/gitlab-runner/cache/*
```

---

## Summary

- **Self-hosted GitLab runner** = Your CI/CD workhorse for tests, data pipelines, and deployments
- **Google Colab** = GPU/TPU sandbox for ad-hoc experiments only
- **Use Docker executor** for clean, reproducible builds
- **Cache `vendor/bundle/`** to speed up pipelines
- **Tag GPU jobs** with `gpu` tag and run on dedicated GPU runner (or fall back to Colab for training)
- **Store notebooks in Git** and test them in CI (using `jupyter nbconvert --execute`), but don't rely on Colab for automation

**Next Steps:**
1. Register your self-hosted runner
2. Add `.gitlab-ci.yml` with a simple test job
3. Push and verify the pipeline runs
4. Gradually add stages for data processing, linting, deployment
5. Reserve Colab for GPU-heavy experiments, then bring results back to Git

---

**Questions?** Check GitLab CI docs: https://docs.gitlab.com/ee/ci/  
**Runner docs:** https://docs.gitlab.com/runner/