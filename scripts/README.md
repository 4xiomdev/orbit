# Orbit release scripts

## `release.sh`

Builds a direct-download Orbit release:

1. archives the app with `xcodebuild`
2. exports a signed Developer ID build
3. creates a drag-install DMG
4. creates an installer PKG that opens Orbit after install
5. notarizes and staples the DMG, and the PKG when a Developer ID Installer certificate is available
6. optionally creates a GitHub release if `gh` is installed and authenticated

### Requirements

- Xcode with your Developer ID signing setup
- `Developer ID Application`
- optional `Developer ID Installer` if you want a signed/notarized PKG
- `create-dmg`
- optional `gh`
- optional notarization credentials stored with:

```bash
xcrun notarytool store-credentials "AC_PASSWORD" \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID
```

### Usage

```bash
./scripts/release.sh
./scripts/release.sh 1.0
./scripts/release.sh 1.0 2026040801
```

Set `GITHUB_REPO=owner/repo` before running if you want the script to publish a GitHub release.
