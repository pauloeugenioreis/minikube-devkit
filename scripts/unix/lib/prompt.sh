#!/usr/bin/env bash
# Interactive prompts. Every prompt falls back to its default answer when the
# session is non-interactive (no TTY, --yes, or DEVKIT_NONINTERACTIVE=1), so
# the same code path works in CI.
# Prompts are written to stderr so functions can return values on stdout.

is_interactive() {
  [ -t 0 ] && ! is_true "${DEVKIT_NONINTERACTIVE:-false}"
}

# ask_yes_no QUESTION DEFAULT(Y|N): succeeds for "yes".
ask_yes_no() {
  local question="$1" default="${2:-Y}" hint answer
  if [ "$default" = Y ]; then hint='[Y/n]'; else hint='[y/N]'; fi

  if ! is_interactive; then
    printf '%s %s: %s (default)\n' "$question" "$hint" "$default" >&2
    [ "$default" = Y ]
    return
  fi

  while :; do
    printf '%s %s: ' "$question" "$hint" >&2
    IFS= read -r answer || answer=''
    log_answer "${answer:-(Enter)}"
    case "${answer:-$default}" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      *) printf '  Please answer y or n.\n' >&2 ;;
    esac
  done
}

# ask_value LABEL DEFAULT [VALIDATOR]: prints the chosen value on stdout.
# VALIDATOR is a function name that receives the value and returns non-zero
# (printing its own message to stderr) when the value is invalid.
ask_value() {
  local label="$1" default="$2" validator="${3:-}" answer
  while :; do
    if is_interactive; then
      printf '  %s [%s]: ' "$label" "$default" >&2
      IFS= read -r answer || answer=''
      log_answer "${answer:-(Enter)}"
      answer="${answer:-$default}"
    else
      answer="$default"
    fi
    if [ -z "$validator" ] || "$validator" "$answer"; then
      printf '%s\n' "$answer"
      return 0
    fi
    is_interactive || return 1
  done
}

# select_option TITLE DEFAULT_VALUE OPTION...: each OPTION is "value|description".
# Prints the selected value on stdout.
select_option() {
  local title="$1" default="$2" i=1 default_index=1 option value answer
  shift 2

  for option in "$@"; do
    [ "${option%%|*}" = "$default" ] && default_index=$i
    i=$((i + 1))
  done

  if ! is_interactive; then
    printf '%s %s (default)\n' "$title" "$default" >&2
    printf '%s\n' "$default"
    return 0
  fi

  printf '%s\n' "$title" >&2
  i=1
  for option in "$@"; do
    value="${option%%|*}"
    if [ "$i" -eq "$default_index" ]; then
      printf '  %d) %-12s %s (default)\n' "$i" "$value" "${option#*|}" >&2
    else
      printf '  %d) %-12s %s\n' "$i" "$value" "${option#*|}" >&2
    fi
    i=$((i + 1))
  done

  while :; do
    printf 'Choice [%d]: ' "$default_index" >&2
    IFS= read -r answer || answer=''
    log_answer "${answer:-(Enter)}"
    answer="${answer:-$default_index}"
    case "$answer" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$answer" -ge 1 ] && [ "$answer" -le $# ]; then
          eval "option=\${$answer}"
          printf '%s\n' "${option%%|*}"
          return 0
        fi
        ;;
    esac
    printf '  Please enter a number between 1 and %d.\n' $# >&2
  done
}
