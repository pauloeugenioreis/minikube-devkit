#!/usr/bin/env bash
# devkit info: prints URLs and credentials of the installed components.

cmd_info() {
  local hide=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-secrets) hide=--no-secrets ;;
      -h|--help) echo "Usage: devkit info [--no-secrets]"; return 0 ;;
      *) die "Unknown option for info: $1" ;;
    esac
    shift
  done
  cluster_exists && cluster_running || die "Cluster '${DEVKIT_PROFILE}' is not running. Start it with: ./devkit.sh up"
  printf '\n'
  access_table $hide
}
