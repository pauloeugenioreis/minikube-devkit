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
    doctor)          cmd_doctor "$@" ;;
    install-prereqs) cmd_install_prereqs "$@" ;;
    version|--version) echo "minikube-devkit ${DEVKIT_VERSION}" ;;
    help|-h|--help)  usage ;;
    *) log_error "Unknown command: ${command}"; usage; exit 1 ;;
  esac
}

main "$@"
