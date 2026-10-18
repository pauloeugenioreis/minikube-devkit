#!/usr/bin/env bash
# Dependency runner. Each dependency ID implements four functions:
#
#   <id>_label      prints a human readable name
#   <id>_check      returns 0 when ready; sets DEP_STATUS to a short message.
#                   Sets DEP_UNFIXABLE=1 when automatic setup cannot help.
#   <id>_install    installs the dependency (no-op when already installed)
#   <id>_configure  configures/starts it; may call exit_pending
#   <id>_update     optional: replaces an older but usable version. <id>_check
#                   signals it by returning 0 with DEP_UPDATE set to the new
#                   version (and DEP_CURRENT to the installed one).
#
# Every function must be idempotent so a run can be repeated or resumed.

DEP_STATUS=''
DEP_UNFIXABLE=0
DEP_CURRENT=''
DEP_UPDATE=''

# Runs <id>_check with fresh status variables.
dep_check() {
  DEP_STATUS=''
  DEP_UNFIXABLE=0
  DEP_CURRENT=''
  DEP_UPDATE=''
  "${1}_check"
}

# dep_report ID...: prints the status of each dependency, returns non-zero if
# any of them is not ready. Sets DEPS_MISSING to the IDs that are not ready.
dep_report() {
  local id label
  DEPS_MISSING=''
  for id in "$@"; do
    label="$("${id}_label")"
    if dep_check "$id"; then
      log_ok "$(printf '%-16s %s' "$label" "$DEP_STATUS")"
    else
      log_error "$(printf '%-16s %s' "$label" "$DEP_STATUS")"
      DEPS_MISSING="${DEPS_MISSING} ${id}"
    fi
  done
  [ -z "$DEPS_MISSING" ]
}

# dep_ensure ID...: checks everything, asks for consent once, then installs
# and configures what is missing and verifies the result. Finally offers to
# update dependencies that have a newer version available.
dep_ensure() {
  log_step "Checking prerequisites"
  dep_report "$@" || _dep_install_missing
  _dep_offer_updates "$@"
}

_dep_install_missing() {
  local id label unfixable=''

  for id in $DEPS_MISSING; do
    dep_check "$id" || true
    [ "$DEP_UNFIXABLE" = 1 ] && unfixable="${unfixable}\n    - $("${id}_label"): ${DEP_STATUS}"
  done
  if [ -n "$unfixable" ]; then
    # shellcheck disable=SC2059
    die "$(printf "These problems cannot be fixed automatically:${unfixable}")"
  fi

  log_step "The following will be installed or configured"
  for id in $DEPS_MISSING; do
    dep_check "$id" || true
    log_info "- $("${id}_label") (${DEP_STATUS})"
  done
  printf '\n'
  ask_yes_no "Proceed?" Y || die "Aborted by user."

  for id in $DEPS_MISSING; do
    label="$("${id}_label")"
    log_step "Setting up ${label}"
    "${id}_install"
    "${id}_configure"
    if dep_check "$id"; then
      log_ok "${label}: ${DEP_STATUS}"
    else
      die "${label} is still not ready: ${DEP_STATUS}"
    fi
  done
}

# Asks, per dependency, whether to update an older installed version.
_dep_offer_updates() {
  local id label current target
  for id in "$@"; do
    declare -F "${id}_update" >/dev/null || continue
    dep_check "$id" || continue
    [ -n "$DEP_UPDATE" ] || continue
    label="$("${id}_label")"; current="$DEP_CURRENT"; target="$DEP_UPDATE"
    printf '\n'
    if ask_yes_no "Update ${label} ${current} to the latest ${target}?" Y; then
      log_step "Updating ${label} to ${target}"
      "${id}_update"
      "${id}_configure"
      dep_check "$id" || die "${label} is not ready after the update: ${DEP_STATUS}"
      log_ok "${label}: ${DEP_STATUS}"
    else
      log_info "Keeping ${label} ${current}."
    fi
  done
}
