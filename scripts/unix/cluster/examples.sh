#!/usr/bin/env bash
# KEDA examples (examples/): a worker image built inside the cluster and
# ScaledObjects for RabbitMQ, Redis and cron. Deployed whenever KEDA is
# installed, even if RabbitMQ or Redis are not (those ScaledObjects then just
# report not ready until the service exists).

_EXAMPLES_DIR="${DEVKIT_ROOT}/examples"

examples_image_present() {
  minikube image ls -p "$DEVKIT_PROFILE" 2>/dev/null | grep -q "${DEVKIT_EXAMPLES_IMAGE}\$"
}

# examples_build [--force]: builds the worker image with "minikube image build".
examples_build() {
  if [ "${1:-}" != --force ] && examples_image_present; then
    log_ok "Worker image ${DEVKIT_EXAMPLES_IMAGE} is present"
    return 0
  fi
  log_info "Building the worker image ${DEVKIT_EXAMPLES_IMAGE} inside the cluster"
  run minikube image build -p "$DEVKIT_PROFILE" -t "$DEVKIT_EXAMPLES_IMAGE" "${_EXAMPLES_DIR}/worker" >/dev/null \
    || die "Building the worker image failed. Retry with: ./devkit.sh examples deploy --rebuild"
  log_ok "Worker image ${DEVKIT_EXAMPLES_IMAGE} built"
}

examples_deploy() {
  local tmp manifest
  is_true "$DEVKIT_INSTALL_KEDA" || { log_info "KEDA is not installed; skipping the KEDA examples."; return 0; }
  log_step "KEDA examples (namespace ${DEVKIT_EXAMPLES_NAMESPACE})"
  examples_build "${1:-}"

  render_template "${_EXAMPLES_DIR}/k8s/namespace.yaml" | kube apply -f - >/dev/null
  tmp="$(mktemp)"
  render_template "${_EXAMPLES_DIR}/k8s/credentials.env" > "$tmp"
  kube create secret generic examples-credentials -n "$DEVKIT_EXAMPLES_NAMESPACE" \
    --from-env-file="$tmp" --dry-run=client -o yaml | kube apply -f - >/dev/null
  rm -f "$tmp"
  for manifest in rabbitmq redis cron; do
    render_template "${_EXAMPLES_DIR}/k8s/${manifest}.yaml" | kube apply -f - >/dev/null
    log_ok "Applied ${manifest} example"
  done

  # KEDA's RabbitMQ scaler needs the queue to exist: declare it once.
  if is_true "$DEVKIT_INSTALL_RABBITMQ"; then
    examples_produce rabbitmq 0 rabbitmq-declare-queue >/dev/null
  fi
}

examples_remove() {
  kube delete namespace "$DEVKIT_EXAMPLES_NAMESPACE" --ignore-not-found --wait=true >/dev/null
  log_ok "Removed the KEDA examples (namespace ${DEVKIT_EXAMPLES_NAMESPACE})"
}

# examples_produce rabbitmq|redis COUNT [JOB_NAME]: runs the producer Job and
# waits for it to finish.
examples_produce() {
  local target="$1" count="$2" name="${3:-}"
  [ -n "$name" ] || name="produce-${target}-$(date +%s)"
  DEVKIT_PRODUCER_NAME="$name"
  DEVKIT_PRODUCER_MODE="${target}-produce"
  DEVKIT_PRODUCER_COUNT="$count"
  kube delete job "$name" -n "$DEVKIT_EXAMPLES_NAMESPACE" --ignore-not-found >/dev/null
  render_template "${_EXAMPLES_DIR}/k8s/producer-job.yaml" | kube apply -f - >/dev/null
  if kube wait --for=condition=complete "job/${name}" -n "$DEVKIT_EXAMPLES_NAMESPACE" --timeout=180s >/dev/null 2>&1; then
    log_ok "Producer sent ${count} messages to ${target}"
  else
    log_error "Producer job ${name} did not complete. Check: kubectl --context ${DEVKIT_PROFILE} -n ${DEVKIT_EXAMPLES_NAMESPACE} logs job/${name}"
    return 1
  fi
}

# Current replica count of an example Deployment.
examples_replicas() {
  local n
  n="$(kube -n "$DEVKIT_EXAMPLES_NAMESPACE" get deployment "$1" -o jsonpath='{.status.replicas}' 2>/dev/null)"
  echo "${n:-0}"
}
