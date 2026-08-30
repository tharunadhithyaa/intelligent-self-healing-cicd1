"""
CivicPulseAI — Kubernetes Remediation Action Handler
===================================================
Executes active Kubernetes remediation routines including deployment rollout restarts,
replica scaling, and Argo CD Application zero-commit rollback patches.
"""

import logging
import os
import time
from datetime import datetime, timezone
from typing import Dict, Any, Optional

try:
    from kubernetes import client, config
    from kubernetes.client.rest import ApiException
    HAS_K8S_LIB = True
except ImportError:
    HAS_K8S_LIB = False

logger = logging.getLogger("ml_decision_controller.k8s")

class KubernetesActionHandler:
    def __init__(self):
        self.k8s_client_loaded = False
        self._init_k8s_client()

    def _init_k8s_client(self):
        if not HAS_K8S_LIB:
            logger.warning("Kubernetes Python library not installed. Operating in dry-run mode.")
            return

        try:
            config.load_incluster_config()
            self.k8s_client_loaded = True
            logger.info("Successfully loaded in-cluster Kubernetes config.")
        except Exception as e_incluster:
            try:
                config.load_kube_config()
                self.k8s_client_loaded = True
                logger.info("Successfully loaded local kubeconfig.")
            except Exception as e_kubeconfig:
                logger.warning(
                    f"Could not load in-cluster config ({e_incluster}) or kubeconfig ({e_kubeconfig}). "
                    "Operating in fallback mode."
                )

    def restart_workload(self, name: str, namespace: str = "civicpulse", kind: str = "Deployment") -> Dict[str, Any]:
        """
        Executes a rollout restart on a Deployment or StatefulSet by updating
        spec.template.metadata.annotations['kubectl.kubernetes.io/restartedAt'].
        """
        logger.info(f"Executing restart action on {kind}/{name} in namespace '{namespace}'...")

        if not self.k8s_client_loaded:
            logger.info(f"[DRY-RUN] Would execute restart on {kind}/{name} in {namespace}")
            return {
                "success": True,
                "mode": "dry-run",
                "action": "RESTART",
                "target": f"{kind}/{name}",
                "message": f"[DRY-RUN] Restart triggered for {kind}/{name}"
            }

        apps_api = client.AppsV1Api()
        now_iso = datetime.now(timezone.utc).isoformat()

        try:
            if kind.lower() == "statefulset":
                sts = apps_api.read_namespaced_stateful_set(name, namespace)
                if sts.spec.template.metadata.annotations is None:
                    sts.spec.template.metadata.annotations = {}
                sts.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = now_iso
                apps_api.patch_namespaced_stateful_set(name, namespace, sts)
                message = f"StatefulSet/{name} successfully restarted (restartedAt={now_iso})"
            else:
                dep = apps_api.read_namespaced_deployment(name, namespace)
                if dep.spec.template.metadata.annotations is None:
                    dep.spec.template.metadata.annotations = {}
                dep.spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"] = now_iso
                apps_api.patch_namespaced_deployment(name, namespace, dep)
                message = f"Deployment/{name} successfully restarted (restartedAt={now_iso})"

            logger.info(message)
            return {
                "success": True,
                "mode": "live",
                "action": "RESTART",
                "target": f"{kind}/{name}",
                "message": message
            }
        except ApiException as e:
            error_msg = f"Kubernetes API error restarting {kind}/{name}: status={e.status}, body={e.body}"
            logger.error(error_msg)
            return {
                "success": False,
                "mode": "live",
                "action": "RESTART",
                "target": f"{kind}/{name}",
                "error": error_msg
            }
        except Exception as e:
            error_msg = f"Unexpected error restarting {kind}/{name}: {str(e)}"
            logger.error(error_msg)
            return {
                "success": False,
                "mode": "live",
                "action": "RESTART",
                "target": f"{kind}/{name}",
                "error": error_msg
            }

    def scale_deployment(self, name: str, namespace: str = "civicpulse", scale_by: int = 1, max_replicas: int = 3) -> Dict[str, Any]:
        """
        Scales up a Deployment's replica count by scale_by up to max_replicas limit.
        """
        logger.info(f"Executing scale action on Deployment/{name} in namespace '{namespace}' (scale_by={scale_by}, max={max_replicas})...")

        if not self.k8s_client_loaded:
            logger.info(f"[DRY-RUN] Would scale Deployment/{name} up by {scale_by} (max {max_replicas})")
            return {
                "success": True,
                "mode": "dry-run",
                "action": "SCALE",
                "target": f"Deployment/{name}",
                "message": f"[DRY-RUN] Scale triggered for Deployment/{name}"
            }

        apps_api = client.AppsV1Api()
        try:
            dep = apps_api.read_namespaced_deployment(name, namespace)
            current_replicas = dep.spec.replicas or 1

            if current_replicas >= max_replicas:
                msg = f"Deployment/{name} already at max replica limit ({current_replicas}/{max_replicas}). No scale change applied."
                logger.info(msg)
                return {
                    "success": True,
                    "mode": "live",
                    "action": "SCALE",
                    "target": f"Deployment/{name}",
                    "message": msg,
                    "current_replicas": current_replicas,
                    "new_replicas": current_replicas
                }

            new_replicas = min(current_replicas + scale_by, max_replicas)
            dep.spec.replicas = new_replicas
            apps_api.patch_namespaced_deployment(name, namespace, dep)

            msg = f"Scaled Deployment/{name} from {current_replicas} to {new_replicas} replicas (max={max_replicas})"
            logger.info(msg)
            return {
                "success": True,
                "mode": "live",
                "action": "SCALE",
                "target": f"Deployment/{name}",
                "message": msg,
                "previous_replicas": current_replicas,
                "new_replicas": new_replicas
            }
        except ApiException as e:
            error_msg = f"Kubernetes API error scaling Deployment/{name}: status={e.status}, body={e.body}"
            logger.error(error_msg)
            return {
                "success": False,
                "mode": "live",
                "action": "SCALE",
                "target": f"Deployment/{name}",
                "error": error_msg
            }
        except Exception as e:
            error_msg = f"Unexpected error scaling Deployment/{name}: {str(e)}"
            logger.error(error_msg)
            return {
                "success": False,
                "mode": "live",
                "action": "SCALE",
                "target": f"Deployment/{name}",
                "error": error_msg
            }

    def rollback_application(self, app_name: str = "civicpulse", target_namespace: str = "argocd", target_build: Optional[int] = None) -> Dict[str, Any]:
        """
        Executes a zero-commit rollback by patching the Argo CD Application parameters
        or performing rollout restart/undo if needed.
        """
        logger.info(f"Executing rollback action for Argo CD Application '{app_name}' in namespace '{target_namespace}'...")

        if not self.k8s_client_loaded:
            logger.info(f"[DRY-RUN] Would trigger rollback on Application/{app_name} (target_build={target_build})")
            return {
                "success": True,
                "mode": "dry-run",
                "action": "ROLLBACK",
                "target": f"Application/{app_name}",
                "message": f"[DRY-RUN] Rollback triggered for Application/{app_name}"
            }

        custom_api = client.CustomObjectsApi()
        apps_api = client.AppsV1Api()

        try:
            # 1. Try to read live Argo CD Application custom resource
            app_obj = custom_api.get_namespaced_custom_object(
                group="argoproj.io",
                version="v1alpha1",
                namespace=target_namespace,
                plural="applications",
                name=app_name
            )

            current_params = app_obj.get("spec", {}).get("source", {}).get("helm", {}).get("parameters", [])
            current_backend_tag = None

            for p in current_params:
                if p.get("name") == "backend.image.tag":
                    current_backend_tag = p.get("value")

            # Determine rollback tag
            if target_build is not None:
                rollback_tag = str(target_build)
            elif current_backend_tag and current_backend_tag.isdigit():
                val = int(current_backend_tag)
                rollback_tag = str(max(1, val - 1))
            else:
                rollback_tag = "latest"

            logger.info(f"Targeting rollback to build tag '{rollback_tag}' for Application/{app_name} (current tag: '{current_backend_tag}')")

            # Patch Argo CD Application custom resource with previous tag
            patch_body = {
                "spec": {
                    "source": {
                        "helm": {
                            "parameters": [
                                {"name": "frontend.image.tag", "value": rollback_tag},
                                {"name": "backend.image.tag", "value": rollback_tag}
                            ]
                        }
                    }
                }
            }

            custom_api.patch_namespaced_custom_object(
                group="argoproj.io",
                version="v1alpha1",
                namespace=target_namespace,
                plural="applications",
                name=app_name,
                body=patch_body
            )

            # Trigger Argo CD refresh annotation
            try:
                anno_patch = {
                    "metadata": {
                        "annotations": {
                            "argocd.argoproj.io/refresh": "normal"
                        }
                    }
                }
                custom_api.patch_namespaced_custom_object(
                    group="argoproj.io",
                    version="v1alpha1",
                    namespace=target_namespace,
                    plural="applications",
                    name=app_name,
                    body=anno_patch
                )
            except Exception as e_anno:
                logger.warning(f"Could not annotate Argo CD Application for refresh: {e_anno}")

            msg = f"Argo CD Application '{app_name}' successfully patched to image tag '{rollback_tag}'"
            logger.info(msg)
            return {
                "success": True,
                "mode": "live",
                "action": "ROLLBACK",
                "target": f"Application/{app_name}",
                "rollback_tag": rollback_tag,
                "message": msg
            }

        except ApiException as e:
            logger.warning(f"Argo CD Application CRD access failed ({e.status}: {e.reason}). Falling back to deployment rollout restart...")
            # Fallback to restarting backend and frontend deployments
            res_b = self.restart_workload("civicpulse-backend", namespace="civicpulse")
            res_f = self.restart_workload("civicpulse-frontend", namespace="civicpulse")
            return {
                "success": res_b.get("success", False) and res_f.get("success", False),
                "mode": "live-fallback",
                "action": "ROLLBACK",
                "target": "Deployments/civicpulse-backend,civicpulse-frontend",
                "message": "Fallback restart executed for backend and frontend workloads"
            }
        except Exception as e:
            error_msg = f"Unexpected error during rollback for Application/{app_name}: {str(e)}"
            logger.error(error_msg)
            return {
                "success": False,
                "mode": "live",
                "action": "ROLLBACK",
                "target": f"Application/{app_name}",
                "error": error_msg
            }
