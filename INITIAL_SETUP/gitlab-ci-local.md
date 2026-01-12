## Background
If you have been following the steps so far, you should have a podman Container called gitlab-runner which is registered with Gitlab omnibus (user interface) Container, and which will run the CI pipeline upon every `git commit` and `git push` to the Gitlab omnibus Container.  This is all well and good, but I don't really want to git commit **every** time I make some changes which I want to be tested.  Ideally, I want to have a way to test the code of a Job in a fresh container which will read its Job instructions from the `.gitlab-ci.yml` file in our repo, which it will have access to in so far as it will have access to all of the codebase within our Host repo.  

How do we achieve this?

Well, we want some way to create and to have new Job Containers which are **manually created** ones which know nothing about, and which are completely separate to, and independent than, the **automated Job Containers** which are created by the GitLab Runner whenever the pipeline which is triggered only by a `git push`, runs.  Recall that we are pushing to GitLab omnibus Container (which acts as the "brain") and it is the registered GitLab Runner (which acts as the "muscle") which acts upon this `git push` by implementing a Pipeline.

So how do we achieve the implementation of these **manually created specific Job Containers**?

So if I merely start a Container via `podman run...`, then let us say that this is my **manual dev Job Container**, and is called "testing".  This Container will have nothing to do with my `.gitlab-ci.yml` file as things stand currently, but we want that it ought to be able to see it.  I am attempting to automate using my `.gitlab-ci.yml` file; so is there any way to prototype the use of this file **before** I `git commit` and `git push`, so that I don't have to `git push` merely to test it out each time?

Well yes, there is.  It is called....

# **gitlab-ci-local**
This a third-party tool which runs on the Host, and which parses your YAML from `.gitlab-ci.yml` and launches local Containers that mount the Host mboxMinerva repo.

To do this:
1.  **Install it on Host** (if you have Node.js: `npm install gitlab-ci-local`, from the root directory of "mboxMinerva", or download the binary from GitHub if not).
2.  **Run it**: `cd /path/to/mboxMinerva` on the Host, then type `npx gitlab-ci-local --list-all` to examine, and `npx gitlab-ci-local --network host --variable VAULT_TOKEN="$ROOT_TOKEN" --volume /run/user/1000/podman/podman.sock:/var/run/docker.sock` to run it.

For this command to work you will need to have first issued an `export ROOT_TOKEN=$(podman exec systemd-openbao bao login -token-only token=MY_REDACTED_ROOT_TOKEN)`.

Note that in a gitlab-ci-local run of our Job Container which invokes our helper called `.secret_fetcher:` (from `.gitlab-ci-local.md`) the variable called VAULT_TOKEN won't see the environment variable by the same name.  This is to be expected: the Job Container *cannot* see the environment variables from the Host.  Please note also that the variable as VAULT_TOKEN *has to be called* the name as VAULT_TOKEN within this helper as .secret_fetcher and that if you call it any other name then anything further which is requiring it to be called VAULT_TOKEN will fail.  Note also that within a gitlab-ci-local run (i.e. outside of the gitlab CI pipeline) we *cannot* rely upon the asymmetric trust between gitlab omnibus and the openbao token vault to exchange keys to get this token (which I have as the root token within my dev environment) so we *must* inject the variable as VAULT_TOKEN (which I do from and after creating an environment variable called ROOT_TOKEN) manually when the command as `gitlab-ci-local` is invoked. Here when the gitlab-ci-local is run we have a variable name collision, and the YAML-defined variable takes precedence and copies over anything of the same name.  This will result in an error when we are running gitlab-ci-local because its environment will not have access to the root token to gain access to OpenBao:
```
rebuild_ruby_base > Error writing data to auth/jwt/login: Error making API request.
rebuild_ruby_base > 
rebuild_ruby_base > URL: PUT http://192.168.1.168:8200/v1/auth/jwt/login
rebuild_ruby_base > Code: 400. Errors:
rebuild_ruby_base > 
rebuild_ruby_base > * missing token
```
If you have understood this, you will also understand that the variable as VAULT_TOKEN injected into th `gitlab-ci-local` command will not be fallen back upon, but overwritten.  So within our .gitlab-ci.yml file we shall set the variable VAULT_TOKEN only if VAULT_TOKEN is not already set.
We do this in the following manner:
```
export VAULT_TOKEN=${VAULT_TOKEN:-$(bao write -field=token auth/jwt/login role=$VAULT_ROLE jwt=$BAO_VAULT_ID)}
```

Note that we are using our root token here within development. There are other methods available though, like token auth or approle.  The first is the simplest where you can either use the root token directly (bad for prod), or create child tokens via `bao token -create -policy=mypolicy -ttl=1h`, or more commonly just consume tokens which have be *produced by* other auth methods (AppRole, JWT, etc).  For the latter, approle uses a role_id + secret_id pair where you'd first create an approle with `bao write auth/approle/role/local-dev policies=your-policy` to get a token.  You can fetch the role_id with `auth/approle/role/local-dev/role-id` and the secret_id with `auth/approle/role/local-dev/secret-id`.  You would obtain a token via `bao write auth/approle/login role_id=X secret_id=Y` and then use this token to subsequently obtain longer-term variables which are stored within openbao.

3.  **Result**: It reads your local `.gitlab-ci.yml`, starts containers via Podman, runs the scripts, and prints the output to your terminal: all without a single `git push`.

Can I run a specific Job only using gitlab-ci-local?

Yes, you can. Run `gitlab-ci-local <job_name>` to run just that job, and you can add `--needs` if you also want to pull in and execute any upstream `needs:` dependencies automatically.

## How does this asymmetric trust thing work?
Well, Gitlab signs a JWT (the `CI_JOB_JWT` or `id_tokens`) with its private key. OpenBao was preconfigured with GitLab's JWKS URL or public key, so when your job calls `bao write auth/jwt/login`, OpenBao validates the signature against that public key without ever talking to GitLab directly.

## Speeding up the dev time.
Is there any way I can speed up the development time as it takes time to `apk add` every time I wish to run this job to test the script contained within get_ruby_image_and_test?  I am thinking of having an intermediate image cached which has `apk add --no-cache docker-cli docker-cli-buildx` already baked into it.  Answer.  This is feasible and readily doable.  We create another dockerfile called "Dockerfile.openbao-docker" which contains:
```
FROM openbao/openbao:latest

RUN apk add --no-cache docker-cli docker-cli-buildx
```
We automate the building of it (within .gitlab-ci.yml) and pushing of it to GHCR (Github Container registry), and then use this pre-baked image within the Job as get_ruby_image_and_test instead of the pre-baked image which lacks the docker commands. This way we will shave off the apk overhead by every run and only pay for it once when we are building that intermediate layer.