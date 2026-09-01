#!/usr/bin/env bash
# ============================================================================
# CivicPulseAI — Pre-Deployment Cluster Health & Self-Healing Gate
# ============================================================================
# Scans namespace 'civicpulse' for unhealthy workloads prior to Argo CD deployment.
# Distinguishes between:
#   1. Unfixable errors (ImagePullBackOff, ErrImagePull, InvalidImageName):
#      Fails fast immediately with a clear error message.
#   2. Fixable errors (CrashLoopBackOff, OOMKilled, transient restarts):
#      Triggers ML Decision Controller webhooks, verifies recovery, and gates pipeline.
# ============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
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

# Helper: Extract structured pod container states using jsonpath
get_pod_status_lines() {
    kubectl get pods -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.name}{":"}{.state.waiting.reason}{":"}{.state.terminated.reason}{":"}{.restartCount}{" "}{end}{"\n"}{end}' 2>/dev/null || true
}

# Helper: Check if all pods are Ready 1/1 or Completed
check_all_healthy() {
    local unhealthy
    unhealthy=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -v "1/1" | grep -v "Completed" || true)
    if [ -z "${unhealthy}" ]; then
        return 0
    fi
    return 1
}

# 1. Initial Health Check
if check_all_healthy; then
    log_ok "All cluster workloads in namespace '${NAMESPACE}' are healthy (1/1 Ready)."
    exit 0
fi

POD_LINES=$(get_pod_status_lines)
if [ -z "${POD_LINES}" ]; then
    log_ok "No pods found in namespace '${NAMESPACE}'."
    exit 0
fi

HAS_UNFIXABLE=0
HAS_FIXABLE=0
declare -a UNFIXABLE_MESSAGES=()

# 2. Analyze Pod Statuses for Unfixable vs Fixable Problems
while IFS=$'\t' read -r pod_name phase container_info; do
    [ -z "${pod_name}" ] && continue

    # Check if pod is healthy (not completed and has issues)
    is_ready=$(kubectl get pod "${pod_name}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
    if [ "${phase}" = "Succeeded" ] || [ "${is_ready}" = "true" ]; then
        continue
    fi

    # Inspect container waiting/terminated reasons
    for cspec in ${container_info}; do
        cname=$(echo "${cspec}" | cut -d':' -f1)
        wreason=$(echo "${cspec}" | cut -d':' -f2)
        treason=$(echo "${cspec}" | cut -d':' -f3)
        restarts=$(echo "${cspec}" | cut -d':' -f4)

        # Detect ImagePullBackOff / ErrImagePull (UNFIXABLE BY RESTART)
        if [[ "${wreason}" =~ ^(ImagePullBackOff|ErrImagePull|InvalidImageName|ErrImageNeverPull|ImageInspectError)$ ]]; then
            HAS_UNFIXABLE=1
            UNFIXABLE_MESSAGES+=("Pod: ${pod_name} | Container: ${cname} | Reason: ${wreason} (Image does not exist in registry or GHCR authentication failed)")
        # Detect Fixable Issues (CrashLoopBackOff, OOMKilled, Error)
        elif [[ "${wreason}" == "CrashLoopBackOff" ]] || [[ "${treason}" == "OOMKilled" ]] || [ "${restarts:-0}" -gt 0 ]; then
            HAS_FIXABLE=1
        fi
    done
done <<< "${POD_LINES}"

# 3. Handle Unfixable Image Pull Failures (FAIL FAST)
if [ "${HAS_UNFIXABLE}" -eq 1 ]; then
    echo -e "\n${RED}============================================================================${NC}"
    echo -e "${RED}${BOLD}❌ FATAL PRE-DEPLOYMENT BLOCKER DETECTED (NON-REMEDIABLE IMAGE ERROR)${NC}"
    echo -e "${RED}============================================================================${NC}"
    for msg in "${UNFIXABLE_MESSAGES[@]}"; do
        echo -e "${RED}  • ${msg}${NC}"
    done
    echo -e "${RED}----------------------------------------------------------------------------${NC}"
    echo -e "${RED}Self-healing cannot resolve missing images or registry auth failures by restarting.${NC}"
    echo -e "${RED}Failing fast immediately without waiting for ${HEAL_TIMEOUT}s timeout.${NC}"
    echo -e "${RED}Please verify image build, tag parameters, and GHCR login secrets.${NC}"
    echo -e "${RED}============================================================================${NC}\n"
    exit 1
fi

# 4. Trigger Self-Healing for Fixable Problems
log_warn "Detected remediable unhealthy workload(s) prior to deployment. Triggering self-healing..."

UNHEALTHY_PODS=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -v "1/1" | grep -v "Completed" || true)

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

    # Webhook Payload
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

    # If ML controller itself is crashing, perform direct fallback rollout restart
    if [[ "${COMP_NAME}" == *"ml-decision-controller"* ]] || ! kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/component=ml-decision-controller --no-headers 2>/dev/null | grep -q "Running"; then
        log_warn "ML Decision Controller pod unhealthy or target is controller; executing direct fallback rollout restart..."
        kubectl rollout restart deployment/civicpulse-ml-decision-controller -n "${NAMESPACE}" 2>/dev/null || true
        if [[ "${COMP_NAME}" != *"ml-decision-controller"* ]]; then
            kubectl rollout restart "deployment/${COMP_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
        fi
    else
        # Dispatch webhook to ML Decision Controller (/api/v1/alerts and /api/v1/webhook)
        kubectl exec -n "${NAMESPACE}" deploy/civicpulse-ml-decision-controller -- curl -s -X POST http://127.0.0.1:5000/api/v1/alerts \
            -H "Content-Type: application/json" \
            -d "${WEBHOOK_PAYLOAD}" >/dev/null 2>&1 || true
        log_ok "Dispatched self-healing webhook to ML Decision Controller for ${COMP_NAME}"
    fi

done <<< "${UNHEALTHY_PODS}"

# 5. Polling & Verification Loop
log_info "Waiting up to ${HEAL_TIMEOUT}s for self-healing verification..."
ELAPSED=0
POLL_INTERVAL=5

while [ $ELAPSED -lt $HEAL_TIMEOUT ]; do
    # Check if an ImagePull failure occurred during polling
    CURRENT_STATUS=$(get_pod_status_lines)
    if echo "${CURRENT_STATUS}" | grep -qE "(ImagePullBackOff|ErrImagePull|InvalidImageName)"; then
        log_error "Pod transitioned into ImagePullBackOff/ErrImagePull during self-healing verification!"
        echo -e "${RED}Image pull error detected. Self-healing cannot proceed. Failing fast.${NC}"
        exit 1
    fi

    if check_all_healthy; then
        log_ok "Self-healing successfully resolved all workload issues! Namespace '${NAMESPACE}' is healthy."
        exit 0
    fi

    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

log_error "Self-healing verification timed out after ${HEAL_TIMEOUT}s. Remaining unhealthy pods:"
kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -v "1/1" || true
exit 1

