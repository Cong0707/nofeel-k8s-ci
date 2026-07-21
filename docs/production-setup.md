# Production Security Checklist

## GitHub

- Repository: `Cong0707/nofeel-k8s-ci`, public.
- Triggers: a newly opened deployment Issue, or an owner-only `workflow_dispatch` with explicit confirmation.
- Comments and reopened Issues do not deploy; push, pull request, and schedule events are not configured.
- `ALLOWED_TRIGGER_ACTORS` is parsed as an exact, case-insensitive comma-separated login list.
- Accounts outside that list have their Issues closed before any environment or deployment Secret is available.
- Direct `workflow_dispatch` checks the event sender against the personal repository owner and does not use the partner allowlist.
- Source: a full `nofeel-k8s` commit entered through Issue or Actions; only commits on protected `main` are accepted.
- `main` requires Pull Request review and CODEOWNER approval.
- `production` Environment accepts deployments from `main` only.
- `ALLOWED_TRIGGER_ACTORS` contains only the accounts that may start a manual run.
- Workflow `GITHUB_TOKEN` has only `contents: read` and `packages: write`; it pushes personal GHCR images.
- The authorization job has only `issues: write`; the production permissions and Environment are scoped to the deployment job.
- `NOFEEL_REPOSITORIES_TOKEN` is read-only and limited to the required NoFeel repositories.

## OVH SSH boundary

- Existing account: `root`.
- CI uses a separate public key entry with `restrict` and `no-user-rc`.
- The CI key cannot request a PTY or use forwarding, but it can execute non-interactive
  commands as root. Protecting the personal repository and `production` Environment is mandatory.
- OVH stores no CI gateway, deployment helper, CI source checkout, or repository PAT.
- The workflow uses the existing `/usr/bin/kubectl` and `/etc/kubernetes/admin.conf`.

## Source and image boundary

- The GitHub Runner checks out the requested `nofeel-k8s` commit and verifies it is an ancestor of protected `main`.
- Generated overlays and rendered manifests are temporary and are removed after every run.
- Only `ghcr.io/cong0707/*@sha256:<digest>` images are accepted.
- The cluster pull token lives only in `secret/nofeel-ghcr`.

## Verification

Before the first production run, verify:

```text
requested nofeel-k8s commit is a 40-character hash on protected main
rendered manifests use immutable personal GHCR digests
the CI key can execute the required read-only kubectl check
local and remote port forwarding are rejected
nofeel-ghcr exists in namespace nofeel
Environment secrets are present
production Environment is restricted to main
```
