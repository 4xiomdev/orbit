#!/bin/bash
set -euo pipefail

USER_HOME="${HOME}"
USER_UID="$(id -u)"
ORBIT_BUNDLE_ID="com.orbit.codex"
ORBIT_APP_PATH="/Applications/Orbit.app"
SHARED_CODEX_HOME="${CODEX_HOME:-${USER_HOME}/.codex}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WIPE_SHARED_CODEX=0

if [[ "${1:-}" == "--wipe-shared-codex" ]]; then
    WIPE_SHARED_CODEX=1
fi

echo "🧹 Resetting Orbit clean-room state..."

orbit_process_patterns=(
    "/Applications/Orbit.app/Contents/MacOS/Orbit"
    "/Users/.*/DerivedData/.*/Orbit.app/Contents/MacOS/Orbit"
    "/Users/.*/orbit/build.*/.*Orbit.app/Contents/MacOS/Orbit"
    "/Users/.*/orbit/.*/Orbit.app/Contents/MacOS/Orbit"
)

for pattern in "${orbit_process_patterns[@]}"; do
    pkill -f "${pattern}" >/dev/null 2>&1 || true
done

while read -r label; do
    [[ -z "${label}" ]] && continue
    /bin/launchctl bootout "gui/${USER_UID}/${label}" >/dev/null 2>&1 || true
done < <(
    launchctl print "gui/${USER_UID}" 2>/dev/null \
        | rg -o 'application\.com\.orbit\.codex\.[^[:space:]]+' || true
)

if sfltool dumpbtm 2>/dev/null | rg -q 'com\.orbit\.codex'; then
    echo "⚠️ Orbit background-task entries still exist; resetting the Background Task database."
    sfltool resetbtm >/dev/null 2>&1 || true
fi

rm -rf "${ORBIT_APP_PATH}"

defaults delete "${ORBIT_BUNDLE_ID}" >/dev/null 2>&1 || true
tccutil reset Accessibility "${ORBIT_BUNDLE_ID}" >/dev/null 2>&1 || true
tccutil reset ScreenCapture "${ORBIT_BUNDLE_ID}" >/dev/null 2>&1 || true
tccutil reset Microphone "${ORBIT_BUNDLE_ID}" >/dev/null 2>&1 || true

rm -rf \
    "${USER_HOME}/Library/Caches/${ORBIT_BUNDLE_ID}" \
    "${USER_HOME}/Library/HTTPStorages/${ORBIT_BUNDLE_ID}" \
    "${USER_HOME}/Library/Preferences/${ORBIT_BUNDLE_ID}.plist" \
    "${USER_HOME}/Library/Saved Application State/${ORBIT_BUNDLE_ID}.savedState" \
    "${USER_HOME}/Library/Application Support/Orbit" \
    "${USER_HOME}/Library/Logs/Orbit"

rm -rf "${USER_HOME}/Library/Developer/Xcode/DerivedData"/Orbit-* 2>/dev/null || true
rm -rf "${PROJECT_DIR}"/build "${PROJECT_DIR}"/build-* 2>/dev/null || true

if [[ "${WIPE_SHARED_CODEX}" == "1" ]]; then
    echo "🔐 Wiping shared Codex auth/session state..."
    rm -f \
        "${SHARED_CODEX_HOME}/auth.json" \
        "${SHARED_CODEX_HOME}/session_index.jsonl" \
        "${SHARED_CODEX_HOME}/.codex-global-state.json"
    rm -rf "${SHARED_CODEX_HOME}/sessions"

    if pgrep -fal '/Applications/Codex.app/Contents/MacOS/Codex|/Applications/CodexBar.app/Contents/MacOS/CodexBar' >/dev/null 2>&1; then
        echo "⚠️ Codex desktop is currently running, so live SQLite state was preserved to avoid breaking this session."
    else
        rm -f "${SHARED_CODEX_HOME}"/state_*.sqlite "${SHARED_CODEX_HOME}"/state_*.sqlite-shm "${SHARED_CODEX_HOME}"/state_*.sqlite-wal 2>/dev/null || true
    fi
fi

echo "✅ Orbit clean-room reset complete"
