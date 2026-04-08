# Orbit

Orbit is a Codex-native macOS menu bar assistant. It wraps a persistent Codex app-server session with push-to-talk voice input, current-screen capture, an always-on-top cursor overlay, and compact menu bar controls.

## Product shape

- One persistent Codex session per app run
- Current-screen screenshot context attached to voice requests
- Optional `[POINT:...]` tags in final Codex answers for cursor-guided help
- Codex progress HUD in the top-right overlay
- Direct-download, unsandboxed macOS utility design
- Bundled Codex runtime in release builds
- Managed ChatGPT login on first run when shared Codex auth is not already present

## Voice modes

- `Local` — Apple Speech transcription and Apple system speech
- `Cloud` — OpenAI `gpt-4o-mini-transcribe` transcription and OpenAI `gpt-4o-mini-tts`

## Runtime stack

- Voice input: push-to-talk via global shortcut
- STT: OpenAI first, Apple fallback
- Brain and actions: Codex app-server
- TTS: OpenAI first, Apple fallback
- UI shell: SwiftUI + AppKit menu bar panel and transparent screen overlays

## Configuration

Orbit stores the Cloud voice OpenAI API key in the macOS Keychain through Orbit’s onboarding/settings UI.

Optional bundle or environment overrides still exist for local development:

- `OpenAIAPIKey`
- `OpenAITranscriptionModel`
- optional `CodexActionModel`
- optional `CodexActionSandbox`
- optional `CodexCLIPath` for advanced external runtime override
- optional `AppleTTSVoiceIdentifier`

Defaults already bundled:

- `OpenAITranscriptionModel = gpt-4o-mini-transcribe`
- `OpenAITTSModel = gpt-4o-mini-tts`
- `CodexActionModel = gpt-5.4-mini`
- `CodexActionSandbox = danger-full-access`

## Running

Open [Orbit.xcodeproj](/Users/4xiom/orbit/Orbit.xcodeproj/project.pbxproj) in Xcode, choose the `Orbit` target, set your signing team, then run from Xcode.

Orbit is currently optimized for direct download and notarized distribution, not the Mac App Store. It depends on full desktop permissions.

Debug builds can use a locally installed `codex` CLI. Release packaging bundles a Codex runtime into `Orbit.app/Contents/Resources/CodexRuntime` and Orbit prefers that bundled runtime automatically.

Orbit uses the normal shared Codex home at `~/.codex`, so an existing ChatGPT login can be reused automatically. If no shared Codex auth is present, Orbit opens the Codex app-server managed ChatGPT browser flow on first run.

Cloud voice setup is separate from Codex auth. When a user chooses `Cloud`, Orbit asks for an OpenAI API key once, validates it, then stores it in Keychain for later launches.

## Release

Use [scripts/release.sh](/Users/4xiom/orbit/scripts/release.sh) for direct-download builds. The release script now:

- regenerates the standardized Orbit icon and DMG artwork
- archives the app
- bundles a Codex runtime into the archived app
- exports a signed Developer ID app
- creates the DMG
- notarizes when `AC_PASSWORD` notary credentials are configured

Before cutting the first public DMG on a machine, install `create-dmg` and add the `AC_PASSWORD` notary profile to Keychain.
