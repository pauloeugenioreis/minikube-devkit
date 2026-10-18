#!/usr/bin/env bash
# devkit examples: manages the KEDA examples.

cmd_examples() {
  local action="${1:-}" target count
  require_cluster_running
  case "$action" in
    deploy)
      if [ "${2:-}" = --rebuild ]; then examples_deploy --force; else examples_deploy; fi
      ;;
    remove) examples_remove ;;
    produce)
      target="${2:-}"; count="${3:-50}"
      case "$target" in rabbitmq|redis) ;; *) die "Usage: devkit examples produce rabbitmq|redis [COUNT]" ;; esac
      is_int "$count" || die "COUNT must be a whole number"
      examples_produce "$target" "$count"
      log_info "Watch it scale: kubectl --context ${DEVKIT_PROFILE} -n ${DEVKIT_EXAMPLES_NAMESPACE} get deploy -w"
      ;;
    *)
      cat <<USAGE
Usage: devkit examples <action>
  deploy [--rebuild]          Build the worker image and apply the ScaledObjects
  remove                      Delete the examples namespace
  produce rabbitmq|redis [N]  Send N messages (default 50) and let KEDA scale the worker
USAGE
      ;;
  esac
}
