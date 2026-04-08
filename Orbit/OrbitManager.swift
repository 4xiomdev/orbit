//
//  OrbitManager.swift
//  Orbit
//
//  Central state manager for Orbit's voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum OrbitVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum OrbitSetupStage: Equatable {
    case permissions
    case auth
    case voiceChoice
    case cloudKey
    case onboarding
    case setupComplete
    case ready
}

@MainActor
final class OrbitManager: ObservableObject {
    let settings = OrbitSettings.shared

    @Published private(set) var voiceState: OrbitVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var screenAccessDiagnosticSummary: String?
    @Published private(set) var textToSpeechProviderDisplayName: String = ""
    @Published private(set) var availableAppleVoices: [OrbitAppleVoiceOption] = []
    @Published private(set) var selectedAppleVoiceSummary: String = "Auto"
    @Published private(set) var openAICloudCredentialState: OrbitOpenAICloudCredentialState = .missing

    /// Screen location (global AppKit coords) of a detected UI element the
    /// Orbit cursor should fly to and point at.
    @Published var detectedElementScreenLocation: CGPoint?
    @Published var detectedElementDisplayFrame: CGRect?
    @Published var detectedElementBubbleText: String?
    @Published private(set) var activeActionStatus: OrbitActionStatus = .idle
    @Published private(set) var activeActionProgress: OrbitActionProgress?
    @Published private(set) var activeActionStatusSummary: String?
    @Published private(set) var activeActionDetailLine: String?
    @Published private(set) var codexSessionSummary: String = "Codex session idle"
    @Published private(set) var codexConfigurationSummary: String = ""
    @Published private(set) var availableCodexModels: [OrbitCodexModelOption] = OrbitCodexModelOption.fallbackPickerModels
    @Published private(set) var availableCodexEfforts: [OrbitCodexReasoningEffort] = OrbitCodexReasoningEffort.allCases
    @Published private(set) var codexAuthState: OrbitCodexAuthState = .unknown
    @Published private(set) var codexAccountSummary: String?
    @Published private(set) var recentActionUpdates: [String] = []
    @Published private(set) var showCodexActivityOverlay: Bool = false

    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false
    @Published private(set) var isRunningOnboardingTour: Bool = false

    let orbitDictationManager = OrbitDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let orbitOverlayWindowManager = OrbitOverlayWindowManager()

    private var textToSpeechProvider: any TextToSpeechProvider
    private let fallbackTextToSpeechProvider: any TextToSpeechProvider
    private let actionProvider = CodexAppServerActionProvider()
    private var lastCodexScreenCapture: OrbitScreenCapture?

    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var voicePresetCancellable: AnyCancellable?
    private var appleVoiceCancellable: AnyCancellable?
    private var showCursorCancellable: AnyCancellable?
    private var codexReasoningEffortCancellable: AnyCancellable?
    private var codexServiceTierCancellable: AnyCancellable?
    private var codexModelCancellable: AnyCancellable?
    private var codexOverlayDismissTask: Task<Void, Never>?
    private var transientHideTask: Task<Void, Never>?
    private var onboardingTask: Task<Void, Never>?
    private var codexSessionWarmupTask: Task<Void, Never>?
    private var actionAcknowledgementTask: Task<Void, Never>?
    private var codexWarmupGeneration: Int = 0
    private var hasSpokenActionAcknowledgement = false

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasMicrophonePermission && hasUsableScreenAccessPermission
    }

    var hasUsableScreenAccessPermission: Bool {
        hasScreenContentPermission || hasScreenRecordingPermission
    }

    var setupStage: OrbitSetupStage {
        if !allPermissionsGranted {
            return .permissions
        }

        switch codexAuthState {
        case .authenticated:
            break
        case .unknown, .checking, .authRequired, .loginInProgress, .authFailed, .runtimeUnavailable:
            return .auth
        }

        if !hasCompletedVoiceModeSetup {
            return .voiceChoice
        }

        if settings.voicePreset == .cloudVoice, !openAICloudCredentialState.isReadyForCloudVoice {
            return .cloudKey
        }

        if !hasCompletedOnboarding {
            return .onboarding
        }

        if !hasSeenSetupComplete {
            return .setupComplete
        }

        return .ready
    }

    @Published private(set) var isOverlayVisible: Bool = false

    @Published var isOrbitCursorEnabled: Bool = OrbitSettings.shared.showCursor

    func setOrbitCursorEnabled(_ enabled: Bool) {
        isOrbitCursorEnabled = enabled
        settings.showCursor = enabled
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            orbitOverlayWindowManager.hasShownOverlayBefore = true
            orbitOverlayWindowManager.showOverlay(onScreens: NSScreen.screens, orbitManager: self)
            isOverlayVisible = true
        } else {
            orbitOverlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    var hasSeenSetupComplete: Bool {
        get {
            if UserDefaults.standard.object(forKey: "hasSeenSetupComplete") == nil {
                return hasCompletedOnboarding
            }
            return UserDefaults.standard.bool(forKey: "hasSeenSetupComplete")
        }
        set { UserDefaults.standard.set(newValue, forKey: "hasSeenSetupComplete") }
    }

    func dismissSetupComplete() {
        hasSeenSetupComplete = true
    }

    var hasCompletedVoiceModeSetup: Bool {
        get {
            if UserDefaults.standard.object(forKey: "hasCompletedVoiceModeSetup") == nil {
                return hasCompletedOnboarding
            }
            return UserDefaults.standard.bool(forKey: "hasCompletedVoiceModeSetup")
        }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedVoiceModeSetup") }
    }

    init() {
        self.textToSpeechProvider = OrbitTTSProviderFactory.makePrimaryProvider(for: OrbitSettings.shared.voicePreset)
        self.fallbackTextToSpeechProvider = OrbitTTSProviderFactory.makeFallbackProvider()
        self.textToSpeechProviderDisplayName = textToSpeechProvider.displayName
        self.availableAppleVoices = []
        self.selectedAppleVoiceSummary = "System Default"
        self.codexSessionSummary = actionProvider.sessionStatusSummary
        self.codexConfigurationSummary = actionProvider.configurationSummary
        self.availableCodexModels = actionProvider.availableModels
        self.availableCodexEfforts = actionProvider.supportedEffortsForSelectedModel
        self.codexAuthState = actionProvider.authState
        self.codexAccountSummary = actionProvider.accountSummary
        self.openAICloudCredentialState = OrbitOpenAIKeychainStore.resolvedAPIKey().map { .connected(source: $0.source) } ?? .missing
        self.actionProvider.stateDidChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshActionProviderPresentation()
            }
        }
    }

    func start() {
        refreshAllPermissions()
        print("🪐 Orbit start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindSettings()
        refreshCloudCredentialState()
        ensureCodexSessionReady(forceFreshSession: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.ensureCodexSessionReady(forceFreshSession: false)
        }

        if hasCompletedOnboarding && allPermissionsGranted && isOrbitCursorEnabled {
            orbitOverlayWindowManager.hasShownOverlayBefore = true
            orbitOverlayWindowManager.showOverlay(onScreens: NSScreen.screens, orbitManager: self)
            isOverlayVisible = true
        }
    }

    func triggerOnboarding() {
        NotificationCenter.default.post(name: .orbitDismissPanel, object: nil)
        onboardingTask?.cancel()
        OrbitAnalytics.trackOnboardingStarted()
        orbitOverlayWindowManager.showOverlay(onScreens: NSScreen.screens, orbitManager: self)
        isOverlayVisible = true
    }

    func replayOnboarding() {
        NotificationCenter.default.post(name: .orbitDismissPanel, object: nil)
        onboardingTask?.cancel()
        OrbitAnalytics.trackOnboardingReplayed()
        orbitOverlayWindowManager.hasShownOverlayBefore = false
        orbitOverlayWindowManager.showOverlay(onScreens: NSScreen.screens, orbitManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        orbitDictationManager.cancelCurrentDictation()
        orbitOverlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        onboardingTask?.cancel()
        codexSessionWarmupTask?.cancel()
        actionAcknowledgementTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        actionProvider.cancelCurrentAction()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        voicePresetCancellable?.cancel()
        appleVoiceCancellable?.cancel()
        showCursorCancellable?.cancel()
        codexModelCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            OrbitAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            OrbitAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            OrbitAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted after a successful real capture.
        // Treat that as usable screen access for setup even if CGPreflight lags
        // behind on a fresh build.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if hasScreenContentPermission && !hasScreenRecordingPermission {
            hasScreenRecordingPermission = true
        }

        updateScreenAccessDiagnostic()

        if !previouslyHadAll && allPermissionsGranted {
            OrbitAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        updateScreenAccessDiagnostic(lastError: "requesting live capture…")
        Task {
            do {
                let capture = try await OrbitScreenCaptureUtility.captureCurrentScreenAsJPEG()
                let didCapture = !capture.imageData.isEmpty
                print("🔑 Screen access verification — bytes: \(capture.imageData.count), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else {
                        updateScreenAccessDiagnostic(lastError: "capture returned 0 bytes")
                        return
                    }
                    WindowPositionManager.recordConfirmedScreenRecordingPermission()
                    hasScreenRecordingPermission = true
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    updateScreenAccessDiagnostic(lastError: "verified via live capture")
                    OrbitAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isOrbitCursorEnabled {
                        orbitOverlayWindowManager.hasShownOverlayBefore = true
                        orbitOverlayWindowManager.showOverlay(onScreens: NSScreen.screens, orbitManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen access verification failed: \(error)")
                let destination = WindowPositionManager.requestScreenRecordingPermission()
                print("⚠️ Screen access fallback destination: \(destination)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    updateScreenAccessDiagnostic(lastError: error.localizedDescription)
                }
            }
        }
    }

    private func updateScreenAccessDiagnostic(lastError: String? = nil) {
        let preflight = CGPreflightScreenCaptureAccess()
        let persistedScreenRecording = WindowPositionManager.hasPreviouslyConfirmedScreenRecordingPermission()
        let persistedScreenContent = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        let usable = hasUsableScreenAccessPermission
        var summary = "debug: preflight=\(preflight) recording=\(hasScreenRecordingPermission) content=\(hasScreenContentPermission) storedRecording=\(persistedScreenRecording) storedContent=\(persistedScreenContent) usable=\(usable)"
        if let lastError, !lastError.isEmpty {
            summary += " error=\(lastError)"
        }
        screenAccessDiagnosticSummary = summary
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = orbitDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = orbitDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                orbitDictationManager.$isFinalizingTranscript,
                orbitDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func bindSettings() {
        voicePresetCancellable = settings.$voicePreset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshTextToSpeechProvider()
                self.refreshCloudCredentialState()
            }

        appleVoiceCancellable = settings.$appleTTSVoiceIdentifier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshTextToSpeechProvider()
            }

        showCursorCancellable = settings.$showCursor
            .receive(on: DispatchQueue.main)
            .sink { [weak self] showCursor in
                self?.isOrbitCursorEnabled = showCursor
            }

        codexReasoningEffortCancellable = settings.$codexReasoningEffort
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshActionProviderPresentation()
            }

        codexServiceTierCancellable = settings.$codexServiceTier
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshActionProviderPresentation()
                self.ensureCodexSessionReady(forceFreshSession: true)
            }

        codexModelCancellable = settings.$codexActionModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshActionProviderPresentation()
                self.ensureCodexSessionReady(forceFreshSession: true)
            }
    }

    private func refreshTextToSpeechProvider() {
        textToSpeechProvider = OrbitTTSProviderFactory.makePrimaryProvider(for: settings.voicePreset)
        textToSpeechProviderDisplayName = textToSpeechProvider.displayName
        availableAppleVoices = []
        selectedAppleVoiceSummary = "System Default"
        orbitDictationManager.refreshConfiguredProviders()
    }

    private func refreshCloudCredentialState() {
        if let resolvedKey = OrbitOpenAIKeychainStore.resolvedAPIKey() {
            openAICloudCredentialState = .connected(source: resolvedKey.source)
        } else {
            openAICloudCredentialState = .missing
        }
    }

    private func handleShortcutTransition(_ transition: OrbitPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !orbitDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isOrbitCursorEnabled && !isOverlayVisible {
                orbitOverlayWindowManager.hasShownOverlayBefore = true
                orbitOverlayWindowManager.showOverlay(onScreens: NSScreen.screens, orbitManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .orbitDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            onboardingTask?.cancel()
            isRunningOnboardingTour = false
            textToSpeechProvider.stopPlayback()
            fallbackTextToSpeechProvider.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    
            OrbitAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await orbitDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Orbit received transcript: \(finalTranscript)")
                        OrbitAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.routeTranscript(finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            OrbitAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            orbitDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    private func routeTranscript(_ transcript: String) {
        submitTranscriptToActionProvider(transcript: transcript)
    }

    private func submitTranscriptToActionProvider(transcript: String) {
        currentResponseTask?.cancel()
        textToSpeechProvider.stopPlayback()
        fallbackTextToSpeechProvider.stopPlayback()
        isRunningOnboardingTour = false
        resetActionPresentationForNewRequest()
        applyActionProgress(
            OrbitActionProgress(
                phase: .capturingScreen,
                rawSource: "capturing current screen before sending to codex"
            )
        )
        voiceState = .processing
        clearDetectedElementLocation()
        showCodexActivityOverlayCard()
        scheduleActionAcknowledgementFallback()

        currentResponseTask = Task {
            defer { self.currentResponseTask = nil }
            let request: OrbitActionRequest
            do {
                request = try await prepareUnifiedCodexRequest(transcript: transcript)
            } catch is CancellationError {
                return
            } catch {
                let fallbackRequest = OrbitActionRequest(
                    transcript: transcript,
                    screenshotPath: nil,
                    screenshotLabel: nil,
                    cursorPointInImagePixels: nil,
                    imagePixelSize: nil,
                    screenNumber: nil
                )
                activeActionDetailLine = "continuing without screen context."
                appendActionUpdate("continuing without screen context")
                request = fallbackRequest
            }

            await actionProvider.submitActionRequest(
                request
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleActionEvent(event)
                }
            }

            if self.voiceState == .processing {
                self.voiceState = .idle
            }
            self.scheduleTransientHideIfNeeded()
        }
    }

    private func handleActionEvent(_ event: OrbitActionEvent) {
        switch event {
        case .phase(let progress):
            applyActionProgress(progress)
            showCodexActivityOverlayCard()
        case .commentary(let commentary):
            handleEarlyActionCommentary(commentary)
        case .completed(let summary):
            let parseResult = Self.parsePointingCoordinates(from: summary)
            let spokenSummary = parseResult.spokenText.isEmpty ? "done." : parseResult.spokenText
            let shortDetail = conciseDetailLine(from: spokenSummary)
            cancelActionAcknowledgementFlow()
            textToSpeechProvider.stopPlayback()
            fallbackTextToSpeechProvider.stopPlayback()
            activeActionProgress = OrbitActionProgress(
                phase: .done,
                detail: shortDetail,
                rawSource: summary
            )
            activeActionStatus = .completed(spokenSummary)
            activeActionStatusSummary = OrbitActionPhase.done.summaryText
            activeActionDetailLine = shortDetail
            appendActionUpdate(OrbitActionPhase.done.summaryText)
            applyCodexPointDirective(parseResult)
            showCodexActivityOverlayCard()
            scheduleCodexActivityOverlayDismiss()
            Task {
                try? await textToSpeechProvider.speakText(spokenSummary)
            }
        case .failed(let errorMessage):
            let shortDetail = conciseDetailLine(from: errorMessage)
            cancelActionAcknowledgementFlow()
            textToSpeechProvider.stopPlayback()
            fallbackTextToSpeechProvider.stopPlayback()
            activeActionProgress = OrbitActionProgress(
                phase: .failed,
                detail: shortDetail,
                rawSource: errorMessage
            )
            activeActionStatus = .failed(errorMessage)
            activeActionStatusSummary = OrbitActionPhase.failed.summaryText
            activeActionDetailLine = shortDetail
            appendActionUpdate(OrbitActionPhase.failed.summaryText)
            showCodexActivityOverlayCard()
            scheduleCodexActivityOverlayDismiss()
            Task {
                try? await fallbackTextToSpeechProvider.speakText("i could not finish that action.")
            }
        }

        refreshActionProviderPresentation()
    }

    private func buildPrimaryScreenLabel(
        for capture: OrbitScreenCapture
    ) -> (data: Data, label: String) {
        let dimensionInfo = "image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels"

        let cursorInfo: String
        if let cursorPoint = currentCursorPointInScreenshotPixels(for: capture) {
            cursorInfo = "current mouse cursor is approximately at \(Int(cursorPoint.x)),\(Int(cursorPoint.y)) in this image"
        } else {
            cursorInfo = "current mouse cursor coordinates are unavailable"
        }

        let label = "current screen \(capture.screenNumber) (primary focus) — \(dimensionInfo); \(cursorInfo)"
        return (data: capture.imageData, label: label)
    }

    private func prepareUnifiedCodexRequest(transcript: String) async throws -> OrbitActionRequest {
        do {
            let activeScreenCapture = try await OrbitScreenCaptureUtility.captureCurrentScreenAsJPEG()

            lastCodexScreenCapture = activeScreenCapture
            let labeledCapture = buildPrimaryScreenLabel(for: activeScreenCapture)
            let cursorPoint = currentCursorPointInScreenshotPixels(for: activeScreenCapture)
            let screenshotPath = try writeCodexScreenshotToTemporaryFile(labeledCapture.data)
            return OrbitActionRequest(
                transcript: transcript,
                screenshotPath: screenshotPath,
                screenshotLabel: labeledCapture.label,
                cursorPointInImagePixels: cursorPoint,
                imagePixelSize: CGSize(
                    width: activeScreenCapture.screenshotWidthInPixels,
                    height: activeScreenCapture.screenshotHeightInPixels
                ),
                screenNumber: activeScreenCapture.screenNumber
            )
        } catch {
            lastCodexScreenCapture = nil
            throw error
        }
    }

    private func writeCodexScreenshotToTemporaryFile(_ data: Data) throws -> String {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-codex-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try data.write(to: temporaryURL, options: .atomic)
        return temporaryURL.path
    }

    private func applyCodexPointDirective(_ parseResult: PointingParseResult) {
        guard let coordinate = parseResult.coordinate,
              let activeScreenCapture = lastCodexScreenCapture else {
            return
        }

        let screenshotWidth = CGFloat(activeScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(activeScreenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(activeScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(activeScreenCapture.displayHeightInPoints)
        let displayFrame = activeScreenCapture.displayFrame

        let clampedX = max(0, min(coordinate.x, screenshotWidth))
        let clampedY = max(0, min(coordinate.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / max(screenshotWidth, 1))
        let displayLocalY = clampedY * (displayHeight / max(screenshotHeight, 1))
        let appKitY = displayHeight - displayLocalY
        let globalLocation = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )

        detectedElementScreenLocation = globalLocation
        detectedElementDisplayFrame = displayFrame
        detectedElementBubbleText = parseResult.elementLabel
    }

    private func currentCursorPointInScreenshotPixels(
        for capture: OrbitScreenCapture
    ) -> CGPoint? {
        let mouseLocation = NSEvent.mouseLocation
        guard capture.displayFrame.contains(mouseLocation) else { return nil }

        let localXInPoints = mouseLocation.x - capture.displayFrame.origin.x
        let localYInPoints = mouseLocation.y - capture.displayFrame.origin.y

        let xScale = CGFloat(capture.screenshotWidthInPixels) / max(capture.displayFrame.width, 1)
        let yScale = CGFloat(capture.screenshotHeightInPixels) / max(capture.displayFrame.height, 1)

        let screenshotX = max(0, min(localXInPoints * xScale, CGFloat(capture.screenshotWidthInPixels)))
        let screenshotYBottomOrigin = localYInPoints * yScale
        let screenshotY = max(
            0,
            min(
                CGFloat(capture.screenshotHeightInPixels) - screenshotYBottomOrigin,
                CGFloat(capture.screenshotHeightInPixels)
            )
        )

        return CGPoint(x: screenshotX, y: screenshotY)
    }

    private func refreshActionProviderPresentation() {
        availableCodexModels = actionProvider.availableModels
        availableCodexEfforts = actionProvider.supportedEffortsForSelectedModel
        codexAuthState = actionProvider.authState
        codexAccountSummary = actionProvider.accountSummary
        reconcileCodexSelectionIfNeeded()
        codexSessionSummary = actionProvider.sessionStatusSummary
        codexConfigurationSummary = actionProvider.configurationSummary
    }

    private func reconcileCodexSelectionIfNeeded() {
        let currentModel = settings.codexActionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !availableCodexModels.contains(where: { $0.model == currentModel }),
           let preferredModel = availableCodexModels.first(where: { $0.isDefault })?.model ?? availableCodexModels.first?.model {
            settings.codexActionModel = preferredModel
        }

        let supportedEfforts = availableCodexEfforts
        guard !supportedEfforts.isEmpty else { return }
        if !supportedEfforts.contains(settings.codexReasoningEffort) {
            settings.codexReasoningEffort = availableCodexModels
                .first(where: { $0.model == settings.codexActionModel })?
                .defaultEffort
                ?? supportedEfforts.first
                ?? .low
        }
    }

    private func resetActionPresentationForNewRequest() {
        recentActionUpdates.removeAll(keepingCapacity: true)
        activeActionProgress = nil
        activeActionStatus = .running
        activeActionStatusSummary = nil
        activeActionDetailLine = nil
        codexOverlayDismissTask?.cancel()
        actionAcknowledgementTask?.cancel()
        actionAcknowledgementTask = nil
        hasSpokenActionAcknowledgement = false
    }

    private func applyActionProgress(_ progress: OrbitActionProgress) {
        activeActionProgress = progress

        if progress.phase == .waitingForApproval {
            activeActionStatus = .waitingForApproval(progress.resolvedDetail ?? progress.phase.summaryText)
        } else {
            activeActionStatus = .running
        }

        activeActionStatusSummary = progress.phase.summaryText
        activeActionDetailLine = progress.resolvedDetail
        appendActionUpdate(progress.phase.summaryText)
    }

    private func handleEarlyActionCommentary(_ commentary: String) {
        guard !hasSpokenActionAcknowledgement,
              let acknowledgement = normalizedEarlyAcknowledgement(from: commentary) else {
            return
        }

        hasSpokenActionAcknowledgement = true
        actionAcknowledgementTask?.cancel()
        actionAcknowledgementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await textToSpeechProvider.speakText(acknowledgement)
            } catch {
                try? await fallbackTextToSpeechProvider.speakText(acknowledgement)
            }
        }
    }

    private func scheduleActionAcknowledgementFallback() {
        actionAcknowledgementTask?.cancel()
        actionAcknowledgementTask = nil
    }

    private func cancelActionAcknowledgementFlow() {
        actionAcknowledgementTask?.cancel()
        actionAcknowledgementTask = nil
    }

    private func normalizedEarlyAcknowledgement(from text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[POINT:[^\]]+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }

        let firstSentence = cleaned.split(whereSeparator: { ".!?".contains($0) }).first.map(String.init) ?? cleaned
        let candidate = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.split(separator: " ").count >= 2 else { return nil }

        if candidate.count <= 72 {
            return candidate.hasSuffix(".") ? candidate : "\(candidate)."
        }

        let prefix = String(candidate.prefix(69))
        let trimmed = prefix
            .replacingOccurrences(of: "\\s+\\S*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "\(trimmed)..."
    }

    private func conciseDetailLine(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 72 else { return cleaned }
        let cutoffIndex = cleaned.index(cleaned.startIndex, offsetBy: 69)
        return cleaned[..<cutoffIndex].trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    func selectVoicePreset(_ preset: OrbitVoicePreset, markSetupComplete: Bool = true) {
        settings.voicePreset = preset
        if markSetupComplete {
            hasCompletedVoiceModeSetup = true
        }

        if preset == .localVoice {
            refreshCloudCredentialState()
        }
    }

    @discardableResult
    func saveOpenAIAPIKey(_ rawValue: String) async -> Bool {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            openAICloudCredentialState = .missing
            return false
        }

        openAICloudCredentialState = .validating

        do {
            try OrbitOpenAIKeychainStore.saveAPIKey(trimmedValue)
        } catch {
            openAICloudCredentialState = .networkError
            return false
        }

        let validationResult = await OrbitOpenAIKeyValidator.validate(apiKey: trimmedValue)

        switch validationResult {
        case .connected:
            hasCompletedVoiceModeSetup = true
            settings.voicePreset = .cloudVoice
            openAICloudCredentialState = .connected(source: .keychain)
            refreshTextToSpeechProvider()
            return true
        case .invalid:
            OrbitOpenAIKeychainStore.deleteAPIKey()
            openAICloudCredentialState = .invalid
            refreshTextToSpeechProvider()
            return false
        case .networkError:
            openAICloudCredentialState = .networkError
            refreshTextToSpeechProvider()
            return false
        }
    }

    func clearOpenAIAPIKey() {
        OrbitOpenAIKeychainStore.deleteAPIKey()
        refreshCloudCredentialState()
        refreshTextToSpeechProvider()
    }

    func ensureCodexSessionReady(forceFreshSession: Bool = false) {
        if let existingTask = codexSessionWarmupTask {
            if forceFreshSession {
                existingTask.cancel()
            } else {
                refreshActionProviderPresentation()
                return
            }
        }

        codexWarmupGeneration += 1
        let generation = codexWarmupGeneration
        codexSessionWarmupTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let warmupError = await actionProvider.prewarmSession(forceFreshSession: forceFreshSession)
            refreshActionProviderPresentation()

            if generation == codexWarmupGeneration {
                codexSessionWarmupTask = nil
            }

            if warmupError != nil {
                activeActionProgress = nil
                activeActionStatus = .idle
                activeActionStatusSummary = nil
                activeActionDetailLine = nil
            } else if case .failed = activeActionStatus {
                activeActionProgress = nil
                activeActionStatus = .idle
                activeActionStatusSummary = nil
                activeActionDetailLine = nil
            }
        }
    }

    func reconnectCodexSession() {
        ensureCodexSessionReady(forceFreshSession: true)
    }

    func connectCodexAccount() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await actionProvider.beginManagedLogin()
            refreshActionProviderPresentation()
        }
    }

    func reopenCodexLogin() {
        actionProvider.reopenManagedLoginURL()
    }

    func signOutCodexAccount() {
        actionProvider.logoutAccount()
        refreshActionProviderPresentation()
        ensureCodexSessionReady(forceFreshSession: true)
    }

    private func appendActionUpdate(_ update: String) {
        let trimmed = update.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if recentActionUpdates.last == trimmed {
            return
        }

        recentActionUpdates.append(trimmed)
        if recentActionUpdates.count > 6 {
            recentActionUpdates.removeFirst(recentActionUpdates.count - 6)
        }
    }

    private func showCodexActivityOverlayCard() {
        codexOverlayDismissTask?.cancel()
        showCodexActivityOverlay = true
    }

    private func scheduleCodexActivityOverlayDismiss(after delay: TimeInterval = 8.0) {
        codexOverlayDismissTask?.cancel()
        codexOverlayDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.showCodexActivityOverlay = false
        }
    }

    /// If the cursor is in transient mode, waits for speech and pointing to
    /// finish, then fades the overlay away after a short pause.
    private func scheduleTransientHideIfNeeded() {
        guard !isOrbitCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while textToSpeechProvider.isPlaying || fallbackTextToSpeechProvider.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the Orbit cursor flies back to the pointer)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            orbitOverlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Codex's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Codex said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Codex's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Orbit Tour

    func beginOrbitTour() {
        OrbitAnalytics.trackOnboardingDemoTriggered()
        onboardingTask?.cancel()
        textToSpeechProvider.stopPlayback()
        fallbackTextToSpeechProvider.stopPlayback()
        clearDetectedElementLocation()
        codexOverlayDismissTask?.cancel()
        showCodexActivityOverlay = false
        recentActionUpdates.removeAll(keepingCapacity: true)
        activeActionProgress = nil
        activeActionStatus = .idle
        activeActionStatusSummary = nil
        activeActionDetailLine = nil
        isRunningOnboardingTour = true

        let steps = [
            "hey, i'm orbit.",
            "hold control + option to talk to me.",
            "i send your words and your current screen to one live codex session.",
            "when something matters on screen, i can point right to it."
        ]

        onboardingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for (index, step) in steps.enumerated() {
                guard !Task.isCancelled else { return }
                let shouldRunPointDemo = index == 3
                await runOnboardingStep(step, runPointDemo: shouldRunPointDemo)
            }

            isRunningOnboardingTour = false
            self.hasCompletedOnboarding = true
            activeActionStatus = .idle
            activeActionStatusSummary = nil
            activeActionDetailLine = nil
        }
    }

    private func runOnboardingStep(_ message: String, runPointDemo: Bool) async {
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        for character in message {
            guard showOnboardingPrompt, !Task.isCancelled else { return }
            onboardingPromptText.append(character)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }

        let pointDemoTask = Task { @MainActor [weak self] in
            guard let self, runPointDemo else { return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            await runSyntheticPointDemo()
        }

        await speakOnboardingMessage(message)
        await pointDemoTask.value
        try? await Task.sleep(nanoseconds: 850_000_000)
        guard showOnboardingPrompt, !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.3)) {
            onboardingPromptOpacity = 0.0
        }

        try? await Task.sleep(nanoseconds: 350_000_000)
        showOnboardingPrompt = false
        onboardingPromptText = ""
    }

    private func speakOnboardingMessage(_ message: String) async {
        do {
            try await textToSpeechProvider.speakText(message)
        } catch {
            try? await fallbackTextToSpeechProvider.speakText(message)
        }
    }

    private func runSyntheticPointDemo() async {
        let mouseLocation = NSEvent.mouseLocation
        guard let currentScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            return
        }

        let frame = currentScreen.frame
        let target = CGPoint(
            x: min(frame.maxX - 140, max(frame.minX + 140, mouseLocation.x + 150)),
            y: max(frame.minY + 140, min(frame.maxY - 140, mouseLocation.y - 90))
        )

        detectedElementDisplayFrame = frame
        detectedElementScreenLocation = target
        detectedElementBubbleText = "right here!"

        for _ in 0..<40 {
            guard !Task.isCancelled else { return }
            if detectedElementScreenLocation == nil {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        clearDetectedElementLocation()
    }
}
