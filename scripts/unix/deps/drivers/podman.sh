#!/usr/bin/env bash
# podman driver dependency (Linux and macOS). The minikube podman driver is
# experimental and runs rootful podman:
#   Linux: minikube calls "sudo -n podman", so devkit installs a sudoers rule
#          that allows only the podman binary without a password (asks first).
#   macOS: a rootful "podman machine" sized to hold the minikube node.
# With DEVKIT_PODMAN_VERSION=latest, package manager updates are offered.

_PODMAN_SUDOERS=/etc/sudoers.d/minikube-devkit-podman

driver_podman_label() { echo podman; }

_podman_version() { podman version --format '{{.Client.Version}}' 2>/dev/null; }

_podman_machine() { podman machine inspect --format "$1" 2>/dev/null | head -n 1; }

driver_podman_check() {
  local version
  if ! has_cmd podman; then
    DEP_STATUS='not installed'
    return 1
  fi
  version="$(_podman_version)"
  if [ -n "$version" ] && ! ver_ge "$version" "$DEVKIT_PODMAN_MIN_VERSION"; then
    DEP_STATUS="${version} is older than the required ${DEVKIT_PODMAN_MIN_VERSION}; upgrade Podman"
    DEP_UNFIXABLE=1
    return 1
  fi

  if [ "$DEVKIT_OS" = linux ]; then
    if ! sudo -n podman version >/dev/null 2>&1; then
      DEP_STATUS='installed, but minikube needs passwordless "sudo podman"'
      return 1
    fi
  else
    if [ -z "$(_podman_machine '{{.Name}}')" ]; then
      DEP_STATUS='installed, but no podman machine exists'
      return 1
    fi
    if [ "$(_podman_machine '{{.Rootful}}')" != true ]; then
      DEP_STATUS='the podman machine is not rootful'
      return 1
    fi
    if [ "$(_podman_machine '{{.Resources.Memory}}')" -lt "$(helper_vm_memory_mb)" ] 2>/dev/null \
      || [ "$(_podman_machine '{{.Resources.CPUs}}')" -lt "$DEVKIT_CPUS" ] 2>/dev/null; then
      DEP_STATUS='the podman machine is smaller than the requested minikube node'
      return 1
    fi
    if [ "$(_podman_machine '{{.State}}')" != running ]; then
      DEP_STATUS='installed, but the podman machine is not running'
      return 1
    fi
  fi
  DEP_CURRENT="${version:-unknown}"
  DEP_STATUS="ok (${version:-unknown})"
  if [ "${DEVKIT_PODMAN_VERSION:-latest}" = latest ]; then
    [ -n "${_PODMAN_UPDATE+x}" ] || _PODMAN_UPDATE="$(pkg_available_update podman)"
    if [ -n "$_PODMAN_UPDATE" ]; then
      DEP_UPDATE="$_PODMAN_UPDATE"
      DEP_STATUS="ok (${version:-unknown}, update available: ${_PODMAN_UPDATE})"
    fi
  fi
}

driver_podman_update() {
  pkg_upgrade podman
  unset _PODMAN_UPDATE
}

driver_podman_install() {
  has_cmd podman && return 0
  if [ "$DEVKIT_OS" = macos ]; then
    brew_ensure
    pkg_install podman
  else
    pkg_install podman
  fi
}

driver_podman_configure() {
  if [ "$DEVKIT_OS" = linux ]; then
    _podman_configure_linux
  else
    _podman_configure_macos
  fi
}

_podman_configure_linux() {
  local podman_bin user tmp
  sudo -n podman version >/dev/null 2>&1 && return 0
  podman_bin="$(command -v podman)"
  user="$(id -un)"
  log_info "minikube runs 'sudo -n podman'. devkit can add this rule to ${_PODMAN_SUDOERS}:"
  log_info "  ${user} ALL=(root) NOPASSWD: ${podman_bin}"
  ask_yes_no "Allow passwordless sudo for podman only?" Y \
    || die "The podman driver needs passwordless sudo for podman. Choose another driver or add the rule manually."
  tmp="$(mktemp)"
  printf '# Added by minikube-devkit for the minikube podman driver.\n%s ALL=(root) NOPASSWD: %s\n' "$user" "$podman_bin" > "$tmp"
  as_root visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "The generated sudoers rule is invalid."; }
  as_root install -m 0440 "$tmp" "$_PODMAN_SUDOERS"
  rm -f "$tmp"
}

_podman_configure_macos() {
  local memory disk
  memory="$(helper_vm_memory_mb)"
  disk="$(helper_vm_disk_gb)"

  if [ -z "$(_podman_machine '{{.Name}}')" ]; then
    log_info "Creating a rootful podman machine (${DEVKIT_CPUS} CPUs, ${memory} MB RAM, ${disk} GB disk)"
    run podman machine init --cpus "$DEVKIT_CPUS" --memory "$memory" --disk-size "$disk" --rootful
  else
    if [ "$(_podman_machine '{{.Rootful}}')" != true ] \
      || [ "$(_podman_machine '{{.Resources.Memory}}')" -lt "$memory" ] 2>/dev/null \
      || [ "$(_podman_machine '{{.Resources.CPUs}}')" -lt "$DEVKIT_CPUS" ] 2>/dev/null; then
      ask_yes_no "Reconfigure the podman machine to rootful, ${DEVKIT_CPUS} CPUs and ${memory} MB RAM? It will restart" Y \
        || die "The podman machine must be rootful and large enough for the minikube node."
      [ "$(_podman_machine '{{.State}}')" = running ] && run podman machine stop
      run podman machine set --rootful --cpus "$DEVKIT_CPUS" --memory "$memory"
    fi
  fi
  if [ "$(_podman_machine '{{.State}}')" != running ]; then
    run podman machine start || die "podman machine start failed."
  fi
}
