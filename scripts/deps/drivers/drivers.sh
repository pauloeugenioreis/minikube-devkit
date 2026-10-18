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

# Sources the driver module; fails for drivers without an implementation yet.
driver_load() {
  local driver="$1" file="${DEVKIT_ROOT}/scripts/deps/drivers/$1.sh"
  driver_is_supported "$driver" \
    || die "Driver '${driver}' is not supported on ${DEVKIT_OS}/${DEVKIT_ARCH}. Supported: $(drivers_supported | cut -d'|' -f1 | tr '\n' ' ')"
  [ -f "$file" ] || die "Driver '${driver}' is not implemented yet. Use --driver docker."
  # shellcheck source=/dev/null
  . "$file"
}
