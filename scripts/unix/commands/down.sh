#!/usr/bin/env bash
# devkit down: stops the port-forwards and the cluster (data is kept).
# devkit destroy: deletes the cluster and all its data.

cmd_down() {
  [ $# -eq 0 ] || { echo "Usage: devkit down"; return 0; }
  log_step "Stopping minikube-devkit"
  forward_stop_all
  cluster_stop
  log_ok "Stopped. Your data is kept; run './devkit.sh up' to start again."
}

cmd_destroy() {
  [ $# -eq 0 ] || { echo "Usage: devkit destroy [--yes]"; return 0; }
  log_step "Destroying minikube-devkit"
  ask_yes_no "Delete the '${DEVKIT_PROFILE}' cluster and ALL its data?" N || die "Aborted by user."
  forward_stop_all
  cluster_delete
  log_ok "Cluster deleted. config/devkit.env was kept."
}
