"""
CivicPulseAI — ML Decision Engine Unit Test Suite
=================================================
Tests severity scoring computation, remediation action selection (RESTART, SCALE, ROLLBACK),
cooldown logic, and Alertmanager webhook processing.
"""

import pytest
import time
from app.models import AlertManagerPayload, AlertItem
from app.decision_engine import MLDecisionEngine
from app.kubernetes.actions import KubernetesActionHandler

@pytest.fixture
def mock_k8s_handler():
    # Return dry-run handler
    handler = KubernetesActionHandler()
    handler.k8s_client_loaded = False
    return handler

@pytest.fixture
def engine(mock_k8s_handler):
    return MLDecisionEngine(k8s_handler=mock_k8s_handler)

def test_alert_severity_scoring(engine):
    alert_crash = AlertItem(status="firing", labels={"alertname": "PodCrashLooping", "severity": "critical"})
    alert_cpu = AlertItem(status="firing", labels={"alertname": "HighCpuUsage", "severity": "warning"})

    assert engine.compute_alert_score(alert_crash) == 10.0
    assert engine.compute_alert_score(alert_cpu) == 6.0

def test_restart_remediation_decision(engine):
    payload = AlertManagerPayload(
        status="firing",
        alerts=[
            AlertItem(status="firing", labels={"alertname": "PodCrashLooping", "severity": "critical", "pod": "civicpulse-backend-123"})
        ]
    )

    decisions = engine.process_alerts(payload)
    assert len(decisions) == 1
    assert decisions[0].remediation_action == "RESTART"
    assert decisions[0].target_workload == "civicpulse-backend"

def test_scale_remediation_decision(engine):
    payload = AlertManagerPayload(
        status="firing",
        alerts=[
            AlertItem(status="firing", labels={"alertname": "HighCpuUsage", "severity": "warning", "pod": "civicpulse-backend-123"})
        ]
    )

    decisions = engine.process_alerts(payload)
    assert len(decisions) == 1
    assert decisions[0].remediation_action == "SCALE"
    assert decisions[0].target_workload == "civicpulse-backend"

def test_rollback_remediation_decision(engine):
    # Multiple critical alerts -> total score >= 20
    payload = AlertManagerPayload(
        status="firing",
        alerts=[
            AlertItem(status="firing", labels={"alertname": "PodCrashLooping", "severity": "critical"}),
            AlertItem(status="firing", labels={"alertname": "BackendHealthFailing", "severity": "critical"}),
            AlertItem(status="firing", labels={"alertname": "MongoDBDown", "severity": "critical"})
        ]
    )

    decisions = engine.process_alerts(payload)
    assert len(decisions) == 1
    assert decisions[0].remediation_action == "ROLLBACK"
    assert decisions[0].target_workload == "civicpulse"

def test_cooldown_enforcement(engine):
    payload = AlertManagerPayload(
        status="firing",
        alerts=[
            AlertItem(status="firing", labels={"alertname": "HighCpuUsage", "severity": "warning"})
        ]
    )

    # First call -> executes SCALE
    d1 = engine.process_alerts(payload)
    assert d1[0].remediation_action == "SCALE"
    assert d1[0].details.get("cooldown_active") is not True

    # Immediate second call -> caught by COOLDOWN
    d2 = engine.process_alerts(payload)
    assert d2[0].remediation_action == "SCALE"
    assert d2[0].details.get("cooldown_active") is True
    assert "COOLDOWN" in d2[0].reason
