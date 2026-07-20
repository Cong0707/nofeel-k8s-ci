#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT="${NOFEEL_ROOT:?NOFEEL_ROOT is required}"
readonly SERVER_ROOT="${ROOT}/.tools/components/nofeel-server"
readonly BROWSER_ROOT="${ROOT}/.tools/components/nofeel-browser"
readonly FRONTEND_ROOT="${ROOT}/.tools/components/nofeel-frontend"
readonly REGISTRY="${REGISTRY:?REGISTRY is required}"
readonly IMAGE_NAMESPACE="${IMAGE_NAMESPACE:?IMAGE_NAMESPACE is required}"
readonly OUTPUT_FILE="${OUTPUT_FILE:-${GITHUB_OUTPUT:-}}"

server_commit="$(git -C "${SERVER_ROOT}" rev-parse HEAD)"
browser_commit="$(git -C "${BROWSER_ROOT}" rev-parse HEAD)"
frontend_commit="$(git -C "${FRONTEND_ROOT}" rev-parse HEAD)"
source_commit="$(git -C "${ROOT}" rev-parse HEAD)"
source_short="${source_commit:0:12}"
image_tag="run-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${source_short}"
build_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

for path in "${SERVER_ROOT}" "${BROWSER_ROOT}" "${FRONTEND_ROOT}"; do
  [[ -z "$(git -C "${path}" status --porcelain)" ]] || {
    echo "component repository is dirty: ${path}" >&2
    exit 1
  }
done

docker build --platform linux/amd64 --pull \
  --build-arg VERSION="${image_tag}" \
  --build-arg COMMIT="${server_commit}" \
  --build-arg BUILD_TIME="${build_time}" \
  -t "nofeel/server:${image_tag}" "${SERVER_ROOT}"

docker build --platform linux/amd64 --pull \
  -t "nofeel/browser-assets:${image_tag}" "${BROWSER_ROOT}"

docker build --platform linux/amd64 --pull=false \
  -f "${ROOT}/Dockerfile.runtime" \
  --build-arg SERVER_IMAGE="nofeel/server:${image_tag}" \
  --build-arg BROWSER_ASSETS_IMAGE="nofeel/browser-assets:${image_tag}" \
  -t "nofeel/runtime:${image_tag}" "${ROOT}"

docker build --platform linux/amd64 --pull \
  -t "nofeel/frontend:${image_tag}" "${FRONTEND_ROOT}"

registry_ref() {
  local name="$1"
  printf '%s/%s/nofeel-%s:%s' "${REGISTRY}" "${IMAGE_NAMESPACE,,}" "${name}" "${image_tag}"
}

push_image() {
  local name="$1"
  local local_ref="nofeel/${name}:${image_tag}"
  local remote_ref
  local digest_ref
  remote_ref="$(registry_ref "${name}")"
  docker tag "${local_ref}" "${remote_ref}"
  docker push "${remote_ref}" >&2
  digest_ref="$(docker image inspect --format='{{index .RepoDigests 0}}' "${remote_ref}")"
  [[ "${digest_ref}" =~ ^${REGISTRY//./\.}/.+@sha256:[0-9a-f]{64}$ ]] || {
    echo "could not resolve immutable digest for ${remote_ref}" >&2
    exit 1
  }
  printf '%s\n' "${digest_ref}"
}

server_image="$(push_image server)"
runtime_image="$(push_image runtime)"
frontend_image="$(push_image frontend)"

write_output() {
  local key="$1"
  local value="$2"
  if [[ -n "${OUTPUT_FILE}" ]]; then
    printf '%s=%s\n' "${key}" "${value}" >> "${OUTPUT_FILE}"
  fi
}

write_output tag "${image_tag}"
write_output source_commit "${source_commit}"
write_output source_short "${source_short}"
write_output server_commit "${server_commit}"
write_output browser_commit "${browser_commit}"
write_output frontend_commit "${frontend_commit}"
write_output server "${server_image}"
write_output runtime "${runtime_image}"
write_output frontend "${frontend_image}"

printf 'image_tag=%s\nsource_commit=%s\nserver=%s\nruntime=%s\nfrontend=%s\n' \
  "${image_tag}" "${source_commit}" "${server_image}" "${runtime_image}" "${frontend_image}"
