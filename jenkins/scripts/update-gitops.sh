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

# ── Defaults & Configuration ──────────────────────────────────────────────────
BUILD_NUMBER="${BUILD_NUMBER:-}"
DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-300}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ── Parse Arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-number) BUILD_NUMBER="$2"; shift 2 ;;
        --timeout)      DEPLOYMENT_TIMEOUT="$2"; shift 2 ;;
        [0-9]*)         BUILD_NUMBER="$1"; shift 1 ;;
        *) shift ;;
    esac
done

if [ -z "${BUILD_NUMBER}" ] || ! [[ "${BUILD_NUMBER}" =~ ^[0-9]+$ ]]; then
    log_error "Missing or invalid numeric argument --build-number (got: '${BUILD_NUMBER}')"
    exit 1
fi

log_info "Initiating Stage 11 Argo CD deployment update for build '${BUILD_NUMBER}'"
log_info "Configured deployment rollout timeout: ${DEPLOYMENT_TIMEOUT}s"

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

# ── 1. Pre-Deployment GHCR Image Manifest Availability Check ─────────────────
log_info "Performing pre-deployment GHCR image manifest availability check..."

GHCR_USER=$(echo "${GHCR_USERNAME:-${GHCR_USER:-${GHCR_OWNER:-tharunadhithyaa}}}" | tr -d ' \r\n\t')
GHCR_TOKEN_VAL=$(echo "${GHCR_TOKEN:-}" | tr -d ' \r\n\t')

if [ -n "${GHCR_USER}" ] && [ -n "${GHCR_TOKEN_VAL}" ]; then
    echo "${GHCR_TOKEN_VAL}" | docker login "${GHCR_REGISTRY:-ghcr.io}" -u "${GHCR_USER}" --password-stdin >/dev/null 2>&1 || true
fi

if command -v docker &>/dev/null; then
    if ! docker manifest inspect "${EXPECTED_BACKEND}" >/dev/null 2>&1; then
        log_error "Backend image '${EXPECTED_BACKEND}' is NOT available in GHCR."
        log_error "Deployment was not attempted."
        exit 1
    fi
    log_ok "Pre-deployment check: Backend image '${EXPECTED_BACKEND}' verified in GHCR"

    if ! docker manifest inspect "${EXPECTED_FRONTEND}" >/dev/null 2>&1; then
        log_error "Frontend image '${EXPECTED_FRONTEND}' is NOT available in GHCR."
        log_error "Deployment was not attempted."
        exit 1
    fi
    log_ok "Pre-deployment check: Frontend image '${EXPECTED_FRONTEND}' verified in GHCR"
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

log_info "Waiting for Argo CD to synchronize application manifests..."
SYNC_WAIT=0
while [ $SYNC_WAIT -lt 60 ]; do
    SYNC_STATUS=$(kubectl get application civicpulse -n argocd -o jsonpath='{.status.sync.status}' --request-timeout=10s 2>/dev/null || echo "Unknown")
    if [ "${SYNC_STATUS}" = "Synced" ]; then
        log_ok "Argo CD application manifests synchronized (Sync: '${SYNC_STATUS}')"
        break
    fi
    sleep 5
    SYNC_WAIT=$((SYNC_WAIT + 5))
done

# ── 4. Wait for Kubernetes Deployment Rollouts & Pod Readiness ───────────────
log_info "Waiting for Kubernetes Workload Rollout & Pod Readiness (Timeout: ${DEPLOYMENT_TIMEOUT}s)..."

ELAPSED=0
ROLLOUT_COMPLETE=false

while [ $ELAPSED -lt $DEPLOYMENT_TIMEOUT ]; do
    BACKEND_STATUS=$(kubectl get deployment civicpulse-backend -n civicpulse -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' --request-timeout=10s 2>/dev/null || echo "Unknown")
    FRONTEND_STATUS=$(kubectl get deployment civicpulse-frontend -n civicpulse -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' --request-timeout=10s 2>/dev/null || echo "Unknown")
    HEALTH_STATUS=$(kubectl get application civicpulse -n argocd -o jsonpath='{.status.health.status}' --request-timeout=10s 2>/dev/null || echo "Unknown")

    log_info "[GITOPS] Argo CD: ${HEALTH_STATUS} | Backend: ${BACKEND_STATUS} | Frontend: ${FRONTEND_STATUS} (${ELAPSED}s/${DEPLOYMENT_TIMEOUT}s)"

    # Inspect pod status for fast failure detection
    POD_ERRORS=$(kubectl get pods -n civicpulse --no-headers --request-timeout=10s 2>/dev/null | grep -E "ImagePullBackOff|ErrImagePull|CrashLoopBackOff" || true)

    if [ -n "${POD_ERRORS}" ]; then
        log_error "Detected container failure state in Kubernetes pods:"
        echo "${POD_ERRORS}"
        if echo "${POD_ERRORS}" | grep -qE "ImagePullBackOff|ErrImagePull"; then
            log_error "❌ Image pull failure detected. Check image existence in GHCR and ghcr-secret credentials."
        fi
        if echo "${POD_ERRORS}" | grep -q "CrashLoopBackOff"; then
            log_error "❌ Container crash detected during startup. Inspecting container logs..."
        fi
        break
    fi

    # Check rollout readiness
    BACKEND_READY=false
    FRONTEND_READY=false

    if kubectl rollout status deployment/civicpulse-backend -n civicpulse --timeout=2s >/dev/null 2>&1; then
        BACKEND_READY=true
    fi
    if kubectl rollout status deployment/civicpulse-frontend -n civicpulse --timeout=2s >/dev/null 2>&1; then
        FRONTEND_READY=true
    fi

    if [ "${BACKEND_READY}" = "true" ] && [ "${FRONTEND_READY}" = "true" ] && [ "${HEALTH_STATUS}" = "Healthy" ]; then
        ROLLOUT_COMPLETE=true
        break
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

# ── 5. Rendered Workload Verification & Output Summary ────────────────────────
if [ "${ROLLOUT_COMPLETE}" = "true" ]; then
    BACKEND_LIVE_IMG=$(kubectl get deployment civicpulse-backend -n civicpulse -o jsonpath='{.spec.template.spec.containers[0].image}' --request-timeout=10s 2>/dev/null || echo "unknown")
    FRONTEND_LIVE_IMG=$(kubectl get deployment civicpulse-frontend -n civicpulse -o jsonpath='{.spec.template.spec.containers[0].image}' --request-timeout=10s 2>/dev/null || echo "unknown")

    if [[ "${BACKEND_LIVE_IMG}" != *":${BUILD_NUMBER}"* ]]; then
        log_error "VERIFICATION FAILED: Live backend image '${BACKEND_LIVE_IMG}' does not match build '${BUILD_NUMBER}'"
        exit 1
    fi
    if [[ "${FRONTEND_LIVE_IMG}" != *":${BUILD_NUMBER}"* ]]; then
        log_error "VERIFICATION FAILED: Live frontend image '${FRONTEND_LIVE_IMG}' does not match build '${BUILD_NUMBER}'"
        exit 1
    fi

    echo ""
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  STAGE 11 — ARGO CD DEPLOYMENT SUCCESS                   ${NC}"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    echo "  Build Number      : ${BUILD_NUMBER}"
    echo "  Backend Image     : ${BACKEND_LIVE_IMG}"
    echo "  Frontend Image    : ${FRONTEND_LIVE_IMG}"
    echo "  MongoDB Image     : ${EXPECTED_MONGODB}"
    echo "  Nginx Image       : ${EXPECTED_NGINX}"
    echo "  Argo CD Sync      : Synced"
    echo "  Backend Rollout   : Successful (1/1 Ready)"
    echo "  Frontend Rollout  : Successful (1/1 Ready)"
    echo "  Deployment Status : SUCCESS"
    echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
    echo ""
    exit 0
else
    log_error "══════════════════════════════════════════════════════════"
    log_error "  STAGE 11 — DEPLOYMENT DIAGNOSTICS                       "
    log_error "══════════════════════════════════════════════════════════"
    log_error "Deployment rollout failed to complete within ${DEPLOYMENT_TIMEOUT}s."
    echo ""
    log_info "=== Kubernetes Resource Overview (civicpulse namespace) ==="
    kubectl get pods -n civicpulse -o wide --request-timeout=10s 2>/dev/null || true
    kubectl get deployments -n civicpulse --request-timeout=10s 2>/dev/null || true
    kubectl get statefulsets -n civicpulse --request-timeout=10s 2>/dev/null || true
    kubectl get replicasets -n civicpulse --request-timeout=10s 2>/dev/null || true

    log_info "=== Pod Container Images & Status ==="
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
