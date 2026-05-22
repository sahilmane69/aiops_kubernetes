#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}

if [[ $# -ne 2 ]]; then
  log "Usage: $0 <namespace> <deployment-name>"
  exit 1
fi

NAMESPACE="$1"
DEPLOYMENT_NAME="$2"

log "Restarting deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE}"
kubectl rollout restart "deployment/${DEPLOYMENT_NAME}" -n "${NAMESPACE}"
kubectl rollout status "deployment/${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout=120s
log "Rollout restart completed successfully for ${DEPLOYMENT_NAME} in namespace ${NAMESPACE}"
