#!/usr/bin/env bash
# Driver registry: which minikube drivers are offered on this OS/architecture
# and how to load their dependency module.

# Prints "value|description" entries for the drivers supported on this host.
drivers_supported() {
  echo 'docker|Docker containers (recommended)'
  if [ "$DEVKIT_OS" = linux ]; then
    echo 'kvm2|KVM virtual machine'
    echo 'podman|Podman containers (experimental)'
    [ "$DEVKIT_ARCH" = amd64 ] && echo 'virtualbox|VirtualBox virtual machine'
    echo 'qemu|QEMU virtual machine'
  else
    echo 'vfkit|vfkit virtual machine (Apple Virtualization)'
    echo 'qemu|QEMU virtual machine'
    echo 'podman|Podman containers (experimental)'
    if [ "$DEVKIT_ARCH" = amd64 ]; then
      echo 'virtualbox|VirtualBox virtual machine'
      echo 'hyperkit|HyperKit virtual machine (deprecated)'
    fi
  fi
}

driver_is_supported() {
  drivers_supported | cut -d'|' -f1 | grep -qx "$1"
}

# ------------------------------------------------- helpers for driver modules ---

# Succeeds when the CPU exposes hardware virtualization to the OS
# (VT-x/AMD-V enabled in firmware on Linux, Hypervisor.framework on macOS).
host_virtualization_supported() {
  if [ "$DEVKIT_OS" = macos ]; then
    [ "$(sysctl -n kern.hv_support 2>/dev/null)" = 1 ]
  else
    grep -Eq '(vmx|svm)' /proc/cpuinfo 2>/dev/null
  fi
}

VIRTUALIZATION_HINT='CPU virtualization (VT-x/AMD-V) is not available; enable it in the BIOS/UEFI settings'

# Group membership as stored in the user database vs. the current session.
user_in_group_db()      { id -nG "$(id -un)" | tr ' ' '\n' | grep -qx "$1"; }
user_in_group_session() { id -nG | tr ' ' '\n' | grep -qx "$1"; }

# Adds the user to GROUP when needed. When the group is not active in this
# session yet, records a pending re-login and exits.
ensure_group_membership() {
  local group="$1" user
  user="$(id -un)"
  getent group "$group" >/dev/null 2>&1 || as_root groupadd "$group"
  if ! user_in_group_db "$group"; then
    log_info "Adding ${user} to the ${group} group"
    as_root usermod -aG "$group" "$user"
  fi
  if ! user_in_group_session "$group"; then
    exit_pending relogin \
      "User ${user} was added to the '${group}' group, which only takes effect in a new login session (or run: newgrp ${group})."
  fi
}

# Starts a systemd/SysV service and enables it at boot.
service_enable_now() {
  if [ -d /run/systemd/system ]; then
    as_root systemctl enable --now "$1"
  elif has_cmd service; then
    as_root service "$1" start
  else
    die "Cannot start ${1}: neither systemd nor the service command is available."
  fi
}

# Size of a helper VM (Colima, Podman machine) that must hold the minikube
# node: node size plus headroom.
helper_vm_memory_mb() { echo $((DEVKIT_MEMORY_MB + 2048)); }
helper_vm_disk_gb()   { echo $((DEVKIT_DISK_GB + 20)); }

# Sources the driver module; fails for drivers without an implementation yet.
driver_load() {
  local driver="$1" file="${DEVKIT_ROOT}/scripts/unix/deps/drivers/$1.sh"
  driver_is_supported "$driver" \
    || die "Driver '${driver}' is not supported on ${DEVKIT_OS}/${DEVKIT_ARCH}. Supported: $(drivers_supported | cut -d'|' -f1 | tr '\n' ' ')"
  [ -f "$file" ] || die "Driver '${driver}' is not implemented yet. Use --driver docker."
  # shellcheck source=/dev/null
  . "$file"
}
