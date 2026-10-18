#!/usr/bin/env bash
# Core CLI dependencies required by every driver: curl, minikube, kubectl, helm.
# minikube, kubectl and helm are installed from their official release
# binaries and verified with SHA-256. DEVKIT_<TOOL>_VERSION is "latest"
# (resolved online on each run) or an exact version such as v1.38.1.
# When an older copy is installed, devkit offers to replace it.

CORE_DEPS='core_curl core_minikube core_kubectl core_helm'

# ------------------------------------------------------------------ curl ---

core_curl_label() { echo curl; }

core_curl_check() {
  if has_cmd curl; then DEP_STATUS='ok'; return 0; fi
  DEP_STATUS='not installed'
  if [ "$DEVKIT_OS" = macos ]; then
    # curl ships with macOS; missing means a broken system install.
    DEP_STATUS='not installed (reinstall the Xcode Command Line Tools: xcode-select --install)'
    DEP_UNFIXABLE=1
  fi
  return 1
}

core_curl_install() {
  has_cmd curl && return 0
  pkg_install curl ca-certificates
}

core_curl_configure() { :; }

# --------------------------------------------------------------- versions ---

# Prints the installed version of a core tool, or nothing.
_core_version() {
  case "$1" in
    minikube) minikube version --short 2>/dev/null | head -n 1 ;;
    kubectl)  kubectl version --client 2>/dev/null | sed -n 's/^Client Version: *//p' | head -n 1 ;;
    helm)     helm version --short 2>/dev/null | sed 's/+.*//' | head -n 1 ;;
  esac
}

# Prints the newest released version of a core tool, or nothing when offline.
_core_fetch_latest() {
  case "$1" in
    minikube)
      curl -fsSL --max-time 10 https://storage.googleapis.com/minikube/releases.json 2>/dev/null \
        | grep -o '"name": *"v[0-9.]*"' | head -n 1 | sed 's/.*"\(v[0-9.]*\)"/\1/'
      ;;
    kubectl) curl -fsSL --max-time 10 https://dl.k8s.io/release/stable.txt 2>/dev/null ;;
    helm)    curl -fsSL --max-time 10 https://get.helm.sh/helm-latest-version 2>/dev/null ;;
  esac
}

# Sets CORE_TARGET to the version devkit should install for TOOL: the
# configured exact version, or the resolved "latest" (empty when offline).
# Resolved values are cached for the rest of the run.
_core_target() {
  local tool="$1" key cache
  key="DEVKIT_$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')_VERSION"
  cache="_CORE_LATEST_${tool}"
  if [ "${!key:-latest}" != latest ]; then
    CORE_TARGET="${!key}"
    return 0
  fi
  if [ -z "${!cache+x}" ]; then
    printf -v "$cache" '%s' "$(_core_fetch_latest "$tool" | tr -d '[:space:]')"
  fi
  CORE_TARGET="${!cache}"
}

# _core_check TOOL MIN_VERSION: ready when installed and >= MIN_VERSION.
# Also sets DEP_CURRENT and, when a newer target exists, DEP_UPDATE.
_core_check() {
  local tool="$1" min="$2" version
  if ! has_cmd "$tool"; then
    DEP_STATUS='not installed'
    return 1
  fi
  version="$(_core_version "$tool")"
  if [ -z "$version" ]; then
    DEP_STATUS="installed at $(command -v "$tool") but its version could not be read"
    return 1
  fi
  DEP_CURRENT="$version"
  if ! ver_ge "$version" "$min"; then
    DEP_STATUS="${version} is older than the required ${min}"
    return 1
  fi
  _core_target "$tool"
  if [ -n "$CORE_TARGET" ] && ! ver_ge "$version" "$CORE_TARGET"; then
    DEP_UPDATE="$CORE_TARGET"
    DEP_STATUS="ok (${version}, update available: ${CORE_TARGET})"
  else
    DEP_STATUS="ok (${version})"
  fi
}

# ------------------------------------------------------------------- PATH ---

# Appends DEVKIT_BIN_DIR to PATH for this run so tools installed by a
# previous run are found even when the user's PATH does not include it.
core_init_path() {
  _CORE_USER_PATH="$PATH"
  case ":${PATH}:" in
    *":${DEVKIT_BIN_DIR}:"*) ;;
    *) PATH="${PATH}:${DEVKIT_BIN_DIR}"; export PATH ;;
  esac
}

# Puts DEVKIT_BIN_DIR first on PATH for this run and warns when it is not on
# the user's PATH permanently.
_core_ensure_bin_on_path() {
  PATH="${DEVKIT_BIN_DIR}:${PATH}"
  export PATH
  case ":${_CORE_USER_PATH:-$PATH}:" in
    *":${DEVKIT_BIN_DIR}:"*) ;;
    *)
      log_warn "${DEVKIT_BIN_DIR} is not on your PATH. Add it to your shell profile:"
      log_info "  export PATH=\"${DEVKIT_BIN_DIR}:\$PATH\""
      ;;
  esac
}

# Warns when another copy of TOOL earlier on PATH shadows the one just installed.
_core_assert_resolves() {
  local tool="$1" resolved
  hash -r
  resolved="$(command -v "$tool" || true)"
  if [ "$resolved" != "${DEVKIT_BIN_DIR}/${tool}" ]; then
    log_warn "'${tool}' resolves to ${resolved}, not ${DEVKIT_BIN_DIR}/${tool}."
    log_info "Remove or upgrade that copy, or put ${DEVKIT_BIN_DIR} first on PATH."
  fi
}

# --------------------------------------------------------- remove old copy ---

# Package names that differ from the tool name: "brew snap".
# (apt/dnf/pacman packages are found by asking which package owns the file.)
_core_pkg_names() {
  case "$1" in
    kubectl) echo 'kubernetes-cli kubectl' ;;
    *)       echo "$1 $1" ;;
  esac
}

# Removes the copy of TOOL found on PATH (unless it is devkit's own), using
# the package manager that installed it when there is one.
_core_remove_old() {
  local tool="$1" path real brew_name snap_name owner
  path="$(command -v "$tool" 2>/dev/null)" || return 0
  [ "$path" = "${DEVKIT_BIN_DIR}/${tool}" ] && return 0
  real="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
  [ -L "$path" ] && real="$(readlink "$path")"
  read -r brew_name snap_name <<EOF
$(_core_pkg_names "$tool")
EOF

  if has_cmd brew && brew list --formula "$brew_name" >/dev/null 2>&1 \
    && case "$real" in "$(brew --prefix)"/*|*/Cellar/*) true ;; *) false ;; esac; then
    log_info "Removing the Homebrew copy of ${tool} (${brew_name})"
    run brew uninstall --formula "$brew_name" || die "brew uninstall ${brew_name} failed."
  elif case "$path" in /snap/*) true ;; *) false ;; esac; then
    log_info "Removing the snap copy of ${tool}"
    as_root snap remove "$snap_name" || die "snap remove ${snap_name} failed."
  elif has_cmd dpkg && owner="$(dpkg -S "$real" 2>/dev/null | head -n 1 | cut -d: -f1)" && [ -n "$owner" ]; then
    log_info "Removing package ${owner} (${tool} ${DEP_CURRENT:-})"
    as_root env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "$owner" || die "apt-get remove ${owner} failed."
  elif has_cmd rpm && owner="$(rpm -qf --qf '%{NAME}\n' "$real" 2>/dev/null)" && [ -n "$owner" ]; then
    log_info "Removing package ${owner} (${tool} ${DEP_CURRENT:-})"
    if has_cmd dnf; then as_root dnf remove -y -q "$owner"; else as_root yum remove -y -q "$owner"; fi \
      || die "Removing package ${owner} failed."
  elif has_cmd pacman && owner="$(pacman -Qqo "$real" 2>/dev/null)" && [ -n "$owner" ]; then
    log_info "Removing package ${owner} (${tool} ${DEP_CURRENT:-})"
    as_root pacman -R --noconfirm "$owner" || die "pacman -R ${owner} failed."
  else
    # A plain binary (or a symlink, e.g. from Docker Desktop): remove only the
    # file on PATH, never the target of a symlink.
    log_info "Removing ${path}"
    if [ -w "$(dirname "$path")" ]; then rm -f "$path"; else as_root rm -f "$path"; fi
  fi
  hash -r
}

# ---------------------------------------------------------------- install ---

# _core_install_binary TOOL URL: downloads a single binary with a .sha256 file.
_core_install_binary() {
  local tool="$1" url="$2" tmp
  tmp="$(mktemp -d)"
  log_info "Downloading ${url}"
  download "$url" "${tmp}/${tool}" || { rm -rf "$tmp"; die "Download failed: $url"; }
  verify_sha256 "${tmp}/${tool}" "${url}.sha256" || { rm -rf "$tmp"; die "Checksum verification failed for ${tool}."; }
  install_binary "${tmp}/${tool}" "$DEVKIT_BIN_DIR" "$tool"
  rm -rf "$tmp"
  _core_ensure_bin_on_path
  _core_assert_resolves "$tool"
}

# Installs VERSION of TOOL into DEVKIT_BIN_DIR.
_core_install_version() {
  local tool="$1" version="$2" platform tmp url
  [ -n "$version" ] || die "Could not resolve the latest ${tool} version (offline?). Set DEVKIT_$(printf '%s' "$tool" | tr '[:lower:]' '[:upper:]')_VERSION to an exact version in config/devkit.env."
  platform="$(os_download_name)-${DEVKIT_ARCH}"
  case "$tool" in
    minikube) _core_install_binary minikube "https://storage.googleapis.com/minikube/releases/${version}/minikube-${platform}" ;;
    kubectl)  _core_install_binary kubectl "https://dl.k8s.io/release/${version}/bin/$(os_download_name)/${DEVKIT_ARCH}/kubectl" ;;
    helm)
      url="https://get.helm.sh/helm-${version}-${platform}.tar.gz"
      tmp="$(mktemp -d)"
      log_info "Downloading ${url}"
      download "$url" "${tmp}/helm.tar.gz" || { rm -rf "$tmp"; die "Download failed: $url"; }
      verify_sha256 "${tmp}/helm.tar.gz" "${url}.sha256sum" || { rm -rf "$tmp"; die "Checksum verification failed for helm."; }
      tar -xzf "${tmp}/helm.tar.gz" -C "$tmp"
      install_binary "${tmp}/${platform}/helm" "$DEVKIT_BIN_DIR" helm
      rm -rf "$tmp"
      _core_ensure_bin_on_path
      _core_assert_resolves helm
      ;;
  esac
}

# Install when missing or below the minimum (the old copy is removed first).
_core_install() {
  local tool="$1" min="$2"
  DEP_UPDATE=''
  _core_check "$tool" "$min" && return 0
  has_cmd "$tool" && _core_remove_old "$tool"
  _core_target "$tool"
  _core_install_version "$tool" "$CORE_TARGET"
}

# Replace an older (but usable) copy with the target version.
_core_update() {
  local tool="$1"
  _core_target "$tool"
  _core_remove_old "$tool"
  _core_install_version "$tool" "$CORE_TARGET"
}

# -------------------------------------------------------------- the tools ---

core_minikube_label()     { echo minikube; }
core_minikube_check()     { _core_check minikube "$DEVKIT_MINIKUBE_MIN_VERSION"; }
core_minikube_install()   { _core_install minikube "$DEVKIT_MINIKUBE_MIN_VERSION"; }
core_minikube_update()    { _core_update minikube; }
core_minikube_configure() { :; }

core_kubectl_label()      { echo kubectl; }
core_kubectl_check()      { _core_check kubectl "$DEVKIT_KUBECTL_MIN_VERSION"; }
core_kubectl_install()    { _core_install kubectl "$DEVKIT_KUBECTL_MIN_VERSION"; }
core_kubectl_update()     { _core_update kubectl; }
core_kubectl_configure()  { :; }

core_helm_label()         { echo helm; }
core_helm_check()         { _core_check helm "$DEVKIT_HELM_MIN_VERSION"; }
core_helm_install()       { _core_install helm "$DEVKIT_HELM_MIN_VERSION"; }
core_helm_update()        { _core_update helm; }
core_helm_configure()     { :; }
