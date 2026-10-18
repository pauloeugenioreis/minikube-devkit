#!/usr/bin/env bash
# devkit test smoke|keda|unit|all
#   smoke  every installed component answers: authenticated checks inside the
#          pods (k8s/<service>/smoke.sh), port-forwards, Dashboard, RabbitMQ
#          API, KEDA metrics API and the example ScaledObjects
#   keda   sends messages and checks the example workers scale 0 -> N -> 0
#   unit   offline tests of the scripts themselves (no cluster needed)

_TEST_FAILED=0

_test_ok()   { log_ok "$*"; }
_test_fail() { log_error "$*"; _TEST_FAILED=$((_TEST_FAILED + 1)); }

# _test_http NAME URL [CURL_ARGS...]: expects HTTP 200.
_test_http() {
  local name="$1" url="$2" code
  shift 2
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" "$url" 2>/dev/null)" || code=000
  if [ "$code" = 200 ]; then _test_ok "${name} answers on ${url}"; else _test_fail "${name}: HTTP ${code} from ${url}"; fi
}

_test_smoke() {
  local id key label port name ready
  log_step "Smoke tests"
  require_cluster_running

  while IFS='|' read -r id key label; do
    is_true "${!key}" || continue
    if ! component_ready "$id"; then
      _test_fail "${label}: pod is not ready"
      continue
    fi
    # </dev/null: kubectl exec would otherwise consume the loop's input.
    if kube -n "$DEVKIT_NAMESPACE" exec "${id}-0" -- sh -c "$(cat "${DEVKIT_ROOT}/k8s/${id}/smoke.sh")" </dev/null >/dev/null 2>&1; then
      _test_ok "${label}: authenticated check passed"
    else
      _test_fail "${label}: authenticated check failed (see ./devkit.sh logs ${id})"
    fi
  done <<EOF
$DATA_SERVICES
EOF

  while IFS='|' read -r name _ _ _ _ key; do
    case "$name" in dashboard) id=dashboard ;; rabbitmq-*) id=rabbitmq ;; *) id="$name" ;; esac
    ready="$(_component_key "$id")"
    is_true "${!ready}" || continue
    port="$(forward_port "$name" "$key")"
    if port_in_use "$port"; then _test_ok "port-forward ${name} on localhost:${port}"; else _test_fail "port-forward ${name}: nothing listening on localhost:${port} (./devkit.sh forward start)"; fi
  done <<EOF
$(_forward_specs)
EOF

  if is_true "$DEVKIT_INSTALL_DASHBOARD"; then
    _test_http 'Kubernetes Dashboard' "http://localhost:$(forward_port dashboard DEVKIT_PORT_DASHBOARD)/"
  fi
  if is_true "$DEVKIT_INSTALL_RABBITMQ"; then
    _test_http 'RabbitMQ Management API' "http://localhost:$(forward_port rabbitmq-mgmt DEVKIT_PORT_RABBITMQ_MGMT)/api/overview" \
      -u "${DEVKIT_RABBITMQ_USER}:${DEVKIT_RABBITMQ_PASSWORD}"
  fi

  if is_true "$DEVKIT_INSTALL_KEDA"; then
    if component_ready keda; then _test_ok "KEDA operator is ready"; else _test_fail "KEDA operator is not ready"; fi
    if [ "$(kube get apiservice v1beta1.external.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)" = True ]; then
      _test_ok "KEDA external metrics API is available"
    else
      _test_fail "KEDA external metrics API is not available"
    fi
    for name in rabbitmq-worker redis-worker cron-demo; do
      case "$name" in
        rabbitmq-worker) is_true "$DEVKIT_INSTALL_RABBITMQ" || continue ;;
        redis-worker)    is_true "$DEVKIT_INSTALL_REDIS" || continue ;;
      esac
      if [ "$(kube -n "$DEVKIT_EXAMPLES_NAMESPACE" get scaledobject "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; then
        _test_ok "ScaledObject ${name} is ready"
      else
        _test_fail "ScaledObject ${name} is not ready (kubectl --context ${DEVKIT_PROFILE} -n ${DEVKIT_EXAMPLES_NAMESPACE} describe scaledobject ${name})"
      fi
    done
  fi
}

# _test_wait_replicas DEPLOYMENT CMP N TIMEOUT: CMP is ge or eq.
_test_wait_replicas() {
  local deploy="$1" cmp="$2" want="$3" timeout="$4" elapsed=0 n
  while :; do
    n="$(examples_replicas "$deploy")"
    if [ "$cmp" = ge ] && [ "$n" -ge "$want" ]; then echo "$n"; return 0; fi
    if [ "$cmp" = eq ] && [ "$n" -eq "$want" ]; then echo "$n"; return 0; fi
    [ "$elapsed" -ge "$timeout" ] && { echo "$n"; return 1; }
    sleep 5
    elapsed=$((elapsed + 5))
  done
}

_test_keda() {
  local target deploy start n peak
  log_step "KEDA autoscaling (0 -> N -> 0)"
  require_cluster_running
  is_true "$DEVKIT_INSTALL_KEDA" || { _test_fail "KEDA is not enabled in config/devkit.env"; return; }

  for target in rabbitmq redis; do
    case "$target" in
      rabbitmq) is_true "$DEVKIT_INSTALL_RABBITMQ" || { log_info "RabbitMQ not installed; skipping its example."; continue; } ;;
      redis)    is_true "$DEVKIT_INSTALL_REDIS" || { log_info "Redis not installed; skipping its example."; continue; } ;;
    esac
    deploy="${target}-worker"
    log_info "${deploy}: waiting for it to be at 0 replicas"
    _test_wait_replicas "$deploy" eq 0 300 >/dev/null || { _test_fail "${deploy} did not start at 0 replicas"; continue; }

    start="$(date +%s)"
    examples_produce "$target" 50 || { _test_fail "${target}: producer failed"; continue; }
    if n="$(_test_wait_replicas "$deploy" ge 1 120)"; then
      _test_ok "${deploy} scaled out to ${n} replica(s) in $(( $(date +%s) - start ))s"
    else
      _test_fail "${deploy} did not scale out within 120s"
      continue
    fi
    sleep 10
    peak="$(examples_replicas "$deploy")"
    log_info "${deploy}: ${peak} replica(s) working through the backlog"
    start="$(date +%s)"
    if _test_wait_replicas "$deploy" eq 0 300 >/dev/null; then
      _test_ok "${deploy} scaled back to 0 in $(( $(date +%s) - start ))s"
    else
      _test_fail "${deploy} did not scale back to 0 within 300s"
    fi
  done
}

_test_unit() {
  log_step "Unit tests (Bash)"
  if bash "${DEVKIT_ROOT}/tests/unit/unix.sh"; then
    _test_ok "unit tests passed"
  else
    _test_fail "unit tests failed"
  fi
}

cmd_test() {
  _TEST_FAILED=0
  case "${1:-}" in
    smoke) _test_smoke ;;
    keda)  _test_keda ;;
    unit)  _test_unit ;;
    all)   _test_unit; _test_smoke; _test_keda ;;
    *) echo "Usage: devkit test smoke|keda|unit|all"; return 0 ;;
  esac
  printf '\n'
  if [ "$_TEST_FAILED" -gt 0 ]; then
    log_error "${_TEST_FAILED} check(s) failed."
    return 1
  fi
  log_ok "All checks passed."
}
