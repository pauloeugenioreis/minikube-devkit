#!/usr/bin/env bash
# Shared helpers: logging, OS detection, configuration, downloads and host info.
# Must stay compatible with bash 3.2 (macOS default): no associative arrays,
# no ${var,,}, no mapfile.

: "${DEVKIT_ROOT:?DEVKIT_ROOT must be set by the entrypoint}"
DEVKIT_STATE_DIR="${DEVKIT_ROOT}/.devkit"

# Exit code used when the user must log out/in or reboot before continuing.
DEVKIT_EXIT_PENDING=10

# ---------------------------------------------------------------- logging ---

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_RESET=$'\033[0m'; _C_BOLD=$'\033[1m'; _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'; _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'; _C_BLUE=$'\033[34m'
else
  _C_RESET=''; _C_BOLD=''; _C_DIM=''; _C_RED=''; _C_GREEN=''; _C_YELLOW=''; _C_BLUE=''
fi

log_step()  { printf '\n%s==> %s%s\n' "${_C_BOLD}${_C_BLUE}" "$*" "${_C_RESET}"; }
log_info()  { printf '    %s\n' "$*"; }
log_ok()    { printf '  %s✔%s %s\n' "${_C_GREEN}" "${_C_RESET}" "$*"; }
log_warn()  { printf '  %s!%s %s\n' "${_C_YELLOW}" "${_C_RESET}" "$*" >&2; }
log_error() { printf '  %s✖%s %s\n' "${_C_RED}" "${_C_RESET}" "$*" >&2; }
log_debug() { [ "${DEVKIT_VERBOSE:-0}" = 1 ] && printf '    %s%s%s\n' "${_C_DIM}" "$*" "${_C_RESET}" >&2; return 0; }
die()       { log_error "$*"; exit 1; }

# Runs a command, echoing it first in verbose mode.
run() {
  log_debug "\$ $*"
  "$@"
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------ OS detection ---

detect_os() {
  case "$(uname -s)" in
    Linux)  DEVKIT_OS=linux ;;
    Darwin) DEVKIT_OS=macos ;;
    MINGW*|MSYS*|CYGWIN*) die "On Windows, run devkit.ps1 from PowerShell instead." ;;
    *) die "Unsupported operating system: $(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64|amd64)  DEVKIT_ARCH=amd64 ;;
    aarch64|arm64) DEVKIT_ARCH=arm64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
  # A shell running under Rosetta reports x86_64 on Apple Silicon.
  if [ "$DEVKIT_OS" = macos ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    DEVKIT_ARCH=arm64
  fi

  DEVKIT_DISTRO_ID=''; DEVKIT_DISTRO_LIKE=''; DEVKIT_DISTRO_NAME=''
  DEVKIT_DISTRO_CODENAME=''; DEVKIT_IS_WSL=0
  if [ "$DEVKIT_OS" = linux ]; then
    if [ -r /etc/os-release ]; then
      DEVKIT_DISTRO_ID="$(_os_release_value ID)"
      DEVKIT_DISTRO_LIKE="$(_os_release_value ID_LIKE)"
      DEVKIT_DISTRO_NAME="$(_os_release_value PRETTY_NAME)"
      DEVKIT_DISTRO_CODENAME="$(_os_release_value UBUNTU_CODENAME)"
      [ -n "$DEVKIT_DISTRO_CODENAME" ] || DEVKIT_DISTRO_CODENAME="$(_os_release_value VERSION_CODENAME)"
    fi
    if grep -qi microsoft /proc/version 2>/dev/null; then DEVKIT_IS_WSL=1; fi
  else
    DEVKIT_DISTRO_NAME="macOS $(sw_vers -productVersion 2>/dev/null)"
  fi
}

_os_release_value() {
  sed -n "s/^$1=//p" /etc/os-release | head -n 1 | tr -d '"'
}

# Name used in download URLs (linux | darwin).
os_download_name() {
  if [ "$DEVKIT_OS" = macos ]; then echo darwin; else echo linux; fi
}

# ----------------------------------------------------------- configuration ---

# DEVKIT_* variables present in the environment before loading the config
# file win over it.
_DEVKIT_ENV_OVERRIDES=" $(env | sed -n 's/^\(DEVKIT_[A-Z0-9_]*\)=.*/\1/p' | tr '\n' ' ') "

DEVKIT_CONFIG_FILE="${DEVKIT_ROOT}/config/devkit.env"

config_load() {
  _config_load_file "$DEVKIT_CONFIG_FILE"
}

_config_load_file() {
  local file="$1" line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac

    key="${line%%=*}"
    value="${line#*=}"
    if [ "$key" = "$line" ] || ! printf '%s' "$key" | grep -Eq '^DEVKIT_[A-Z0-9_]+$'; then
      log_warn "Ignoring invalid line in ${file##*/}: $line"
      continue
    fi
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    case "$_DEVKIT_ENV_OVERRIDES" in *" $key "*) continue ;; esac
    printf -v "$key" '%s' "$value"
  done < "$file"
}

# Persists KEY=value in config/devkit.env, updating the existing line in place
# (comments and order are preserved) or appending it when missing.
config_save() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  if grep -q "^${key}=" "$DEVKIT_CONFIG_FILE"; then
    # ENVIRON avoids awk -v escape processing of the value.
    K="$key" V="$value" awk 'index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; next } { print }' \
      "$DEVKIT_CONFIG_FILE" > "$tmp"
  else
    cp "$DEVKIT_CONFIG_FILE" "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  # Rewrite in place to keep the file's permissions.
  cat "$tmp" > "$DEVKIT_CONFIG_FILE"
  rm -f "$tmp"
  printf -v "$key" '%s' "$value"
}

is_int() {
  case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

is_true() {
  case "$1" in true|TRUE|True|1|yes|y|Y) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- versions ---

# ver_ge A B: succeeds when version A >= version B. Ignores a leading "v" and
# any "-suffix" / "+build" part.
ver_ge() {
  local a b i x y
  a="$(_ver_core "$1")"; b="$(_ver_core "$2")"
  for i in 1 2 3; do
    x="$(printf '%s' "$a" | cut -d. -f"$i")"; y="$(printf '%s' "$b" | cut -d. -f"$i")"
    x="${x:-0}"; y="${y:-0}"
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}

_ver_core() {
  local v="${1#v}"
  v="${v%%[-+]*}"
  printf '%s' "$v" | sed 's/[^0-9.]//g'
}

# --------------------------------------------------------------- downloads ---

download() {
  local url="$1" dest="$2"
  log_debug "download $url"
  if has_cmd curl; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
  elif has_cmd wget; then
    wget -q --tries=3 -O "$dest" "$url"
  else
    die "Neither curl nor wget is available to download files."
  fi
}

sha256_of() {
  if has_cmd sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# verify_sha256 FILE CHECKSUM_URL: the checksum file may contain "hash" or
# "hash  filename".
verify_sha256() {
  local file="$1" sum_url="$2" sum_file expected actual
  sum_file="$(mktemp)"
  download "$sum_url" "$sum_file" || { rm -f "$sum_file"; return 1; }
  expected="$(awk '{print $1; exit}' "$sum_file")"
  rm -f "$sum_file"
  actual="$(sha256_of "$file")"
  if [ "$expected" != "$actual" ]; then
    log_error "Checksum mismatch for ${file##*/} (expected $expected, got $actual)"
    return 1
  fi
}

# ------------------------------------------------------------- privileges ---

# Runs a command as root, using sudo when needed.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    run "$@"
  elif has_cmd sudo; then
    run sudo "$@"
  else
    die "This step needs root privileges but sudo is not installed: $*"
  fi
}

# Installs a file into a directory, escalating only if the directory is not writable.
install_binary() {
  local src="$1" dir="$2" name="$3"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || as_root mkdir -p "$dir"
  fi
  if [ -w "$dir" ]; then
    run install -m 0755 "$src" "${dir}/${name}"
  else
    as_root install -m 0755 "$src" "${dir}/${name}"
  fi
}

# ---------------------------------------------------------------- waiting ---

# wait_until TIMEOUT_SECONDS COMMAND...: polls every 3s until COMMAND succeeds.
wait_until() {
  local timeout="$1" elapsed=0
  shift
  while ! "$@" >/dev/null 2>&1; do
    [ "$elapsed" -ge "$timeout" ] && return 1
    sleep 3
    elapsed=$((elapsed + 3))
  done
}

# -------------------------------------------------------------- host info ---

host_cpus() {
  if [ "$DEVKIT_OS" = macos ]; then sysctl -n hw.ncpu; else nproc 2>/dev/null || getconf _NPROCESSORS_ONLN; fi
}

host_memory_mb() {
  if [ "$DEVKIT_OS" = macos ]; then
    echo $(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
  else
    awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo
  fi
}

# Free disk space (GB) on the filesystem that holds PATH.
free_disk_gb() {
  local path="$1"
  while [ ! -e "$path" ]; do path="$(dirname "$path")"; done
  df -Pk "$path" | awk 'NR == 2 {print int($4 / 1024 / 1024)}'
}

# Succeeds when something is listening on 127.0.0.1:PORT.
port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Succeeds when HOST answers HTTPS (any HTTP status counts as reachable).
url_reachable() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null)" || return 1
  [ "$code" != "000" ]
}
