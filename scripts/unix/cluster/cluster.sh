#!/usr/bin/env bash
# Minikube cluster lifecycle: create/start/recreate the profile and enable addons.

kube() { kubectl --context "$DEVKIT_PROFILE" "$@"; }

# Replaces every ${DEVKIT_*} placeholder in a template with its config value.
# Other $VARS are left untouched. Unknown DEVKIT_ keys are an error.
render_template() {
  local file="$1" line name value rest token out
  while IFS= read -r line || [ -n "$line" ]; do
    rest="$line"
    while :; do
      case "$rest" in *'${DEVKIT_'*'}'*) ;; *) break ;; esac
      name="${rest#*\$\{}"
      name="${name%%\}*}"
      if ! printf '%s' "$name" | grep -Eq '^DEVKIT_[A-Z0-9_]+$'; then
        break
      fi
      if [ -z "${!name+x}" ]; then
        die "Template ${file#"$DEVKIT_ROOT"/} uses \${${name}}, which is not defined in config/devkit.env"
      fi
      value="${!name}"
      # Splits around each occurrence instead of ${line//pat/rep}: bash 3.2
      # (macOS) keeps quotes in the replacement literally, while bash >= 5.2
      # needs them to stop "&" from expanding to the match.
      token="\${${name}}"
      out=''
      while :; do
        case "$line" in *"$token"*) ;; *) break ;; esac
        out="${out}${line%%"$token"*}${value}"
        line="${line#*"$token"}"
      done
      line="${out}${line}"
      rest="${rest#*\$\{"${name}"\}}"
    done
    printf '%s\n' "$line"
  done < "$file"
}

# Prints the minikube home directory (same rules as minikube itself).
_minikube_dir() {
  local home="${MINIKUBE_HOME:-}"
  if [ -z "$home" ]; then echo "${HOME}/.minikube"
  elif [ "${home##*/}" = .minikube ]; then echo "$home"
  else echo "${home}/.minikube"
  fi
}

# Reads a numeric/string field from the profile's config.json.
_profile_field() {
  local file field="$1"
  file="$(_minikube_dir)/profiles/${DEVKIT_PROFILE}/config.json"
  [ -f "$file" ] || return 1
  # minikube indents with tabs (older versions used spaces).
  sed -n "s/^[[:space:]]*\"${field}\":[[:space:]]*\"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}[[:space:]]*$/\1/p" "$file" | head -n 1
}

cluster_exists() {
  [ -f "$(_minikube_dir)/profiles/${DEVKIT_PROFILE}/config.json" ]
}

cluster_running() {
  [ "$(minikube status -p "$DEVKIT_PROFILE" --format '{{.Host}}/{{.APIServer}}' 2>/dev/null)" = "Running/Running" ]
}

# Creates the cluster, starts it, or offers to recreate it when the driver
# or resources in config/devkit.env differ from the existing profile.
cluster_ensure() {
  local cur_driver cur_cpus cur_mem cur_disk addons

  log_step "Minikube cluster '${DEVKIT_PROFILE}'"
  if cluster_exists; then
    cur_driver="$(_profile_field Driver)"
    cur_cpus="$(_profile_field CPUs)"
    cur_mem="$(_profile_field Memory)"
    cur_disk="$(_profile_field DiskSize)"
    if [ "$cur_driver" != "$DEVKIT_DRIVER" ] || [ "$cur_cpus" != "$DEVKIT_CPUS" ] \
      || [ "$cur_mem" != "$DEVKIT_MEMORY_MB" ] || [ "$cur_disk" != "$((DEVKIT_DISK_GB * 1024))" ]; then
      log_warn "The existing cluster uses: ${cur_driver}, ${cur_cpus} CPUs, ${cur_mem} MB RAM, $((cur_disk / 1024)) GB disk."
      log_info "Requested:                 ${DEVKIT_DRIVER}, ${DEVKIT_CPUS} CPUs, ${DEVKIT_MEMORY_MB} MB RAM, ${DEVKIT_DISK_GB} GB disk."
      if ask_yes_no "Recreate cluster to apply new resources? Data will be lost" N; then
        forward_stop_all
        run minikube delete -p "$DEVKIT_PROFILE"
      else
        log_info "Keeping the existing cluster and its current resources."
      fi
    fi
  fi

  if cluster_exists; then
    if cluster_running; then
      log_ok "Cluster is running"
    else
      log_info "Starting the existing cluster"
      run_tty minikube start -p "$DEVKIT_PROFILE" || die "minikube start failed. See: minikube logs -p ${DEVKIT_PROFILE}"
    fi
  else
    log_info "Creating the cluster (${DEVKIT_DRIVER}, ${DEVKIT_CPUS} CPUs, ${DEVKIT_MEMORY_MB} MB RAM, ${DEVKIT_DISK_GB} GB disk)"
    run_tty minikube start -p "$DEVKIT_PROFILE" \
      --driver="$DEVKIT_DRIVER" \
      --cpus="$DEVKIT_CPUS" \
      --memory="$DEVKIT_MEMORY_MB" \
      --disk-size="${DEVKIT_DISK_GB}g" \
      --kubernetes-version="$DEVKIT_KUBERNETES_VERSION" \
      || die "minikube start failed. See: minikube logs -p ${DEVKIT_PROFILE}"
  fi

  # metrics-server feeds the HPA that KEDA drives and the Dashboard graphs.
  addons='metrics-server'
  is_true "$DEVKIT_INSTALL_DASHBOARD" && addons="${addons} dashboard"
  for addon in $addons; do
    run minikube addons enable "$addon" -p "$DEVKIT_PROFILE" >/dev/null \
      || die "Could not enable the ${addon} addon."
    log_ok "Addon ${addon} enabled"
  done
}

# Fails with a hint unless the devkit cluster exists and is running.
require_cluster_running() {
  if ! cluster_exists || ! cluster_running; then
    die "Cluster '${DEVKIT_PROFILE}' is not running. Start it with: ./devkit.sh up"
  fi
}

cluster_stop() {
  if cluster_exists && cluster_running; then
    run minikube stop -p "$DEVKIT_PROFILE"
  else
    log_info "Cluster '${DEVKIT_PROFILE}' is not running."
  fi
}

cluster_delete() {
  if cluster_exists; then
    run minikube delete -p "$DEVKIT_PROFILE"
  else
    log_info "Cluster '${DEVKIT_PROFILE}' does not exist."
  fi
}
