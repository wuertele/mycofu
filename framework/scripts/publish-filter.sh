#!/usr/bin/env bash
# publish-filter.sh — Shared allowlist helpers for GitHub publishing.
#
# Source this file from publishing workflows. It defines:
#   - PUBLISH_PATHS: top-level git archive allowlist
#   - publish_filter_archive <git-ref> <output-dir>
#   - publish_filter_verify <output-dir>

if [[ -z "${PUBLISH_FILTER_GIT_BIN:-}" ]]; then
  PUBLISH_FILTER_GIT_BIN="git"
fi

if [[ -z "${PUBLISH_FILTER_REPO_DIR:-}" ]]; then
  PUBLISH_FILTER_REPO_DIR="$(
    cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd
  )"
fi

PUBLISH_PATHS=(
  "framework"
  "tests"
  "docs"
  "README.md"
  "architecture.md"
  "GETTING-STARTED.md"
  "OPERATIONS.md"
  "CLAUDE.md"
  ".gitlab-ci.yml"
  "flake.nix"
  "flake.lock"
)

PUBLISH_DOCS_EXCLUDED_PATHS=(
  "docs/prompts"
  "docs/reports"
  "docs/sprints"
)

publish_filter_path_allowed() {
  local rel_path="${1#./}"

  case "$rel_path" in
    framework|framework/*|tests|tests/*|README.md|architecture.md|GETTING-STARTED.md|OPERATIONS.md|CLAUDE.md|.gitlab-ci.yml|flake.nix|flake.lock|docs|docs/*|.mycofu-publish.json)
      ;;
    *)
      return 1
      ;;
  esac

  case "$rel_path" in
    docs/prompts|docs/prompts/*|docs/reports|docs/reports/*|docs/sprints|docs/sprints/*)
      return 1
      ;;
  esac

  return 0
}

publish_filter_archive() {
  if [[ $# -ne 2 ]]; then
    echo "Usage: publish_filter_archive <git-ref> <output-dir>" >&2
    return 1
  fi

  local git_ref="$1"
  local output_dir="$2"
  local publish_path=""
  local archive_paths=()

  if [[ -z "$output_dir" || "$output_dir" == "/" ]]; then
    echo "ERROR: Refusing to publish into unsafe output directory: ${output_dir}" >&2
    return 1
  fi

  rm -rf "$output_dir"
  mkdir -p "$output_dir"

  for publish_path in "${PUBLISH_PATHS[@]}"; do
    if "${PUBLISH_FILTER_GIT_BIN}" -C "${PUBLISH_FILTER_REPO_DIR}" cat-file -e "${git_ref}:${publish_path}" 2>/dev/null; then
      archive_paths+=("$publish_path")
    fi
  done

  if [[ "${#archive_paths[@]}" -eq 0 ]]; then
    echo "ERROR: No publishable paths found at git ref ${git_ref}" >&2
    return 1
  fi

  "${PUBLISH_FILTER_GIT_BIN}" -C "${PUBLISH_FILTER_REPO_DIR}" archive --format=tar "${git_ref}" "${archive_paths[@]}" \
    | tar -xf - -C "$output_dir"

  for publish_path in "${PUBLISH_DOCS_EXCLUDED_PATHS[@]}"; do
    rm -rf "${output_dir}/${publish_path}"
  done
}

publish_filter_verify() {
  if [[ $# -ne 1 ]]; then
    echo "Usage: publish_filter_verify <output-dir>" >&2
    return 1
  fi

  local output_dir="$1"
  local path=""
  local rel_path=""
  local violations=()

  if [[ ! -d "$output_dir" ]]; then
    echo "ERROR: Publish output directory not found: ${output_dir}" >&2
    return 1
  fi

  while IFS= read -r -d '' path; do
    rel_path="${path#"${output_dir%/}/"}"
    if [[ "$rel_path" == "$path" || -z "$rel_path" ]]; then
      continue
    fi

    if ! publish_filter_path_allowed "$rel_path"; then
      violations+=("$rel_path")
    fi
  done < <(find "$output_dir" -mindepth 1 -print0)

  if [[ "${#violations[@]}" -ne 0 ]]; then
    echo "ERROR: Non-allowlisted paths detected in publish output:" >&2
    printf '  %s\n' "${violations[@]}" >&2
    return 1
  fi

  return 0
}
