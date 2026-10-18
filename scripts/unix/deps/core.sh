#!/usr/bin/env bash
# Core CLI dependencies required by every driver: curl, minikube, kubectl, helm.
# minikube, kubectl and helm are installed from their official release
# binaries (pinned in config/devkit.env) and verified with SHA-256.

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

# --------------------------------------------------------------- helpers ---

# Prints the installed version of a core tool, or nothing.
_core_version() {
  case "$1" in
    minikube) minikube version --short 2>/dev/null | head -n 1 ;;
    kubectl)  kubectl version --client 2>/dev/null | sed -n 's/^Client Version: *//p' | head -n 1 ;;
    helm)     helm version --short 2>/dev/null | sed 's/+.*//' | head -n 1 ;;
  esac
}

# _core_check TOOL MIN_VERSION
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
  if ! ver_ge "$version" "$min"; then
    DEP_STATUS="${version} is older than the required ${min}"
    return 1
  fi
  DEP_STATUS="ok (${version})"
}

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

# Fails when an older copy of TOOL earlier on PATH shadows the one just installed.
_core_assert_resolves() {
  local tool="$1" resolved
  hash -r
  resolved="$(command -v "$tool" || true)"
  if [ "$resolved" != "${DEVKIT_BIN_DIR}/${tool}" ]; then
    log_warn "'${tool}' resolves to ${resolved}, not ${DEVKIT_BIN_DIR}/${tool}."
    log_info "Remove or upgrade that copy, or put ${DEVKIT_BIN_DIR} first on PATH."
  fi
}

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

# -------------------------------------------------------------- minikube ---

core_minikube_label() { echo minikube; }
core_minikube_check() { _core_check minikube "$DEVKIT_MINIKUBE_MIN_VERSION"; }
core_minikube_configure() { :; }

core_minikube_install() {
  _core_check minikube "$DEVKIT_MINIKUBE_MIN_VERSION" && return 0
  _core_install_binary minikube \
    "https://storage.googleapis.com/minikube/releases/${DEVKIT_MINIKUBE_VERSION}/minikube-$(os_download_name)-${DEVKIT_ARCH}"
}

# --------------------------------------------------------------- kubectl ---

core_kubectl_label() { echo kubectl; }
core_kubectl_check() { _core_check kubectl "$DEVKIT_KUBECTL_MIN_VERSION"; }
core_kubectl_configure() { :; }

core_kubectl_install() {
  _core_check kubectl "$DEVKIT_KUBECTL_MIN_VERSION" && return 0
  _core_install_binary kubectl \
    "https://dl.k8s.io/release/${DEVKIT_KUBECTL_VERSION}/bin/$(os_download_name)/${DEVKIT_ARCH}/kubectl"
}

# ------------------------------------------------------------------ helm ---

core_helm_label() { echo helm; }
core_helm_check() { _core_check helm "$DEVKIT_HELM_MIN_VERSION"; }
core_helm_configure() { :; }

core_helm_install() {
  _core_check helm "$DEVKIT_HELM_MIN_VERSION" && return 0
  local platform tmp url
  platform="$(os_download_name)-${DEVKIT_ARCH}"
  url="https://get.helm.sh/helm-${DEVKIT_HELM_VERSION}-${platform}.tar.gz"
  tmp="$(mktemp -d)"
  log_info "Downloading ${url}"
  download "$url" "${tmp}/helm.tar.gz" || { rm -rf "$tmp"; die "Download failed: $url"; }
  verify_sha256 "${tmp}/helm.tar.gz" "${url}.sha256sum" || { rm -rf "$tmp"; die "Checksum verification failed for helm."; }
  tar -xzf "${tmp}/helm.tar.gz" -C "$tmp"
  install_binary "${tmp}/${platform}/helm" "$DEVKIT_BIN_DIR" helm
  rm -rf "$tmp"
  _core_ensure_bin_on_path
  _core_assert_resolves helm
}
