#!/usr/bin/env bash
# Deploys the data services from k8s/<component> templates and KEDA via Helm.

# Data services backed by k8s/<id>/, in deploy order: "id|config key|label".
DATA_SERVICES='rabbitmq|DEVKIT_INSTALL_RABBITMQ|RabbitMQ
mongodb|DEVKIT_INSTALL_MONGODB|MongoDB
postgresql|DEVKIT_INSTALL_POSTGRESQL|PostgreSQL
mysql|DEVKIT_INSTALL_MYSQL|MySQL
redis|DEVKIT_INSTALL_REDIS|Redis'

# Creates/updates the <id>-credentials Secret and applies the manifest.
_component_apply() {
  local id="$1" dir="${DEVKIT_ROOT}/k8s/$1" tmp
  if [ -f "${dir}/credentials.env" ]; then
    tmp="$(mktemp)"
    render_template "${dir}/credentials.env" > "$tmp"
    kube create secret generic "${id}-credentials" -n "$DEVKIT_NAMESPACE" \
      --from-env-file="$tmp" --dry-run=client -o yaml | kube apply -f - >/dev/null
    rm -f "$tmp"
  fi
  render_template "${dir}/manifest.yaml" | kube apply -f - >/dev/null
}

components_deploy() {
  local id key label selected=''

  log_step "Data services"
  render_template "${DEVKIT_ROOT}/k8s/namespace.yaml" | kube apply -f - >/dev/null

  # Apply everything first so images are pulled in parallel, then wait.
  while IFS='|' read -r id key label; do
    is_true "${!key}" || continue
    _component_apply "$id"
    log_info "Applied ${label}"
    selected="${selected} ${id}|${label}"
  done <<EOF
$DATA_SERVICES
EOF
  [ -n "$selected" ] || { log_info "No data services selected."; return 0; }

  log_info "Waiting for the services to become ready (first run downloads images; up to ${DEVKIT_DEPLOY_TIMEOUT}s each)..."
  for entry in $selected; do
    id="${entry%%|*}"; label="${entry#*|}"
    if kube rollout status "statefulset/${id}" -n "$DEVKIT_NAMESPACE" --timeout="${DEVKIT_DEPLOY_TIMEOUT}s" >/dev/null 2>&1; then
      log_ok "${label} is ready"
    else
      log_error "${label} did not become ready. Check: kubectl --context ${DEVKIT_PROFILE} -n ${DEVKIT_NAMESPACE} describe pod ${id}-0"
    fi
  done
}

keda_deploy() {
  is_true "$DEVKIT_INSTALL_KEDA" || return 0
  log_step "KEDA ${DEVKIT_KEDA_CHART_VERSION}"
  run helm repo add kedacore https://kedacore.github.io/charts --force-update >/dev/null \
    || die "Could not add the KEDA Helm repository."
  run helm repo update kedacore >/dev/null || die "Could not update the KEDA Helm repository."
  if run helm upgrade --install keda kedacore/keda \
      --kube-context "$DEVKIT_PROFILE" \
      --namespace keda --create-namespace \
      --version "$DEVKIT_KEDA_CHART_VERSION" \
      --values "${DEVKIT_ROOT}/helm/keda-values.yaml" \
      --wait --timeout "${DEVKIT_DEPLOY_TIMEOUT}s" >/dev/null; then
    log_ok "KEDA is ready"
  else
    log_error "KEDA did not become ready. Check: kubectl --context ${DEVKIT_PROFILE} -n keda get pods"
  fi
}

# Succeeds when the component's workload reports ready replicas.
component_ready() {
  local ready
  case "$1" in
    dashboard) ready="$(kube -n kubernetes-dashboard get deployment kubernetes-dashboard -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" ;;
    keda)      ready="$(kube -n keda get deployment keda-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" ;;
    *)         ready="$(kube -n "$DEVKIT_NAMESPACE" get statefulset "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" ;;
  esac
  [ "${ready:-0}" -ge 1 ] 2>/dev/null
}
