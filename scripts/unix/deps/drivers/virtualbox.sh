#!/usr/bin/env bash
# virtualbox driver dependency (Linux amd64 and Intel Macs).
# With DEVKIT_VIRTUALBOX_VERSION=latest, package manager updates are offered.

driver_virtualbox_label() { echo virtualbox; }

driver_virtualbox_check() {
  local version
  if ! host_virtualization_supported; then
    DEP_STATUS="$VIRTUALIZATION_HINT"
    DEP_UNFIXABLE=1
    return 1
  fi
  if ! has_cmd VBoxManage; then
    DEP_STATUS='not installed'
    return 1
  fi
  # A missing kernel module makes VBoxManage print a warning with its version.
  version="$(VBoxManage --version 2>&1 | tail -n 1)"
  case "$version" in
    [0-9]*) ;;
    *)
      DEP_STATUS='installed, but the VirtualBox kernel driver is not loaded'
      return 1
      ;;
  esac
  if ! ver_ge "$version" "$DEVKIT_VIRTUALBOX_MIN_VERSION"; then
    DEP_STATUS="${version} is older than the required ${DEVKIT_VIRTUALBOX_MIN_VERSION}; upgrade VirtualBox"
    DEP_UNFIXABLE=1
    return 1
  fi
  DEP_CURRENT="${version%%r*}"
  DEP_STATUS="ok (${DEP_CURRENT})"
  if [ "${DEVKIT_VIRTUALBOX_VERSION:-latest}" = latest ]; then
    if [ -z "${_VBOX_UPDATE+x}" ]; then
      if [ "$DEVKIT_OS" = macos ]; then _VBOX_UPDATE="$(pkg_available_update virtualbox --cask)"
      else _VBOX_UPDATE="$(pkg_available_update virtualbox)"
      fi
    fi
    if [ -n "$_VBOX_UPDATE" ]; then
      DEP_UPDATE="$_VBOX_UPDATE"
      DEP_STATUS="ok (${DEP_CURRENT}, update available: ${_VBOX_UPDATE})"
    fi
  fi
}

driver_virtualbox_update() {
  if [ "$DEVKIT_OS" = macos ]; then pkg_upgrade --cask virtualbox; else pkg_upgrade virtualbox; fi
  unset _VBOX_UPDATE
}

driver_virtualbox_install() {
  has_cmd VBoxManage && return 0
  if [ "$DEVKIT_OS" = macos ]; then
    pkg_install_cask virtualbox
    log_warn "macOS may block the VirtualBox system extension: allow it in System Settings > Privacy & Security, then retry."
    return
  fi
  pkg_detect
  case "$DEVKIT_PKG" in
    apt)    pkg_install virtualbox ;;
    pacman) pkg_install virtualbox virtualbox-host-modules-arch ;;
    zypper) pkg_install virtualbox ;;
    *) die "Install VirtualBox from https://www.virtualbox.org/wiki/Linux_Downloads (not packaged for ${DEVKIT_DISTRO_NAME})." ;;
  esac
}

driver_virtualbox_configure() {
  [ "$DEVKIT_OS" = linux ] || return 0
  case "$(VBoxManage --version 2>&1 | tail -n 1)" in
    [0-9]*) ;;
    *)
      log_info "Loading the VirtualBox kernel driver"
      as_root modprobe vboxdrv \
        || die "Could not load vboxdrv. With Secure Boot enabled, the module must be signed (see your distribution's VirtualBox docs)."
      ;;
  esac
  ensure_group_membership vboxusers
}
