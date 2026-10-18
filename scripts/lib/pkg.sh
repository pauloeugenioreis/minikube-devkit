#!/usr/bin/env bash
# Package manager abstraction for Linux (apt, dnf, yum, pacman, zypper) and
# macOS (Homebrew).

DEVKIT_PKG=''
_PKG_REFRESHED=0

pkg_detect() {
  [ -n "$DEVKIT_PKG" ] && return 0
  if [ "$DEVKIT_OS" = macos ]; then
    if has_cmd brew; then DEVKIT_PKG=brew; else DEVKIT_PKG=none; fi
    return 0
  fi
  local manager
  for manager in apt-get dnf yum pacman zypper; do
    if has_cmd "$manager"; then
      DEVKIT_PKG="${manager%-get}"
      return 0
    fi
  done
  DEVKIT_PKG=none
}

# Refreshes package indexes once per run (call pkg_refresh_reset after adding
# a repository to force another refresh).
pkg_refresh() {
  [ "$_PKG_REFRESHED" = 1 ] && return 0
  case "$DEVKIT_PKG" in
    apt) as_root apt-get update -qq ;;
    brew) run brew update --quiet ;;
  esac
  _PKG_REFRESHED=1
}

pkg_refresh_reset() { _PKG_REFRESHED=0; }

pkg_install() {
  pkg_detect
  pkg_refresh
  log_info "Installing packages: $*"
  case "$DEVKIT_PKG" in
    apt)    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf)    as_root dnf install -y -q "$@" ;;
    yum)    as_root yum install -y -q "$@" ;;
    pacman) as_root pacman -S --needed --noconfirm "$@" ;;
    zypper) as_root zypper --non-interactive --quiet install "$@" ;;
    brew)   run brew install "$@" ;;
    *) die "No supported package manager found. Install manually: $*" ;;
  esac
}

pkg_install_cask() {
  brew_ensure
  log_info "Installing application: $*"
  run brew install --cask "$@"
}

# Makes sure Homebrew is available on macOS, installing it with consent.
brew_ensure() {
  [ "$DEVKIT_OS" = macos ] || return 0
  if ! has_cmd brew; then
    # Homebrew may be installed but not on PATH in this shell.
    local prefix
    for prefix in /opt/homebrew /usr/local; do
      if [ -x "${prefix}/bin/brew" ]; then
        eval "$("${prefix}/bin/brew" shellenv)"
        break
      fi
    done
  fi
  if ! has_cmd brew; then
    ask_yes_no "Homebrew is required to install dependencies on macOS. Install it now?" Y \
      || die "Homebrew is required. See https://brew.sh"
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || die "Homebrew installation failed."
    local prefix
    for prefix in /opt/homebrew /usr/local; do
      [ -x "${prefix}/bin/brew" ] && eval "$("${prefix}/bin/brew" shellenv)" && break
    done
    has_cmd brew || die "Homebrew was installed but 'brew' is not on PATH. Open a new terminal and retry."
  fi
  DEVKIT_PKG=brew
}
