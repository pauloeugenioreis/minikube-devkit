#!/usr/bin/env bash
# vfkit driver dependency (macOS): VMs on Apple's Virtualization framework.

driver_vfkit_label() { echo vfkit; }

driver_vfkit_check() {
  if ! host_virtualization_supported; then
    DEP_STATUS='Hypervisor.framework is not available on this Mac'
    DEP_UNFIXABLE=1
    return 1
  fi
  if ! has_cmd vfkit; then
    DEP_STATUS='not installed'
    return 1
  fi
  DEP_STATUS="ok ($(vfkit --version 2>/dev/null | awk '{print $NF}'))"
}

driver_vfkit_install() {
  has_cmd vfkit && return 0
  brew_ensure
  pkg_install vfkit
}

driver_vfkit_configure() { :; }
