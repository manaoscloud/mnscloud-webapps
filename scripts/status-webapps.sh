#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<EOF
Usage: scripts/status-webapps.sh [--json] [--env /etc/mnscloud/webapps/webapps.env]

Read-only inventory of the enabled apps: configured source/ref, installed release, the release the
last install/sync resolved, and the result of that last install/sync. With --json it prints one
JSON array (consumed by mnscloud-agent); otherwise a table. Takes no lock and changes nothing.
EOF
}

ENV_FILE="$DEFAULT_ENV_FILE"
FORMAT="table"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --env) ENV_FILE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_runtime_env

state_field() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -n1
}

app_rows() {
  local app
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    (
      load_app_env "$app"
      state="$(app_state_file "$APP_NAME")"
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$APP_NAME" "$APP_BASE_PATH" "$APP_SOURCE" \
        "$APP_REF" "$(current_app_release || true)" "$(state_field "$state" resolvedRef)" \
        "$(state_field "$state" lastSyncStatus)" "$(state_field "$state" lastSyncAt)" \
        "$(state_field "$state" lastError)"
    ) 2>/dev/null || printf '%s\x1f\x1f\x1f\x1f\x1f\x1ffailed\x1f\x1finvalid app configuration\n' "$app"
  done < <(enabled_apps)
}

json_items=()
while IFS=$'\x1f' read -r name base source ref installed resolved status at error; do
  if [[ "$FORMAT" == "json" ]]; then
    json_items+=("$(printf '{"app":%s,"basePath":%s,"source":%s,"ref":%s,"installedVersion":%s,"resolvedRef":%s,"lastSyncStatus":%s,"lastSyncAt":%s,"lastError":%s}' \
      "$(json_string "$name")" "$(json_string "$base")" "$(json_string "$source")" \
      "$(json_string "$ref")" "$(json_string "$installed")" "$(json_string "$resolved")" \
      "$(json_string "${status:-unknown}")" "$(json_string "$at")" "$(json_string "$error")")")
  else
    printf '%-18s %-20s %-8s %-8s installed=%-10s resolved=%-10s last=%s %s %s\n' \
      "$name" "$base" "$source" "$ref" "${installed:--}" "${resolved:--}" "${status:-unknown}" \
      "${at:--}" "$error"
  fi
done < <(app_rows)

if [[ "$FORMAT" == "json" ]]; then
  (IFS=,; printf '[%s]\n' "${json_items[*]:-}")
fi
