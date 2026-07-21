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
- CI uses a separate public key entry with `restrict`, `no-user-rc`, and a fixed
  `/usr/local/sbin/nofeel-ci-gateway` forced command.
- The CI key cannot request a PTY, execute a command, use forwarding, or use scp/sftp.
- The gateway accepts at most 8192 bytes from standard input.
- The deployment helper is root-owned and reads only the fixed five-field manifest.

## Source and image boundary

- The server-side checkout uses a root-only fine-grained read credential because organization policy disables Deploy Keys.
- The server fetches the requested `nofeel-k8s` commit and verifies it is an ancestor of protected `main`.
- The helper never executes scripts received from GitHub Actions.
- Generated overlays are temporary and are removed after every run.
- Only `ghcr.io/cong0707/*@sha256:<digest>` images are accepted.
- The cluster pull token lives only in `secret/nofeel-ghcr`.

## Verification

Before the first production run, verify:

```text
requested nofeel-k8s commit is a 40-character hash on protected main
invalid protocol manifest is rejected
remote command execution is rejected
local and remote port forwarding are rejected
nofeel-ghcr exists in namespace nofeel
OVH can fetch nofeel-k8s with the read-only Deploy Key
Environment secrets are present
production Environment is restricted to main
```
