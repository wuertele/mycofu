#!/usr/bin/env bash
# known-hosts-scope-lib.sh — scope-aware workstation known_hosts refresh.
#
# Functions defined here:
#   vm_key_to_module_name <vms-key>     — map a `vms.<key>` config field to
#                                         the root tofu module that consumes
#                                         it (e.g., dns1_prod → dns_prod).
#   refresh_known_hosts_for_scope       — for each VM whose module is in the
#                                         current scope, run ssh-keygen -R on
#                                         the workstation's known_hosts. With
#                                         no scope, all VMs are in scope
#                                         (full-rebuild semantics).
#
# Expected environment:
#   CONFIG          — path to site/config.yaml
#   TOFU_TARGETS    — space-separated `-target=module.X` flags, or empty
#   YQ_BIN          — yq binary (optional; defaults to `yq` on PATH)
#   SSH_KEYGEN_BIN  — ssh-keygen binary (optional; defaults to `ssh-keygen`
#                     on PATH). Override for hermetic tests.
#
# Why this lives in its own file:
#   The function is sourced and unit-tested in
#   tests/test_rebuild_known_hosts_scope.sh. Keeping it out of
#   rebuild-cluster.sh's monolithic top-level body makes that possible
#   without executing the rest of rebuild-cluster.sh.
#
# History:
#   #349 — before this lib existed, rebuild-cluster.sh ran
#   `ssh-keygen -R` for every VM in config.yaml regardless of --scope.
#   A scoped rebuild of one VM silently invalidated the workstation's
#   known_hosts for every other VM, breaking workstation tooling
#   (e.g., the validate-github-mirror.sh gatus probe).

# vm_key_to_module_name — derive a root tofu module name from a vms.<key>.
#
# Convention enforced by site/tofu and framework/tofu/root/main.tf:
#   - Single-instance VMs: vms.<role>           → module.<role>
#                          vms.<role>_<env>     → module.<role>_<env>
#                          (e.g., cicd → cicd; vault_prod → vault_prod)
#   - Multi-instance VMs:  vms.<role><N>_<env>  → module.<role>_<env>
#                          (e.g., dns1_prod → dns_prod;
#                                 dns2_prod → dns_prod)
#
# Implementation: strip a digit run sitting between an alpha prefix and
# the optional `_<env>` suffix. The resulting name is one of the modules
# declared in framework/tofu/root/*.tf.
vm_key_to_module_name() {
  local vm_key="$1"
  printf '%s' "$vm_key" | sed -E 's/^([a-z]+)[0-9]+(_[a-z]+)?$/\1\2/'
}

# refresh_known_hosts_for_scope — workstation-side known_hosts refresh
# limited to the current rebuild scope.
#
# Reads CONFIG (yaml) and TOFU_TARGETS (env). For each `vms.<key>` whose
# derived module appears in TOFU_TARGETS as `-target=module.<name>`,
# run `ssh-keygen -R <ip>`.
#
# When TOFU_TARGETS is empty, every VM is in scope — this preserves the
# legacy full-rebuild behavior. The function is silent on stdout when
# nothing matches; ssh-keygen's own output is suppressed.
#
# Match semantics: target matching is EXACT
# (`-target=module.<vm_module>`), not substring. This is intentionally
# stricter than `step_in_scope` in rebuild-cluster.sh, which uses
# substring matching to fan out a single `vault`/`dns` step across both
# env-suffixed modules (e.g., `module.vault_prod` and `module.vault_dev`
# both match `*"module.vault"*`). Exact matching here guards against
# prefix-collision false positives — a stray `-target=module.vault`
# would otherwise touch known_hosts for `vault_prod` and `vault_dev`
# even though no such root module exists. See TC6 in
# tests/test_rebuild_known_hosts_scope.sh.
refresh_known_hosts_for_scope() {
  local yq_bin="${YQ_BIN:-yq}"
  local ssh_keygen_bin="${SSH_KEYGEN_BIN:-ssh-keygen}"
  local vm_key vm_module vm_ip target in_scope

  if [[ -z "${CONFIG:-}" ]]; then
    echo "refresh_known_hosts_for_scope: CONFIG is not set" >&2
    return 1
  fi
  if [[ ! -f "$CONFIG" ]]; then
    echo "refresh_known_hosts_for_scope: CONFIG file not found: $CONFIG" >&2
    return 1
  fi

  while IFS= read -r vm_key; do
    [[ -z "$vm_key" ]] && continue
    vm_module=$(vm_key_to_module_name "$vm_key")
    in_scope=0
    if [[ -z "${TOFU_TARGETS:-}" ]]; then
      in_scope=1
    else
      for target in $TOFU_TARGETS; do
        if [[ "$target" == "-target=module.${vm_module}" ]]; then
          in_scope=1
          break
        fi
      done
    fi
    if [[ "$in_scope" -eq 1 ]]; then
      vm_ip=$("$yq_bin" -r ".vms.${vm_key}.ip" "$CONFIG")
      if [[ -n "$vm_ip" && "$vm_ip" != "null" ]]; then
        "$ssh_keygen_bin" -R "$vm_ip" 2>/dev/null || true
      fi
    fi
  done < <("$yq_bin" -r '.vms | keys | .[]' "$CONFIG")
}
