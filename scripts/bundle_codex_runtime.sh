#!/bin/bash
set -euo pipefail

APP_BUNDLE_PATH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BROWSER_RUNTIME_SOURCE_DIR="${PROJECT_DIR}/BundledResources/browser-runtime"
BUNDLED_SKILLS_SOURCE_DIR="${PROJECT_DIR}/BundledResources/skills"
MODEL_INSTRUCTIONS_SOURCE_PATH="${PROJECT_DIR}/BundledResources/orbit-model-instructions.md"

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
BROWSER_TOOLS_ROOT="${RUNTIME_ROOT}/browser-tools"
SKILLS_DEST="${APP_BUNDLE_PATH}/Contents/Resources/OrbitBundledSkills"
MODEL_INSTRUCTIONS_DEST="${APP_BUNDLE_PATH}/Contents/Resources/OrbitModelInstructions.md"

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

if [[ ! -f "${BROWSER_RUNTIME_SOURCE_DIR}/package.json" || ! -f "${BROWSER_RUNTIME_SOURCE_DIR}/package-lock.json" ]]; then
    echo "Bundled browser runtime manifest is missing from ${BROWSER_RUNTIME_SOURCE_DIR}" >&2
    exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "npm is required to bundle the browser MCP runtime." >&2
    exit 1
fi

TMP_BROWSER_RUNTIME="$(mktemp -d)"
cleanup_tmp_runtime() {
    rm -rf "${TMP_BROWSER_RUNTIME}"
}
trap cleanup_tmp_runtime EXIT

cp "${BROWSER_RUNTIME_SOURCE_DIR}/package.json" "${TMP_BROWSER_RUNTIME}/package.json"
cp "${BROWSER_RUNTIME_SOURCE_DIR}/package-lock.json" "${TMP_BROWSER_RUNTIME}/package-lock.json"

(
    cd "${TMP_BROWSER_RUNTIME}"
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --omit=dev --ignore-scripts --no-audit --no-fund
)

mkdir -p "${BROWSER_TOOLS_ROOT}"
ditto "${TMP_BROWSER_RUNTIME}/node_modules" "${BROWSER_TOOLS_ROOT}/node_modules"

cat > "${BIN_ROOT}/chrome-devtools-mcp" <<'EOF'
#!/bin/sh
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/node" "${SCRIPT_DIR}/../browser-tools/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js" "$@"
EOF
chmod 755 "${BIN_ROOT}/chrome-devtools-mcp"

cat > "${BIN_ROOT}/playwright-mcp" <<'EOF'
#!/bin/sh
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "${SCRIPT_DIR}/node" "${SCRIPT_DIR}/../browser-tools/node_modules/@playwright/mcp/cli.js" "$@"
EOF
chmod 755 "${BIN_ROOT}/playwright-mcp"

rm -rf "${SKILLS_DEST}"
if [[ -d "${BUNDLED_SKILLS_SOURCE_DIR}" ]]; then
    ditto "${BUNDLED_SKILLS_SOURCE_DIR}" "${SKILLS_DEST}"
else
    echo "Bundled skills directory is missing from ${BUNDLED_SKILLS_SOURCE_DIR}" >&2
    exit 1
fi

if [[ -f "${MODEL_INSTRUCTIONS_SOURCE_PATH}" ]]; then
    cp "${MODEL_INSTRUCTIONS_SOURCE_PATH}" "${MODEL_INSTRUCTIONS_DEST}"
else
    echo "Bundled model instructions file is missing from ${MODEL_INSTRUCTIONS_SOURCE_PATH}" >&2
    exit 1
fi

echo "Bundled Codex runtime into ${RUNTIME_ROOT}"
