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
    apt) _apt_update ;;
    brew) run brew update --quiet ;;
  esac
  _PKG_REFRESHED=1
}

pkg_refresh_reset() { _PKG_REFRESHED=0; }

# ------------------------------------------------------------ apt sources ---

_APT_DIR="${_APT_DIR:-/etc/apt}"
_APT_SIGNED_BY_ERROR='Conflicting values set for option Signed-By regarding source'

# Runs "apt-get update", repairing repositories declared more than once with
# different keyrings (an error that makes apt refuse to read any source).
_apt_update() {
  local output url attempt
  for attempt in 1 2 3 4 5; do
    if output="$(as_root apt-get update -qq 2>&1)"; then
      [ -z "$output" ] || printf '%s\n' "$output"
      return 0
    fi
    url="$(printf '%s\n' "$output" | sed -n "s|.*${_APT_SIGNED_BY_ERROR} \([^ ]*\) .*|\1|p" | head -n 1)"
    if [ -z "$url" ]; then
      printf '%s\n' "$output" >&2
      die "apt-get update failed. Fix the apt sources reported above and retry."
    fi
    log_warn "The apt repository ${url} is declared more than once with different keyrings; keeping a single entry."
    apt_fix_signed_by_conflict "$url"
  done
  printf '%s\n' "$output" >&2
  die "apt-get update still fails after repairing the apt sources."
}

# Lists the apt source files (one-line .list and deb822 .sources) with an
# active entry for a repository URL (deb822 stanzas with "Enabled: no" are not).
apt_sources_with() {
  local url="${1%/}" file
  for file in "${_APT_DIR}/sources.list" "${_APT_DIR}"/sources.list.d/*.list "${_APT_DIR}"/sources.list.d/*.sources; do
    [ -f "$file" ] || continue
    awk -v u="$url" '
      function check() { if (m && !off) found = 1; m = 0; off = 0 }
      /^[[:space:]]*$/ { check(); next }
      /^[[:space:]]*#/ { next }
      index($0, u) { m = 1 }
      tolower($1) == "enabled:" && tolower($2) == "no" { off = 1 }
      FILENAME !~ /\.sources$/ { check() }
      END { check(); exit !found }' "$file" \
      && printf '%s\n' "$file"
  done
  return 0
}

# Prints the keyring file an apt source FILE uses for URL (empty when the
# entry has no Signed-By path, e.g. an inline key).
_apt_source_keyring() {
  local file="$1" url="${2%/}"
  case "$file" in
    *.sources)
      awk -v u="$url" '
        /^[[:space:]]*$/ { if (m && k != "") { print k; exit } m = 0; k = ""; next }
        /^[[:space:]]*#/ { next }
        tolower($1) == "uris:" && index($0, u) { m = 1 }
        tolower($1) == "signed-by:" { k = $2 }
        END { if (m && k != "") print k }' "$file"
      ;;
    *)
      awk -v u="$url" '!/^[[:space:]]*#/ && index($0, u) && match($0, /signed-by=[^] ]+/) {
        print substr($0, RSTART + 10, RLENGTH - 10); exit }' "$file"
      ;;
  esac
}

# apt_disable_source FILE URL: stops apt from reading the entries of FILE for
# URL. A source file holding only those entries is renamed to *.disabled (apt
# ignores it silently, and it can be renamed back); otherwise the matching
# lines are commented out (.list) or their stanzas get "Enabled: no" (.sources).
apt_disable_source() {
  local file="$1" url="${2%/}" tmp
  case "$file" in
    */sources.list) ;;
    *.sources)
      if ! awk -v u="$url" 'tolower($1) == "uris:" && !index($0, u) { other = 1 } END { exit !other }' "$file"; then
        as_root mv "$file" "${file}.disabled"
        log_info "Renamed ${file} to ${file}.disabled"
        return 0
      fi
      ;;
    *)
      if ! awk -v u="$url" '!/^[[:space:]]*(#|$)/ && !index($0, u) { other = 1 } END { exit !other }' "$file"; then
        as_root mv "$file" "${file}.disabled"
        log_info "Renamed ${file} to ${file}.disabled"
        return 0
      fi
      ;;
  esac

  tmp="$(mktemp)"
  case "$file" in
    *.sources)
      awk -v u="$url" '
        function flush() { if (n) { for (i = 1; i <= n; i++) print s[i]; if (m) print "Enabled: no"; n = 0; m = 0 } }
        /^[[:space:]]*$/ { flush(); print; next }
        tolower($1) == "uris:" && index($0, u) { m = 1 }
        tolower($1) == "enabled:" { next }
        { s[++n] = $0 }
        END { flush() }' "$file" >"$tmp"
      ;;
    *)
      awk -v u="$url" '!/^[[:space:]]*#/ && index($0, u) { print "# disabled by devkit: " $0; next } { print }' "$file" >"$tmp"
      ;;
  esac
  as_root install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
  log_info "Disabled the entries for ${url} in ${file}"
}

# Keeps one declaration of a repository URL (the first whose keyring exists)
# and disables the others, resolving apt's Signed-By conflict.
apt_fix_signed_by_conflict() {
  local url="$1" file keyring keep='' files
  files="$(apt_sources_with "$url")"
  [ -n "$files" ] || die "apt reports a conflict for ${url}, but no source file declares it. Check ${_APT_DIR}."
  while IFS= read -r file; do
    keyring="$(_apt_source_keyring "$file" "$url")"
    if [ -z "$keyring" ] || [ -f "$keyring" ]; then keep="$file"; break; fi
  done <<EOF
$files
EOF
  [ -n "$keep" ] || keep="$(printf '%s\n' "$files" | head -n 1)"
  while IFS= read -r file; do
    [ "$file" = "$keep" ] || apt_disable_source "$file" "$url"
  done <<EOF
$files
EOF
}

# Succeeds when the package is already installed by the current manager.
pkg_is_installed() {
  case "$DEVKIT_PKG" in
    apt)         dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed' ;;
    dnf|yum|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    pacman)      pacman -Q "$1" >/dev/null 2>&1 ;;
    brew)        brew list --formula "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# Base packages devkit may install but never removes on uninstall.
_PKG_KEEP=' curl ca-certificates '

# Records the packages a pkg_install call added (not the ones already present).
_pkg_record() {
  local prefix="$1" name
  shift
  for name in "$@"; do
    case "$_PKG_KEEP" in *" ${name} "*) continue ;; esac
    state_list_add INSTALLED_PKGS "${prefix}:${name}"
  done
}

pkg_install() {
  local name new=''
  pkg_detect
  pkg_refresh
  for name in "$@"; do pkg_is_installed "$name" || new="${new} ${name}"; done
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
  # shellcheck disable=SC2086
  [ -z "$new" ] || _pkg_record "$DEVKIT_PKG" $new
}

pkg_install_cask() {
  local name new=''
  brew_ensure
  for name in "$@"; do brew list --cask "$name" >/dev/null 2>&1 || new="${new} ${name}"; done
  log_info "Installing application: $*"
  run brew install --cask "$@"
  # shellcheck disable=SC2086
  [ -z "$new" ] || _pkg_record brew-cask $new
}

# pkg_remove MANAGER:PACKAGE: uninstalls a package recorded by pkg_install.
pkg_remove() {
  local manager="${1%%:*}" name="${1#*:}"
  case "$manager" in
    apt)       as_root env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "$name" ;;
    dnf|yum)   as_root "$manager" remove -y -q "$name" ;;
    pacman)    as_root pacman -R --noconfirm "$name" ;;
    zypper)    as_root zypper --non-interactive --quiet remove "$name" ;;
    brew)      run brew uninstall --formula "$name" ;;
    brew-cask) run brew uninstall --cask "$name" ;;
    *) log_warn "Unknown package manager '${manager}' for ${name}; skipping." ;;
  esac
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

# ---------------------------------------------------------------- updates ---

# "5:29.9.1-1~ubuntu.26.04~resolute" -> "29.9.1"
pkg_pretty_version() {
  local v="${1#*:}"
  printf '%s\n' "${v%%-*}"
}

# pkg_available_update NAME [--cask]: prints the newer version offered by the
# package manager for an installed package, or nothing (up to date, not
# installed by this manager, or unknown). Uses the local package metadata.
pkg_available_update() {
  local name="$1" kind="${2:-}" installed candidate
  pkg_detect
  case "$DEVKIT_PKG" in
    apt)
      dpkg-query -W -f='${Status}' "$name" 2>/dev/null | grep -q 'ok installed' || return 0
      installed="$(apt-cache policy "$name" 2>/dev/null | awk '/Installed:/ {print $2}')"
      candidate="$(apt-cache policy "$name" 2>/dev/null | awk '/Candidate:/ {print $2}')"
      if [ -n "$candidate" ] && [ "$candidate" != '(none)' ] && [ "$candidate" != "$installed" ]; then
        pkg_pretty_version "$candidate"
      fi
      ;;
    dnf|yum)
      rpm -q "$name" >/dev/null 2>&1 || return 0
      candidate="$("$DEVKIT_PKG" -q check-update "$name" 2>/dev/null | awk -v n="$name" 'index($1, n ".") == 1 {print $2; exit}')"
      [ -z "$candidate" ] || pkg_pretty_version "$candidate"
      ;;
    pacman)
      pacman -Q "$name" >/dev/null 2>&1 || return 0
      pacman -Qu "$name" 2>/dev/null | awk '{print $4; exit}'
      ;;
    zypper)
      rpm -q "$name" >/dev/null 2>&1 || return 0
      zypper -q list-updates 2>/dev/null | awk -F'|' -v n="$name" '{gsub(/ /, "", $3)} $3 == n {gsub(/ /, "", $5); print $5; exit}'
      ;;
    brew)
      if [ "$kind" = --cask ]; then
        brew list --cask "$name" >/dev/null 2>&1 || return 0
        # Cask versions may carry a build suffix ("4.42.0,195023").
        brew outdated --cask --greedy --verbose "$name" 2>/dev/null | sed -n 's/.*!= *//p' | head -n 1 | cut -d, -f1
      else
        brew list --formula "$name" >/dev/null 2>&1 || return 0
        brew outdated --verbose "$name" 2>/dev/null | sed -n 's/.*< *//p' | head -n 1
      fi
      ;;
  esac
  return 0
}

# pkg_upgrade [--cask] NAME...: upgrades installed packages to the newest version.
pkg_upgrade() {
  local cask=''
  [ "${1:-}" = --cask ] && { cask=--cask; shift; }
  pkg_detect
  case "$DEVKIT_PKG" in
    apt)     pkg_refresh; as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade "$@" ;;
    dnf|yum) as_root "$DEVKIT_PKG" upgrade -y -q "$@" ;;
    pacman)  as_root pacman -S --noconfirm "$@" ;;
    zypper)  as_root zypper --non-interactive --quiet update "$@" ;;
    brew)    if [ -n "$cask" ]; then run brew upgrade --cask --greedy "$@"; else run brew upgrade "$@"; fi ;;
    *) die "No supported package manager found to upgrade: $*" ;;
  esac
}
