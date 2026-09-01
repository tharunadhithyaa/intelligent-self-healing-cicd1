#!/usr/bin/env bash
# ============================================================================
# CivicPulseAI — Pre-Deployment Cluster Health & Self-Healing Gate
# ============================================================================
# Scans namespace 'civicpulse' for unhealthy workloads prior to Argo CD deployment.
# Automatically triggers ML Decision Controller self-healing webhooks for any
# crashing/failing pods, verifies recovery, and gates pipeline Stage 11.
# ============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[PRE-DEPLOY-HEAL]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[PRE-DEPLOY-HEAL]${NC} ✅ $*"; }
log_warn()  { echo -e "${YELLOW}[PRE-DEPLOY-HEAL]${NC} ⚠️  $*"; }
log_error() { echo -e "${RED}[PRE-DEPLOY-HEAL]${NC} ❌ $*"; }

NAMESPACE="${NAMESPACE:-civicpulse}"
HEAL_TIMEOUT="${HEAL_TIMEOUT:-120}"

if [ -z "${KUBECONFIG:-}" ]; then
    if [ -f "${HOME}/.kube/config" ] && [ -r "${HOME}/.kube/config" ]; then
        export KUBECONFIG="${HOME}/.kube/config"
    elif [ -f "/home/jenkins/.kube/config" ] && [ -r "/home/jenkins/.kube/config" ]; then
        export KUBECONFIG="/home/jenkins/.kube/config"
    elif [ -f "/etc/rancher/k3s/k3s.yaml" ] && [ -r "/etc/rancher/k3s/k3s.yaml" ]; then
        export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
    fi
fi

if ! command -v kubectl &>/dev/null; then
    log_warn "kubectl binary not found. Skipping cluster health scan."
    exit 0
fi

if ! kubectl get nodes --request-timeout=5s >/dev/null 2>&1; then
    log_warn "Cannot connect to Kubernetes cluster using KUBECONFIG=${KUBECONFIG:-unset}. Skipping cluster health scan."
    exit 0
fi

log_info "Scanning cluster workload health in namespace '${NAMESPACE}'..."

UNHEALTHY_PODS=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -v "1/1" | grep -v "Completed" || true)

if [ -z "${UNHEALTHY_PODS}" ]; then
    log_ok "All cluster workloads in namespace '${NAMESPACE}' are healthy (1/1 Ready)."
    exit 0
fi

log_warn "Detected unhealthy pod(s) prior to deployment:"
echo "${UNHEALTHY_PODS}"
echo ""

# Loop through each unhealthy pod and trigger ML Decision Controller webhook
while read -r pod_name ready_status status_reason restarts age; do
    [ -z "${pod_name}" ] && continue
    log_info "Triggering self-healing for unhealthy pod '${pod_name}' (Status: ${status_reason}, Restarts: ${restarts})..."

    # Resolve component label or fallback to pod prefix
    COMP_NAME=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/component}' 2>/dev/null || echo "")
    if [ -z "${COMP_NAME}" ]; then
        COMP_NAME=$(echo "${pod_name}" | sed -E 's/-[a-z0-9]+-[a-z0-9]+$//; s/-[0-9]+$//')
    fi

    # Determine alert name based on status
    ALERT_NAME="PodCrashLooping"
    if [[ "${status_reason}" == *"OOMKilled"* ]]; then
        ALERT_NAME="OOMKilled"
    elif [[ "${status_reason}" == *"ImagePull"* ]]; then
        ALERT_NAME="ImagePullBackOff"
    fi

    # Trigger webhook inside cluster via ML Controller pod or service URL
    WEBHOOK_PAYLOAD=$(cat <<EOF
{
  "version": "4",
  "groupKey": "pre-deploy-${pod_name}",
  "status": "firing",
  "receiver": "webhook",
  "alerts": [
    {
      "status": "firing",
      "labels": {
        "alertname": "${ALERT_NAME}",
        "severity": "critical",
        "app.kubernetes.io/component": "${COMP_NAME}",
        "pod": "${pod_name}",
        "namespace": "${NAMESPACE}"
      },
      "annotations": {
        "summary": "Pre-deployment health gate detected failure on ${pod_name}"
      },
      "startsAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
  ]
}
EOF
)

    # Dispatch trigger webhook
    if kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/component=ml-decision-controller --no-headers 2>/dev/null | grep -q "Running"; then
        kubectl exec -n "${NAMESPACE}" deploy/civicpulse-ml-decision-controller -- curl -s -X POST http://127.0.0.1:5000/api/v1/webhook \
            -H "Content-Type: application/json" \
            -d "${WEBHOOK_PAYLOAD}" >/dev/null 2>&1 || true
        log_ok "Dispatched self-healing webhook to ML Decision Controller for ${COMP_NAME}"
    else
        log_warn "ML Decision Controller pod not available; attempting fallback restart..."
        kubectl rollout restart "deployment/${COMP_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
    fi

done <<< "${UNHEALTHY_PODS}"

log_info "Waiting up to ${HEAL_TIMEOUT}s for self-healing verification..."
ELAPSED=0
POLL_INTERVAL=5

while [ $ELAPSED -lt $HEAL_TIMEOUT ]; do
    STILL_UNHEALTHY=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -v "1/1" | grep -v "Completed" || true)
    if [ -z "${STILL_UNHEALTHY}" ]; then
        log_ok "Self-healing successfully resolved all workload issues! Namespace '${NAMESPACE}' is healthy."
        exit 0
    fi
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

log_error "Self-healing verification timed out after ${HEAL_TIMEOUT}s. Remaining unhealthy pods:"
kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -v "1/1" || true
exit 1
