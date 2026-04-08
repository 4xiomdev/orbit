# AGENTS.md - Orbit (Main App Target)

## Core Architecture

### Voice and Codex pipeline
- `OrbitDictationManager.swift` manages push-to-talk, audio capture, and speech-to-text provider selection.
- `OrbitSpeechToTextProvider.swift` defines the STT abstraction and selects providers from the active Orbit preset.
- `OpenAITranscriptionProvider.swift` is the default cloud STT provider using `gpt-4o-mini-transcribe`.
- `AppleSpeechTranscriptionProvider.swift` is the built-in macOS STT fallback.
- `TextToSpeechProvider.swift` defines the TTS abstraction plus provider factory logic.
- `OpenAITTSProvider.swift` is the default cloud TTS provider using `gpt-4o-mini-tts`.
- `TextToSpeechProvider.swift` also includes `AppleSystemTTSProvider` as the local speech fallback.
- `OrbitOpenAIVoiceConfiguration.swift` stores the Cloud voice API key in Keychain and validates it.

### Actions and state
- `ActionProvider.swift` defines Orbit's unified Codex request contract.
- `CodexAppServerActionProvider.swift` streams action progress from `codex app-server`.
- `OrbitSettings.swift` stores persisted menu bar settings in `UserDefaults`, including voice mode, Codex effort, and cursor visibility.
- `OrbitManager.swift` orchestrates Codex turns, current-screen screenshot capture, cursor overlay, and spoken summaries.

### UI shell
- `OrbitApp.swift` boots the menu bar app and startup services.
- `OrbitPanelView.swift` renders the compact panel, including Orbit preset controls and action status.
- `MenuBarPanelManager.swift` and `OverlayWindow.swift` own the menu bar shell and cursor-adjacent overlay behavior.
- `OrbitScreenCaptureUtility.swift` captures current-screen context for Codex turns.

## Defaults

- STT default: OpenAI `gpt-4o-mini-transcribe`
- Codex model default: `gpt-5.4-mini`
- Codex effort default: `medium`
- Codex service tier default: `fast`
- TTS default: OpenAI `gpt-4o-mini-tts`
- Local fallbacks: Apple Speech and Apple system speech
- Unified assistant path: Codex app-server
