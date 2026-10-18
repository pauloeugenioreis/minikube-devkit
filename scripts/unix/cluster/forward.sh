#!/usr/bin/env bash
# Background port-forwards. Each forward runs "kubectl port-forward" in a
# restart loop (pods restart, connections drop). PID and local port are kept
# in .devkit/forwards/<name>.{pid,port}; output goes to log/port-forward-<name>.log.

_FORWARD_DIR="${DEVKIT_STATE_DIR}/forwards"

# "name|component|namespace|service|remote port|local port key"
_forward_specs() {
  cat <<EOF
dashboard|dashboard|kubernetes-dashboard|kubernetes-dashboard|80|DEVKIT_PORT_DASHBOARD
rabbitmq-mgmt|rabbitmq|${DEVKIT_NAMESPACE}|rabbitmq|15672|DEVKIT_PORT_RABBITMQ_MGMT
rabbitmq-amqp|rabbitmq|${DEVKIT_NAMESPACE}|rabbitmq|5672|DEVKIT_PORT_RABBITMQ_AMQP
mongodb|mongodb|${DEVKIT_NAMESPACE}|mongodb|27017|DEVKIT_PORT_MONGODB
postgresql|postgresql|${DEVKIT_NAMESPACE}|postgresql|5432|DEVKIT_PORT_POSTGRESQL
mysql|mysql|${DEVKIT_NAMESPACE}|mysql|3306|DEVKIT_PORT_MYSQL
redis|redis|${DEVKIT_NAMESPACE}|redis|6379|DEVKIT_PORT_REDIS
EOF
}

_component_key() {
  case "$1" in
    dashboard) echo DEVKIT_INSTALL_DASHBOARD ;;
    *) printf 'DEVKIT_INSTALL_%s\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" ;;
  esac
}

_pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

forward_pid() { cat "${_FORWARD_DIR}/$1.pid" 2>/dev/null || true; }

# Local port actually used by a forward (may differ from the configured one
# when that port was busy).
forward_port() {
  local name="$1" key="$2" port
  port="$(cat "${_FORWARD_DIR}/${name}.port" 2>/dev/null || true)"
  echo "${port:-${!key}}"
}

forward_running() { _pid_alive "$(forward_pid "$1")"; }

_forward_start_one() {
  local name="$1" ns="$2" svc="$3" remote="$4" port="$5" try pid log
  log="${DEVKIT_LOG_DIR}/port-forward-${name}.log"
  mkdir -p "$_FORWARD_DIR" "$DEVKIT_LOG_DIR"

  if forward_running "$name"; then
    return 0
  fi

  try="$port"
  while port_in_use "$try"; do
    try=$((try + 1))
    [ "$try" -le $((port + 50)) ] || { log_error "No free local port near ${port} for ${name}."; return 1; }
  done
  [ "$try" = "$port" ] || log_warn "Port ${port} is in use; ${name} will use ${try} instead."

  nohup bash -c '
    while :; do
      kubectl --context "$1" -n "$2" port-forward --address 127.0.0.1 "svc/$3" "$4:$5"
      sleep 2
    done' devkit-forward "$DEVKIT_PROFILE" "$ns" "$svc" "$try" "$remote" \
    >>"$log" 2>&1 &
  pid=$!
  echo "$pid" > "${_FORWARD_DIR}/${name}.pid"
  echo "$try" > "${_FORWARD_DIR}/${name}.port"

  wait_until 20 port_in_use "$try" || log_warn "Port-forward for ${name} is not answering yet (see log/port-forward-${name}.log)."
}

_forward_stop_one() {
  local name="$1" pid children
  pid="$(forward_pid "$name")"
  if _pid_alive "$pid"; then
    # Kill the restart loop first, then the kubectl it spawned.
    children="$(pgrep -P "$pid" 2>/dev/null || true)"
    kill "$pid" 2>/dev/null || true
    # shellcheck disable=SC2086
    [ -z "$children" ] || kill $children 2>/dev/null || true
  fi
  rm -f "${_FORWARD_DIR}/${name}.pid" "${_FORWARD_DIR}/${name}.port"
}

# Starts forwards for every installed component.
forward_start_all() {
  local name component ns svc remote key ckey
  while IFS='|' read -r name component ns svc remote key; do
    ckey="$(_component_key "$component")"
    is_true "${!ckey}" || continue
    _forward_start_one "$name" "$ns" "$svc" "$remote" "${!key}" || true
  done <<EOF
$(_forward_specs)
EOF
}

forward_stop_all() {
  local name rest
  while IFS='|' read -r name rest; do
    _forward_stop_one "$name"
  done <<EOF
$(_forward_specs)
EOF
}

forward_status() {
  local name component ns svc remote key port ckey
  while IFS='|' read -r name component ns svc remote key; do
    ckey="$(_component_key "$component")"
    is_true "${!ckey}" || continue
    port="$(forward_port "$name" "$key")"
    if forward_running "$name" && port_in_use "$port"; then
      log_ok "$(printf '%-16s localhost:%s -> %s/%s:%s' "$name" "$port" "$ns" "$svc" "$remote")"
    else
      log_error "$(printf '%-16s not running' "$name")"
    fi
  done <<EOF
$(_forward_specs)
EOF
}
