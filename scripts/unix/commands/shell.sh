#!/usr/bin/env bash
# devkit shell <service>: opens the service's client inside its pod, already
# authenticated (psql, mysql, mongosh, redis-cli; a shell for RabbitMQ).

cmd_shell() {
  local svc="${1:-}" file
  case "$svc" in
    rabbitmq|mongodb|postgresql|mysql|redis) ;;
    *) die "Usage: devkit shell rabbitmq|mongodb|postgresql|mysql|redis" ;;
  esac
  file="${DEVKIT_ROOT}/k8s/${svc}/shell.sh"
  require_cluster_running
  component_ready "$svc" || die "${svc} is not ready. Check: ./devkit.sh status"
  [ -t 0 ] || die "devkit shell needs an interactive terminal."
  kube -n "$DEVKIT_NAMESPACE" exec -it "${svc}-0" -- sh -c "$(cat "$file")"
}
