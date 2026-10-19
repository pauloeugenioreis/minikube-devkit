#!/usr/bin/env bash
# Access table: URLs and credentials of every installed component.

_ACCESS_ROWS=''
_ACCESS_NOT_READY=''

# _access_add LABEL URL CREDENTIALS COMPONENT [FORWARD_NAME PORT]
_access_add() {
  local label="$1" url="$2" creds="$3" component="$4" forward="${5:-}" port="${6:-}"
  if ! component_ready "$component" || { [ -n "$forward" ] && ! port_in_use "$port"; }; then
    url='NOT READY'
    creds='-'
    _ACCESS_NOT_READY="${_ACCESS_NOT_READY} ${component}"
  fi
  _ACCESS_ROWS="${_ACCESS_ROWS}${label}|${url}|${creds}
"
}

_access_border() {
  printf '+-%s-+-%s-+-%s-+\n' "$(printf '%*s' "$1" '' | tr ' ' '-')" \
    "$(printf '%*s' "$2" '' | tr ' ' '-')" "$(printf '%*s' "$3" '' | tr ' ' '-')"
}

# _access_table_rows W1 W2 W3: the rows as a bordered table.
_access_table_rows() {
  local w1="$1" w2="$2" w3="$3" label url creds
  _access_border "$w1" "$w2" "$w3"
  printf '| %-*s | %-*s | %-*s |\n' "$w1" Resource "$w2" 'URL / Endpoint' "$w3" Credentials
  _access_border "$w1" "$w2" "$w3"
  while IFS='|' read -r label url creds; do
    [ -n "$label" ] || continue
    printf '| %-*s | %-*s | %-*s |\n' "$w1" "$label" "$w2" "$url" "$w3" "$creds"
  done <<EOF
$_ACCESS_ROWS
EOF
  _access_border "$w1" "$w2" "$w3"
}

# The rows as one block per resource, for terminals narrower than the table.
_access_list() {
  local label url creds
  while IFS='|' read -r label url creds; do
    [ -n "$label" ] || continue
    printf '\n  %s%s%s\n' "$_C_BOLD" "$label" "$_C_RESET"
    printf '    %-13s %s\n' 'URL:' "$url"
    [ "$creds" = '-' ] || printf '    %-13s %s\n' 'Credentials:' "$creds"
  done <<EOF
$_ACCESS_ROWS
EOF
}

# Width of the terminal on stdout (0 when unknown, e.g. output is piped).
_access_term_cols() {
  local cols=''
  # While the run is logged, stdout is a pipe but the terminal is still there.
  if [ -t 1 ] || [ "${DEVKIT_TTY_OUT:-0}" = 1 ]; then
    cols="$(stty size </dev/tty 2>/dev/null | cut -d' ' -f2)"
  fi
  [ -n "$cols" ] || cols="${COLUMNS:-0}"
  if is_int "$cols"; then printf '%s\n' "$cols"; else printf '0\n'; fi
}

# access_table [--no-secrets]
access_table() {
  local hide=0 p label url creds cols w1=8 w2=14 w3=11
  [ "${1:-}" = --no-secrets ] && hide=1
  # mask VALUE: prints **** instead of the value with --no-secrets.
  secret() { if [ "$hide" = 1 ]; then printf '****'; else printf '%s' "$1"; fi; }

  _ACCESS_ROWS=''
  _ACCESS_NOT_READY=''

  if is_true "$DEVKIT_INSTALL_DASHBOARD"; then
    p="$(forward_port dashboard DEVKIT_PORT_DASHBOARD)"
    _access_add 'Kubernetes Dashboard' "http://localhost:${p}" '(no login)' dashboard dashboard "$p"
  fi
  if is_true "$DEVKIT_INSTALL_RABBITMQ"; then
    p="$(forward_port rabbitmq-mgmt DEVKIT_PORT_RABBITMQ_MGMT)"
    _access_add 'RabbitMQ Management' "http://localhost:${p}" \
      "${DEVKIT_RABBITMQ_USER} / $(secret "$DEVKIT_RABBITMQ_PASSWORD")" rabbitmq rabbitmq-mgmt "$p"
    p="$(forward_port rabbitmq-amqp DEVKIT_PORT_RABBITMQ_AMQP)"
    _access_add 'RabbitMQ AMQP' "amqp://${DEVKIT_RABBITMQ_USER}:$(secret "$DEVKIT_RABBITMQ_PASSWORD")@localhost:${p}/" \
      "${DEVKIT_RABBITMQ_USER} / $(secret "$DEVKIT_RABBITMQ_PASSWORD")" rabbitmq rabbitmq-amqp "$p"
  fi
  if is_true "$DEVKIT_INSTALL_MONGODB"; then
    p="$(forward_port mongodb DEVKIT_PORT_MONGODB)"
    _access_add 'MongoDB' "mongodb://${DEVKIT_MONGODB_USER}:$(secret "$DEVKIT_MONGODB_PASSWORD")@localhost:${p}/${DEVKIT_MONGODB_DATABASE}?authSource=admin" \
      "${DEVKIT_MONGODB_USER} / $(secret "$DEVKIT_MONGODB_PASSWORD")" mongodb mongodb "$p"
  fi
  if is_true "$DEVKIT_INSTALL_POSTGRESQL"; then
    p="$(forward_port postgresql DEVKIT_PORT_POSTGRESQL)"
    _access_add 'PostgreSQL' "postgresql://${DEVKIT_POSTGRESQL_USER}:$(secret "$DEVKIT_POSTGRESQL_PASSWORD")@localhost:${p}/${DEVKIT_POSTGRESQL_DATABASE}" \
      "${DEVKIT_POSTGRESQL_USER} / $(secret "$DEVKIT_POSTGRESQL_PASSWORD")" postgresql postgresql "$p"
  fi
  if is_true "$DEVKIT_INSTALL_MYSQL"; then
    p="$(forward_port mysql DEVKIT_PORT_MYSQL)"
    _access_add 'MySQL' "mysql://${DEVKIT_MYSQL_USER}:$(secret "$DEVKIT_MYSQL_PASSWORD")@localhost:${p}/${DEVKIT_MYSQL_DATABASE}" \
      "${DEVKIT_MYSQL_USER} / $(secret "$DEVKIT_MYSQL_PASSWORD") (root: $(secret "$DEVKIT_MYSQL_ROOT_PASSWORD"))" mysql mysql "$p"
  fi
  if is_true "$DEVKIT_INSTALL_REDIS"; then
    p="$(forward_port redis DEVKIT_PORT_REDIS)"
    _access_add 'Redis' "redis://:$(secret "$DEVKIT_REDIS_PASSWORD")@localhost:${p}" \
      "password: $(secret "$DEVKIT_REDIS_PASSWORD")" redis redis "$p"
  fi
  if is_true "$DEVKIT_INSTALL_KEDA"; then
    _access_add 'KEDA' 'namespace: keda (operator running)' '-' keda
  fi
  unset -f secret

  if [ -z "$_ACCESS_ROWS" ]; then
    log_info "No components are installed."
    return 0
  fi

  while IFS='|' read -r label url creds; do
    [ -n "$label" ] || continue
    if [ "${#label}" -gt "$w1" ]; then w1="${#label}"; fi
    if [ "${#url}" -gt "$w2" ]; then w2="${#url}"; fi
    if [ "${#creds}" -gt "$w3" ]; then w3="${#creds}"; fi
  done <<EOF
$_ACCESS_ROWS
EOF

  # Borders and padding add 10 columns; switch to a list when the table would wrap.
  cols="$(_access_term_cols)"
  if [ "$cols" -gt 0 ] && [ $((w1 + w2 + w3 + 10)) -gt "$cols" ]; then
    _access_list
  else
    _access_table_rows "$w1" "$w2" "$w3"
  fi

  if [ -n "$_ACCESS_NOT_READY" ]; then
    printf '\n'
    log_warn "Not ready:${_ACCESS_NOT_READY}. Check the pods with: kubectl --context ${DEVKIT_PROFILE} get pods -A"
    log_info "If the cluster is up but URLs do not answer, restart the port-forwards: ./devkit.sh forward start"
  fi
}
