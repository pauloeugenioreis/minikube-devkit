#!/usr/bin/env bash
# devkit up: wizard -> prerequisites -> (cluster and components).

# With the docker driver the node cannot be larger than what the Docker daemon
# can use (on macOS that is the Docker Desktop / Colima VM). When the request
# does not fit, offer to shrink it to the largest size that does.
_up_fit_docker_resources() {
  local docker_cpus docker_mem_mb fit_mem_mb
  [ "$DEVKIT_DRIVER" = docker ] || return 0

  docker_cpus="$(docker info --format '{{.NCPU}}' 2>/dev/null)" || return 0
  docker_mem_mb=$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null) / 1024 / 1024 ))
  # Leave room for the Docker VM itself and round down to 256 MB.
  fit_mem_mb=$(( (docker_mem_mb - 512) / 256 * 256 ))

  if [ "$DEVKIT_CPUS" -gt "$docker_cpus" ]; then
    log_warn "Docker can use only ${docker_cpus} CPUs, but ${DEVKIT_CPUS} were requested."
    [ "$docker_cpus" -ge "$DEVKIT_MIN_CPUS" ] \
      || die "Give Docker at least ${DEVKIT_MIN_CPUS} CPUs in Docker Desktop/Colima settings and retry."
    ask_yes_no "Use ${docker_cpus} CPUs instead?" Y \
      || die "Increase the CPUs available to Docker (Docker Desktop/Colima settings) and retry."
    config_save DEVKIT_CPUS "$docker_cpus"
  fi

  if [ "$DEVKIT_MEMORY_MB" -gt "$fit_mem_mb" ]; then
    log_warn "Docker can use only ${docker_mem_mb} MB, but ${DEVKIT_MEMORY_MB} MB were requested."
    [ "$fit_mem_mb" -ge "$DEVKIT_MIN_MEMORY_MB" ] \
      || die "Give Docker at least $((DEVKIT_MIN_MEMORY_MB + 512)) MB in Docker Desktop/Colima settings and retry."
    ask_yes_no "Use ${fit_mem_mb} MB instead?" Y \
      || die "Increase the memory available to Docker (Docker Desktop/Colima settings) and retry."
    config_save DEVKIT_MEMORY_MB "$fit_mem_mb"
  fi
}

cmd_up() {
  local rc=0
  wizard_parse_args "Usage: devkit up [options]

Runs the setup wizard, installs missing prerequisites and starts the environment.

Options:
${WIZARD_FLAGS_HELP}" "$@" || rc=$?
  [ "$rc" = 2 ] && return 0

  [ "$(id -u)" -ne 0 ] || die "Do not run devkit as root; it uses sudo only for the steps that need it."
  state_resume
  wizard_run
  driver_load "$DEVKIT_DRIVER"

  # shellcheck disable=SC2086
  dep_ensure $CORE_DEPS "driver_${DEVKIT_DRIVER}"
  _up_fit_docker_resources

  printf '\n'
  log_ok "Prerequisites ready for: ${DEVKIT_DRIVER}, ${DEVKIT_CPUS} CPUs, ${DEVKIT_MEMORY_MB} MB RAM, ${DEVKIT_DISK_GB} GB disk."
  log_warn "Cluster and component provisioning is not implemented yet (next phase)."
}
