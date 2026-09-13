#!/usr/bin/env bash
set -euo pipefail

ensure_secret() {
  :
}

if yq -e '.applications.fixtureapp.enabled == true' "$APPS_CONFIG" >/dev/null 2>&1; then
  ensure_secret "app_declared_token" "Fixture app token"
fi

if yq -e '.applications.disabledapp.enabled == true' "$APPS_CONFIG" >/dev/null 2>&1; then
  ensure_secret "disabled_declared_token" "Disabled app token"
fi
