#!/usr/bin/env bash
# kvm2 driver dependency (Linux): KVM + libvirt. minikube downloads its own
# docker-machine-driver-kvm2 plugin on first start.

driver_kvm2_label() { echo kvm2; }

_kvm2_virsh() { virsh -c qemu:///system "$@"; }

driver_kvm2_check() {
  if ! host_virtualization_supported; then
    DEP_STATUS="$VIRTUALIZATION_HINT"
    DEP_UNFIXABLE=1
    return 1
  fi
  if [ ! -e /dev/kvm ]; then
    DEP_STATUS='/dev/kvm is missing (KVM kernel modules not loaded)'
    return 1
  fi
  if ! has_cmd virsh; then
    DEP_STATUS='libvirt is not installed'
    return 1
  fi
  if ! user_in_group_session libvirt; then
    DEP_STATUS="installed, but the current user is not in the 'libvirt' group"
    return 1
  fi
  if ! _kvm2_virsh list >/dev/null 2>&1; then
    DEP_STATUS='installed, but the libvirt daemon is not running'
    return 1
  fi
  if [ "$(_kvm2_virsh net-info default 2>/dev/null | awk '/^Active:/ {print $2}')" != yes ]; then
    DEP_STATUS="installed, but the libvirt 'default' network is not active"
    return 1
  fi
  DEP_STATUS="ok (libvirt $(virsh --version 2>/dev/null))"
}

driver_kvm2_install() {
  has_cmd virsh && [ -e /dev/kvm ] && return 0
  pkg_detect
  case "$DEVKIT_PKG" in
    apt)
      if [ "$DEVKIT_ARCH" = arm64 ]; then
        pkg_install qemu-system-arm qemu-utils libvirt-daemon-system libvirt-clients
      else
        pkg_install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients
      fi
      ;;
    dnf|yum) pkg_install qemu-kvm libvirt libvirt-client ;;
    pacman)  pkg_install qemu-base libvirt dnsmasq ;;
    zypper)  pkg_install qemu-kvm libvirt ;;
    *) die "No supported package manager found. Install KVM and libvirt manually." ;;
  esac
}

driver_kvm2_configure() {
  if [ ! -e /dev/kvm ]; then
    if grep -q vmx /proc/cpuinfo; then as_root modprobe kvm_intel; else as_root modprobe kvm_amd; fi
    [ -e /dev/kvm ] || die "/dev/kvm is still missing after loading the KVM modules."
  fi

  # Newer distributions ship modular daemons (virtqemud) instead of libvirtd.
  if [ -d /run/systemd/system ] && systemctl list-unit-files virtqemud.socket >/dev/null 2>&1 \
    && ! systemctl list-unit-files libvirtd.service >/dev/null 2>&1; then
    service_enable_now virtqemud.socket
    service_enable_now virtnetworkd.socket
  else
    service_enable_now libvirtd
  fi

  ensure_group_membership libvirt

  wait_until 30 _kvm2_virsh list || die "libvirt is not answering. Check: sudo systemctl status libvirtd"
  if [ "$(_kvm2_virsh net-info default 2>/dev/null | awk '/^Active:/ {print $2}')" != yes ]; then
    log_info "Starting the libvirt 'default' network"
    _kvm2_virsh net-start default >/dev/null 2>&1 || true
    _kvm2_virsh net-autostart default >/dev/null 2>&1 || true
  fi
}
