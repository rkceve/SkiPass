#!/usr/bin/env bash
# Writes ios/Config/Secrets.xcconfig from CI secrets (docs/CONTRACTS.md §2).
# Values that are unset keep the defaults from Secrets.example.xcconfig. Never prints values.
set -euo pipefail

out=ios/Config/Secrets.xcconfig
: > "$out"

# xcconfig treats "//" as a comment start; escape it as "/$()/".
esc() { printf '%s' "$1" | sed 's#//#/$()/#g'; }

[ -n "${SKIPASS_SERVER_URL:-}" ] && echo "SKIPASS_SERVER_URL = $(esc "$SKIPASS_SERVER_URL")" >> "$out"
[ -n "${SKIPASS_APP_TOKEN:-}" ] && echo "SKIPASS_APP_TOKEN = $(esc "$SKIPASS_APP_TOKEN")" >> "$out"
if [ -n "${GOOGLE_CLIENT_ID:-}" ]; then
  echo "GOOGLE_CLIENT_ID_PREFIX = ${GOOGLE_CLIENT_ID%.apps.googleusercontent.com}" >> "$out"
fi
[ -n "${MICROSOFT_CLIENT_ID:-}" ] && echo "MICROSOFT_CLIENT_ID = $MICROSOFT_CLIENT_ID" >> "$out"
[ -n "${REVENUECAT_API_KEY:-}" ] && echo "REVENUECAT_API_KEY = $REVENUECAT_API_KEY" >> "$out"

echo "Secrets.xcconfig keys: $(cut -d' ' -f1 "$out" | tr '\n' ' ')"

# Unset secrets leave the example placeholders in Info.plist; the app then treats Google /
# Microsoft sign-in as not configured and shows no purchasable plans.
for name in SKIPASS_SERVER_URL SKIPASS_APP_TOKEN GOOGLE_CLIENT_ID MICROSOFT_CLIENT_ID REVENUECAT_API_KEY; do
  if [ -z "${!name:-}" ]; then
    echo "::warning::GitHub secret $name is not set; this build keeps the example placeholder"
  fi
done
