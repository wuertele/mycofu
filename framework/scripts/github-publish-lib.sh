#!/usr/bin/env bash
# github-publish-lib.sh — Shared helpers for GitHub publishing workflows.

github_remote_validate() {
  local remote_url="${1:-}"

  [[ "${remote_url}" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]]
}

github_remote_to_raw_metadata_url() {
  local remote_url="${1:-}"
  local owner_repo=""

  if ! github_remote_validate "${remote_url}"; then
    echo "ERROR: invalid GitHub SSH remote URL: ${remote_url}" >&2
    return 1
  fi

  owner_repo="${remote_url#git@github.com:}"
  owner_repo="${owner_repo%.git}"
  printf 'https://raw.githubusercontent.com/%s/main/.mycofu-publish.json\n' "${owner_repo}"
}

github_publish_write_metadata() {
  if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: github_publish_write_metadata <output-dir> <source-commit> [publisher]" >&2
    return 1
  fi

  local output_dir="$1"
  local source_commit="$2"
  local publisher="${3:-publish:github}"
  local source_short="${source_commit:0:12}"
  local published_at=""

  if [[ ! "${source_commit}" =~ ^[0-9a-fA-F]{40}$ ]]; then
    echo "ERROR: source commit must be a full 40-character SHA: ${source_commit}" >&2
    return 1
  fi

  published_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "${output_dir}"
  jq -n \
    --arg source_commit "${source_commit}" \
    --arg source_short "${source_short}" \
    --arg published_at "${published_at}" \
    --arg publisher "${publisher}" \
    '{
      schema: 1,
      source_ref: "prod",
      source_commit: $source_commit,
      source_short: $source_short,
      published_at: $published_at,
      publisher: $publisher
    }' > "${output_dir}/.mycofu-publish.json"
}

# Extract the remote main OID from `git ls-remote` output, ignoring any
# stderr that 2>&1 captured ahead of the oid line. The line must look
# like a real ls-remote record:
#
#   <40-lowercase-hex>\trefs/heads/main
#
# Anything else (SSH "Warning: Permanently added", agent forwarding
# notices, MOTD lines, blank lines, 40-hex tokens followed by garbage,
# 40-hex tokens that happen to head an unrelated banner) is rejected.
# Returns the empty string if no matching line is present.
#
# Why this shape:
#
# - publish-to-github.sh captures `2>&1` so it can classify network
#   failures with github_publish_classify_git_error. On the first SSH
#   to github.com from a runner whose known_hosts lacks the host,
#   OpenSSH emits "Warning: Permanently added 'github.com' (...)" to
#   stderr. A naive `awk 'NF{print $1}'` parser picks "Warning:" and
#   feeds it to `git push --force-with-lease=main:Warning:`, which
#   fails with "cannot parse expected object name 'Warning:'". See
#   issue #297.
# - Validating $2 == refs/heads/main is defense-in-depth: even if a
#   future stderr line begins with a 40-hex-shaped token (e.g., a
#   commit-SHA banner), it will not match because the second field
#   will not be the ref name.
# - The trailing \r? on the ref allows CRLF line endings (intermediate
#   proxies, future SSH banner munging) without breaking extraction.
#   git ls-remote on Linux emits LF, but the parser shouldn't fail on
#   CRLF if the runner's environment ever introduces it.
github_publish_extract_remote_oid() {
  local output="${1:-}"

  printf '%s\n' "${output}" | awk '$1 ~ /^[0-9a-f]{40}$/ && $2 ~ /^refs\/heads\/main\r?$/ { print $1; exit }'
}

github_publish_classify_git_error() {
  local output="${1:-}"

  if grep -Eqi 'Repository not found|not a github repository|ERROR: Repository' <<< "${output}"; then
    printf 'config_error\n'
  elif grep -Eqi 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|known_hosts' <<< "${output}"; then
    printf 'config_error\n'
  elif grep -Eqi 'stale info|cannot lock ref|failed to push some refs|fetch first|non-fast-forward|force-with-lease|lease' <<< "${output}"; then
    printf 'lease_conflict\n'
  elif grep -Eqi 'Permission denied \(publickey\)|Could not read from remote repository|Load key .* invalid format|bad permissions|invalid format|sign_and_send_pubkey|Authentication failed|publickey' <<< "${output}"; then
    printf 'auth_error\n'
  elif grep -Eqi 'kex_exchange_identification|ssh_exchange_identification|banner exchange|handshake failed|protocol error' <<< "${output}"; then
    printf 'auth_error\n'
  elif grep -Eqi 'Network is unreachable|No route to host|Connection timed out|Operation timed out|Connection refused|Connection reset by peer|Could not resolve hostname|Temporary failure in name resolution|Name or service not known|nodename nor servname provided|Connection closed by remote host' <<< "${output}"; then
    printf 'outage\n'
  else
    printf 'unknown_error\n'
  fi
}

github_publish_select_deploy_key() {
  if [[ $# -ne 2 ]]; then
    echo "Usage: github_publish_select_deploy_key <primary-path> <fallback-path>" >&2
    return 1
  fi

  local primary_path="$1"
  local fallback_path="$2"

  if [[ -s "${primary_path}" ]]; then
    printf '%s\n' "${primary_path}"
    return 0
  fi

  if [[ -s "${fallback_path}" ]]; then
    printf '%s\n' "${fallback_path}"
    return 0
  fi

  return 1
}

github_publish_initial_rewrite_guard() {
  if [[ "${GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE:-}" == "1" ]]; then
    return 0
  fi

  echo "ERROR: GitHub main does not contain a valid .mycofu-publish.json; refusing initial history rewrite." >&2
  echo "Set GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE=1 after reviewing the recorded GitHub main OID." >&2
  return 1
}

# Returns 0 only if `<ref>:.mycofu-publish.json` exists AND parses as
# exactly one JSON document of shape
# {schema: 1, source_commit: <exactly-40-hex-chars>}.
# Returns 1 for missing, empty, malformed JSON, multi-document streams,
# wrong schema, or invalid source_commit. Treating any malformed
# metadata as "missing" keeps the initial-rewrite guard load-bearing
# during the pre-first-publish window.
#
# Implementation notes:
# - Stream cat-file directly into jq via pipe. Bash command
#   substitution silently strips NUL bytes, which would let a blob
#   like "\0{...valid JSON...}" be normalized into valid JSON before
#   validation.
# - Use `jq -s` to slurp the input into an array and require
#   `length == 1`, so a multi-document stream like
#   "{wrong-schema}\n{valid}" cannot satisfy `jq -e` based on the
#   last document.
# - Use `length == 40` on source_commit instead of relying on regex
#   anchors; jq's `$` is permissive at end-of-string and would match
#   a trailing newline.
github_publish_metadata_present() {
  if [[ $# -ne 3 ]]; then
    echo "Usage: github_publish_metadata_present <git-bin> <workdir> <ref>" >&2
    return 1
  fi

  local git_bin="$1"
  local workdir="$2"
  local ref="$3"

  "${git_bin}" -C "${workdir}" cat-file -p "${ref}:.mycofu-publish.json" 2>/dev/null \
    | jq -s -e '
        length == 1 and
        (.[0] | (
          .schema == 1 and
          (.source_commit | type == "string") and
          (.source_commit | length == 40) and
          (.source_commit | test("^[0-9a-f]{40}$"))
        ))
      ' \
    >/dev/null 2>&1
}

github_publish_transport_preflight() {
  local host="${1:-github.com}"
  local dns_probe="${GITHUB_PUBLISH_DNS_PROBE_BIN:-getent}"
  local tcp_probe="${GITHUB_PUBLISH_TCP_PROBE_BIN:-}"
  local output=""

  set +e
  output="$("${dns_probe}" hosts "${host}" 2>&1)"
  local dns_exit=$?
  set -e
  if [[ "${dns_exit}" -ne 0 ]]; then
    echo "DNS lookup for ${host} failed: ${output}" >&2
    return 10
  fi

  if [[ -n "${tcp_probe}" ]]; then
    set +e
    output="$("${tcp_probe}" "${host}" 22 2>&1)"
    local tcp_exit=$?
    set -e
  elif command -v nc >/dev/null 2>&1; then
    set +e
    output="$(nc -z -w 5 "${host}" 22 2>&1)"
    local tcp_exit=$?
    set -e
  else
    set +e
    output="$(timeout 5 bash -c "</dev/tcp/${host}/22" 2>&1)"
    local tcp_exit=$?
    set -e
  fi

  if [[ "${tcp_exit}" -ne 0 ]]; then
    echo "TCP connect to ${host}:22 failed: ${output}" >&2
    return 11
  fi

  return 0
}

