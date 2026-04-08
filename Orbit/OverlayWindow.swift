import AppKit
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct OnboardingBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

enum OrbitNavigationMode {
    case followingCursor
    case navigatingToTarget
    case pointingAtTarget
}

@MainActor
struct OrbitCursorOverlayView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var orbitManager: OrbitManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, orbitManager: OrbitManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.orbitManager = orbitManager

        // Seed the cursor position from the current mouse location so the
        // Orbit cursor doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var onboardingBubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    @State private var orbitNavigationMode: OrbitNavigationMode = .followingCursor
    @State private var triangleRotationDegrees: Double = 0

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Task driving the frame-by-frame bezier arc flight animation.
    /// Canceled when the flight completes, is interrupted, or the view disappears.
    @State private var navigationAnimationTask: Task<Void, Never>?

    /// Scale factor applied to the Orbit cursor during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var orbitFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the Orbit cursor is flying BACK to the pointer after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    private let fullWelcomeMessage = "hey, i'm orbit"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            if shouldShowCodexActivityHUD {
                codexActivityHUD
                    .padding(.top, 34)
                    .padding(.trailing, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: orbitManager.showCodexActivityOverlay)
                    .animation(.easeInOut(duration: 0.18), value: orbitManager.activeActionDetailLine)
                    .allowsHitTesting(false)
            }

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.clear)
                            .orbitGlassCard(
                                shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                fillOpacity: 0.40,
                                borderOpacity: 0.16,
                                highlightOpacity: 0.24,
                                shadowOpacity: 0.14,
                                glowOpacity: 0.03
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            if isCursorOnThisScreen && orbitManager.showOnboardingPrompt && !orbitManager.onboardingPromptText.isEmpty {
                Text(orbitManager.onboardingPromptText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .frame(maxWidth: 228, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.clear)
                            .orbitGlassCard(
                                shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                fillOpacity: 0.42,
                                borderOpacity: 0.16,
                                highlightOpacity: 0.24,
                                shadowOpacity: 0.14,
                                glowOpacity: 0.03
                            )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: OnboardingBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(orbitManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 14 + (onboardingBubbleSize.width / 2), y: cursorPosition.y + 22)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: orbitManager.onboardingPromptOpacity)
                    .onPreferenceChange(OnboardingBubbleSizePreferenceKey.self) { newSize in
                        onboardingBubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when the Orbit cursor arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if orbitNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.clear)
                            .orbitGlassCard(
                                shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                fillOpacity: 0.42,
                                borderOpacity: 0.16,
                                highlightOpacity: 0.26,
                                shadowOpacity: 0.16,
                                glowOpacity: 0.04
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            OrbitCursorGlyphView(isReturning: isReturningToCursor)
                .frame(width: 28, height: 28)
                .rotationEffect(.degrees(triangleRotationDegrees))
                .scaleEffect(orbitFlightScale)
                .opacity(orbitCursorIsVisibleOnThisScreen && (orbitManager.voiceState == .idle || orbitManager.voiceState == .responding) ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(
                    orbitNavigationMode == .followingCursor
                        ? .spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(.easeIn(duration: 0.25), value: orbitManager.voiceState)
                .animation(
                    orbitNavigationMode == .navigatingToTarget ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )

            OrbitListeningCursorView(audioPowerLevel: orbitManager.currentAudioPowerLevel)
                .opacity(orbitCursorIsVisibleOnThisScreen && orbitManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: orbitManager.voiceState)

            OrbitProcessingCursorView()
                .opacity(orbitCursorIsVisibleOnThisScreen && orbitManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: orbitManager.voiceState)

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.showWelcome = false
                    self.bubbleOpacity = 0.0
                    self.orbitManager.beginOrbitTour()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            navigationAnimationTask?.cancel()
        }
        .onChange(of: orbitManager.detectedElementScreenLocation) { _, newLocation in
            // When a UI element location is detected, navigate the Orbit cursor to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = orbitManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
    }

    private var orbitCursorIsVisibleOnThisScreen: Bool {
        switch orbitNavigationMode {
        case .followingCursor:
            // If another screen's OrbitCursorOverlayView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate Orbit cursor
            if orbitManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    private var shouldShowCodexActivityHUD: Bool {
        guard orbitManager.showCodexActivityOverlay else { return false }
        guard let menuBarScreenFrame = NSScreen.screens.first?.frame else { return false }
        return screenFrame.equalTo(menuBarScreenFrame)
    }

    @ViewBuilder
    private var codexActivityHUD: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    switch orbitManager.activeActionStatus {
                    case .running, .waitingForApproval:
                        OrbitMiniSpinner(tint: actionStatusAccentColor)
                    case .completed:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(DS.Colors.success)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(DS.Colors.warning)
                    case .idle:
                        OrbitMarkView(size: 13)
                    }
                }
                .frame(width: 14, height: 14)

                Text("Codex")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer(minLength: 8)

                DSQuietStatusChip(title: actionStatusLabel, tint: actionStatusAccentColor)
            }

            Text(orbitManager.activeActionStatusSummary ?? orbitManager.codexSessionSummary)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)

            if let detail = codexHUDDetailLine {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
            }

            if !orbitManager.codexConfigurationSummary.isEmpty {
                Text(orbitManager.codexConfigurationSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 252, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.clear)
                .orbitGlassCard(
                    shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                    fillOpacity: 0.36,
                    borderOpacity: 0.15,
                    highlightOpacity: 0.22,
                    shadowOpacity: 0.18,
                    glowOpacity: 0.03
                )
        )
    }

    private var actionStatusLabel: String {
        switch orbitManager.activeActionStatus {
        case .idle:
            return "Idle"
        case .running:
            return "Working"
        case .waitingForApproval:
            return "Waiting"
        case .completed:
            return "Done"
        case .failed:
            return "Issue"
        }
    }

    private var actionStatusAccentColor: Color {
        switch orbitManager.activeActionStatus {
        case .idle:
            return Color.white.opacity(0.86)
        case .running:
            return Color.white.opacity(0.96)
        case .waitingForApproval:
            return DS.Colors.warning
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.warning
        }
    }

    private var codexHUDDetailLine: String? {
        orbitManager.activeActionDetailLine
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            Task { @MainActor in
                let mouseLocation = NSEvent.mouseLocation
                self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

                // During forward flight or pointing, the Orbit cursor is not interrupted by
                // mouse movement. Only during the return flight do we allow movement to
                // cancel the animation and resume normal following behavior.
                if self.orbitNavigationMode == .navigatingToTarget && self.isReturningToCursor {
                    let currentMouseInSwiftUI = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                    let distanceFromNavigationStart = hypot(
                        currentMouseInSwiftUI.x - self.cursorPositionWhenNavigationStarted.x,
                        currentMouseInSwiftUI.y - self.cursorPositionWhenNavigationStarted.y
                    )
                    if distanceFromNavigationStart > 100 {
                        self.cancelNavigationAndResumeFollowing()
                    }
                    return
                }

                if self.orbitNavigationMode != .followingCursor {
                    return
                }

                let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
                let orbitCursorX = swiftUIPosition.x + 35
                let orbitCursorY = swiftUIPosition.y + 25
                self.cursorPosition = CGPoint(x: orbitCursorX, y: orbitCursorY)
            }
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the Orbit cursor toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the Orbit cursor sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        orbitNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.orbitNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the Orbit cursor along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping () -> Void
    ) {
        navigationAnimationTask?.cancel()

        let startPosition = cursorPosition
        let endPosition = destination

        let deltaX = endPosition.x - startPosition.x
        let deltaY = endPosition.y - startPosition.y
        let distance = hypot(deltaX, deltaY)

        // Flight duration scales with distance: short hops are quick, long
        // flights are more dramatic. Clamped to 0.6s–1.4s.
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let frameInterval: Double = 1.0 / 60.0
        let totalFrames = Int(flightDurationSeconds / frameInterval)
        // Control point for the quadratic bezier arc. Offset the midpoint
        // upward (negative Y in SwiftUI) so the cursor flies in a parabolic arc.
        let midPoint = CGPoint(
            x: (startPosition.x + endPosition.x) / 2.0,
            y: (startPosition.y + endPosition.y) / 2.0
        )
        let arcHeight = min(distance * 0.2, 80.0)
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y - arcHeight)

        navigationAnimationTask = Task { @MainActor in
            for currentFrame in 1...totalFrames {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))

                // Linear progress 0→1 over the flight duration
                let linearProgress = Double(currentFrame) / Double(totalFrames)

                // Smoothstep easeInOut: 3t² - 2t³ (Hermite interpolation)
                let t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress)

                // Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2
                let oneMinusT = 1.0 - t
                let bezierX = oneMinusT * oneMinusT * startPosition.x
                            + 2.0 * oneMinusT * t * controlPoint.x
                            + t * t * endPosition.x
                let bezierY = oneMinusT * oneMinusT * startPosition.y
                            + 2.0 * oneMinusT * t * controlPoint.y
                            + t * t * endPosition.y

                self.cursorPosition = CGPoint(x: bezierX, y: bezierY)

                // Rotation: face the direction of travel by computing the tangent
                // to the bezier curve. B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
                let tangentX = 2.0 * oneMinusT * (controlPoint.x - startPosition.x)
                             + 2.0 * t * (endPosition.x - controlPoint.x)
                let tangentY = 2.0 * oneMinusT * (controlPoint.y - startPosition.y)
                             + 2.0 * t * (endPosition.y - controlPoint.y)
                self.triangleRotationDegrees = atan2(tangentY, tangentX) * (180.0 / .pi) - OrbitBranding.defaultMarkHeadingDegrees

                let scalePulse = sin(linearProgress * .pi)
                self.orbitFlightScale = 1.0 + scalePulse * 0.3
            }

            guard !Task.isCancelled else { return }
            self.navigationAnimationTask = nil
            self.cursorPosition = endPosition
            self.orbitFlightScale = 1.0
            onComplete()
        }
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        orbitNavigationMode = .pointingAtTarget

        // Rotate back to default pointer angle now that we've arrived
        triangleRotationDegrees = 0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the Orbit manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = orbitManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.orbitNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.orbitNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard orbitNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the Orbit cursor back to the current pointer position after pointing is done.
    private func startFlyingBackToCursor() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = CGPoint(x: cursorInSwiftUI.x + 35, y: cursorInSwiftUI.y + 25)

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        orbitNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        navigationAnimationTask?.cancel()
        navigationAnimationTask = nil
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        orbitFlightScale = 1.0
        finishNavigationAndResumeFollowing()
    }

    /// Returns the Orbit cursor to normal pointer-following mode after navigation completes.
    private func finishNavigationAndResumeFollowing() {
        navigationAnimationTask?.cancel()
        navigationAnimationTask = nil
        orbitNavigationMode = .followingCursor
        isReturningToCursor = false
        triangleRotationDegrees = 0
        orbitFlightScale = 1.0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        orbitManager.clearDetectedElementLocation()
    }

}

private enum OrbitCursorMetrics {
    static let markSize: CGFloat = 28
    static let auraLineWidth: CGFloat = 1.68
    static let baseLineWidth: CGFloat = 1.54
    static let auraBlurRadius: CGFloat = 2.24
    static let railDiameter: CGFloat = 21.28
    static let railLineWidth: CGFloat = 0.84
    static let arcLineWidth: CGFloat = 0.98
    static let spinnerSize: CGFloat = 14
    static let spinnerLineWidth: CGFloat = 0.77
}

private struct OrbitOverlayMarkView: View {
    var size: CGFloat = OrbitCursorMetrics.markSize
    var fillColor: Color = Color(hex: "#111111")
    var strokeColor: Color = .white
    var lineWidth: CGFloat = OrbitCursorMetrics.baseLineWidth

    var body: some View {
        OrbitMarkShape()
            .fill(fillColor, style: FillStyle(eoFill: true, antialiased: true))
            .overlay(
                OrbitMarkShape()
                    .stroke(strokeColor, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
            )
            .frame(width: size, height: size)
            .shadow(color: Color.black.opacity(0.55), radius: 1.68, x: 0, y: 0.56)
    }
}

private struct OrbitDashedMarkStroke: View {
    var size: CGFloat
    var tint: Color
    var opacity: Double = 1
    var lineWidth: CGFloat
    var phaseProgress: CGFloat

    var body: some View {
        let perimeter = OrbitBranding.markPerimeter(in: CGSize(width: size, height: size))
        let dashOn = perimeter * 0.22
        let dashOff = max(perimeter - dashOn, 0.01)

        OrbitMarkShape()
            .stroke(
                tint.opacity(opacity),
                style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round,
                    dash: [dashOn, dashOff],
                    dashPhase: perimeter * phaseProgress
                )
            )
            .frame(width: size, height: size)
    }
}

private struct OrbitCursorGlyphView: View {
    var isReturning: Bool = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let cycleProgress = cycleProgress(for: timeline.date, duration: 4.0)
            let auraOpacity = 0.75 - (0.25 * CGFloat(cos(Double(cycleProgress) * .pi * 2)))

            ZStack {
                OrbitMarkShape()
                    .fill(
                        Color.white.opacity(Double(0.12 * auraOpacity)),
                        style: FillStyle(eoFill: true, antialiased: true)
                    )
                    .overlay(
                        OrbitMarkShape()
                            .stroke(
                                Color.white.opacity(Double(auraOpacity)),
                                style: StrokeStyle(
                                    lineWidth: OrbitCursorMetrics.auraLineWidth,
                                    lineJoin: .round
                                )
                            )
                    )
                    .frame(width: OrbitCursorMetrics.markSize, height: OrbitCursorMetrics.markSize)
                    .blur(radius: OrbitCursorMetrics.auraBlurRadius)

                OrbitOverlayMarkView()
            }
        }
    }
}

private struct OrbitListeningCursorView: View {
    let audioPowerLevel: CGFloat

    var body: some View {
        TimelineView(.animation) { timeline in
            let cycle = cycleProgress(for: timeline.date, duration: 1.2)
            let resonancePhase = cubicBezierProgress(
                cycle,
                c1x: 0.2,
                c1y: 0.0,
                c2x: 0.8,
                c2y: 1.0
            )
            let clampedAudio = max(0, min(audioPowerLevel, 1))
            let diameter = 4.48 + (resonancePhase * (34.72 + (clampedAudio * 2.4)))
            let strokeOpacity = max(0, (0.8 + (clampedAudio * 0.08)) * (1 - resonancePhase))
            let strokeWidth = max(0.56, 1.96 - (1.4 * resonancePhase) + (clampedAudio * 0.12))

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(Double(strokeOpacity)), lineWidth: strokeWidth)
                    .frame(width: diameter, height: diameter)
                    .offset(x: -6.16, y: -6.16)

                OrbitOverlayMarkView()
            }
        }
    }
}

private struct OrbitProcessingCursorView: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let cycle = cycleProgress(for: timeline.date, duration: 0.9)
            let circumference = CGFloat.pi * OrbitCursorMetrics.railDiameter
            let dashOn = circumference * 0.22
            let dashOff = max(circumference - dashOn, 0.01)

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: OrbitCursorMetrics.railLineWidth)
                    .frame(width: OrbitCursorMetrics.railDiameter, height: OrbitCursorMetrics.railDiameter)

                Circle()
                    .stroke(
                        Color.white,
                        style: StrokeStyle(
                            lineWidth: OrbitCursorMetrics.arcLineWidth,
                            lineCap: .round,
                            dash: [dashOn, dashOff],
                            dashPhase: 0
                        )
                    )
                    .frame(width: OrbitCursorMetrics.railDiameter, height: OrbitCursorMetrics.railDiameter)
                    .rotationEffect(.degrees(Double(cycle) * 360))

                OrbitOverlayMarkView()
            }
        }
    }
}

private struct OrbitMiniSpinner: View {
    var tint: Color = Color.white.opacity(0.96)

    var body: some View {
        TimelineView(.animation) { timeline in
            let cycle = cycleProgress(for: timeline.date, duration: 1.2)

            ZStack {
                OrbitMarkShape()
                    .stroke(
                        Color.white.opacity(0.12),
                        style: StrokeStyle(
                            lineWidth: OrbitCursorMetrics.spinnerLineWidth,
                            lineJoin: .round
                        )
                    )
                    .frame(width: OrbitCursorMetrics.spinnerSize, height: OrbitCursorMetrics.spinnerSize)

                OrbitDashedMarkStroke(
                    size: OrbitCursorMetrics.spinnerSize,
                    tint: tint,
                    lineWidth: OrbitCursorMetrics.spinnerLineWidth,
                    phaseProgress: 1 - cycle
                )
            }
        }
    }
}

private func cycleProgress(for date: Date, duration: TimeInterval) -> CGFloat {
    guard duration > 0 else { return 0 }
    let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
    return CGFloat(progress)
}

private func cubicBezierProgress(
    _ x: CGFloat,
    c1x: CGFloat,
    c1y: CGFloat,
    c2x: CGFloat,
    c2y: CGFloat
) -> CGFloat {
    func sampleCurveX(_ t: CGFloat) -> CGFloat {
        let invT = 1 - t
        return (3 * invT * invT * t * c1x) + (3 * invT * t * t * c2x) + (t * t * t)
    }

    func sampleCurveY(_ t: CGFloat) -> CGFloat {
        let invT = 1 - t
        return (3 * invT * invT * t * c1y) + (3 * invT * t * t * c2y) + (t * t * t)
    }

    func sampleCurveDerivativeX(_ t: CGFloat) -> CGFloat {
        let invT = 1 - t
        return (3 * invT * invT * c1x) + (6 * invT * t * (c2x - c1x)) + (3 * t * t * (1 - c2x))
    }

    var t = x
    for _ in 0..<6 {
        let derivative = sampleCurveDerivativeX(t)
        guard abs(derivative) > 0.0001 else { break }
        t -= (sampleCurveX(t) - x) / derivative
        t = min(max(t, 0), 1)
    }

    return sampleCurveY(t)
}

@MainActor
class OrbitOverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], orbitManager: OrbitManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = OrbitCursorOverlayView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                orbitManager: orbitManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}
