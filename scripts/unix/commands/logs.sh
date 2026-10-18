#!/usr/bin/env bash
# devkit logs <component> [-f]: shows recent logs of a component.

_LOGS_COMPONENTS='rabbitmq mongodb postgresql mysql redis keda dashboard rabbitmq-worker redis-worker'

# Prints "namespace resource" for a component.
_logs_target() {
  case "$1" in
    rabbitmq|mongodb|postgresql|mysql|redis) echo "${DEVKIT_NAMESPACE} statefulset/$1" ;;
    keda)      echo "keda deployment/keda-operator" ;;
    dashboard) echo "kubernetes-dashboard deployment/kubernetes-dashboard" ;;
    rabbitmq-worker|redis-worker) echo "${DEVKIT_EXAMPLES_NAMESPACE} deployment/$1" ;;
    *) return 1 ;;
  esac
}

cmd_logs() {
  local component="${1:-}" follow='' target
  case "${2:-}" in -f|--follow) follow=-f ;; esac
  target="$(_logs_target "$component")" \
    || die "Usage: devkit logs <component> [-f]  (components: ${_LOGS_COMPONENTS})"
  require_cluster_running
  # shellcheck disable=SC2086
  set -- $target
  if [ "$(kube -n "$1" get "$2" -o jsonpath='{.status.replicas}' 2>/dev/null)" = 0 ]; then
    log_info "${component} is scaled to zero right now, so there are no logs (KEDA starts it when there is work)."
    return 0
  fi
  # shellcheck disable=SC2086
  kube -n "$1" logs "$2" --tail=200 --all-containers $follow
}
