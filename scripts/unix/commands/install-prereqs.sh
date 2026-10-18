#!/usr/bin/env bash
# devkit install-prereqs: installs and configures everything the selected
# driver needs (core CLIs + driver runtime).

cmd_install_prereqs() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --driver) [ $# -ge 2 ] || die "--driver needs a value"; DEVKIT_DRIVER="$2"; shift ;;
      -h|--help) echo "Usage: devkit install-prereqs [--driver NAME] [--yes]"; return 0 ;;
      *) die "Unknown option for install-prereqs: $1" ;;
    esac
    shift
  done

  [ "$(id -u)" -ne 0 ] || die "Do not run devkit as root; it uses sudo only for the steps that need it."
  driver_load "$DEVKIT_DRIVER"
  state_resume

  # shellcheck disable=SC2086
  dep_ensure $CORE_DEPS "driver_${DEVKIT_DRIVER}"
  printf '\n'
  log_ok "All prerequisites for the '${DEVKIT_DRIVER}' driver are ready."
}
