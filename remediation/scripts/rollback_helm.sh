#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}

if [[ $# -ne 2 ]]; then
  log "Usage: $0 <release-name> <namespace>"
  exit 1
fi

RELEASE_NAME="$1"
NAMESPACE="$2"

log "Inspecting current Helm history for release ${RELEASE_NAME} in namespace ${NAMESPACE}"
CURRENT_REVISION="$(helm history "${RELEASE_NAME}" -n "${NAMESPACE}" --max 1 -o json | jq -r '.[0].revision')"

if [[ -z "${CURRENT_REVISION}" || "${CURRENT_REVISION}" == "null" ]]; then
  log "Unable to determine current Helm revision for ${RELEASE_NAME}"
  exit 1
fi

if (( CURRENT_REVISION <= 1 )); then
  log "Release ${RELEASE_NAME} is already at the first revision; rollback is not possible"
  exit 1
fi

PREVIOUS_REVISION="$((CURRENT_REVISION - 1))"
log "Rolling back release ${RELEASE_NAME} from revision ${CURRENT_REVISION} to ${PREVIOUS_REVISION}"
helm rollback "${RELEASE_NAME}" "${PREVIOUS_REVISION}" -n "${NAMESPACE}" --wait --timeout 120s

log "Waiting for pods owned by release ${RELEASE_NAME} to become ready"
kubectl wait pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE_NAME}" --for=condition=Ready --timeout=120s
log "Helm rollback completed successfully for ${RELEASE_NAME}"
