#!/usr/bin/env bash
# devkit configure: setup wizard. Asks for the driver, the minikube resources
# and the components to install, then saves the answers to config/devkit.env.
# Command-line flags pre-answer questions; with --yes every remaining question
# takes its default, so the same flow works in CI.

# "id|config key|label" for every installable component, in prompt order.
WIZARD_COMPONENTS='dashboard|DEVKIT_INSTALL_DASHBOARD|Kubernetes Dashboard
rabbitmq|DEVKIT_INSTALL_RABBITMQ|RabbitMQ
mongodb|DEVKIT_INSTALL_MONGODB|MongoDB
postgresql|DEVKIT_INSTALL_POSTGRESQL|PostgreSQL
mysql|DEVKIT_INSTALL_MYSQL|MySQL
redis|DEVKIT_INSTALL_REDIS|Redis
keda|DEVKIT_INSTALL_KEDA|KEDA'

# Values given on the command line (empty = ask).
_WZ_DRIVER=''; _WZ_CPUS=''; _WZ_MEMORY=''; _WZ_DISK=''; _WZ_SERVICES=''; _WZ_RECONFIGURE=0

# Parses wizard flags. Prints usage and returns 2 for --help.
wizard_parse_args() {
  local usage="$1"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --driver|--cpus|--memory|--disk|--services)
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --driver) _WZ_DRIVER="$2" ;;
          --cpus) _WZ_CPUS="$2" ;;
          --memory) _WZ_MEMORY="$2" ;;
          --disk) _WZ_DISK="$2" ;;
          --services) _WZ_SERVICES="$2" ;;
        esac
        shift
        ;;
      --reconfigure) _WZ_RECONFIGURE=1 ;;
      -h|--help) echo "$usage"; return 2 ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
}

WIZARD_FLAGS_HELP='  --driver NAME        Minikube driver (asked when omitted)
  --cpus N             CPUs for the minikube node
  --memory MB          Memory for the minikube node, in MB
  --disk GB            Disk size for the minikube node, in GB
  --services LIST      Comma-separated components to install, e.g. postgresql,redis,keda
                       (all | none | dashboard,rabbitmq,mongodb,postgresql,mysql,redis,keda)
  --reconfigure        Ask every question again even if a previous setup was saved'

# ------------------------------------------------------------ validators ---

_wz_validate_cpus() {
  is_int "$1" || { printf '    Please enter a whole number.\n' >&2; return 1; }
  [ "$1" -ge "$DEVKIT_MIN_CPUS" ] || { printf '    Minimum is %s CPUs.\n' "$DEVKIT_MIN_CPUS" >&2; return 1; }
  [ "$1" -le "$_WZ_HOST_CPUS" ] || { printf '    This machine has only %s CPUs.\n' "$_WZ_HOST_CPUS" >&2; return 1; }
}

_wz_validate_memory() {
  is_int "$1" || { printf '    Please enter a whole number of MB (e.g. 8192).\n' >&2; return 1; }
  [ "$1" -ge "$DEVKIT_MIN_MEMORY_MB" ] || { printf '    Minimum is %s MB.\n' "$DEVKIT_MIN_MEMORY_MB" >&2; return 1; }
  [ "$1" -le "$_WZ_HOST_MEMORY_MB" ] || { printf '    This machine has only %s MB.\n' "$_WZ_HOST_MEMORY_MB" >&2; return 1; }
}

_wz_validate_disk() {
  is_int "$1" || { printf '    Please enter a whole number of GB.\n' >&2; return 1; }
  [ "$1" -ge "$DEVKIT_MIN_DISK_GB" ] || { printf '    Minimum is %s GB.\n' "$DEVKIT_MIN_DISK_GB" >&2; return 1; }
  [ "$1" -le "$_WZ_HOST_DISK_GB" ] || { printf '    Only %s GB are free.\n' "$_WZ_HOST_DISK_GB" >&2; return 1; }
}

# ---------------------------------------------------------------- helpers ---

_wz_min() { if [ "$1" -lt "$2" ]; then echo "$1"; else echo "$2"; fi; }
_wz_max() { if [ "$1" -gt "$2" ]; then echo "$1"; else echo "$2"; fi; }

# Default resources: the configured value, capped at half of the host (but
# never below the minimum).
_wz_default_resource() {
  local configured="$1" host="$2" minimum="$3" half
  is_int "$configured" || configured="$minimum"
  half=$(_wz_max $((host / 2)) "$minimum")
  _wz_min "$configured" "$half"
}

_wz_selected_components() {
  local id key label list=''
  while IFS='|' read -r id key label; do
    is_true "${!key}" && list="${list:+${list}, }${id}"
  done <<EOF
$WIZARD_COMPONENTS
EOF
  echo "${list:-none}"
}

# Applies --services to the component flags.
_wz_apply_services() {
  local services="$1" id key label wanted
  case "$services" in
    all) services="$(printf '%s\n' "$WIZARD_COMPONENTS" | cut -d'|' -f1 | tr '\n' ',')" ;;
    none) services='' ;;
  esac
  for wanted in $(printf '%s' "$services" | tr ',' ' '); do
    printf '%s\n' "$WIZARD_COMPONENTS" | cut -d'|' -f1 | grep -qx "$wanted" \
      || die "Unknown component '${wanted}'. Valid: $(printf '%s\n' "$WIZARD_COMPONENTS" | cut -d'|' -f1 | tr '\n' ' ')"
  done
  while IFS='|' read -r id key label; do
    case ",${services}," in
      *",${id},"*) printf -v "$key" '%s' true ;;
      *) printf -v "$key" '%s' false ;;
    esac
  done <<EOF
$WIZARD_COMPONENTS
EOF
}

wizard_show_summary() {
  log_step "Summary"
  log_info "Driver:     ${DEVKIT_DRIVER}"
  log_info "Resources:  ${DEVKIT_CPUS} CPUs, ${DEVKIT_MEMORY_MB} MB RAM, ${DEVKIT_DISK_GB} GB disk"
  log_info "Components: $(_wz_selected_components)"
}

# Saves the wizard answers to config/devkit.env, touching only changed keys.
_wz_save() {
  local key current saved
  for key in DEVKIT_DRIVER DEVKIT_CPUS DEVKIT_MEMORY_MB DEVKIT_DISK_GB \
             $(printf '%s\n' "$WIZARD_COMPONENTS" | cut -d'|' -f2); do
    current="${!key}"
    saved="$(sed -n "s/^${key}=//p" "$DEVKIT_CONFIG_FILE" | tail -n 1)"
    [ "$current" = "$saved" ] || config_save "$key" "$current"
  done
  state_set WIZARD_COMPLETED 1
}

# ------------------------------------------------------------------ wizard ---

# Runs the wizard. Leaves the chosen values in the DEVKIT_* variables and in
# config/devkit.env.
wizard_run() {
  local id key label default answer drivers

  _WZ_HOST_CPUS="$(host_cpus)"
  _WZ_HOST_MEMORY_MB="$(host_memory_mb)"
  _WZ_HOST_DISK_GB="$(free_disk_gb "${MINIKUBE_HOME:-$HOME}")"
  [ "$_WZ_HOST_CPUS" -ge "$DEVKIT_MIN_CPUS" ] \
    || die "This machine has ${_WZ_HOST_CPUS} CPU(s); minikube-devkit needs at least ${DEVKIT_MIN_CPUS}."
  [ "$_WZ_HOST_MEMORY_MB" -ge "$DEVKIT_MIN_MEMORY_MB" ] \
    || die "This machine has ${_WZ_HOST_MEMORY_MB} MB RAM; minikube-devkit needs at least ${DEVKIT_MIN_MEMORY_MB} MB."

  log_step "minikube-devkit setup"

  # A previous run saved its answers: offer to reuse them.
  if [ "$_WZ_RECONFIGURE" = 0 ] && [ "$(state_get WIZARD_COMPLETED)" = 1 ] \
    && [ -z "${_WZ_DRIVER}${_WZ_CPUS}${_WZ_MEMORY}${_WZ_DISK}${_WZ_SERVICES}" ]; then
    wizard_show_summary
    printf '\n'
    if ask_yes_no "Use saved configuration?" Y; then
      driver_is_supported "$DEVKIT_DRIVER" || die "Saved driver '${DEVKIT_DRIVER}' is not supported on this machine. Run with --reconfigure."
      return 0
    fi
    printf '\n'
  fi

  # Driver
  if [ -n "$_WZ_DRIVER" ]; then
    driver_is_supported "$_WZ_DRIVER" \
      || die "Driver '${_WZ_DRIVER}' is not supported on ${DEVKIT_OS}/${DEVKIT_ARCH}. Supported: $(drivers_supported | cut -d'|' -f1 | tr '\n' ' ')"
    DEVKIT_DRIVER="$_WZ_DRIVER"
  else
    default="$DEVKIT_DRIVER"
    driver_is_supported "$default" || default=docker
    drivers="$(drivers_supported)"
    # Split the "value|description" lines on newlines only.
    local IFS=$'\n'
    # shellcheck disable=SC2086
    DEVKIT_DRIVER="$(select_option "Select Minikube driver:" "$default" $drivers)"
    unset IFS
  fi

  # Resources
  printf '\n%s\n' "Minikube resources (host: ${_WZ_HOST_CPUS} CPUs, ${_WZ_HOST_MEMORY_MB} MB RAM, ${_WZ_HOST_DISK_GB} GB free disk)" >&2
  DEVKIT_CPUS="$(ask_value 'CPUs' "${_WZ_CPUS:-$(_wz_default_resource "$DEVKIT_CPUS" "$_WZ_HOST_CPUS" "$DEVKIT_MIN_CPUS")}" _wz_validate_cpus)" \
    || die "Invalid CPUs value: ${_WZ_CPUS}"
  default="$(_wz_default_resource "$DEVKIT_MEMORY_MB" "$_WZ_HOST_MEMORY_MB" "$DEVKIT_MIN_MEMORY_MB")"
  default=$(_wz_max $((default / 256 * 256)) "$DEVKIT_MIN_MEMORY_MB")
  while :; do
    DEVKIT_MEMORY_MB="$(ask_value 'Memory (MB)' "${_WZ_MEMORY:-$default}" _wz_validate_memory)" \
      || die "Invalid memory value: ${_WZ_MEMORY}"
    [ "$DEVKIT_MEMORY_MB" -le $((_WZ_HOST_MEMORY_MB * 3 / 4)) ] && break
    if ! is_interactive; then
      log_warn "${DEVKIT_MEMORY_MB} MB is more than 75% of this machine's memory."
      break
    fi
    ask_yes_no "    ${DEVKIT_MEMORY_MB} MB is more than 75% of this machine's memory and may slow it down. Continue?" N && break
    _WZ_MEMORY=''
  done
  DEVKIT_DISK_GB="$(ask_value 'Disk size (GB)' "${_WZ_DISK:-$(_wz_min "$DEVKIT_DISK_GB" "$_WZ_HOST_DISK_GB")}" _wz_validate_disk)" \
    || die "Invalid disk value: ${_WZ_DISK}"

  # Components
  printf '\n' >&2
  if [ -n "$_WZ_SERVICES" ]; then
    _wz_apply_services "$_WZ_SERVICES"
  else
    # The list is read from fd 3 so the prompts keep reading answers from stdin.
    while IFS='|' read -r id key label <&3; do
      if is_true "${!key}"; then default=Y; else default=N; fi
      if ask_yes_no "$(printf 'Install %-21s' "${label}?")" "$default"; then answer=true; else answer=false; fi
      printf -v "$key" '%s' "$answer"
    done 3<<EOF
$WIZARD_COMPONENTS
EOF
  fi

  wizard_show_summary
  printf '\n'
  ask_yes_no "Proceed?" Y || die "Aborted by user. Nothing was changed."
  _wz_save
}

cmd_configure() {
  local rc=0
  wizard_parse_args "Usage: devkit configure [options]

Options:
${WIZARD_FLAGS_HELP}" "$@" || rc=$?
  [ "$rc" = 2 ] && return 0
  wizard_run
  printf '\n'
  log_ok "Configuration saved to config/devkit.env"
}
