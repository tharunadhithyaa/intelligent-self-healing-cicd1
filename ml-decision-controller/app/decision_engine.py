import logging
import time
import uuid
from datetime import datetime, timezone
from typing import List, Dict, Tuple, Optional, Any

from app.models import AlertManagerPayload, AlertItem, DecisionLog
from app.kubernetes.actions import KubernetesActionHandler

logger = logging.getLogger("ml_decision_controller.engine")

# Severity Scoring Map
ALERT_SEVERITY_SCORES = {
    "PodCrashLooping": 10.0,
    "BackendHealthFailing": 10.0,
    "MongoDBDown": 12.0,
    "HighCpuUsage": 6.0,
    "HighMemoryUsage": 6.0,
    "DiskPressureWarning": 4.0,
}

# Base Severity Level Scores
LEVEL_SCORES = {
    "critical": 10.0,
    "warning": 5.0,
    "info": 2.0,
}

# 5-minute cooldown (300 seconds) per workload
COOLDOWN_PERIOD_SECONDS = 300

class MLDecisionEngine:
    def __init__(self, k8s_handler: Optional[KubernetesActionHandler] = None):
        self.k8s_handler = k8s_handler or KubernetesActionHandler()
        self.decision_history: List[DecisionLog] = []
        # Store timestamp of last action per target key: e.g. "civicpulse-backend:RESTART" -> float(timestamp)
        self.last_action_times: Dict[str, float] = {}

    def compute_alert_score(self, alert: AlertItem) -> float:
        alert_name = alert.labels.get("alertname", "UnknownAlert")
        severity_label = alert.labels.get("severity", "warning").lower()

        base_score = LEVEL_SCORES.get(severity_label, 5.0)
        specific_score = ALERT_SEVERITY_SCORES.get(alert_name, base_score)

        return max(base_score, specific_score)

    def _is_in_cooldown(self, target_key: str) -> Tuple[bool, float]:
        last_time = self.last_action_times.get(target_key, 0.0)
        elapsed = time.time() - last_time
        if elapsed < COOLDOWN_PERIOD_SECONDS:
            remaining = COOLDOWN_PERIOD_SECONDS - elapsed
            return True, remaining
        return False, 0.0

    def _record_action_time(self, target_key: str):
        self.last_action_times[target_key] = time.time()

    def process_alerts(self, payload: AlertManagerPayload) -> List[DecisionLog]:
        firing_alerts = [a for a in payload.alerts if a.status.lower() == "firing"]
        if not firing_alerts:
            logger.info("No active firing alerts in payload. Skipping remediation.")
            return []

        alert_names = [a.labels.get("alertname", "UnknownAlert") for a in firing_alerts]
        total_score = sum(self.compute_alert_score(a) for a in firing_alerts)
        critical_count = sum(1 for a in firing_alerts if a.labels.get("severity", "").lower() == "critical")

        logger.info(
            f"Processing {len(firing_alerts)} firing alert(s): {alert_names} | "
            f"Total Severity Score: {total_score} | Critical Alerts Count: {critical_count}"
        )

        decisions: List[DecisionLog] = []

        # Determine target workload & action
        # 1. ROLLBACK Condition: Score >= 20.0 OR > 1 Critical Alerts
        if total_score >= 20.0 or critical_count > 1 or "RollbackRequired" in alert_names:
            target_key = "civicpulse:ROLLBACK"
            in_cooldown, remaining = self._is_in_cooldown(target_key)

            if in_cooldown:
                reason = f"Cumulative score {total_score} requires Rollback, but action is in COOLDOWN ({remaining:.1f}s remaining)."
                log_entry = self._create_decision_log(
                    alert_names=alert_names,
                    namespace="civicpulse",
                    target_workload="civicpulse",
                    target_kind="Application",
                    remediation_action="ROLLBACK",
                    severity_score=total_score,
                    reason=reason,
                    execution_success=False,
                    details={"cooldown_active": True, "remaining_seconds": remaining}
                )
                decisions.append(log_entry)
            else:
                logger.info(f"Triggering ROLLBACK remediation (Score: {total_score}, Critical Count: {critical_count})...")
                res = self.k8s_handler.rollback_application(app_name="civicpulse", target_namespace="argocd")
                self._record_action_time(target_key)
                log_entry = self._create_decision_log(
                    alert_names=alert_names,
                    namespace="civicpulse",
                    target_workload="civicpulse",
                    target_kind="Application",
                    remediation_action="ROLLBACK",
                    severity_score=total_score,
                    reason=f"High cumulative severity score ({total_score}) triggered automated Argo CD Rollback",
                    execution_success=res.get("success", False),
                    details=res
                )
                decisions.append(log_entry)

        # 2. RESTART Condition: PodCrashLooping, BackendHealthFailing, MongoDBDown
        elif any(name in ["PodCrashLooping", "BackendHealthFailing", "MongoDBDown"] for name in alert_names):
            if "MongoDBDown" in alert_names:
                target_workload = "civicpulse-mongodb"
                target_kind = "StatefulSet"
            else:
                target_workload = "civicpulse-backend"
                target_kind = "Deployment"

            target_key = f"{target_workload}:RESTART"
            in_cooldown, remaining = self._is_in_cooldown(target_key)

            if in_cooldown:
                reason = f"Alert(s) {alert_names} require Restart of {target_kind}/{target_workload}, but action is in COOLDOWN ({remaining:.1f}s remaining)."
                log_entry = self._create_decision_log(
                    alert_names=alert_names,
                    namespace="civicpulse",
                    target_workload=target_workload,
                    target_kind=target_kind,
                    remediation_action="RESTART",
                    severity_score=total_score,
                    reason=reason,
                    execution_success=False,
                    details={"cooldown_active": True, "remaining_seconds": remaining}
                )
                decisions.append(log_entry)
            else:
                logger.info(f"Triggering RESTART remediation for {target_kind}/{target_workload}...")
                res = self.k8s_handler.restart_workload(target_workload, namespace="civicpulse", kind=target_kind)
                self._record_action_time(target_key)
                log_entry = self._create_decision_log(
                    alert_names=alert_names,
                    namespace="civicpulse",
                    target_workload=target_workload,
                    target_kind=target_kind,
                    remediation_action="RESTART",
                    severity_score=total_score,
                    reason=f"Alert(s) {alert_names} triggered automated rollout restart for {target_kind}/{target_workload}",
                    execution_success=res.get("success", False),
                    details=res
                )
                decisions.append(log_entry)

        # 3. SCALE Condition: HighCpuUsage or HighMemoryUsage
        elif any(name in ["HighCpuUsage", "HighMemoryUsage"] for name in alert_names):
            target_workload = "civicpulse-backend"
            target_kind = "Deployment"
            target_key = f"{target_workload}:SCALE"

            in_cooldown, remaining = self._is_in_cooldown(target_key)

            if in_cooldown:
                reason = f"Alert(s) {alert_names} require Scale of {target_kind}/{target_workload}, but action is in COOLDOWN ({remaining:.1f}s remaining)."
                log_entry = self._create_decision_log(
                    alert_names=alert_names,
                    namespace="civicpulse",
                    target_workload=target_workload,
                    target_kind=target_kind,
                    remediation_action="SCALE",
                    severity_score=total_score,
                    reason=reason,
                    execution_success=False,
                    details={"cooldown_active": True, "remaining_seconds": remaining}
                )
                decisions.append(log_entry)
            else:
                logger.info(f"Triggering SCALE remediation for {target_kind}/{target_workload}...")
                res = self.k8s_handler.scale_deployment(target_workload, namespace="civicpulse", scale_by=1, max_replicas=3)
                self._record_action_time(target_key)
                log_entry = self._create_decision_log(
                    alert_names=alert_names,
                    namespace="civicpulse",
                    target_workload=target_workload,
                    target_kind=target_kind,
                    remediation_action="SCALE",
                    severity_score=total_score,
                    reason=f"Alert(s) {alert_names} triggered automated scale up (+1 replica) for {target_kind}/{target_workload}",
                    execution_success=res.get("success", False),
                    details=res
                )
                decisions.append(log_entry)

        else:
            reason = f"Alert(s) {alert_names} (Score: {total_score}) evaluated; no automated remediation policy matched."
            log_entry = self._create_decision_log(
                alert_names=alert_names,
                namespace="civicpulse",
                target_workload="none",
                target_kind="none",
                remediation_action="NONE",
                severity_score=total_score,
                reason=reason,
                execution_success=True,
                details={}
            )
            decisions.append(log_entry)

        # Store in decision history
        for d in decisions:
            self.decision_history.append(d)
            if len(self.decision_history) > 50:
                self.decision_history.pop(0)

        return decisions

    def _create_decision_log(
        self,
        alert_names: List[str],
        namespace: str,
        target_workload: str,
        target_kind: str,
        remediation_action: str,
        severity_score: float,
        reason: str,
        execution_success: bool,
        details: Dict[str, Any]
    ) -> DecisionLog:
        return DecisionLog(
            id=str(uuid.uuid4())[:8],
            timestamp=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            alert_names=alert_names,
            namespace=namespace,
            target_workload=target_workload,
            target_kind=target_kind,
            remediation_action=remediation_action,
            severity_score=severity_score,
            reason=reason,
            execution_success=execution_success,
            details=details
        )

    def get_recent_decisions(self, limit: int = 20) -> List[DecisionLog]:
        return self.decision_history[-limit:]
