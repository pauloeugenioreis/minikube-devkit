#!/usr/bin/env bash
# devkit doctor: read-only diagnostics. Never installs or changes anything.

_DOCTOR_ERRORS=0
_DOCTOR_WARNINGS=0

_doctor_fail() { log_error "$*"; _DOCTOR_ERRORS=$((_DOCTOR_ERRORS + 1)); }
_doctor_warn() { log_warn "$*"; _DOCTOR_WARNINGS=$((_DOCTOR_WARNINGS + 1)); }

# Prints "label|port" for every enabled component.
_doctor_ports() {
  is_true "$DEVKIT_INSTALL_DASHBOARD" && echo "Kubernetes Dashboard|${DEVKIT_PORT_DASHBOARD}"
  if is_true "$DEVKIT_INSTALL_RABBITMQ"; then
    echo "RabbitMQ Management|${DEVKIT_PORT_RABBITMQ_MGMT}"
    echo "RabbitMQ AMQP|${DEVKIT_PORT_RABBITMQ_AMQP}"
  fi
  is_true "$DEVKIT_INSTALL_MONGODB" && echo "MongoDB|${DEVKIT_PORT_MONGODB}"
  is_true "$DEVKIT_INSTALL_POSTGRESQL" && echo "PostgreSQL|${DEVKIT_PORT_POSTGRESQL}"
  is_true "$DEVKIT_INSTALL_MYSQL" && echo "MySQL|${DEVKIT_PORT_MYSQL}"
  is_true "$DEVKIT_INSTALL_REDIS" && echo "Redis|${DEVKIT_PORT_REDIS}"
  return 0
}

cmd_doctor() {
  local cpus memory_mb disk_gb docker_cpus docker_mem_mb entry label port url errors_before key

  while [ $# -gt 0 ]; do
    case "$1" in
      --driver) [ $# -ge 2 ] || die "--driver needs a value"; DEVKIT_DRIVER="$2"; shift ;;
      -h|--help) echo "Usage: devkit doctor [--driver NAME]"; return 0 ;;
      *) die "Unknown option for doctor: $1" ;;
    esac
    shift
  done
  driver_load "$DEVKIT_DRIVER"

  cpus="$(host_cpus)"
  memory_mb="$(host_memory_mb)"
  disk_gb="$(free_disk_gb "${MINIKUBE_HOME:-$HOME}")"

  log_step "System"
  log_info "OS:        ${DEVKIT_DISTRO_NAME:-$DEVKIT_OS} (${DEVKIT_ARCH})$([ "$DEVKIT_IS_WSL" = 1 ] && echo ', WSL')"
  log_info "CPUs:      ${cpus}"
  log_info "Memory:    ${memory_mb} MB"
  log_info "Free disk: ${disk_gb} GB (${MINIKUBE_HOME:-$HOME})"
  log_info "Driver:    ${DEVKIT_DRIVER}"
  if [ "$(id -u)" -eq 0 ]; then
    _doctor_fail "Running as root. Run devkit as a regular user; it uses sudo only when needed."
  fi

  log_step "Prerequisites"
  # shellcheck disable=SC2086
  if ! dep_report $CORE_DEPS "driver_${DEVKIT_DRIVER}"; then
    _DOCTOR_ERRORS=$((_DOCTOR_ERRORS + 1))
    log_info "Run './devkit.sh install-prereqs' to install or fix them."
  fi

  log_step "Resources (requested: ${DEVKIT_CPUS} CPUs, ${DEVKIT_MEMORY_MB} MB RAM, ${DEVKIT_DISK_GB} GB disk)"
  errors_before=$_DOCTOR_ERRORS
  for key in DEVKIT_CPUS DEVKIT_MEMORY_MB DEVKIT_DISK_GB; do
    is_int "${!key}" || die "${key} must be a whole number (got '${!key}')"
  done
  [ "$DEVKIT_CPUS" -ge "$DEVKIT_MIN_CPUS" ] || _doctor_fail "CPUs below the minimum of ${DEVKIT_MIN_CPUS}"
  [ "$DEVKIT_CPUS" -le "$cpus" ] || _doctor_fail "Requested ${DEVKIT_CPUS} CPUs but the host has ${cpus}"
  [ "$DEVKIT_MEMORY_MB" -ge "$DEVKIT_MIN_MEMORY_MB" ] || _doctor_fail "Memory below the minimum of ${DEVKIT_MIN_MEMORY_MB} MB"
  if [ "$DEVKIT_MEMORY_MB" -gt "$memory_mb" ]; then
    _doctor_fail "Requested ${DEVKIT_MEMORY_MB} MB but the host has ${memory_mb} MB"
  elif [ "$DEVKIT_MEMORY_MB" -gt $((memory_mb * 3 / 4)) ]; then
    _doctor_warn "Requested memory is more than 75% of the host memory"
  fi
  [ "$DEVKIT_DISK_GB" -ge "$DEVKIT_MIN_DISK_GB" ] || _doctor_fail "Disk below the minimum of ${DEVKIT_MIN_DISK_GB} GB"
  [ "$DEVKIT_DISK_GB" -le "$disk_gb" ] || _doctor_fail "Requested ${DEVKIT_DISK_GB} GB disk but only ${disk_gb} GB are free"

  # With the docker driver the node is limited by what the daemon can use,
  # which on macOS is the Docker Desktop / Colima VM size.
  if [ "$DEVKIT_DRIVER" = docker ] && docker info >/dev/null 2>&1; then
    docker_cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null)"
    docker_mem_mb=$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null) / 1024 / 1024 ))
    log_info "Docker can use ${docker_cpus} CPUs and ${docker_mem_mb} MB RAM"
    [ "$DEVKIT_CPUS" -le "$docker_cpus" ] \
      || _doctor_fail "Docker only has ${docker_cpus} CPUs available; increase it in Docker Desktop/Colima settings"
    [ "$DEVKIT_MEMORY_MB" -le "$docker_mem_mb" ] \
      || _doctor_fail "Docker only has ${docker_mem_mb} MB RAM available; increase it in Docker Desktop/Colima settings"
  fi
  [ "$_DOCTOR_ERRORS" -eq "$errors_before" ] && log_ok "Resources look fine"

  log_step "Local ports"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    label="${entry%|*}"; port="${entry#*|}"
    if port_in_use "$port"; then
      _doctor_warn "$(printf '%-22s %s is already in use' "$label" "$port")"
    else
      log_ok "$(printf '%-22s %s is free' "$label" "$port")"
    fi
  done <<EOF
$(_doctor_ports)
EOF

  log_step "Network"
  for url in https://storage.googleapis.com https://dl.k8s.io https://get.helm.sh https://registry-1.docker.io/v2/; do
    if has_cmd curl && url_reachable "$url"; then
      log_ok "$url"
    else
      _doctor_fail "$url is not reachable"
    fi
  done

  printf '\n'
  if [ "$_DOCTOR_ERRORS" -gt 0 ]; then
    log_error "${_DOCTOR_ERRORS} problem(s), ${_DOCTOR_WARNINGS} warning(s)."
    return 1
  fi
  log_ok "No problems found (${_DOCTOR_WARNINGS} warning(s))."
}
