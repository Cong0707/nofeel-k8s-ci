#!/usr/bin/env bash
set -Eeuo pipefail

: "${SOURCE_COMMIT:?SOURCE_COMMIT is required}"
: "${SERVER_IMAGE:?SERVER_IMAGE is required}"
: "${RUNTIME_IMAGE:?RUNTIME_IMAGE is required}"
: "${FRONTEND_IMAGE:?FRONTEND_IMAGE is required}"

[[ "${SOURCE_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || exit 1
for image in "${SERVER_IMAGE}" "${RUNTIME_IMAGE}" "${FRONTEND_IMAGE}"; do
  [[ "${image}" =~ ^ghcr\.io/cong0707/nofeel-(server|runtime|frontend)@sha256:[0-9a-f]{64}$ ]] || {
    echo "invalid immutable image reference: ${image}" >&2
    exit 1
  }
done

cat <<EOF
version=1
source_commit=${SOURCE_COMMIT}
server_image=${SERVER_IMAGE}
runtime_image=${RUNTIME_IMAGE}
frontend_image=${FRONTEND_IMAGE}
EOF
