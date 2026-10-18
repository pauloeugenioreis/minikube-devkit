#!/usr/bin/env bash
# Literal ${...} strings and variables read indirectly are intended here.
# shellcheck disable=SC2016,SC2034,SC2153
# Offline unit tests for the Bash implementation (no cluster, no network).
# Run: bash tests/unit/unix.sh   (or ./devkit.sh test unit)
set -uo pipefail

DEVKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Isolate state and config writes from the real project.
export NO_COLOR=1
for lib in common prompt pkg state; do
  # shellcheck source=/dev/null
  . "${DEVKIT_ROOT}/scripts/unix/lib/${lib}.sh"
done
for f in deps/deps deps/core deps/drivers/drivers cluster/cluster cluster/components cluster/forward; do
  # shellcheck source=/dev/null
  . "${DEVKIT_ROOT}/scripts/unix/${f}.sh"
done
DEVKIT_STATE_DIR="${TMP}/state"
_STATE_FILE="${DEVKIT_STATE_DIR}/state"
detect_os
config_load

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL: %s\n' "$*"; }
assert_eq() { if [ "$1" = "$2" ]; then pass; else fail "$3 (expected [$2], got [$1])"; fi; }
# Subshells: a failing command may call "die", which exits.
assert_ok() { if ("$@") >/dev/null 2>&1; then pass; else fail "expected success: $*"; fi; }
assert_fail() { if ("$@") >/dev/null 2>&1; then fail "expected failure: $*"; else pass; fi; }

# ------------------------------------------------------- driver contract ---
# Every driver offered on any OS/arch has a module defining the 4 functions.
for os in linux macos; do
  for arch in amd64 arm64; do
    for driver in $(DEVKIT_OS=$os DEVKIT_ARCH=$arch drivers_supported | cut -d'|' -f1); do
      file="${DEVKIT_ROOT}/scripts/unix/deps/drivers/${driver}.sh"
      if [ ! -f "$file" ]; then fail "driver ${driver} (${os}/${arch}) has no module"; continue; fi
      for fn in label check install configure; do
        if (. "$file"; declare -F "driver_${driver}_${fn}" >/dev/null); then pass; else fail "driver ${driver} lacks driver_${driver}_${fn}"; fi
      done
    done
  done
done
for id in $CORE_DEPS; do
  for fn in label check install configure; do
    if declare -F "${id}_${fn}" >/dev/null; then pass; else fail "${id} lacks ${id}_${fn}"; fi
  done
done

# --------------------------------------------------------------- versions ---
assert_ok   ver_ge v1.38.1 v1.34.0
assert_fail ver_ge 1.9.0 1.10.0
assert_ok   ver_ge v3.20.1+gabc v3.12.0
assert_ok   ver_ge v1.30.0-rc.1 v1.30.0
assert_fail ver_ge 2.0 2.0.1
assert_eq "$(pkg_pretty_version '5:29.9.1-1~ubuntu.26.04~resolute')" 29.9.1 'pkg_pretty_version'

# ----------------------------------------------------------------- config ---
cfg="${TMP}/cfg.env"
printf '# comment\nDEVKIT_A=plain\r\nDEVKIT_B="quoted value"\nDEVKIT_C=x=y#z\nnot valid\nDEVKIT_ENVWINS=file\n' > "$cfg"
_DEVKIT_ENV_OVERRIDES=' DEVKIT_ENVWINS '
DEVKIT_ENVWINS='env'
_config_load_file "$cfg" 2>/dev/null
assert_eq "$DEVKIT_A" plain 'config: CRLF is stripped'
assert_eq "$DEVKIT_B" 'quoted value' 'config: quotes are removed'
assert_eq "$DEVKIT_C" 'x=y#z' 'config: value keeps = and #'
assert_eq "$DEVKIT_ENVWINS" env 'config: environment wins over the file'

DEVKIT_CONFIG_FILE="${TMP}/save.env"
printf '# header\nDEVKIT_X=1\nDEVKIT_Y=2\n' > "$DEVKIT_CONFIG_FILE"
config_save DEVKIT_X 'p\a&ss=#1'
config_save DEVKIT_NEW new
assert_eq "$(sed -n 2p "$DEVKIT_CONFIG_FILE")" 'DEVKIT_X=p\a&ss=#1' 'config_save: updates in place'
assert_eq "$(sed -n 1p "$DEVKIT_CONFIG_FILE")" '# header' 'config_save: keeps comments'
assert_eq "$(tail -n 1 "$DEVKIT_CONFIG_FILE")" 'DEVKIT_NEW=new' 'config_save: appends new keys'

# -------------------------------------------------------------- templates ---
tpl="${TMP}/tpl.txt"
printf 'a=${DEVKIT_T1} b=${DEVKIT_T2}${DEVKIT_T1} keep=$HOME $(X) ${OTHER}\n' > "$tpl"
DEVKIT_T1='p&a\ss/${x}'; DEVKIT_T2='*?[]'
assert_eq "$(render_template "$tpl")" 'a=p&a\ss/${x} b=*?[]p&a\ss/${x} keep=$HOME $(X) ${OTHER}' 'render_template: literal values'
printf 'x=${DEVKIT_UNDEFINED_KEY}\n' > "$tpl"
assert_fail render_template "$tpl"

# Every shipped template renders with the shipped configuration.
DEVKIT_PRODUCER_NAME=test DEVKIT_PRODUCER_MODE=redis-produce DEVKIT_PRODUCER_COUNT=1
for t in "${DEVKIT_ROOT}"/k8s/*.yaml "${DEVKIT_ROOT}"/k8s/*/*.yaml "${DEVKIT_ROOT}"/k8s/*/*.env \
         "${DEVKIT_ROOT}"/examples/k8s/*.yaml "${DEVKIT_ROOT}"/examples/k8s/*.env; do
  if (render_template "$t" >/dev/null 2>&1); then pass; else fail "template does not render: ${t#"$DEVKIT_ROOT"/}"; fi
done

# Every data service ships its manifest, credentials and in-pod commands.
while IFS='|' read -r id _ _; do
  for f in manifest.yaml credentials.env shell.sh smoke.sh; do
    if [ -f "${DEVKIT_ROOT}/k8s/${id}/${f}" ]; then pass; else fail "k8s/${id}/${f} is missing"; fi
  done
done <<EOF
$DATA_SERVICES
EOF

# ------------------------------------------------------------------ state ---
state_list_add INSTALLED_BINS '/opt/my tools/kubectl'
state_list_add INSTALLED_BINS /usr/local/bin/helm
state_list_add INSTALLED_BINS '/opt/my tools/kubectl'
assert_eq "$(state_list INSTALLED_BINS | wc -l | tr -d ' ')" 2 'state_list_add: no duplicates'
assert_eq "$(state_list INSTALLED_BINS | head -n 1)" '/opt/my tools/kubectl' 'state_list: keeps spaces'

# ------------------------------------------------------------------- misc ---
assert_eq "$(_component_key dashboard)" DEVKIT_INSTALL_DASHBOARD '_component_key dashboard'
assert_eq "$(_component_key postgresql)" DEVKIT_INSTALL_POSTGRESQL '_component_key postgresql'
assert_eq "$(DEVKIT_OS=macos DEVKIT_ARCH=arm64 drivers_supported | cut -d'|' -f1 | grep -c virtualbox)" 0 'no virtualbox on Apple Silicon'

printf '\n  %d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
