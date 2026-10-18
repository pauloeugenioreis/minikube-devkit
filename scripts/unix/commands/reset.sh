#!/usr/bin/env bash
# devkit reset <service>: deletes a data service and its volume, then
# deploys it again from scratch (fresh database with the current config).

cmd_reset() {
  local svc="${1:-}" key forward
  case "$svc" in
    rabbitmq|mongodb|postgresql|mysql|redis) ;;
    *) die "Usage: devkit reset rabbitmq|mongodb|postgresql|mysql|redis" ;;
  esac
  key="$(_component_key "$svc")"
  is_true "${!key}" || die "${svc} is not enabled in config/devkit.env (${key})."
  require_cluster_running

  ask_yes_no "Delete ${svc} and ALL its data, then recreate it?" N || die "Aborted by user."
  for forward in "$svc" "${svc}-mgmt" "${svc}-amqp"; do _forward_stop_one "$forward"; done
  kube -n "$DEVKIT_NAMESPACE" delete statefulset "$svc" --ignore-not-found --wait=true >/dev/null
  kube -n "$DEVKIT_NAMESPACE" delete pvc "data-${svc}-0" --ignore-not-found --wait=true >/dev/null
  log_ok "Deleted ${svc} and its volume"

  _component_apply "$svc"
  log_info "Waiting for ${svc} to become ready..."
  kube rollout status "statefulset/${svc}" -n "$DEVKIT_NAMESPACE" --timeout="${DEVKIT_DEPLOY_TIMEOUT}s" >/dev/null \
    || die "${svc} did not become ready. Check: ./devkit.sh logs ${svc}"
  log_ok "${svc} is ready with a fresh volume"
  forward_start_all
}
