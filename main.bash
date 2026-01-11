#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# git-gb: Create a git branch from Jira issues via fzf
#
# Required (personal; DO NOT COMMIT):
#   JIRA_BASE_URL   e.g. https://xxx.atlassian.net
#   JIRA_EMAIL
#   JIRA_API_TOKEN
#
# Required (repo; OK to share via .env/.envrc):
#   JIRA_BOARD_ID   e.g. 206
#
# Optional:
#   GB_BRANCH_PREFIX   default: feature
#   GB_CACHE_TTL_SEC   default: 900
#   GB_MAX_RESULTS     default: 200
# ============================================================

# ------------------------------
# helpers
# ------------------------------
fatal() {
  echo "gb: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fatal "required command not found: $1"
}

# Load .env if present (simple KEY=VALUE, no shell expansions)
load_dotenv() {
  [[ -f .env ]] || return 0

  # Only accept simple KEY=VALUE lines (ignores comments/blank lines)
  # Note: This doesn't evaluate shell expressions like ${HOME}.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    # allow "export KEY=VALUE" or "KEY=VALUE"
    line="${line#export }"

    # must match KEY=VALUE
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      export "$line"
    fi
  done < .env
}

load_optional_env() {
  GB_BRANCH_PREFIX="${GB_BRANCH_PREFIX:-feature}"
  GB_CACHE_TTL_SEC="${GB_CACHE_TTL_SEC:-900}"
  GB_MAX_RESULTS="${GB_MAX_RESULTS:-200}"
}

require_personal_env() {
  : "${JIRA_BASE_URL:?set JIRA_BASE_URL (personal)}"
  : "${JIRA_EMAIL:?set JIRA_EMAIL (personal)}"
  : "${JIRA_API_TOKEN:?set JIRA_API_TOKEN (personal)}"
}

require_repo_env() {
  : "${JIRA_BOARD_ID:?set JIRA_BOARD_ID (repo .env / .envrc)}"
}

auth_curl() {
  curl -sS -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" -H "Accept: application/json" "$@"
}

cache_paths() {
  CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/jira"
  CACHE_FILE="$CACHE_DIR/issues_${JIRA_BOARD_ID}.json"
}

is_cache_fresh() {
  [[ -f "$CACHE_FILE" ]] || return 1
  local now ts
  now=$(date +%s)
  ts=$(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE")
  (( now - ts < GB_CACHE_TTL_SEC ))
}

fetch_issues() {
  mkdir -p "$CACHE_DIR"

  # 1) try active sprint (scrum)
  local sprint_id
  sprint_id=$(
    auth_curl "${JIRA_BASE_URL}/rest/agile/1.0/board/${JIRA_BOARD_ID}/sprint?state=active&maxResults=1" \
    | jq -r '.values[0].id // empty'
  )

  if [[ -n "${sprint_id}" ]]; then
    auth_curl "${JIRA_BASE_URL}/rest/agile/1.0/sprint/${sprint_id}/issue?fields=summary,status&maxResults=${GB_MAX_RESULTS}" \
      | jq '{issues: [.issues[] | {key:.key, summary:.fields.summary, status:.fields.status.name}]}' \
      > "$CACHE_FILE"
  else
    # 2) kanban (or no active sprint): board issues
    auth_curl "${JIRA_BASE_URL}/rest/agile/1.0/board/${JIRA_BOARD_ID}/issue?fields=summary,status&maxResults=${GB_MAX_RESULTS}" \
      | jq '{issues: [.issues[] | {key:.key, summary:.fields.summary, status:.fields.status.name}]}' \
      > "$CACHE_FILE"
  fi
}

slugify() {
  # lower -> replace non-alnum with _ -> collapse _ -> trim -> cut to 50 chars
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g; s/_+/_/g' \
    | cut -c1-50
}

# ------------------------------
# main
# ------------------------------
require_cmd git
require_cmd curl
require_cmd jq
require_cmd fzf

load_dotenv
load_optional_env
require_personal_env
require_repo_env

# Basic validation
[[ "$GB_MAX_RESULTS" =~ ^[0-9]+$ ]] || fatal "GB_MAX_RESULTS must be a positive integer (got: $GB_MAX_RESULTS)"
[[ "$GB_CACHE_TTL_SEC" =~ ^[0-9]+$ ]] || fatal "GB_CACHE_TTL_SEC must be a positive integer (got: $GB_CACHE_TTL_SEC)"
[[ "$JIRA_BOARD_ID" =~ ^[0-9]+$ ]] || fatal "JIRA_BOARD_ID must be a number (got: $JIRA_BOARD_ID)"

# Normalize prefix (avoid feature//...)
GB_BRANCH_PREFIX="${GB_BRANCH_PREFIX%/}"

cache_paths

update=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update|-u) update=1; shift ;;
    *) break ;;
  esac
done

if [[ $update -eq 1 ]] || ! is_cache_fresh; then
  # UX-first: if fetch fails but cache exists, continue
  fetch_issues || true
fi

[[ -f "$CACHE_FILE" ]] || fatal "no cache and fetch failed. check jira settings."

# fzf input format (TSV): KEY \t [STATUS] \t SUMMARY
selected=$(
  jq -r '.issues[] | "\(.key)\t[\(.status)]\t\(.summary)"' "$CACHE_FILE" \
  | fzf --delimiter=$'\t' --with-nth=1,2,3 --prompt="Jira issue> " --height=70%
) || exit 0

key=$(echo "$selected" | cut -f1)
summary=$(echo "$selected" | cut -f3)

[[ -n "$key" ]] || exit 0

branch="${GB_BRANCH_PREFIX}/${key}_$(slugify "$summary")"

echo "=> git switch -c $branch"
git switch -c "$branch"

