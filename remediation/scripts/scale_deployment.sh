#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] $*"
}

if [[ $# -ne 3 ]]; then
  log "Usage: $0 <namespace> <deployment-name> <replica-count>"
  exit 1
fi

NAMESPACE="$1"
DEPLOYMENT_NAME="$2"
REPLICA_COUNT="$3"

log "Scaling deployment ${DEPLOYMENT_NAME} in namespace ${NAMESPACE} to ${REPLICA_COUNT} replicas"
kubectl scale "deployment/${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --replicas="${REPLICA_COUNT}"
kubectl rollout status "deployment/${DEPLOYMENT_NAME}" -n "${NAMESPACE}" --timeout=120s
log "Scale operation completed successfully for ${DEPLOYMENT_NAME} in namespace ${NAMESPACE}"
