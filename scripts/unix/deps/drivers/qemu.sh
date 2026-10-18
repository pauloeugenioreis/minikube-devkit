#!/usr/bin/env bash
# qemu driver dependency (Linux and macOS). Uses minikube's builtin user-mode
# network, which is enough for devkit (everything is reached through
# kubectl port-forward).

driver_qemu_label() { echo qemu; }

_qemu_binary() {
  if [ "$DEVKIT_ARCH" = arm64 ]; then echo qemu-system-aarch64; else echo qemu-system-x86_64; fi
}

driver_qemu_check() {
  local bin
  bin="$(_qemu_binary)"
  if ! host_virtualization_supported; then
    DEP_STATUS="$VIRTUALIZATION_HINT"
    DEP_UNFIXABLE=1
    return 1
  fi
  if ! has_cmd "$bin"; then
    DEP_STATUS="${bin} is not installed"
    return 1
  fi
  if [ "$DEVKIT_OS" = linux ] && [ ! -w /dev/kvm ]; then
    DEP_STATUS='installed, but KVM acceleration (/dev/kvm) is not usable by the current user'
    return 1
  fi
  DEP_STATUS="ok ($("$bin" --version 2>/dev/null | head -n 1 | sed 's/.*version \([0-9.]*\).*/\1/'))"
}

driver_qemu_install() {
  has_cmd "$(_qemu_binary)" && return 0
  if [ "$DEVKIT_OS" = macos ]; then
    brew_ensure
    pkg_install qemu
    return
  fi
  pkg_detect
  case "$DEVKIT_PKG" in
    apt)
      if [ "$DEVKIT_ARCH" = arm64 ]; then pkg_install qemu-system-arm qemu-utils qemu-efi-aarch64
      else pkg_install qemu-system-x86 qemu-utils
      fi
      ;;
    dnf|yum) pkg_install qemu-kvm qemu-img ;;
    pacman)  pkg_install qemu-base ;;
    zypper)  pkg_install qemu-x86 qemu-tools ;;
    *) die "No supported package manager found. Install QEMU manually." ;;
  esac
}

driver_qemu_configure() {
  [ "$DEVKIT_OS" = linux ] || return 0
  if [ ! -e /dev/kvm ]; then
    if grep -q vmx /proc/cpuinfo; then as_root modprobe kvm_intel; else as_root modprobe kvm_amd; fi
    [ -e /dev/kvm ] || die "/dev/kvm is still missing after loading the KVM modules."
  fi
  # Without KVM, QEMU falls back to software emulation (far too slow).
  [ -w /dev/kvm ] || ensure_group_membership kvm
}
