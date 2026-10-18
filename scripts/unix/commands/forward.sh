#!/usr/bin/env bash
# devkit forward: manages the background port-forwards.

cmd_forward() {
  case "${1:-status}" in
    start)
      require_cluster_running
      forward_start_all
      forward_status
      ;;
    stop)
      forward_stop_all
      log_ok "Port-forwards stopped"
      ;;
    restart)
      forward_stop_all
      cmd_forward start
      ;;
    status) forward_status ;;
    -h|--help) echo "Usage: devkit forward [start|stop|restart|status]" ;;
    *) die "Unknown forward action: $1 (use start, stop, restart or status)" ;;
  esac
}
