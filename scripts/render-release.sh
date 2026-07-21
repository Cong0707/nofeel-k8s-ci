#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT="${NOFEEL_ROOT:?NOFEEL_ROOT is required}"
readonly OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"
readonly SERVER_IMAGE="${SERVER_IMAGE:?SERVER_IMAGE is required}"
readonly RUNTIME_IMAGE="${RUNTIME_IMAGE:?RUNTIME_IMAGE is required}"
readonly FRONTEND_IMAGE="${FRONTEND_IMAGE:?FRONTEND_IMAGE is required}"
readonly GENERATED_ROOT="${ROOT}/ci/generated"
readonly APP_DIR="${GENERATED_ROOT}/production/app"
readonly MIGRATE_DIR="${GENERATED_ROOT}/production/migrate"

for image in "${SERVER_IMAGE}" "${RUNTIME_IMAGE}" "${FRONTEND_IMAGE}"; do
  [[ "${image}" =~ ^ghcr\.io/cong0707/nofeel-(server|runtime|frontend)@sha256:[0-9a-f]{64}$ ]] || {
    echo "invalid immutable image reference: ${image}" >&2
    exit 1
  }
done

if git -C "${ROOT}" ls-files --error-unmatch ci/generated >/dev/null 2>&1; then
  echo 'ci/generated is tracked in the selected source repository' >&2
  exit 1
fi

cleanup() {
  rm -rf "${GENERATED_ROOT}"
}
trap cleanup EXIT

rm -rf "${GENERATED_ROOT}" "${OUTPUT_DIR}"
mkdir -p "${APP_DIR}" "${MIGRATE_DIR}" "${OUTPUT_DIR}"
cp "${ROOT}/kustomize/overlays/production/app/config-patch.yaml" "${APP_DIR}/config-patch.yaml"
cp "${ROOT}/kustomize/overlays/production/migrate/config-patch.yaml" "${MIGRATE_DIR}/config-patch.yaml"

cat > "${APP_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../../kustomize/base/app
patches:
  - path: config-patch.yaml
  - path: image-pull-secret-patch.yaml
images:
  - name: nofeel-runtime
    newName: ${RUNTIME_IMAGE%@*}
    digest: ${RUNTIME_IMAGE##*@}
  - name: nofeel-server
    newName: ${SERVER_IMAGE%@*}
    digest: ${SERVER_IMAGE##*@}
  - name: nofeel-frontend
    newName: ${FRONTEND_IMAGE%@*}
    digest: ${FRONTEND_IMAGE##*@}
EOF

cat > "${MIGRATE_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../../kustomize/base/migrate
patches:
  - path: config-patch.yaml
  - path: image-pull-secret-patch.yaml
images:
  - name: nofeel-server
    newName: ${SERVER_IMAGE%@*}
    digest: ${SERVER_IMAGE##*@}
EOF

cat > "${APP_DIR}/image-pull-secret-patch.yaml" <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nofeel
  namespace: nofeel
imagePullSecrets:
  - name: nofeel-ghcr
EOF
cp "${APP_DIR}/image-pull-secret-patch.yaml" "${MIGRATE_DIR}/image-pull-secret-patch.yaml"

kubectl kustomize "${ROOT}/kustomize/overlays/production/state" > "${OUTPUT_DIR}/state.yaml"
kubectl kustomize "${MIGRATE_DIR}" > "${OUTPUT_DIR}/migrate.yaml"
kubectl kustomize "${APP_DIR}" > "${OUTPUT_DIR}/app.yaml"

for manifest in state migrate app; do
  [[ -s "${OUTPUT_DIR}/${manifest}.yaml" ]] || {
    echo "rendered ${manifest} manifest is empty" >&2
    exit 1
  }
done

echo "rendered release manifests: ${OUTPUT_DIR}"
