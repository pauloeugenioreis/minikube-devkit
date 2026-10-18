#!/usr/bin/env bash
# Docker driver dependency (Linux and macOS).
#
# Linux: Docker Engine from Docker's official repository (apt/dnf/yum), or the
#        distribution package as a fallback (pacman, zypper, unsupported
#        releases). The daemon is enabled and the user joins the docker group.
# macOS: Docker Desktop (default) or Colima, chosen by DEVKIT_DOCKER_RUNTIME_MACOS.
#
# With DEVKIT_DOCKER_VERSION=latest, devkit offers updates published by the
# package manager that installed Docker (apt, dnf/yum or Homebrew).

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
  DEP_CURRENT="${version:-unknown}"
  DEP_STATUS="ok (server ${version:-unknown})"
  if [ "${DEVKIT_DOCKER_VERSION:-latest}" = latest ]; then
    _docker_available_update
    if [ -n "$_DOCKER_UPDATE" ]; then
      DEP_UPDATE="$_DOCKER_UPDATE"
      # Homebrew versions Docker Desktop / Colima, not the engine.
      [ "$DEVKIT_OS" = macos ] && DEP_CURRENT="$(_docker_macos_app_version)"
      DEP_STATUS="ok (server ${version:-unknown}, update available: ${_DOCKER_UPDATE})"
    fi
  fi
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
  state_list_add INSTALLED_FILES /etc/apt/keyrings/docker.asc
  state_list_add INSTALLED_FILES /etc/apt/sources.list.d/docker.list
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
  state_list_add INSTALLED_FILES /etc/yum.repos.d/docker-ce.repo
  rm -f "$tmp"
  pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin
}

_docker_configure_linux() {
  if ! as_root docker info >/dev/null 2>&1; then
    log_info "Starting the Docker daemon"
    service_enable_now docker
    wait_until "$DEVKIT_DOCKER_START_TIMEOUT" as_root docker info \
      || die "The Docker daemon did not become ready. Check: sudo journalctl -u docker"
  fi

  # minikube's docker driver must not run as root, so the user needs direct
  # access to the daemon socket through the docker group.
  ensure_group_membership docker
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

# ---------------------------------------------------------------- updates ---

# Sets _DOCKER_UPDATE to the newer version offered by the package manager
# (empty when up to date or unknown). Cached for the rest of the run.
_docker_available_update() {
  [ -n "${_DOCKER_UPDATE+x}" ] && return 0
  _DOCKER_UPDATE=''
  local candidate
  if [ "$DEVKIT_OS" = macos ]; then
    has_cmd brew || return 0
    _DOCKER_UPDATE="$(pkg_available_update docker-desktop --cask)"
    if [ -z "$_DOCKER_UPDATE" ]; then
      candidate="$(pkg_available_update colima)"
      [ -z "$candidate" ] || _DOCKER_UPDATE="colima ${candidate}"
    fi
    return 0
  fi
  _DOCKER_UPDATE="$(pkg_available_update "$(_docker_linux_package)")"
}

# Installed Docker Desktop (or Colima) version as Homebrew reports it.
_docker_macos_app_version() {
  if brew list --cask docker-desktop >/dev/null 2>&1; then
    printf 'Docker Desktop %s\n' "$(brew list --cask --versions docker-desktop | awk '{print $2}' | cut -d, -f1)"
  else
    printf 'colima %s\n' "$(brew list --versions colima | awk '{print $2}')"
  fi
}

# Package that provides the Docker engine on Linux.
_docker_linux_package() {
  if has_cmd dpkg-query; then
    if dpkg-query -W -f='${Status}' docker.io 2>/dev/null | grep -q 'ok installed' \
      && ! dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -q 'ok installed'; then
      echo docker.io
      return 0
    fi
  elif has_cmd rpm && ! rpm -q docker-ce >/dev/null 2>&1 && rpm -q docker >/dev/null 2>&1; then
    echo docker
    return 0
  fi
  echo docker-ce
}

driver_docker_update() {
  if [ "$DEVKIT_OS" = macos ]; then
    if brew list --cask docker-desktop >/dev/null 2>&1; then
      pkg_upgrade --cask docker-desktop
    else
      pkg_upgrade colima
    fi
  elif [ "$(_docker_linux_package)" = docker-ce ]; then
    pkg_upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  else
    pkg_upgrade "$(_docker_linux_package)"
  fi
  unset _DOCKER_UPDATE
}
