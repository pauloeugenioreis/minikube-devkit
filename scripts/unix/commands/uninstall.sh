#!/usr/bin/env bash
# devkit uninstall: removes what minikube-devkit itself installed, as recorded
# in .devkit/state (binaries, packages, system files), plus the KEDA Helm
# repository, the minikube cache (only when no other minikube profile exists),
# and devkit's own state and logs. Tools that were already installed before
# devkit are never touched.

# Other minikube profiles (besides DEVKIT_PROFILE) that still exist.
_uninstall_other_profiles() {
  local dir name others=''
  dir="$(_minikube_dir)/profiles"
  [ -d "$dir" ] || return 0
  for name in "$dir"/*; do
    [ -d "$name" ] || continue
    name="${name##*/}"
    [ "$name" = "$DEVKIT_PROFILE" ] || others="${others} ${name}"
  done
  printf '%s\n' "${others# }"
}

_uninstall_plan() {
  local item others
  log_step "minikube-devkit will remove"
  while IFS= read -r item; do [ -z "$item" ] || log_info "- binary   ${item}"; done <<EOF
$(state_list INSTALLED_BINS)
EOF
  while IFS= read -r item; do [ -z "$item" ] || log_info "- package  ${item#*:} (${item%%:*})"; done <<EOF
$(state_list INSTALLED_PKGS)
EOF
  while IFS= read -r item; do [ -z "$item" ] || log_info "- file     ${item}"; done <<EOF
$(state_list INSTALLED_FILES)
EOF
  if has_cmd helm && helm repo list 2>/dev/null | grep -q '^kedacore'; then log_info "- helm repo kedacore"; fi
  others="$(_uninstall_other_profiles)"
  if [ -z "$others" ]; then
    log_info "- minikube cache and configuration ($(_minikube_dir))"
  else
    log_info "  (keeping $(_minikube_dir): other minikube profiles exist: ${others})"
  fi
  log_info "- devkit state (.devkit/) and logs (log/)"
}

uninstall_run() {
  local item others
  _uninstall_plan
  printf '\n'
  ask_yes_no "Uninstall all of the above?" N || { log_info "Nothing was uninstalled."; return 0; }

  forward_stop_all
  # Use the tools before removing them.
  if has_cmd helm && helm repo list 2>/dev/null | grep -q '^kedacore'; then
    run helm repo remove kedacore >/dev/null && log_ok "Removed helm repo kedacore"
  fi
  others="$(_uninstall_other_profiles)"
  if [ -z "$others" ] && has_cmd minikube; then
    run minikube delete --all --purge >/dev/null 2>&1 && log_ok "Removed the minikube cache ($(_minikube_dir))"
  fi

  while IFS= read -r item; do
    [ -n "$item" ] && [ -e "$item" ] || continue
    if [ -w "$(dirname "$item")" ]; then rm -f "$item"; else as_root rm -f "$item"; fi
    log_ok "Removed ${item}"
  done <<EOF
$(state_list INSTALLED_BINS)
EOF
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    if pkg_remove "$item" </dev/null; then log_ok "Removed package ${item#*:}"; else log_warn "Could not remove ${item#*:}"; fi
  done <<EOF
$(state_list INSTALLED_PKGS)
EOF
  while IFS= read -r item; do
    [ -n "$item" ] && [ -e "$item" ] || continue
    if as_root rm -f "$item"; then log_ok "Removed ${item}"; else log_warn "Could not remove ${item}"; fi
  done <<EOF
$(state_list INSTALLED_FILES)
EOF

  rm -rf "$DEVKIT_STATE_DIR"
  find "$DEVKIT_LOG_DIR" -mindepth 1 ! -name .gitkeep -delete 2>/dev/null || true
  log_ok "Removed devkit state and logs"

  printf '\n'
  log_info "Not reverted: group memberships (docker, libvirt, kvm, vboxusers), Homebrew, and config/devkit.env."
}

cmd_uninstall() {
  [ $# -eq 0 ] || { echo "Usage: devkit uninstall [--yes]"; return 0; }
  if cluster_exists; then
    die "Cluster '${DEVKIT_PROFILE}' still exists. Run './devkit.sh destroy' first (it can uninstall too)."
  fi
  uninstall_run
}
