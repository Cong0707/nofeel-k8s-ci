#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEPLOY_HOST="${DEPLOY_HOST:?DEPLOY_HOST is required}"
readonly DEPLOY_USER="${DEPLOY_USER:-root}"
readonly MANIFEST_DIR="${MANIFEST_DIR:?MANIFEST_DIR is required}"
readonly SSH_KEY="${DEPLOY_SSH_KEY:-${HOME}/.ssh/id_ed25519}"

[[ "${DEPLOY_USER}" == root ]] || { echo 'DEPLOY_USER must be root' >&2; exit 1; }
[[ "${DEPLOY_HOST}" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo 'invalid DEPLOY_HOST' >&2; exit 1; }
[[ -f "${SSH_KEY}" ]] || { echo "SSH key is missing: ${SSH_KEY}" >&2; exit 1; }
for manifest in state migrate app; do
  [[ -s "${MANIFEST_DIR}/${manifest}.yaml" ]] || {
    echo "release manifest is missing: ${manifest}.yaml" >&2
    exit 1
  }
done

readonly TARGET="${DEPLOY_USER}@${DEPLOY_HOST}"
readonly -a SSH_ARGS=(
  -T
  -i "${SSH_KEY}"
  -o StrictHostKeyChecking=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
)

remote() {
  ssh "${SSH_ARGS[@]}" "${TARGET}" "$1"
}

apply_manifest() {
  local manifest="$1"
  remote 'export KUBECONFIG=/etc/kubernetes/admin.conf; exec /usr/bin/kubectl apply -f -' \
    < "${MANIFEST_DIR}/${manifest}.yaml"
}

rollout_started=0
cleanup_and_rollback() {
  local status=$?
  if (( status != 0 && rollout_started == 1 )); then
    echo 'deployment failed; restoring previous application revisions' >&2
    remote 'export KUBECONFIG=/etc/kubernetes/admin.conf; for deployment in nofeel-api nofeel-worker nofeel-frontend; do /usr/bin/kubectl -n nofeel rollout undo "deployment/${deployment}" >/dev/null 2>&1 || true; done; for deployment in nofeel-api nofeel-worker nofeel-frontend; do /usr/bin/kubectl -n nofeel rollout status "deployment/${deployment}" --timeout=300s >/dev/null 2>&1 || true; done' || true
  fi
  exit "${status}"
}
trap cleanup_and_rollback EXIT

remote 'export KUBECONFIG=/etc/kubernetes/admin.conf; /usr/bin/kubectl -n nofeel get secret nofeel-ghcr >/dev/null'

apply_manifest state
remote 'export KUBECONFIG=/etc/kubernetes/admin.conf; /usr/bin/kubectl -n nofeel rollout status statefulset/nofeel-redis-ha --timeout=900s; /usr/bin/kubectl -n nofeel rollout status deployment/nofeel-redis-proxy --timeout=600s'
remote 'export KUBECONFIG=/etc/kubernetes/admin.conf; for selector in "postgres-operator.crunchydata.com/cluster=nofeel-postgres,postgres-operator.crunchydata.com/data=postgres" "postgres-operator.crunchydata.com/cluster=nofeel-postgres,postgres-operator.crunchydata.com/role=pgbouncer" "postgres-operator.crunchydata.com/cluster=nofeel-postgres,postgres-operator.crunchydata.com/data=pgbackrest"; do /usr/bin/kubectl -n nofeel wait --for=condition=Ready pod -l "${selector}" --timeout=900s; done'

remote 'export KUBECONFIG=/etc/kubernetes/admin.conf; /usr/bin/kubectl -n nofeel delete job nofeel-migrate --ignore-not-found=true --wait=true'
apply_manifest migrate
remote 'export KUBECONFIG=/etc/kubernetes/admin.conf; /usr/bin/kubectl -n nofeel wait --for=condition=complete job/nofeel-migrate --timeout=600s'

rollout_started=1
apply_manifest app
remote 'export KUBECONFIG=/etc/kubernetes/admin.conf; for deployment in nofeel-api nofeel-worker nofeel-frontend; do /usr/bin/kubectl -n nofeel rollout status "deployment/${deployment}" --timeout=900s; done'
remote 'export KUBECONFIG=/etc/kubernetes/admin.conf; /usr/bin/kubectl -n nofeel get deployment nofeel-api nofeel-worker nofeel-frontend -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,UPDATED:.status.updatedReplicas'

trap - EXIT
echo 'NoFeelCaptcha production rollout completed'
