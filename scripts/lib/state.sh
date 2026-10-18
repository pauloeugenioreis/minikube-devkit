#!/usr/bin/env bash
# Persistent run state, used to resume after steps that need a re-login or
# a reboot (e.g. joining the docker group). Stored in .devkit/state.

_STATE_FILE="${DEVKIT_STATE_DIR}/state"

state_get() {
  [ -f "$_STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$_STATE_FILE" | tail -n 1
}

state_set() {
  local tmp
  mkdir -p "$DEVKIT_STATE_DIR"
  tmp="$(mktemp)"
  if [ -f "$_STATE_FILE" ]; then
    grep -v "^$1=" "$_STATE_FILE" > "$tmp" || true
  fi
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  mv "$tmp" "$_STATE_FILE"
}

state_unset() {
  local tmp
  [ -f "$_STATE_FILE" ] || return 0
  tmp="$(mktemp)"
  grep -v "^$1=" "$_STATE_FILE" > "$tmp" || true
  mv "$tmp" "$_STATE_FILE"
}

# state_set_pending ACTION(relogin|reboot) REASON
state_set_pending() {
  state_set PENDING_ACTION "$1"
  state_set PENDING_REASON "$2"
}

# Reports a pending action left by a previous run and clears it; the checks
# that follow are idempotent and will detect whether it was really completed.
state_resume() {
  local action reason
  action="$(state_get PENDING_ACTION)"
  [ -n "$action" ] || return 0
  reason="$(state_get PENDING_REASON)"
  log_step "Resuming previous setup"
  log_info "The last run required a ${action}: ${reason}"
  state_unset PENDING_ACTION
  state_unset PENDING_REASON
}

# Prints instructions for a pending action and exits with DEVKIT_EXIT_PENDING.
exit_pending() {
  local action="$1" reason="$2"
  state_set_pending "$action" "$reason"
  printf '\n'
  log_warn "$reason"
  if [ "$action" = reboot ]; then
    log_info "Reboot your computer, then run the same command again to continue."
  else
    log_info "Log out and back in (or open a new login session), then run the same command again."
  fi
  exit "$DEVKIT_EXIT_PENDING"
}
