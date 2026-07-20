#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT="${NOFEEL_ROOT:?NOFEEL_ROOT is required}"
readonly OUTPUT_ROOT="${OUTPUT_ROOT:-${ROOT}/ci/generated}"
readonly IMAGE_RUNTIME="${IMAGE_RUNTIME:?IMAGE_RUNTIME is required}"
readonly IMAGE_SERVER="${IMAGE_SERVER:?IMAGE_SERVER is required}"
readonly IMAGE_FRONTEND="${IMAGE_FRONTEND:?IMAGE_FRONTEND is required}"

validate_image() {
  local value="$1"
  [[ "${value}" =~ ^ghcr\.io/[a-z0-9._-]+/nofeel-(runtime|server|frontend)@sha256:[0-9a-f]{64}$ ]] || {
    echo "invalid immutable GHCR image reference: ${value}" >&2
    exit 1
  }
}

validate_image "${IMAGE_RUNTIME}"
validate_image "${IMAGE_SERVER}"
validate_image "${IMAGE_FRONTEND}"

readonly APP_DIR="${OUTPUT_ROOT}/production/app"
readonly MIGRATE_DIR="${OUTPUT_ROOT}/production/migrate"
mkdir -p "${APP_DIR}" "${MIGRATE_DIR}"

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
    newName: ${IMAGE_RUNTIME%@*}
    digest: ${IMAGE_RUNTIME##*@}
  - name: nofeel-server
    newName: ${IMAGE_SERVER%@*}
    digest: ${IMAGE_SERVER##*@}
  - name: nofeel-frontend
    newName: ${IMAGE_FRONTEND%@*}
    digest: ${IMAGE_FRONTEND##*@}
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
    newName: ${IMAGE_SERVER%@*}
    digest: ${IMAGE_SERVER##*@}
EOF

cp "${ROOT}/kustomize/overlays/production/app/config-patch.yaml" "${APP_DIR}/config-patch.yaml"
cp "${ROOT}/kustomize/overlays/production/migrate/config-patch.yaml" "${MIGRATE_DIR}/config-patch.yaml"

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

echo "generated production overlays under ${OUTPUT_ROOT}"
