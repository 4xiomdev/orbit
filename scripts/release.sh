#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"

# Direct-download release helper for Orbit.
# Builds, exports, packages, notarizes, and optionally creates a GitHub release.

SCHEME="Orbit"
APP_NAME="Orbit"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ORBIT_BUILD_DIR:-${PROJECT_DIR}/build-$(date +%Y%m%d%H%M%S)}"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"
GITHUB_REPO="${GITHUB_REPO:-}"
ORBIT_SKIP_GITHUB_RELEASE="${ORBIT_SKIP_GITHUB_RELEASE:-0}"
BUNDLE_RUNTIME_SCRIPT="${PROJECT_DIR}/scripts/bundle_codex_runtime.sh"
GENERATE_BRAND_ASSETS_SCRIPT="${PROJECT_DIR}/scripts/generate_brand_assets.swift"
DEVELOPMENT_TEAM_ID="${ORBIT_DEVELOPMENT_TEAM:-}"
DEVELOPER_ID_IDENTITY="${ORBIT_DEVELOPER_ID_IDENTITY:-}"
DEVELOPER_ID_INSTALLER_IDENTITY="${ORBIT_DEVELOPER_ID_INSTALLER_IDENTITY:-}"

if [[ -z "${DEVELOPMENT_TEAM_ID}" ]]; then
    DEVELOPMENT_TEAM_ID="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamManagerLastSelectedTeamID 2>/dev/null || true)"
fi

if [[ -z "${DEVELOPMENT_TEAM_ID}" ]]; then
    IDENTITY_OUTPUT="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    DEVELOPMENT_TEAM_ID="$(printf '%s\n' "${IDENTITY_OUTPUT}" | grep -Eo '\([A-Z0-9]{10}\)' | tr -d '()' | head -n 1)"
fi

if [[ -z "${DEVELOPMENT_TEAM_ID}" ]]; then
    echo "❌ No local Apple signing team was detected. Set ORBIT_DEVELOPMENT_TEAM and try again."
    exit 1
fi

if [[ -z "${DEVELOPER_ID_IDENTITY}" ]]; then
    DEVELOPER_ID_IDENTITY="$(
        security find-identity -v -p codesigning 2>/dev/null |
        sed -nE "s/^[[:space:]]*[0-9]+\) [A-F0-9]+ \"(Developer ID Application: .+ \\(${DEVELOPMENT_TEAM_ID}\\))\"$/\\1/p" |
        head -n 1
    )"
fi

if [[ -z "${DEVELOPER_ID_IDENTITY}" ]]; then
    echo "❌ No Developer ID Application identity was detected for team ${DEVELOPMENT_TEAM_ID}."
    exit 1
fi

if [[ -z "${DEVELOPER_ID_INSTALLER_IDENTITY}" ]]; then
    DEVELOPER_ID_INSTALLER_IDENTITY="$(
        security find-identity -v -p basic 2>/dev/null |
        sed -nE "s/^[[:space:]]*[0-9]+\) [A-F0-9]+ \"(Developer ID Installer: .+ \\(${DEVELOPMENT_TEAM_ID}\\))\"$/\\1/p" |
        head -n 1
    )"
fi

if [[ -z "${GITHUB_REPO}" ]] && command -v git >/dev/null 2>&1; then
    if git -C "${PROJECT_DIR}" remote get-url origin >/dev/null 2>&1; then
        ORIGIN_URL="$(git -C "${PROJECT_DIR}" remote get-url origin)"
        if [[ "${ORIGIN_URL}" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
            GITHUB_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        fi
    fi
fi

if ! command -v create-dmg >/dev/null 2>&1; then
    echo "❌ create-dmg is required. Install it with: brew install create-dmg"
    exit 1
fi

DEFAULT_MARKETING_VERSION="$(
    sed -nE 's/^[[:space:]]*MARKETING_VERSION = ([^;]+);$/\1/p' "${PROJECT_DIR}/Orbit.xcodeproj/project.pbxproj" | head -n 1
)"
MARKETING_VERSION="${1:-${DEFAULT_MARKETING_VERSION:-1.0.4}}"
BUILD_NUMBER="${2:-$(date +%Y%m%d%H%M)}"
TAG="v${MARKETING_VERSION}"
DMG_PATH="${BUILD_DIR}/${APP_NAME}-${MARKETING_VERSION}.dmg"
PKG_PATH="${BUILD_DIR}/${APP_NAME}-${MARKETING_VERSION}.pkg"
PKG_ROOT="${BUILD_DIR}/pkg-root"
PKG_SCRIPTS_DIR="${PROJECT_DIR}/scripts/installer"
PKG_COMPONENT_PLIST="${BUILD_DIR}/components.plist"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

echo "🚀 Releasing ${APP_NAME} ${TAG} (build ${BUILD_NUMBER})"
if [[ -n "${GITHUB_REPO}" ]]; then
    echo "   Repo: ${GITHUB_REPO}"
else
    echo "   Repo: (not configured)"
fi
echo "   Team: ${DEVELOPMENT_TEAM_ID}"
echo ""

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}"

echo "🎨 Generating branded app assets..."
swift "${GENERATE_BRAND_ASSETS_SCRIPT}"

cat > "${EXPORT_OPTIONS}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM_ID}</string>
</dict>
</plist>
PLIST

echo "📦 Archiving..."
xcodebuild archive \
    -project "${PROJECT_DIR}/Orbit.xcodeproj" \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM_ID}"

echo "📎 Bundling Codex runtime..."
"${BUNDLE_RUNTIME_SCRIPT}" "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"

echo "📤 Exporting signed app..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}"

EXPORT_APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
if [[ -f "${EXPORT_APP_PATH}/Contents/Resources/LocalSecrets.plist" ]]; then
    echo "🧼 Removing bundled LocalSecrets from release app..."
    rm -f "${EXPORT_APP_PATH}/Contents/Resources/LocalSecrets.plist"
fi

echo "🔏 Re-signing bundled runtime executables..."
while IFS= read -r executable_path; do
    codesign --force --sign "${DEVELOPER_ID_IDENTITY}" --options runtime --timestamp "${executable_path}"
done < <(find "${EXPORT_APP_PATH}/Contents/Resources/CodexRuntime" -type f -perm -111 | sort)

codesign --force \
    --sign "${DEVELOPER_ID_IDENTITY}" \
    --options runtime \
    --timestamp \
    --entitlements "${PROJECT_DIR}/Orbit/Orbit.entitlements" \
    "${EXPORT_APP_PATH}"

echo "📦 Building installer package..."
rm -rf "${PKG_ROOT}"
mkdir -p "${PKG_ROOT}/Applications"
cp -R "${EXPORT_APP_PATH}" "${PKG_ROOT}/Applications/"

# Prevent Installer from "relocating" Orbit onto previously moved dev/export
# app bundles that happen to share the same bundle identifier.
cat > "${PKG_COMPONENT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>RootRelativeBundlePath</key>
        <string>Applications/${APP_NAME}.app</string>
        <key>BundleIsRelocatable</key>
        <false/>
        <key>BundleIsVersionChecked</key>
        <true/>
        <key>BundleHasStrictIdentifier</key>
        <true/>
        <key>BundleOverwriteAction</key>
        <string>upgrade</string>
    </dict>
</array>
</plist>
PLIST

PKGBUILD_ARGS=(
    --root "${PKG_ROOT}"
    --component-plist "${PKG_COMPONENT_PLIST}"
    --scripts "${PKG_SCRIPTS_DIR}"
    --identifier "com.orbit.codex.installer"
    --version "${MARKETING_VERSION}"
    --install-location "/"
)

if [[ -n "${DEVELOPER_ID_INSTALLER_IDENTITY}" ]]; then
    PKGBUILD_ARGS+=(--sign "${DEVELOPER_ID_INSTALLER_IDENTITY}")
else
    echo "⚠️ No Developer ID Installer identity detected for team ${DEVELOPMENT_TEAM_ID}. Building an unsigned PKG."
fi

pkgbuild "${PKGBUILD_ARGS[@]}" "${PKG_PATH}"

echo "💿 Creating DMG..."
create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 160 195 \
    --app-drop-link 500 195 \
    --background "${DMG_BACKGROUND}" \
    "${DMG_PATH}" \
    "${EXPORT_APP_PATH}"

if xcrun notarytool history --keychain-profile "AC_PASSWORD" >/dev/null 2>&1; then
    echo "🔏 Notarizing DMG..."
    xcrun notarytool submit "${DMG_PATH}" --keychain-profile "AC_PASSWORD" --wait
    xcrun stapler staple "${DMG_PATH}"
    if [[ -n "${DEVELOPER_ID_INSTALLER_IDENTITY}" ]]; then
        echo "🔏 Notarizing PKG..."
        xcrun notarytool submit "${PKG_PATH}" --keychain-profile "AC_PASSWORD" --wait
        xcrun stapler staple "${PKG_PATH}"
    else
        echo "⚠️ Skipping PKG notarization because no Developer ID Installer identity is configured."
    fi
else
    echo "⚠️ Skipping notarization because AC_PASSWORD credentials are not configured in Keychain."
fi

if [[ "${ORBIT_SKIP_GITHUB_RELEASE}" == "1" ]]; then
    echo "⚠️ Skipping GitHub release creation because ORBIT_SKIP_GITHUB_RELEASE=1."
elif [[ -n "${GITHUB_REPO}" ]] && command -v gh >/dev/null 2>&1; then
    echo "🏷️ Creating GitHub release ${TAG}..."
    RELEASE_ASSETS=("${DMG_PATH}")
    if [[ -f "${PKG_PATH}" ]]; then
        RELEASE_ASSETS+=("${PKG_PATH}")
    fi
    gh release create "${TAG}" "${RELEASE_ASSETS[@]}" \
        --repo "${GITHUB_REPO}" \
        --title "${TAG}" \
        --notes "Orbit ${TAG}"
else
    echo "⚠️ Skipping GitHub release creation because repo is not configured or GitHub CLI is unavailable."
fi

echo ""
echo "✅ Release artifacts ready"
echo "   DMG: ${DMG_PATH}"
echo "   PKG: ${PKG_PATH}"
