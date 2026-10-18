#!/usr/bin/env bash
# minikube-devkit entrypoint for Linux and macOS.
# Windows users: run devkit.ps1 from PowerShell.
set -euo pipefail

DEVKIT_VERSION=0.1.0
DEVKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/unix/lib/common.sh
. "${DEVKIT_ROOT}/scripts/unix/lib/common.sh"
# shellcheck source=scripts/unix/lib/prompt.sh
. "${DEVKIT_ROOT}/scripts/unix/lib/prompt.sh"
# shellcheck source=scripts/unix/lib/pkg.sh
. "${DEVKIT_ROOT}/scripts/unix/lib/pkg.sh"
# shellcheck source=scripts/unix/lib/state.sh
. "${DEVKIT_ROOT}/scripts/unix/lib/state.sh"
# shellcheck source=scripts/unix/deps/deps.sh
. "${DEVKIT_ROOT}/scripts/unix/deps/deps.sh"
# shellcheck source=scripts/unix/deps/core.sh
. "${DEVKIT_ROOT}/scripts/unix/deps/core.sh"
# shellcheck source=scripts/unix/deps/drivers/drivers.sh
. "${DEVKIT_ROOT}/scripts/unix/deps/drivers/drivers.sh"
# shellcheck source=scripts/unix/cluster/cluster.sh
. "${DEVKIT_ROOT}/scripts/unix/cluster/cluster.sh"
# shellcheck source=scripts/unix/cluster/components.sh
. "${DEVKIT_ROOT}/scripts/unix/cluster/components.sh"
# shellcheck source=scripts/unix/cluster/forward.sh
. "${DEVKIT_ROOT}/scripts/unix/cluster/forward.sh"
# shellcheck source=scripts/unix/cluster/access.sh
. "${DEVKIT_ROOT}/scripts/unix/cluster/access.sh"
# shellcheck source=scripts/unix/commands/info.sh
. "${DEVKIT_ROOT}/scripts/unix/commands/info.sh"
# shellcheck source=scripts/unix/commands/forward.sh
. "${DEVKIT_ROOT}/scripts/unix/commands/forward.sh"
# shellcheck source=scripts/unix/commands/down.sh
. "${DEVKIT_ROOT}/scripts/unix/commands/down.sh"
# shellcheck source=scripts/unix/commands/doctor.sh
. "${DEVKIT_ROOT}/scripts/unix/commands/doctor.sh"
# shellcheck source=scripts/unix/commands/install-prereqs.sh
. "${DEVKIT_ROOT}/scripts/unix/commands/install-prereqs.sh"
# shellcheck source=scripts/unix/commands/configure.sh
. "${DEVKIT_ROOT}/scripts/unix/commands/configure.sh"
# shellcheck source=scripts/unix/commands/up.sh
. "${DEVKIT_ROOT}/scripts/unix/commands/up.sh"

usage() {
  cat <<EOF
minikube-devkit ${DEVKIT_VERSION}

Usage: ./devkit.sh <command> [options]

Commands:
  up                 Run the setup wizard, install prerequisites and start the environment
  configure          Run the setup wizard only (saves answers to config/devkit.env)
  info               Show URLs and credentials (--no-secrets hides passwords)
  forward ACTION     Manage port-forwards: start | stop | restart | status
  down               Stop port-forwards and the cluster (data is kept)
  destroy            Delete the cluster and all its data
  doctor             Check prerequisites, resources, ports and network (read-only)
  install-prereqs    Install and configure everything the selected driver needs
  version            Print the devkit version
  help               Show this help

Global options:
  -y, --yes          Non-interactive: accept the default answer for every prompt
  -v, --verbose      Print the commands being executed

Run './devkit.sh <command> --help' for command options (e.g. --driver, --cpus).

Environment variables named like the keys in config/devkit.env override them.
EOF
}

main() {
  local command='' arg
  # Global flags may appear anywhere; everything else goes to the command.
  set -- "$@" '--end-of-args--'
  while [ "$1" != '--end-of-args--' ]; do
    arg="$1"; shift
    case "$arg" in
      -y|--yes) DEVKIT_NONINTERACTIVE=true ;;
      -v|--verbose) DEVKIT_VERBOSE=1 ;;
      *)
        if [ -z "$command" ]; then command="$arg"; else set -- "$@" "$arg"; fi
        ;;
    esac
  done
  shift

  detect_os
  config_load
  core_init_path

  case "${command:-help}" in
    up)              cmd_up "$@" ;;
    configure)       cmd_configure "$@" ;;
    info)            cmd_info "$@" ;;
    forward)         cmd_forward "$@" ;;
    down)            cmd_down "$@" ;;
    destroy)         cmd_destroy "$@" ;;
    doctor)          cmd_doctor "$@" ;;
    install-prereqs) cmd_install_prereqs "$@" ;;
    version|--version) echo "minikube-devkit ${DEVKIT_VERSION}" ;;
    help|-h|--help)  usage ;;
    *) log_error "Unknown command: ${command}"; usage; exit 1 ;;
  esac
}

main "$@"
