#!/usr/bin/env bash
# hyperkit driver dependency (Intel Macs only). Deprecated by minikube; kept
# for older machines. minikube downloads docker-machine-driver-hyperkit and
# asks for sudo once to make it setuid root.

driver_hyperkit_label() { echo hyperkit; }

driver_hyperkit_check() {
  if ! host_virtualization_supported; then
    DEP_STATUS='Hypervisor.framework is not available on this Mac'
    DEP_UNFIXABLE=1
    return 1
  fi
  if ! has_cmd hyperkit; then
    DEP_STATUS='not installed'
    return 1
  fi
  DEP_STATUS='ok (deprecated: prefer vfkit or docker)'
}

driver_hyperkit_install() {
  has_cmd hyperkit && return 0
  brew_ensure
  pkg_install hyperkit
}

driver_hyperkit_configure() { :; }
