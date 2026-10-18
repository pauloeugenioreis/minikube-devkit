#!/usr/bin/env bash
# minikube-devkit entrypoint for Linux and macOS.
# Windows users: run devkit.ps1 from PowerShell.
set -euo pipefail

DEVKIT_VERSION=0.1.0
DEVKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/lib/common.sh
. "${DEVKIT_ROOT}/scripts/lib/common.sh"
# shellcheck source=scripts/lib/prompt.sh
. "${DEVKIT_ROOT}/scripts/lib/prompt.sh"
# shellcheck source=scripts/lib/pkg.sh
. "${DEVKIT_ROOT}/scripts/lib/pkg.sh"
# shellcheck source=scripts/lib/state.sh
. "${DEVKIT_ROOT}/scripts/lib/state.sh"
# shellcheck source=scripts/deps/deps.sh
. "${DEVKIT_ROOT}/scripts/deps/deps.sh"
# shellcheck source=scripts/deps/core.sh
. "${DEVKIT_ROOT}/scripts/deps/core.sh"
# shellcheck source=scripts/deps/drivers/drivers.sh
. "${DEVKIT_ROOT}/scripts/deps/drivers/drivers.sh"
# shellcheck source=scripts/commands/doctor.sh
. "${DEVKIT_ROOT}/scripts/commands/doctor.sh"
# shellcheck source=scripts/commands/install-prereqs.sh
. "${DEVKIT_ROOT}/scripts/commands/install-prereqs.sh"

usage() {
  cat <<EOF
minikube-devkit ${DEVKIT_VERSION}

Usage: ./devkit.sh <command> [options]

Commands:
  doctor             Check prerequisites, resources, ports and network (read-only)
  install-prereqs    Install and configure everything the selected driver needs
  version            Print the devkit version
  help               Show this help

Global options:
  -y, --yes          Non-interactive: accept the default answer for every prompt
  -v, --verbose      Print the commands being executed
      --driver NAME  Minikube driver to use (default: ${DEVKIT_DRIVER:-docker})

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
    doctor)          cmd_doctor "$@" ;;
    install-prereqs) cmd_install_prereqs "$@" ;;
    version|--version) echo "minikube-devkit ${DEVKIT_VERSION}" ;;
    help|-h|--help)  usage ;;
    *) log_error "Unknown command: ${command}"; usage; exit 1 ;;
  esac
}

main "$@"
