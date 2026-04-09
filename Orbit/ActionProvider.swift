import CoreGraphics
import Foundation

enum OrbitActionStatus: Equatable {
    case idle
    case running
    case waitingForApproval(String)
    case interrupted(String)
    case completed(String)
    case failed(String)
}

enum OrbitCodexAuthState: Equatable {
    case unknown
    case checking
    case authenticated(email: String?, plan: String?)
    case authRequired
    case loginInProgress
    case authFailed(String)
    case runtimeUnavailable(String)
}

enum OrbitActionPhase: String, Equatable {
    case capturingScreen
    case startingCodex
    case thinking
    case previewingAction
    case executingDesktopAction
    case runningCommand
    case usingTool
    case editingFiles
    case openingBrowser
    case navigating
    case clicking
    case typing
    case readingScreen
    case waitingForApproval
    case waitingForChoice
    case interrupted
    case done
    case failed

    var summaryText: String {
        switch self {
        case .capturingScreen:
            return "capturing screen"
        case .startingCodex:
            return "starting codex"
        case .thinking:
            return "thinking"
        case .previewingAction:
            return "about to act"
        case .executingDesktopAction:
            return "acting on desktop"
        case .runningCommand:
            return "running command"
        case .usingTool:
            return "using tool"
        case .editingFiles:
            return "editing files"
        case .openingBrowser:
            return "opening browser"
        case .navigating:
            return "navigating"
        case .clicking:
            return "clicking"
        case .typing:
            return "typing"
        case .readingScreen:
            return "reading screen"
        case .waitingForApproval:
            return "waiting for approval"
        case .waitingForChoice:
            return "waiting for choice"
        case .interrupted:
            return "interrupted"
        case .done:
            return "done"
        case .failed:
            return "failed"
        }
    }

    var defaultDetailText: String? {
        switch self {
        case .capturingScreen:
            return "preparing the current screen for codex."
        case .startingCodex:
            return "connecting to the live codex session."
        case .thinking:
            return "working in the current codex session."
        case .previewingAction:
            return "pointing to the next target before acting."
        case .executingDesktopAction:
            return "performing the next desktop action locally."
        case .runningCommand:
            return "running a command in the current session."
        case .usingTool:
            return "using a tool in the current session."
        case .editingFiles:
            return "editing files in the current session."
        case .openingBrowser:
            return "using browser tools in the current session."
        case .navigating:
            return "moving through the current page."
        case .clicking:
            return "interacting with a control on screen."
        case .typing:
            return "entering text in the current session."
        case .readingScreen:
            return "checking the current screen before acting."
        case .waitingForApproval:
            return "finishing an approval handshake."
        case .waitingForChoice:
            return "waiting for your answer before continuing."
        case .interrupted:
            return "stopping the current codex turn."
        case .done, .failed:
            return nil
        }
    }
}

struct OrbitActionProgress: Equatable {
    let phase: OrbitActionPhase
    let detail: String?
    let rawSource: String?

    init(
        phase: OrbitActionPhase,
        detail: String? = nil,
        rawSource: String? = nil
    ) {
        self.phase = phase
        self.detail = detail
        self.rawSource = rawSource
    }

    var resolvedDetail: String? {
        detail ?? phase.defaultDetailText
    }
}

enum OrbitActionEvent {
    case phase(OrbitActionProgress)
    case commentary(String)
    case liveUpdate(String)
    case toolPrompt(OrbitToolPrompt)
    case interrupted(String)
    case completed(String)
    case failed(String)
}

struct OrbitToolPrompt: Equatable {
    let requestID: Int
    let title: String
    let detail: String?
    let questionID: String
    let options: [String]
}

struct OrbitActionRequest {
    let transcript: String
    let screenshotPath: String?
    let screenshotLabel: String?
    let cursorPointInImagePixels: CGPoint?
    let imagePixelSize: CGSize?
    let screenNumber: Int?
    let frontmostApplicationName: String?
    let frontmostWindowTitle: String?
}

protocol ActionProvider: AnyObject {
    var displayName: String { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }
    var status: OrbitActionStatus { get }
    var sessionStatusSummary: String { get }
    var configurationSummary: String { get }
    var authState: OrbitCodexAuthState { get }
    var canInterruptCurrentAction: Bool { get }
    var activeTurnSummary: String? { get }
    var debugEvents: [String] { get }
    var collaborationModes: [String] { get }
    var experimentalFeatures: [String] { get }

    func submitActionRequest(
        _ request: OrbitActionRequest,
        onEvent: @escaping @Sendable (OrbitActionEvent) -> Void
    ) async

    func cancelCurrentAction()
    func respondToToolPrompt(requestID: Int, questionID: String, answer: String)
}
