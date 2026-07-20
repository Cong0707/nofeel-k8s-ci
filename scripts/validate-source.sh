#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT="${NOFEEL_ROOT:?NOFEEL_ROOT is required}"
readonly COMPONENT_ROOT="${ROOT}/.tools/components"

[[ -d "${ROOT}/.git" ]] || { echo "nofeel-k8s checkout is missing: ${ROOT}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required on the runner" >&2; exit 1; }

read_commit() {
  local component="$1"
  awk -v component="${component}" \
    '$1 == component ":" { found=1; next } found && $1 == "commit:" { print $2; exit }' \
    "${ROOT}/config/components.lock.yaml"
}

for component in server browser frontend; do
  expected="$(read_commit "${component}")"
  [[ "${expected}" =~ ^[0-9a-f]{40}$ ]] || {
    echo "invalid locked commit for ${component}" >&2
    exit 1
  }
  path="${COMPONENT_ROOT}/nofeel-${component}"
  [[ -d "${path}/.git" ]] || { echo "component checkout missing: ${path}" >&2; exit 1; }
  actual="$(git -C "${path}" rev-parse HEAD)"
  [[ "${actual}" == "${expected}" ]] || {
    echo "component ${component} is not at locked commit" >&2
    echo "expected=${expected} actual=${actual}" >&2
    exit 1
  }
  [[ -z "$(git -C "${path}" status --porcelain)" ]] || {
    echo "component checkout is dirty: ${path}" >&2
    exit 1
  }
done

for target in \
  "${ROOT}/kustomize/base/common" \
  "${ROOT}/kustomize/overlays/production/state" \
  "${ROOT}/kustomize/overlays/production/migrate" \
  "${ROOT}/kustomize/overlays/production/app"; do
  kubectl kustomize "${target}" >/dev/null
done

if rg -n --hidden --glob '!.git/**' --glob '!.tools/**' \
  '(^|[/:])latest([@: ]|$)' "${ROOT}"; then
  echo 'latest image tags are forbidden' >&2
  exit 1
fi

if rg -n --hidden --glob '!.git/**' --glob '!.tools/**' \
  'example\.invalid|replace-with|sha256:0{64}' \
  "${ROOT}/kustomize/overlays/production"; then
  echo 'production overlay contains a placeholder' >&2
  exit 1
fi

echo "source validation passed: ${ROOT}"
