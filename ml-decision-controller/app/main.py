import logging
import os
from typing import List, Dict, Any, Optional
from fastapi import FastAPI, Response, status, Request
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

from app.models import AlertManagerPayload, DecisionResponse, DecisionLog
from app.decision_engine import MLDecisionEngine

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s"
)
logger = logging.getLogger("ml_decision_controller.main")

app = FastAPI(
    title="CivicPulseAI ML Decision Controller",
    description="Intelligent Self-Healing Decision Controller microservice receiving Alertmanager JSON webhooks and executing automated Kubernetes remediations.",
    version="1.0.0"
)

# Prometheus Metrics
ALERT_WEBHOOK_REQUESTS = Counter(
    "civicpulse_ml_alert_webhooks_total",
    "Total Alertmanager webhook calls received"
)
DECISION_ACTIONS_TOTAL = Counter(
    "civicpulse_ml_remediation_actions_total",
    "Total remediation actions executed by type",
    ["action", "target_workload", "status"]
)
DECISION_LATENCY_HISTOGRAM = Histogram(
    "civicpulse_ml_decision_processing_seconds",
    "Time spent processing Alertmanager webhook payload"
)

engine = MLDecisionEngine()

@app.get("/health", status_code=status.HTTP_200_OK)
def health_check():
    """
    Service health check endpoint used by Kubernetes readiness/liveness probes and Jenkins Stage 12.7.
    """
    return {
        "status": "healthy",
        "service": "civicpulse-ml-decision-controller",
        "k8s_connected": engine.k8s_handler.k8s_client_loaded
    }

@app.get("/metrics")
def get_metrics():
    """
    Exposes Prometheus format metrics for scrape target inspection.
    """
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.post("/api/v1/alerts", response_model=DecisionResponse, status_code=status.HTTP_200_OK)
@DECISION_LATENCY_HISTOGRAM.time()
async def receive_alerts(payload: AlertManagerPayload, request: Request):
    """
    Alertmanager Webhook Receiver Endpoint.
    Parses alert payload, evaluates severity and decision rules, triggers K8s remediation, and records logs.
    """
    ALERT_WEBHOOK_REQUESTS.inc()
    logger.info(f"Received Alertmanager webhook payload (Status: {payload.status}, Alerts count: {len(payload.alerts)})")

    decisions = engine.process_alerts(payload)

    for d in decisions:
        DECISION_ACTIONS_TOTAL.labels(
            action=d.remediation_action,
            target_workload=d.target_workload,
            status="success" if d.execution_success else "failed"
        ).inc()

    firing_count = sum(1 for a in payload.alerts if a.status.lower() == "firing")

    return DecisionResponse(
        status="processed",
        total_alerts=len(payload.alerts),
        firing_alerts=firing_count,
        decisions_taken=decisions
    )

@app.get("/api/v1/decisions", response_model=List[DecisionLog])
def list_recent_decisions(limit: int = 20):
    """
    Returns recent remediation decision audit logs.
    """
    return engine.get_recent_decisions(limit=limit)

@app.post("/api/v1/reset-cooldown")
async def reset_cooldown(request: Request, target_key: Optional[str] = None):
    """
    Resets active action cooldown timers for test verification suites.
    """
    key_to_reset = target_key
    if not key_to_reset:
        try:
            body = await request.json()
            if isinstance(body, dict):
                key_to_reset = body.get("target_key")
        except Exception:
            pass

    if key_to_reset:
        engine.last_action_times.pop(key_to_reset, None)
        return {"status": "cooldown_reset", "message": f"Cooldown timer for '{key_to_reset}' cleared."}
    engine.last_action_times.clear()
    return {"status": "cooldown_reset", "message": "All action cooldown timers cleared."}

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("PORT", 5000))
    uvicorn.run("app.main:app", host="0.0.0.0", port=port, reload=True)
