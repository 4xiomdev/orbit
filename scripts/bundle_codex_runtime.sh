#!/bin/bash
set -euo pipefail

APP_BUNDLE_PATH="${1:-}"

if [[ -z "${APP_BUNDLE_PATH}" ]]; then
    echo "usage: $0 /absolute/path/to/Orbit.app" >&2
    exit 1
fi

if [[ ! -d "${APP_BUNDLE_PATH}" ]]; then
    echo "Orbit app bundle not found at ${APP_BUNDLE_PATH}" >&2
    exit 1
fi

resolve_realpath() {
    python3 - "$1" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
}

resolve_codex_source() {
    if [[ -n "${CODEX_CLI_PATH:-}" && -x "${CODEX_CLI_PATH}" ]]; then
        printf '%s\n' "${CODEX_CLI_PATH}"
        return 0
    fi

    if command -v codex >/dev/null 2>&1; then
        command -v codex
        return 0
    fi

    return 1
}

CODEX_SOURCE="$(resolve_codex_source || true)"
if [[ -z "${CODEX_SOURCE}" ]]; then
    echo "Could not find a Codex CLI to bundle. Set CODEX_CLI_PATH or install codex first." >&2
    exit 1
fi

CODEX_JS="$(resolve_realpath "${CODEX_SOURCE}")"
PACKAGE_ROOT="$(cd "$(dirname "${CODEX_JS}")/.." && pwd)"
NODE_BIN="$(cd "$(dirname "${CODEX_SOURCE}")" && pwd)/node"

if [[ ! -x "${NODE_BIN}" ]]; then
    echo "Could not find sibling node binary for ${CODEX_SOURCE}" >&2
    exit 1
fi

find_vendor_root() {
    local package_root="$1"
    local candidate=""

    while IFS= read -r candidate; do
        if find "${candidate}" -type f \( -name codex -o -name codex.exe \) -print -quit | grep -q .; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done < <(find "${package_root}" -type d -name vendor | sort)

    return 1
}

VENDOR_ROOT="$(find_vendor_root "${PACKAGE_ROOT}" || true)"
if [[ -z "${VENDOR_ROOT}" ]]; then
    echo "Could not find Codex vendor runtime under ${PACKAGE_ROOT}" >&2
    exit 1
fi

RUNTIME_ROOT="${APP_BUNDLE_PATH}/Contents/Resources/CodexRuntime"
BIN_ROOT="${RUNTIME_ROOT}/bin"
VENDOR_DEST="${RUNTIME_ROOT}/vendor"

rm -rf "${RUNTIME_ROOT}"
mkdir -p "${BIN_ROOT}" "${VENDOR_DEST}"

cp "${CODEX_JS}" "${BIN_ROOT}/codex"
chmod 755 "${BIN_ROOT}/codex"
cp "${NODE_BIN}" "${BIN_ROOT}/node"
chmod 755 "${BIN_ROOT}/node"

if [[ -x "${PACKAGE_ROOT}/bin/rg" ]]; then
    cp "${PACKAGE_ROOT}/bin/rg" "${BIN_ROOT}/rg"
    chmod 755 "${BIN_ROOT}/rg"
fi

ditto "${VENDOR_ROOT}" "${VENDOR_DEST}"

echo "Bundled Codex runtime into ${RUNTIME_ROOT}"
