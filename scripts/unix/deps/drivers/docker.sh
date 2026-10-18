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
