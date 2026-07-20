# Production Setup Checklist

## Repository

1. Create `NoFeelCaptcha/nofeel-k8s-ci` as a public repository.
2. Set the default branch to `main`.
3. Add the workflow environment named `production`.
4. Add at least one required reviewer to that environment before allowing a run.

## Tokens

Use separate credentials for separate boundaries:

- component checkout: read-only GitHub token;
- GHCR push: `write:packages` token or the repository `GITHUB_TOKEN`;
- cluster pull: read-only `read:packages` token;
- deploy transport: SSH key restricted to the OVH deployment account.

Do not put a kubeconfig in the repository or in a workflow input. The workflow uses
the kubeconfig already present on OVH at `/etc/kubernetes/admin.conf`.

## First dry run

Before using production credentials, run the scripts locally with a disposable
registry and inspect the generated overlays:

```bash
export NOFEEL_ROOT=/path/to/nofeel-k8s
export IMAGE_RUNTIME=ghcr.io/nofeelcaptcha/nofeel-runtime@sha256:<64-hex>
export IMAGE_SERVER=ghcr.io/nofeelcaptcha/nofeel-server@sha256:<64-hex>
export IMAGE_FRONTEND=ghcr.io/nofeelcaptcha/nofeel-frontend@sha256:<64-hex>
bash scripts/render-production.sh
kubectl kustomize "$NOFEEL_ROOT/ci/generated/production/app"
kubectl kustomize "$NOFEEL_ROOT/ci/generated/production/migrate"
```

The generated files are intentionally temporary and are not committed to either
repository.
