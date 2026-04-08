#!/bin/bash
set -euo pipefail

PROFILE_NAME="${1:-AC_PASSWORD}"
DEFAULT_TEAM_ID="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamManagerLastSelectedTeamID 2>/dev/null || true)"

echo "🔐 Store Apple notarization credentials in Keychain"
echo "   Profile: ${PROFILE_NAME}"
if [[ -n "${DEFAULT_TEAM_ID}" ]]; then
    echo "   Default team: ${DEFAULT_TEAM_ID}"
fi
echo ""

read -r -p "Apple ID email: " APPLE_ID

TEAM_ID="${DEFAULT_TEAM_ID}"
read -r -p "Team ID [${TEAM_ID:-none}]: " TEAM_INPUT
if [[ -n "${TEAM_INPUT}" ]]; then
    TEAM_ID="${TEAM_INPUT}"
fi

if [[ -z "${APPLE_ID}" || -z "${TEAM_ID}" ]]; then
    echo "❌ Apple ID and Team ID are required."
    exit 1
fi

echo ""
echo "Use an Apple app-specific password from appleid.apple.com."
echo ""

read -r -s -p "App-specific password: " APP_SPECIFIC_PASSWORD
echo ""

if [[ -z "${APP_SPECIFIC_PASSWORD}" ]]; then
    echo "❌ App-specific password is required."
    exit 1
fi

xcrun notarytool store-credentials "${PROFILE_NAME}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${TEAM_ID}" \
    --password "${APP_SPECIFIC_PASSWORD}"

echo ""
echo "✅ Stored Keychain profile '${PROFILE_NAME}'"
