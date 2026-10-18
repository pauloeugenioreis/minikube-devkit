#!/usr/bin/env bash
# devkit status: cluster, workloads, KEDA ScaledObjects and port-forwards.

cmd_status() {
  local ns
  [ $# -eq 0 ] || { echo "Usage: devkit status"; return 0; }
  log_step "Cluster '${DEVKIT_PROFILE}'"
  if ! cluster_exists; then
    log_info "Not created. Run: ./devkit.sh up"
    return 0
  fi
  minikube status -p "$DEVKIT_PROFILE" 2>/dev/null | sed 's/^/    /' || true
  cluster_running || return 0

  for ns in "$DEVKIT_NAMESPACE" keda "$DEVKIT_EXAMPLES_NAMESPACE" kubernetes-dashboard; do
    kube get namespace "$ns" >/dev/null 2>&1 || continue
    log_step "Namespace ${ns}"
    kube -n "$ns" get pods 2>/dev/null | sed 's/^/    /'
  done
  if kube get namespace "$DEVKIT_EXAMPLES_NAMESPACE" >/dev/null 2>&1; then
    log_step "KEDA ScaledObjects"
    kube -n "$DEVKIT_EXAMPLES_NAMESPACE" get scaledobjects 2>/dev/null | sed 's/^/    /'
  fi
  if kube get pvc -n "$DEVKIT_NAMESPACE" >/dev/null 2>&1; then
    log_step "Volumes"
    kube -n "$DEVKIT_NAMESPACE" get pvc 2>/dev/null | sed 's/^/    /'
  fi
  log_step "Port-forwards"
  forward_status
}
