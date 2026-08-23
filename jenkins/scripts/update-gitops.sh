#!/usr/bin/env bash
# ============================================================================
# CivicPulseAI — Argo CD Zero-Commit Deployment Script
# ============================================================================
# Applies Argo CD Application parameter overrides (image.tag = BUILD_NUMBER)
# directly to the 'civicpulse' Argo CD Application in Kubernetes.
# Executed by Jenkinsfile Stage 11 (Deploy via Argo CD).
#
# ZERO GIT COMMITS ARE CREATED BY THIS SCRIPT.
# ============================================================================
set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[GITOPS]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[GITOPS]${NC} ✅ $*"; }
log_warn()  { echo -e "${YELLOW}[GITOPS]${NC} ⚠️  $*"; }
log_error() { echo -e "${RED}[GITOPS]${NC} ❌ $*"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
BUILD_NUMBER="${BUILD_NUMBER:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Parse Arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-number) BUILD_NUMBER="$2"; shift 2 ;;
        [0-9]*)         BUILD_NUMBER="$1"; shift 1 ;;
        *) shift ;;
    esac
done

if [ -z "${BUILD_NUMBER}" ]; then
    log_error "Missing required argument --build-number"
    exit 1
fi

log_info "Starting Argo CD deployment update for build '${BUILD_NUMBER}'"

# Ensure we are in the repository root
cd "${REPO_ROOT}"

EXPECTED_BACKEND="ghcr.io/tharunadhithyaa/civicpulse-backend:${BUILD_NUMBER}"
EXPECTED_FRONTEND="ghcr.io/tharunadhithyaa/civicpulse-frontend:${BUILD_NUMBER}"
EXPECTED_MONGODB="ghcr.io/tharunadhithyaa/civicpulse-mongodb:latest"
EXPECTED_NGINX="ghcr.io/tharunadhithyaa/civicpulse-nginx:latest"

log_info "Target Backend image : ${EXPECTED_BACKEND}"
log_info "Target Frontend image: ${EXPECTED_FRONTEND}"
log_info "Target MongoDB image : ${EXPECTED_MONGODB}"
log_info "Target Nginx image   : ${EXPECTED_NGINX}"

# ── 1. Validate Base Helm Chart ──────────────────────────────────────────────
HELM_DIR="${REPO_ROOT}/helm/civicpulse"
if [ -d "${HELM_DIR}" ] && command -v helm &>/dev/null; then
    log_info "Validating Helm chart structure"
    helm lint "${HELM_DIR}" >/dev/null 2>&1 || log_warn "Helm lint warning (non-blocking)"
fi

# ── 2. Update Argo CD Application Parameter Overrides (Zero Commit) ───────────
if [ -z "${KUBECONFIG:-}" ]; then
    if [ -f "${HOME}/.kube/config" ] && [ -r "${HOME}/.kube/config" ]; then
        export KUBECONFIG="${HOME}/.kube/config"
    elif [ -f "/home/jenkins/.kube/config" ] && [ -r "/home/jenkins/.kube/config" ]; then
        export KUBECONFIG="/home/jenkins/.kube/config"
    elif [ -f "/home/tharun_adhithyaa/.kube/config" ] && [ -r "/home/tharun_adhithyaa/.kube/config" ]; then
        export KUBECONFIG="/home/tharun_adhithyaa/.kube/config"
    elif [ -f "/etc/rancher/k3s/k3s.yaml" ] && [ -r "/etc/rancher/k3s/k3s.yaml" ]; then
        export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
    fi
fi

if ! command -v kubectl &>/dev/null; then
    log_error "kubectl binary not found on PATH."
    exit 1
fi

log_info "Using KUBECONFIG=${KUBECONFIG:-unset}"

if ! kubectl get nodes --request-timeout=10s >/dev/null 2>&1; then
    log_error "Cannot connect to Kubernetes cluster using KUBECONFIG=${KUBECONFIG:-unset}."
    exit 1
fi
log_ok "K3s cluster accessible"

if ! kubectl get application civicpulse -n argocd --request-timeout=10s >/dev/null 2>&1; then
    log_error "Argo CD Application 'civicpulse' not accessible in namespace 'argocd'."
    exit 1
fi
log_ok "Argo CD Application 'civicpulse' found in namespace 'argocd'"

# ── Ensure Namespace and Secrets Exist ────────────────────────────────────────
kubectl create namespace civicpulse --dry-run=client -o yaml | kubectl apply --request-timeout=10s -f - >/dev/null 2>&1 || true

GHCR_USER=$(echo "${GHCR_USERNAME:-${GHCR_USER:-${GHCR_OWNER:-tharunadhithyaa}}}" | tr -d ' \r\n\t')
GHCR_TOKEN_VAL=$(echo "${GHCR_TOKEN:-}" | tr -d ' \r\n\t')
if [ -n "${GHCR_TOKEN_VAL}" ]; then
    log_info "Ensuring secret 'ghcr-secret' exists in namespace 'civicpulse'..."
    kubectl create secret docker-registry ghcr-secret \
        --namespace civicpulse \
        --docker-server="${GHCR_REGISTRY:-ghcr.io}" \
        --docker-username="${GHCR_USER}" \
        --docker-password="${GHCR_TOKEN_VAL}" \
        --dry-run=client -o yaml | kubectl apply --request-timeout=10s -f - >/dev/null 2>&1
    log_ok "ghcr-secret ready in namespace 'civicpulse'"
fi

JWT_ACCESS_SECRET_VAL="${JWT_ACCESS_SECRET:-civicpulse-ci-access-secret}"
JWT_REFRESH_SECRET_VAL="${JWT_REFRESH_SECRET:-civicpulse-ci-refresh-secret}"
DEFAULT_PASSWORD_VAL="${DEFAULT_PASSWORD:-CivicPulse@2026}"
kubectl create secret generic civicpulse-secret \
    --namespace civicpulse \
    --from-literal=JWT_ACCESS_SECRET="${JWT_ACCESS_SECRET_VAL}" \
    --from-literal=JWT_REFRESH_SECRET="${JWT_REFRESH_SECRET_VAL}" \
    --from-literal=DEFAULT_PASSWORD="${DEFAULT_PASSWORD_VAL}" \
    --dry-run=client -o yaml | kubectl apply --request-timeout=10s -f - >/dev/null 2>&1
log_ok "civicpulse-secret ready in namespace 'civicpulse'"

# ── Retrieve and Log Pre-Patch Application Parameters ─────────────────────────
log_info "Inspecting existing Argo CD Application spec parameters..."
PREV_PARAMS=$(kubectl get application civicpulse -n argocd -o jsonpath='{.spec.source.helm.parameters}' --request-timeout=10s 2>/dev/null || echo "[]")
log_info "Current spec parameters before patch: ${PREV_PARAMS}"

# ── Patch Argo CD Application Parameters ──────────────────────────────────────
log_info "Applying Argo CD Application parameter overrides for build '${BUILD_NUMBER}' (backend & frontend)..."
if ! kubectl patch application civicpulse -n argocd --type merge --request-timeout=10s -p "{
  \"spec\": {
    \"source\": {
      \"helm\": {
        \"parameters\": [
          {\"name\": \"frontend.image.tag\", \"value\": \"${BUILD_NUMBER}\"},
          {\"name\": \"backend.image.tag\", \"value\": \"${BUILD_NUMBER}\"}
        ]
      }
    }
  }
}"; then
    log_error "Failed to patch Argo CD Application parameter overrides for build '${BUILD_NUMBER}'"
    exit 1
fi

log_ok "Argo CD Application parameter overrides patch submitted"

# ── Verify Live Application Spec Parameters Immediately After Patch ───────────
FRONTEND_SPEC_TAG=$(kubectl get application civicpulse -n argocd -o jsonpath='{.spec.source.helm.parameters[?(@.name=="frontend.image.tag")].value}' --request-timeout=10s 2>/dev/null || echo "")
BACKEND_SPEC_TAG=$(kubectl get application civicpulse -n argocd -o jsonpath='{.spec.source.helm.parameters[?(@.name=="backend.image.tag")].value}' --request-timeout=10s 2>/dev/null || echo "")

if [ "${FRONTEND_SPEC_TAG}" != "${BUILD_NUMBER}" ] || [ "${BACKEND_SPEC_TAG}" != "${BUILD_NUMBER}" ]; then
    log_error "VERIFICATION FAILED: Argo CD Application live spec does NOT contain target build '${BUILD_NUMBER}'!"
    log_error "Live spec values — frontend.image.tag: '${FRONTEND_SPEC_TAG}', backend.image.tag: '${BACKEND_SPEC_TAG}'"
    exit 1
fi
log_ok "Verified Argo CD Application live spec parameters: frontend=${FRONTEND_SPEC_TAG}, backend=${BACKEND_SPEC_TAG}"

# ── 3. Argo CD Application Refresh & Synchronization Wait ─────────────────────
log_info "Triggering Argo CD application refresh via Kubernetes API..."
kubectl annotate application civicpulse -n argocd argocd.argoproj.io/refresh=normal --overwrite --request-timeout=10s >/dev/null 2>&1 || true

log_info "Waiting for Argo CD to synchronize application 'civicpulse' and reach Healthy state..."
MAX_WAIT_SECONDS=120
ELAPSED=0
SYNCED=false

while [ $ELAPSED -lt $MAX_WAIT_SECONDS ]; do
    SYNC_STATUS=$(kubectl get application civicpulse -n argocd -o jsonpath='{.status.sync.status}' --request-timeout=10s 2>/dev/null || echo "Unknown")
    HEALTH_STATUS=$(kubectl get application civicpulse -n argocd -o jsonpath='{.status.health.status}' --request-timeout=10s 2>/dev/null || echo "Unknown")

    log_info "Argo CD Status — Sync: '${SYNC_STATUS}' | Health: '${HEALTH_STATUS}' (${ELAPSED}s/${MAX_WAIT_SECONDS}s)"

    if [ "${SYNC_STATUS}" = "Synced" ] && [ "${HEALTH_STATUS}" = "Healthy" ]; then
        SYNCED=true
        break
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

# ── 4. Rendered Manifest Verification & Diagnostic Output ─────────────────────
if [ "${SYNCED}" = "true" ]; then
    log_ok "Argo CD application 'civicpulse' successfully synchronized and is Healthy"

    log_info "Verifying actual rendered Kubernetes Deployment pod templates in namespace 'civicpulse'..."
    BACKEND_LIVE_IMG=$(kubectl get deployment civicpulse-backend -n civicpulse -o jsonpath='{.spec.template.spec.containers[0].image}' --request-timeout=10s 2>/dev/null || echo "unknown")
    FRONTEND_LIVE_IMG=$(kubectl get deployment civicpulse-frontend -n civicpulse -o jsonpath='{.spec.template.spec.containers[0].image}' --request-timeout=10s 2>/dev/null || echo "unknown")

    log_info "Live Backend Deployment Image : ${BACKEND_LIVE_IMG}"
    log_info "Live Frontend Deployment Image: ${FRONTEND_LIVE_IMG}"

    if [[ "${BACKEND_LIVE_IMG}" != *":${BUILD_NUMBER}"* ]]; then
        log_error "VERIFICATION FAILED: Live backend deployment image '${BACKEND_LIVE_IMG}' does not use target build '${BUILD_NUMBER}'"
        exit 1
    fi
    if [[ "${FRONTEND_LIVE_IMG}" != *":${BUILD_NUMBER}"* ]]; then
        log_error "VERIFICATION FAILED: Live frontend deployment image '${FRONTEND_LIVE_IMG}' does not use target build '${BUILD_NUMBER}'"
        exit 1
    fi

    log_ok "Verified live Deployments in Kubernetes match target build '${BUILD_NUMBER}'!"
    log_ok "Argo CD deployment update completed successfully for build '${BUILD_NUMBER}'"
    exit 0
else
    log_error "Argo CD application 'civicpulse' failed to reach Synced/Healthy status within ${MAX_WAIT_SECONDS}s."
    log_error "Final Sync Status: '${SYNC_STATUS:-Unknown}' | Health Status: '${HEALTH_STATUS:-Unknown}'"
    echo ""
    log_info "=== Kubernetes Resource Overview (civicpulse namespace) ==="
    kubectl get pods -n civicpulse -o wide --request-timeout=10s 2>/dev/null || true
    kubectl get deployments -n civicpulse --request-timeout=10s 2>/dev/null || true
    kubectl get statefulsets -n civicpulse --request-timeout=10s 2>/dev/null || true
    kubectl get replicasets -n civicpulse --request-timeout=10s 2>/dev/null || true

    log_info "=== Pod Container Images ==="
    kubectl get pods -n civicpulse -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\t"}{.status.phase}{"\n"}{end}' --request-timeout=10s 2>/dev/null || true

    log_info "=== Diagnostic Details for Non-Running / Non-Ready Pods ==="
    for pod in $(kubectl get pods -n civicpulse --no-headers --request-timeout=10s 2>/dev/null | grep -v "1/1" | awk '{print $1}'); do
        log_info "--- Describe Pod ${pod} ---"
        kubectl describe pod "$pod" -n civicpulse --request-timeout=10s 2>/dev/null || true
        log_info "--- Logs for Pod ${pod} ---"
        kubectl logs "$pod" -n civicpulse --all-containers --tail=50 --request-timeout=10s 2>/dev/null || true
    done

    log_info "=== Recent Kubernetes Events ==="
    kubectl get events -n civicpulse --sort-by='.lastTimestamp' --request-timeout=10s 2>/dev/null | tail -n 25 || true

    log_info "=== Argo CD Application Spec & Status Summary ==="
    kubectl get application civicpulse -n argocd -o yaml --request-timeout=10s 2>/dev/null || true
    exit 1
fi
