#!/usr/bin/env bash
# Docker driver dependency (Linux and macOS).
#
# Linux: Docker Engine from Docker's official repository (apt/dnf/yum), or the
#        distribution package as a fallback (pacman, zypper, unsupported
#        releases). The daemon is enabled and the user joins the docker group.
# macOS: Docker Desktop (default) or Colima, chosen by DEVKIT_DOCKER_RUNTIME_MACOS.

driver_docker_label() { echo docker; }

driver_docker_check() {
  local output version
  if ! has_cmd docker && ! _docker_find_desktop_cli; then
    DEP_STATUS='not installed'
    return 1
  fi
  if docker --version 2>/dev/null | grep -qi podman; then
    DEP_STATUS="'docker' is the Podman compatibility wrapper; use --driver podman or remove podman-docker"
    DEP_UNFIXABLE=1
    return 1
  fi
  if ! output="$(docker info 2>&1)"; then
    if printf '%s' "$output" | grep -qi 'permission denied'; then
      DEP_STATUS='installed, but the current user cannot access the Docker daemon'
    else
      DEP_STATUS='installed, but the Docker daemon is not running'
    fi
    return 1
  fi
  version="$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if [ -n "$version" ] && ! ver_ge "$version" "$DEVKIT_DOCKER_MIN_VERSION"; then
    DEP_STATUS="server ${version} is older than the required ${DEVKIT_DOCKER_MIN_VERSION}; upgrade Docker"
    DEP_UNFIXABLE=1
    return 1
  fi
  DEP_STATUS="ok (server ${version:-unknown})"
}

driver_docker_install() {
  has_cmd docker && return 0
  case "$DEVKIT_OS" in
    linux) _docker_install_linux ;;
    macos) _docker_install_macos ;;
  esac
}

driver_docker_configure() {
  case "$DEVKIT_OS" in
    linux) _docker_configure_linux ;;
    macos) _docker_configure_macos ;;
  esac
}

# ----------------------------------------------------------------- Linux ---

_docker_install_linux() {
  pkg_detect
  case "$DEVKIT_PKG" in
    apt)     _docker_install_apt ;;
    dnf|yum) _docker_install_rpm ;;
    pacman|zypper) pkg_install docker ;;
    *) die "No supported package manager found. Install Docker Engine manually: https://docs.docker.com/engine/install/" ;;
  esac
}

# Docker's apt repository supports Debian and Ubuntu (and derivatives through
# ID_LIKE + UBUNTU_CODENAME, e.g. Linux Mint, Pop!_OS).
_docker_install_apt() {
  local distro='' codename="$DEVKIT_DISTRO_CODENAME" tmp arch
  case " ${DEVKIT_DISTRO_ID} ${DEVKIT_DISTRO_LIKE} " in
    *" ubuntu "*) distro=ubuntu ;;
    *" debian "*) distro=debian ;;
  esac

  if [ -z "$distro" ] || [ -z "$codename" ] \
    || ! curl -fsSI --max-time 8 "https://download.docker.com/linux/${distro}/dists/${codename}/Release" >/dev/null 2>&1; then
    log_warn "Docker's repository has no packages for ${DEVKIT_DISTRO_NAME:-this distribution}; using the distribution package (docker.io)."
    pkg_install docker.io
    return
  fi

  pkg_install ca-certificates curl
  tmp="$(mktemp)"
  download "https://download.docker.com/linux/${distro}/gpg" "$tmp"
  as_root install -m 0755 -d /etc/apt/keyrings
  as_root install -m 0644 "$tmp" /etc/apt/keyrings/docker.asc
  rm -f "$tmp"
  arch="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$distro" "$codename" | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
  pkg_refresh_reset
  pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin
}

_docker_install_rpm() {
  local repo tmp
  case "$DEVKIT_DISTRO_ID" in
    fedora) repo=fedora ;;
    rhel)   repo=rhel ;;
    *)
      case " ${DEVKIT_DISTRO_LIKE} " in
        *" rhel "*|*" centos "*) repo=centos ;;
        *" fedora "*) repo=fedora ;;
        *) die "Unsupported RPM distribution (${DEVKIT_DISTRO_NAME}). Install Docker Engine manually: https://docs.docker.com/engine/install/" ;;
      esac
      ;;
  esac

  tmp="$(mktemp)"
  download "https://download.docker.com/linux/${repo}/docker-ce.repo" "$tmp"
  as_root install -m 0644 "$tmp" /etc/yum.repos.d/docker-ce.repo
  rm -f "$tmp"
  pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin
}

_docker_configure_linux() {
  local user
  user="$(id -un)"

  if ! as_root docker info >/dev/null 2>&1; then
    log_info "Starting the Docker daemon"
    if [ -d /run/systemd/system ]; then
      as_root systemctl enable --now docker.service
    elif has_cmd service; then
      as_root service docker start
    else
      die "Cannot start Docker: neither systemd nor the service command is available."
    fi
    wait_until "$DEVKIT_DOCKER_START_TIMEOUT" as_root docker info \
      || die "The Docker daemon did not become ready. Check: sudo journalctl -u docker"
  fi

  # minikube's docker driver must not run as root, so the user needs direct
  # access to the daemon socket through the docker group.
  if ! getent group docker >/dev/null 2>&1; then
    as_root groupadd docker
  fi
  if ! id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
    log_info "Adding ${user} to the docker group"
    as_root usermod -aG docker "$user"
  fi
  if ! id -nG | tr ' ' '\n' | grep -qx docker; then
    exit_pending relogin \
      "User ${user} was added to the 'docker' group, which only takes effect in a new login session (or run: newgrp docker)."
  fi
}

# ----------------------------------------------------------------- macOS ---

# Docker Desktop installs its CLI inside the app bundle; expose it if needed.
_docker_find_desktop_cli() {
  local dir
  for dir in /Applications/Docker.app/Contents/Resources/bin "${HOME}/Applications/Docker.app/Contents/Resources/bin"; do
    if [ -x "${dir}/docker" ]; then
      PATH="${PATH}:${dir}"
      export PATH
      return 0
    fi
  done
  return 1
}

_docker_desktop_installed() {
  [ -d /Applications/Docker.app ] || [ -d "${HOME}/Applications/Docker.app" ]
}

_docker_macos_runtime() {
  if _docker_desktop_installed; then echo desktop; return; fi
  if has_cmd colima; then echo colima; return; fi
  select_option "Select the Docker runtime for macOS:" "$DEVKIT_DOCKER_RUNTIME_MACOS" \
    'desktop|Docker Desktop (free for personal use and small businesses)' \
    'colima|Colima (open source, CLI only)'
}

_docker_install_macos() {
  local runtime
  brew_ensure
  runtime="$(_docker_macos_runtime)"
  config_save DEVKIT_DOCKER_RUNTIME_MACOS "$runtime"
  if [ "$runtime" = colima ]; then
    pkg_install colima docker
  elif ! _docker_desktop_installed; then
    pkg_install_cask docker-desktop
  fi
  has_cmd docker || _docker_find_desktop_cli || true
}

_docker_configure_macos() {
  docker info >/dev/null 2>&1 && return 0

  if [ "$DEVKIT_DOCKER_RUNTIME_MACOS" = colima ] || ! _docker_desktop_installed; then
    has_cmd colima || die "Colima is not installed. Run: brew install colima docker"
    # The Colima VM must be larger than the minikube node running inside it.
    local memory_gb=$(( (DEVKIT_MEMORY_MB + 1023) / 1024 + 2 ))
    log_info "Starting Colima (${DEVKIT_CPUS} CPUs, ${memory_gb} GB RAM, $((DEVKIT_DISK_GB + 20)) GB disk)"
    run colima start --cpu "$DEVKIT_CPUS" --memory "$memory_gb" --disk "$((DEVKIT_DISK_GB + 20))"
  else
    log_info "Starting Docker Desktop"
    log_info "On the first launch, accept the Docker Desktop terms in the window that opens."
    run open -a Docker
  fi

  log_info "Waiting up to ${DEVKIT_DOCKER_START_TIMEOUT}s for the Docker daemon..."
  has_cmd docker || _docker_find_desktop_cli || true
  wait_until "$DEVKIT_DOCKER_START_TIMEOUT" docker info \
    || die "The Docker daemon did not become ready. Open Docker Desktop (or run 'colima status') and retry."
}
