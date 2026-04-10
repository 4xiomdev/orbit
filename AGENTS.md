# Orbit Agent Notes

Orbit is a Codex-native macOS menu bar assistant.

## Current architecture

- UI shell: SwiftUI + AppKit panel/overlay
- STT: OpenAI `gpt-4o-mini-transcribe` with Apple Speech fallback
- Brain and actions: Codex app-server
- TTS: OpenAI `gpt-4o-mini-tts` with Apple system speech fallback

## Important files

- [Orbit/OrbitManager.swift](Orbit/OrbitManager.swift) — unified Codex routing, screenshots, overlay updates, action summaries
- [Orbit/OrbitDictationManager.swift](Orbit/OrbitDictationManager.swift) — push-to-talk capture and STT session management
- [Orbit/OrbitSettings.swift](Orbit/OrbitSettings.swift) — persisted voice mode, Codex effort, and overlay settings
- [Orbit/CodexAppServerActionProvider.swift](Orbit/CodexAppServerActionProvider.swift) — persistent Codex session and event streaming
- [Orbit/OverlayWindow.swift](Orbit/OverlayWindow.swift) — Orbit cursor, HUD, and pointing animations

## Notes

- Keep the point-tag flow in v1 instead of introducing a second coordinate detection architecture.
- Orbit now uses one persistent Codex session for both answers and actions.
- Menu bar settings should stay compact; prefer clear model/effort controls over sprawling configuration UI.
