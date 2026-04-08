# Contributing to Orbit

Thanks for helping improve Orbit.

## Before you start

- Check open issues before starting a larger change.
- For substantial product or architectural changes, open an issue or discussion first so the direction is aligned.
- Security issues should go through [SECURITY.md](SECURITY.md), not public issues.

## Development setup

Requirements:

- macOS 13 or later
- Xcode
- Git

Clone the repo and build locally:

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Run unit tests:

```bash
xcodebuild -project Orbit.xcodeproj -scheme Orbit -destination 'platform=macOS' -only-testing:OrbitTests test CODE_SIGNING_ALLOWED=NO
```

If you want to run the full app with signing, open the project in Xcode and run the `Orbit` scheme with your own signing team.

## Branch and PR workflow

- Treat `main` as a protected branch.
- Create a feature branch for changes.
- Keep pull requests focused and easy to review.
- Include screenshots or short clips for visible UI changes when possible.
- Call out any permission-flow, auth-flow, or release-script changes explicitly in the PR description.

## Code and product expectations

- Prefer small, readable changes over broad rewrites.
- Keep the menu bar UI compact and calm.
- Avoid adding telemetry, hidden network services, or background infrastructure.
- Do not commit local secrets, signing credentials, notarization credentials, or API keys.
- If a change affects installation, onboarding, screen permissions, or auth, test that flow directly.

## Maintainer notes

- `scripts/release.sh` is the canonical release path for signed direct-download builds.
- Release credentials are local-machine concerns and should never be checked in.
- The public installer is PKG-first, with DMG retained as a quieter fallback artifact.
