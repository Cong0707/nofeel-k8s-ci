#!/usr/bin/env bash
set -Eeuo pipefail

readonly RELEASE_ROOT="${1:?release root is required}"
readonly REGISTRY_ENV="${2:?registry environment file is required}"
readonly KUBECTL="${KUBECTL:-kubectl}"
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

[[ -d "${RELEASE_ROOT}" ]] || { echo "release root is missing" >&2; exit 1; }
[[ -f "${REGISTRY_ENV}" ]] || { echo "registry environment file is missing" >&2; exit 1; }
# The file is transferred over the SSH channel and is removed by the caller.
# shellcheck disable=SC1090
source "${REGISTRY_ENV}"
: "${GHCR_PULL_USERNAME:?GHCR_PULL_USERNAME is required}"
: "${GHCR_PULL_TOKEN:?GHCR_PULL_TOKEN is required}"

readonly APP_OVERLAY="${RELEASE_ROOT}/ci/generated/production/app"
readonly MIGRATE_OVERLAY="${RELEASE_ROOT}/ci/generated/production/migrate"
readonly STATE_OVERLAY="${RELEASE_ROOT}/kustomize/overlays/production/state"
[[ -f "${APP_OVERLAY}/kustomization.yaml" ]] || { echo "generated app overlay is missing" >&2; exit 1; }
[[ -f "${MIGRATE_OVERLAY}/kustomization.yaml" ]] || { echo "generated migrate overlay is missing" >&2; exit 1; }

rollout_started=0
rollback_on_failure() {
  local status=$?
  if (( status != 0 && rollout_started == 1 )); then
    echo "deployment failed; restoring previous application revisions" >&2
    for deployment in nofeel-api nofeel-worker nofeel-frontend; do
      "${KUBECTL}" -n nofeel rollout undo "deployment/${deployment}" >/dev/null 2>&1 || true
    done
    for deployment in nofeel-api nofeel-worker nofeel-frontend; do
      "${KUBECTL}" -n nofeel rollout status "deployment/${deployment}" --timeout=300s >/dev/null 2>&1 || true
    done
  fi
  exit "${status}"
}
trap rollback_on_failure EXIT

"${KUBECTL}" -n nofeel create secret docker-registry nofeel-ghcr \
  --docker-server=ghcr.io \
  --docker-username="${GHCR_PULL_USERNAME}" \
  --docker-password="${GHCR_PULL_TOKEN}" \
  --dry-run=client -o yaml | "${KUBECTL}" apply -f - >/dev/null

# Reconcile only declarative state resources; secrets and database data are not
# recreated by this workflow.
"${KUBECTL}" apply -k "${STATE_OVERLAY}"
"${KUBECTL}" -n nofeel rollout status statefulset/nofeel-redis-ha --timeout=900s
"${KUBECTL}" -n nofeel rollout status deployment/nofeel-redis-proxy --timeout=600s

for selector in \
  'postgres-operator.crunchydata.com/cluster=nofeel-postgres,postgres-operator.crunchydata.com/data=postgres' \
  'postgres-operator.crunchydata.com/cluster=nofeel-postgres,postgres-operator.crunchydata.com/role=pgbouncer' \
  'postgres-operator.crunchydata.com/cluster=nofeel-postgres,postgres-operator.crunchydata.com/data=pgbackrest'; do
  "${KUBECTL}" -n nofeel wait --for=condition=Ready pod -l "${selector}" --timeout=900s
done

"${KUBECTL}" -n nofeel delete job nofeel-migrate --ignore-not-found=true --wait=true
"${KUBECTL}" apply -k "${MIGRATE_OVERLAY}"
"${KUBECTL}" -n nofeel wait --for=condition=complete job/nofeel-migrate --timeout=600s

"${KUBECTL}" apply -k "${APP_OVERLAY}"
rollout_started=1
for deployment in nofeel-api nofeel-worker nofeel-frontend; do
  "${KUBECTL}" -n nofeel rollout status "deployment/${deployment}" --timeout=900s
done

"${KUBECTL}" -n nofeel get deployment nofeel-api nofeel-worker nofeel-frontend \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,UPDATED:.status.updatedReplicas
"${KUBECTL}" -n nofeel get pods -o wide

trap - EXIT
unset GHCR_PULL_USERNAME GHCR_PULL_TOKEN
echo 'NoFeelCaptcha production rollout completed'
