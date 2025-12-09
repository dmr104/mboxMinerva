# Background
If you have been following the steps so far you should have a podman Container called gitlab-runner which is registered with Gitlab omnibus (user interface) Container, and which will run the CI pipeline upon every `git commit` and `git push` to the Gitlab omnibus Container.  This is all well and good, but I don't really want to git commit **every** time I make some changes which I want to be tested.  Ideally I want to have a way to test the code of a Job in a fresh container which will read its Job instructions from the `.gitlab-ci.yml` file in our repo, which it will have access to in so far as it will have access to all of the codebase within our Host repo.  

How do we achieve this?

Well we want some way to create and to have new Job Containers which are **manually created** ones which know nothing about the completely separate to and independent than the **automated Job Containers** which are created by the GitLab Runner whenever the pipeline which is triggered only by a `git push` runs.  Recall that we are pushing to GitLab omnibus Container (which acts as the "brain") and it is the registered GitLab Runner (which acts as the "muscle") which acts upon this `git push` by implementing a Pipeline.

So how do we achieve the implementation of these **manually created specific Job Containers**?

So if I merely start a Container via `podman run...` let us say that this is my **manual dev Job Container** and is called "testing".  This Container will have nothing to do with my `.gitlab-ci.yml` file as things stand currently, but should be able to see it. 

But I am attempting to automate using my `.gitlab-ci.yml` file; so is there any way to prototype the use of this file **before** I `git commit` and `git push`, so that I don't have to `git push` merely to test it out each time?

Well yes, there is.  It is called....

# **gitlab-ci-local**
This a third-party tool which runs on the Host, and which parses your YAML from `.gitlab-ci.yml` and launches local Containers that mount the Host mboxMinerva repo.

To do this:
1.  **Install it on Host** (if you have Node.js: `npm install -g gitlab-ci-local`, or download the binary from GitHub if not).
2.  **Run it**: `cd /path/to/mboxMinerva` on Host, then type `gitlab-ci-local`.
3.  **Result**: It reads your local `.gitlab-ci.yml`, starts containers via Podman, runs the scripts, and prints the output to your terminal—all without a single `git push`.

Can I run a specific Job only using gitlab-ci-local?

Yes, you can. Run `gitlab-ci-local <job_name>` or `gitlab-ci-local -j <job_name>` to run just that job, and you can add `--needs` if you also want to pull in and execute any upstream `needs:` dependencies automatically.



