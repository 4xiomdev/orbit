import AppKit
import Foundation

private enum OrbitMcpStartupState: Equatable {
    case unknown
    case starting
    case ready
    case failed(String?)

    var isResolved: Bool {
        switch self {
        case .ready, .failed:
            return true
        case .unknown, .starting:
            return false
        }
    }
}

@MainActor
final class CodexAppServerActionProvider: ActionProvider {
    let displayName = "Codex"
    private static let browserToolServerNames = ["playwright", "chrome-devtools"]
    private static func makeInitialMcpStartupStates() -> [String: OrbitMcpStartupState] {
        Dictionary(uniqueKeysWithValues: browserToolServerNames.map { ($0, .unknown) })
    }
    private(set) var status: OrbitActionStatus = .idle
    private let settings = OrbitSettings.shared
    private(set) var authState: OrbitCodexAuthState = .unknown
    private(set) var debugEvents: [String] = []
    private(set) var collaborationModes: [String] = []
    private(set) var experimentalFeatures: [String] = []

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID = 99
    private var activeThreadID: String?
    private var pendingPrompt: String?
    private var eventHandler: (@Sendable (OrbitActionEvent) -> Void)?
    private var startupTimeoutTask: Task<Void, Never>?
    private var hasReceivedInitializeResponse = false
    private var isAwaitingTurnCompletion = false
    private var latestAgentMessageText: String?
    private var latestFinalAnswerText: String?
    private var activeTurnID: String?
    private var latestRequest: OrbitActionRequest?
    private var hasSentInitialize = false
    private var hasSentThreadStart = false
    private var hasOpenedBrowserInCurrentTurn = false
    private var lastEmittedProgress: OrbitActionProgress?
    private var intentionalShutdownInProgress = false
    private var prewarmTask: Task<String?, Never>?
    private var streamedCommentaryBuffer = ""
    private var hasEmittedEarlyCommentary = false
    private var availableModelOptions: [OrbitCodexModelOption] = OrbitCodexModelOption.fallbackPickerModels
    private var pendingModelCatalogRequestID: Int?
    private var pendingAccountReadRequestID: Int?
    private var pendingCollaborationModeRequestID: Int?
    private var pendingExperimentalFeatureRequestID: Int?
    private var pendingLoginRequestID: Int?
    private var pendingLogoutRequestID: Int?
    private var lastLoginURL: URL?
    private var lastLoginID: String?
    private var loginRequestTimeoutTask: Task<Void, Never>?
    private var pendingTurnStartRetryTask: Task<Void, Never>?
    private var lastEmittedLiveCommentary: String?
    private var preparedCodexHome: OrbitPreparedCodexHome?
    private var mcpStartupStates: [String: OrbitMcpStartupState] = CodexAppServerActionProvider.makeInitialMcpStartupStates()
    var stateDidChange: (() -> Void)?

    var isConfigured: Bool {
        true
    }

    var unavailableExplanation: String? {
        nil
    }

    var sessionStatusSummary: String {
        switch authState {
        case .checking:
            return "Checking ChatGPT account"
        case .authRequired:
            return "ChatGPT login required"
        case .loginInProgress:
            return "Finish ChatGPT sign-in"
        case .authFailed(let message):
            return message
        case .runtimeUnavailable(let message):
            return message
        case .authenticated, .unknown:
            break
        }

        if let activeThreadID, !activeThreadID.isEmpty {
            let shortThreadID = String(activeThreadID.suffix(6))
            if isAwaitingTurnCompletion {
                return "Working in session \(shortThreadID)"
            }
            return "Ready in session \(shortThreadID)"
        }

        if process != nil {
            return hasReceivedInitializeResponse ? "Connected to Codex" : "Starting Codex"
        }

        return "Codex session idle"
    }

    var configurationSummary: String {
        "\(currentActionModelDisplayName) · \(resolvedEffortForCurrentModel.displayName) · \(resolvedServiceTier.displayName)"
    }

    var availableModels: [OrbitCodexModelOption] {
        availableModelOptions
    }

    var supportedEffortsForSelectedModel: [OrbitCodexReasoningEffort] {
        supportedEfforts(for: normalizedCurrentActionModel)
    }

    func supportedEfforts(for model: String) -> [OrbitCodexReasoningEffort] {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return modelOption(for: normalizedModel)?.supportedEfforts
            ?? OrbitCodexModelOption.fallbackOption(for: normalizedModel)?.supportedEfforts
            ?? OrbitCodexReasoningEffort.allCases
    }

    var hasReadySession: Bool {
        guard let process else { return false }
        return process.isRunning
            && hasReceivedInitializeResponse
            && activeThreadID?.isEmpty == false
    }

    var isAuthenticatedForTurns: Bool {
        switch authState {
        case .authenticated:
            return true
        default:
            return false
        }
    }

    var accountSummary: String? {
        switch authState {
        case .authenticated(let email, let plan):
            let normalizedPlan = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let normalizedEmail, !normalizedEmail.isEmpty, let normalizedPlan, !normalizedPlan.isEmpty {
                return "\(normalizedEmail) · \(normalizedPlan.capitalized)"
            }
            if let normalizedEmail, !normalizedEmail.isEmpty {
                return normalizedEmail
            }
            if let normalizedPlan, !normalizedPlan.isEmpty {
                return "ChatGPT \(normalizedPlan.capitalized)"
            }
            return "Connected"
        case .loginInProgress:
            return "Finish sign-in in your browser."
        case .authRequired:
            return "Connect ChatGPT to use Orbit."
        case .authFailed(let message), .runtimeUnavailable(let message):
            return message
        case .checking:
            return "Checking ChatGPT account."
        case .unknown:
            return nil
        }
    }

    var canInterruptCurrentAction: Bool {
        guard let process else { return false }
        return process.isRunning && isAwaitingTurnCompletion && activeTurnID?.isEmpty == false && activeThreadID?.isEmpty == false
    }

    var activeTurnSummary: String? {
        guard let threadID = activeThreadID else { return nil }
        let shortThread = String(threadID.suffix(6))
        if let turnID = activeTurnID, !turnID.isEmpty {
            return "thr \(shortThread) · turn \(String(turnID.suffix(6)))"
        }
        return "thr \(shortThread)"
    }

    func submitActionRequest(
        _ request: OrbitActionRequest,
        onEvent: @escaping @Sendable (OrbitActionEvent) -> Void
    ) async {
        eventHandler = onEvent
        latestRequest = request
        status = .running
        hasOpenedBrowserInCurrentTurn = false
        lastEmittedProgress = nil
        emitPhase(.startingCodex)

        if let warmupError = await prewarmSession() {
            status = .failed(warmupError)
            authState = .runtimeUnavailable(warmupError)
            notifyStateChanged()
            onEvent(.failed(warmupError))
            return
        }

        guard isAuthenticatedForTurns else {
            let message: String
            switch authState {
            case .authRequired:
                message = "connect chatgpt before using orbit."
            case .loginInProgress:
                message = "finish chatgpt sign-in in your browser first."
            case .authFailed(let authMessage), .runtimeUnavailable(let authMessage):
                message = authMessage
            case .checking, .unknown:
                message = "orbit is still checking your codex account."
            case .authenticated:
                message = "orbit could not start the codex session."
            }
            status = .failed(message)
            notifyStateChanged()
            onEvent(.failed(message))
            return
        }

        if isAwaitingTurnCompletion {
            if case .waitingForApproval = status {
                emitPhase(
                    .waitingForChoice,
                    detail: "answer the current tool question before steering codex.",
                    rawSource: "orbit is waiting on a tool choice"
                )
                appendDebugEvent("turn blocked while waiting on tool choice")
                return
            }

            pendingPrompt = wrappedPrompt(for: request)
            latestRequest = request
            latestAgentMessageText = nil
            latestFinalAnswerText = nil
            streamedCommentaryBuffer = ""
            hasEmittedEarlyCommentary = false
            lastEmittedLiveCommentary = nil
            sendTurnSteer()
            return
        }

        pendingPrompt = wrappedPrompt(for: request)
        latestAgentMessageText = nil
        latestFinalAnswerText = nil
        streamedCommentaryBuffer = ""
        hasEmittedEarlyCommentary = false
        lastEmittedLiveCommentary = nil
        attemptPendingTurnStart()
    }

    func respondToToolPrompt(requestID: Int, questionID: String, answer: String) {
        appendDebugEvent("tool prompt answered with \(answer)")
        sendResponse(
            id: requestID,
            result: [
                "answers": [
                    [
                        "id": questionID,
                        "value": answer
                    ]
                ]
            ]
        )
        status = .running
        emitPhase(.thinking, detail: "continuing with your answer.", rawSource: "tool prompt answered")
    }

    func prewarmSession(forceFreshSession: Bool = false) async -> String? {
        if let prewarmTask {
            return await prewarmTask.value
        }

        let task = Task<String?, Never> { @MainActor [weak self] in
            guard let self else { return "Orbit could not connect to Codex app-server." }
            defer { self.prewarmTask = nil }
            return await self.performPrewarmSession(forceFreshSession: forceFreshSession)
        }
        prewarmTask = task
        return await task.value
    }

    func beginManagedLogin() async {
        if case .loginInProgress = authState {
            if lastLoginURL != nil {
                reopenManagedLoginURL()
                return
            }

            appendDebugEvent("restarting stale login request without saved URL")
            pendingLoginRequestID = nil
            loginRequestTimeoutTask?.cancel()
            loginRequestTimeoutTask = nil
        }

        if let error = await prewarmSession() {
            authState = .runtimeUnavailable(error)
            notifyStateChanged()
            return
        }

        guard hasReceivedInitializeResponse else { return }

        authState = .loginInProgress
        notifyStateChanged()

        let requestID = nextClientRequestID()
        pendingLoginRequestID = requestID
        appendDebugEvent("-> account/login/start #\(requestID)")
        beginLoginTimeoutWatch(for: requestID)
        sendJSON([
            "method": "account/login/start",
            "id": requestID,
            "params": [
                "type": "chatgpt"
            ]
        ])
    }

    func reopenManagedLoginURL() {
        guard let lastLoginURL else { return }
        appendDebugEvent("reopening saved login URL")
        _ = openExternalURL(lastLoginURL)
    }

    func logoutAccount() {
        guard hasReceivedInitializeResponse else { return }
        let requestID = nextClientRequestID()
        pendingLogoutRequestID = requestID
        sendJSON([
            "method": "account/logout",
            "id": requestID
        ])
    }

    private func performPrewarmSession(forceFreshSession: Bool = false) async -> String? {
        if forceFreshSession {
            restartServerForRecovery()
        } else if let process, !process.isRunning {
            teardownProcess()
        }

        if hasReadySession {
            status = .idle
            return nil
        }

        let maxAttempts = 3
        var lastFailureMessage: String?

        for attempt in 0..<maxAttempts {
            do {
                try bootstrapSessionIfNeeded()
            } catch {
                let message = "Orbit could not start Codex app-server: \(error.localizedDescription)"
                lastFailureMessage = message
                status = .failed(message)
                authState = .runtimeUnavailable(message)
                notifyStateChanged()
                restartServerForRecovery()

                if attempt < maxAttempts - 1 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                return message
            }

            for _ in 0..<100 {
                if hasReadySession && pendingModelCatalogRequestID == nil {
                    status = .idle
                    notifyStateChanged()
                    return nil
                }

                if pendingModelCatalogRequestID == nil,
                   pendingAccountReadRequestID == nil,
                   setupResolutionReached {
                    status = .idle
                    notifyStateChanged()
                    return nil
                }

                if case .failed(let message) = status {
                    lastFailureMessage = message
                    break
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            if attempt < maxAttempts - 1 {
                emitPhase(
                    .startingCodex,
                    detail: "restarting the codex session.",
                    rawSource: "orbit is retrying codex startup",
                    force: true
                )
                restartServerForRecovery()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        let message = lastFailureMessage ?? "Orbit could not connect to Codex app-server."
        status = .failed(message)
        authState = .runtimeUnavailable(message)
        notifyStateChanged()
        teardownProcess()
        return message
    }

    func cancelCurrentAction() {
        if let activeThreadID,
           let activeTurnID,
           let process,
           process.isRunning,
           isAwaitingTurnCompletion {
            appendDebugEvent("-> turn/interrupt turn=\(String(activeTurnID.suffix(6)))")
            sendJSON([
                "method": "turn/interrupt",
                "id": 3,
                "params": [
                    "threadId": activeThreadID,
                    "turnId": activeTurnID
                ]
            ])
            status = .interrupted("stopping the current codex turn.")
            emitPhase(.interrupted, detail: "stopping the current codex turn.", rawSource: "interrupting codex")
            return
        }

        if let process, process.isRunning {
            intentionalShutdownInProgress = true
            process.terminationHandler = nil
            process.terminate()
        }
        teardownProcess()
        status = .idle
    }

    private func bootstrapSessionIfNeeded() throws {
        if let process, !process.isRunning {
            teardownProcess()
        }

        if process == nil {
            try startServerIfNeeded()
        }

        if !hasReceivedInitializeResponse {
            authState = .checking
            notifyStateChanged()
            beginStartupTimeoutWatch()
            sendInitialize()
        } else if activeThreadID == nil, isAuthenticatedForTurns {
            sendThreadStart()
        }
    }

    private func startServerIfNeeded() throws {
        let codexExecutable = try resolveCodexExecutable()
        let preparedCodexHome = try OrbitCodexEnvironment.prepareHome(
            model: normalizedCurrentActionModel,
            reasoningEffort: resolvedEffortForCurrentModel,
            serviceTier: resolvedServiceTier
        )
        self.preparedCodexHome = preparedCodexHome
        mcpStartupStates = Self.makeInitialMcpStartupStates()
        let launchCommand = resolvedCodexLaunchCommand(
            for: codexExecutable,
            preparedCodexHome: preparedCodexHome
        )
        appendDebugEvent("starting codex app-server from \(codexExecutable)")
        appendDebugEvent("using isolated codex home \(preparedCodexHome.homeDirectory.path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchCommand.executable)
        process.arguments = launchCommand.arguments
        process.environment = launchCommand.environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.handleProcessTermination(terminatedProcess)
            }
        }

        try process.run()

        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }

            Task { @MainActor [weak self] in
                self?.consumeOutput(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }

            Task { @MainActor [weak self] in
                self?.consumeStandardError(data)
            }
        }
    }

    private func resolvedCodexLaunchCommand(
        for codexExecutable: String,
        preparedCodexHome: OrbitPreparedCodexHome
    ) -> (executable: String, arguments: [String], environment: [String: String]) {
        let executableURL = URL(fileURLWithPath: codexExecutable)
        let executableDirectory = executableURL.deletingLastPathComponent().path
        let existingEnvironment = ProcessInfo.processInfo.environment
        var mergedEnvironment = existingEnvironment

        let existingPath = existingEnvironment["PATH"] ?? ""
        let pathSegments = [executableDirectory] + existingPath.split(separator: ":").map(String.init)
        mergedEnvironment["PATH"] = Array(NSOrderedSet(array: pathSegments)).compactMap { $0 as? String }.joined(separator: ":")
        mergedEnvironment["HOME"] = NSHomeDirectory()
        mergedEnvironment["CODEX_HOME"] = preparedCodexHome.homeDirectory.path

        if let firstLine = try? String(contentsOf: executableURL, encoding: .utf8)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           firstLine == "#!/usr/bin/env node" {
            let siblingNode = executableURL.deletingLastPathComponent().appendingPathComponent("node").path
            if FileManager.default.isExecutableFile(atPath: siblingNode) {
                return (
                    executable: siblingNode,
                    arguments: [codexExecutable, "app-server"],
                    environment: mergedEnvironment
                )
            }
        }

        return (
            executable: codexExecutable,
            arguments: ["app-server"],
            environment: mergedEnvironment
        )
    }

    private func consumeOutput(_ data: Data) {
        stdoutBuffer.append(data)

        while let newlineRange = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: 0..<newlineRange.lowerBound)
            stdoutBuffer.removeSubrange(0...newlineRange.lowerBound)

            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8),
                  let jsonData = line.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            handleServerMessage(jsonObject)
        }
    }

    private func consumeStandardError(_ data: Data) {
        stderrBuffer.append(data)
    }

    private func handleServerMessage(_ message: [String: Any]) {
        if let error = message["error"] as? [String: Any] {
            let errorMessage = error["message"] as? String ?? "Codex app-server returned an unknown error."
            appendDebugEvent("<- error \(errorMessage)")

            if let id = message["id"] as? Int {
                if id == pendingCollaborationModeRequestID {
                    pendingCollaborationModeRequestID = nil
                    collaborationModes = []
                    notifyStateChanged()
                    return
                }

                if id == pendingExperimentalFeatureRequestID {
                    pendingExperimentalFeatureRequestID = nil
                    experimentalFeatures = []
                    notifyStateChanged()
                    return
                }

                if id == pendingLoginRequestID {
                    pendingLoginRequestID = nil
                    loginRequestTimeoutTask?.cancel()
                    loginRequestTimeoutTask = nil
                    authState = .authFailed(errorMessage)
                    notifyStateChanged()
                    return
                }
            }

            status = .failed(errorMessage)
            eventHandler?(.failed(errorMessage))
            teardownProcess()
            return
        }

        if let method = message["method"] as? String {
            switch method {
            case "account/login/completed":
                appendDebugEvent("<- account/login/completed")
                handleAccountLoginCompleted(message)
            case "account/updated":
                appendDebugEvent("<- account/updated")
                handleAccountUpdated(message)
            case "mcpServer/elicitation/request":
                appendDebugEvent("<- mcpServer/elicitation/request")
                handleMcpElicitationRequest(message)
            case "item/commandExecution/requestApproval":
                appendDebugEvent("<- item/commandExecution/requestApproval")
                handleCommandApprovalRequest(message)
            case "item/fileChange/requestApproval":
                appendDebugEvent("<- item/fileChange/requestApproval")
                handleFileChangeApprovalRequest(message)
            case "item/permissions/requestApproval":
                appendDebugEvent("<- item/permissions/requestApproval")
                handlePermissionsApprovalRequest(message)
            case "item/tool/requestUserInput":
                appendDebugEvent("<- item/tool/requestUserInput")
                handleToolRequestUserInput(message)
            case "thread/status/changed":
                handleThreadStatusChanged(message)
            case "serverRequest/resolved":
                appendDebugEvent("<- serverRequest/resolved")
                emitPhase(.thinking, rawSource: "codex resumed work")
            case "mcpServer/startupStatus/updated":
                handleMcpStartupStatus(message)
            case "turn/started":
                if let params = message["params"] as? [String: Any],
                   let turn = params["turn"] as? [String: Any],
                   let turnID = turn["id"] as? String {
                    appendDebugEvent("<- turn/started \(String(turnID.suffix(6)))")
                    activeTurnID = turnID
                    isAwaitingTurnCompletion = true
                    emitPhase(.thinking, rawSource: "codex is working on it")
                }
            case "item/agentMessage/delta":
                handleAgentMessageDelta(message)
            case "item/started":
                handleItemStarted(message)
            case "item/completed":
                if let params = message["params"] as? [String: Any],
                   let item = params["item"] as? [String: Any],
                   let type = item["type"] as? String,
                   type == "agentMessage",
                   let text = item["text"] as? String,
                   !text.isEmpty {
                    let phase = item["phase"] as? String
                    if phase == "final_answer" || phase == "finalAnswer" {
                        appendDebugEvent("<- item/completed final_answer")
                        latestFinalAnswerText = text
                    } else {
                        appendDebugEvent("<- item/completed agentMessage")
                        latestAgentMessageText = text
                        emitCompletedCommentaryIfNeeded(text: text)
                    }
                }
            case "item/mcpToolCall/progress":
                handleMcpToolCallProgress(message)
            case "turn/completed":
                let turnStatus = turnStatus(from: message)
                appendDebugEvent("<- turn/completed status=\(turnStatus ?? "unknown")")
                let summary = summarizedCompletionMessage(from: message)
                    ?? latestFinalAnswerText
                    ?? latestAgentMessageText
                    ?? "codex finished the action"
                activeTurnID = nil
                isAwaitingTurnCompletion = false
                pendingPrompt = nil
                latestFinalAnswerText = nil
                latestAgentMessageText = nil
                streamedCommentaryBuffer = ""
                hasEmittedEarlyCommentary = false
                hasOpenedBrowserInCurrentTurn = false
                lastEmittedProgress = nil

                if turnStatus == "failed" {
                    status = .failed(summary)
                    eventHandler?(.failed(summary))
                } else if turnStatus == "interrupted" {
                    status = .interrupted(summary)
                    eventHandler?(.interrupted(summary))
                } else {
                    status = .completed(summary)
                    eventHandler?(.completed(summary))
                }
            default:
                break
            }
            return
        }

        if let id = message["id"] as? Int,
           id == 0,
           message["result"] as? [String: Any] != nil {
            appendDebugEvent("<- initialize ok")
            hasReceivedInitializeResponse = true
            hasSentInitialize = false
            startupTimeoutTask?.cancel()
            sendInitialized()
            sendModelList()
            sendAccountRead()
            return
        }

        if let id = message["id"] as? Int,
           id == pendingAccountReadRequestID,
           let result = message["result"] as? [String: Any] {
            pendingAccountReadRequestID = nil
            appendDebugEvent("<- account/read ok")
            updateAccountState(from: result)
            if isAuthenticatedForTurns, activeThreadID == nil {
                sendThreadStart()
            }
            notifyStateChanged()
            return
        }

        if let id = message["id"] as? Int,
           id == pendingCollaborationModeRequestID,
           let result = message["result"] as? [String: Any] {
            pendingCollaborationModeRequestID = nil
            updateCollaborationModes(from: result)
            appendDebugEvent("<- collaborationMode/list modes=\(collaborationModes.count)")
            notifyStateChanged()
            return
        }

        if let id = message["id"] as? Int,
           id == pendingExperimentalFeatureRequestID,
           let result = message["result"] as? [String: Any] {
            pendingExperimentalFeatureRequestID = nil
            updateExperimentalFeatures(from: result)
            appendDebugEvent("<- experimentalFeature/list features=\(experimentalFeatures.count)")
            notifyStateChanged()
            return
        }

        if let id = message["id"] as? Int,
           id == pendingLoginRequestID,
           let result = message["result"] as? [String: Any] {
            pendingLoginRequestID = nil
            loginRequestTimeoutTask?.cancel()
            loginRequestTimeoutTask = nil
            if let authURLString = result["authUrl"] as? String,
               let authURL = URL(string: authURLString) {
                appendDebugEvent("<- account/login/start authUrl")
                lastLoginURL = authURL
                lastLoginID = result["loginId"] as? String
                authState = .loginInProgress
                notifyStateChanged()
                if !openExternalURL(authURL) {
                    authState = .authFailed("Orbit received the ChatGPT login link, but could not open your browser.")
                    notifyStateChanged()
                }
            } else {
                authState = .authFailed("Orbit could not open ChatGPT sign-in.")
                notifyStateChanged()
            }
            return
        }

        if let id = message["id"] as? Int,
           id == pendingLogoutRequestID,
           message["result"] as? [String: Any] != nil {
            pendingLogoutRequestID = nil
            appendDebugEvent("<- account/logout ok")
            authState = .authRequired
            activeThreadID = nil
            hasSentThreadStart = false
            notifyStateChanged()
            return
        }

        if let id = message["id"] as? Int,
           id == pendingModelCatalogRequestID,
           let result = message["result"] as? [String: Any] {
            pendingModelCatalogRequestID = nil
            updateModelCatalog(from: result)
            appendDebugEvent("<- model/list models=\(availableModelOptions.count)")
            notifyStateChanged()
            return
        }

        if let id = message["id"] as? Int,
           id == 1,
           message["result"] as? [String: Any] != nil,
           let result = message["result"] as? [String: Any],
           let thread = result["thread"] as? [String: Any],
           let threadID = thread["id"] as? String {
            activeThreadID = threadID
            hasSentThreadStart = false
            appendDebugEvent("<- thread/start ok \(String(threadID.suffix(6)))")
            notifyStateChanged()
            if pendingPrompt != nil {
                attemptPendingTurnStart()
            } else {
                status = .idle
            }
            return
        }

        if let id = message["id"] as? Int, id == 2,
           message["result"] as? [String: Any] != nil {
            appendDebugEvent("<- turn/start accepted")
            isAwaitingTurnCompletion = true
            emitPhase(.thinking, rawSource: "codex is working on it")
            return
        }

        if let id = message["id"] as? Int,
           id == 3,
           message["result"] as? [String: Any] != nil {
            appendDebugEvent("<- turn/interrupt accepted")
            emitPhase(.interrupted, detail: "stopping the current codex turn.", rawSource: "interrupting codex")
            return
        }
    }

    private func sendInitialize() {
        guard !hasSentInitialize else { return }
        hasSentInitialize = true
        sendJSON([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "orbit_mac",
                    "title": "Orbit Mac",
                    "version": "0.1.0"
                ]
            ]
        ])
    }

    private func sendInitialized() {
        sendJSON([
            "method": "initialized",
            "params": [:]
        ])
    }

    private func sendAccountRead(refreshToken: Bool = false) {
        let requestID = nextClientRequestID()
        pendingAccountReadRequestID = requestID
        authState = .checking
        notifyStateChanged()
        sendJSON([
            "method": "account/read",
            "id": requestID,
            "params": [
                "refreshToken": refreshToken
            ]
        ])
    }

    private func sendModelList() {
        let requestID = nextClientRequestID()
        pendingModelCatalogRequestID = requestID
        appendDebugEvent("-> model/list #\(requestID)")
        sendJSON([
            "method": "model/list",
            "id": requestID,
            "params": [
                "limit": 50,
                "includeHidden": false
            ]
        ])
    }

    private func sendCollaborationModeList() {
        let requestID = nextClientRequestID()
        pendingCollaborationModeRequestID = requestID
        appendDebugEvent("-> collaborationMode/list #\(requestID)")
        sendJSON([
            "method": "collaborationMode/list",
            "id": requestID,
            "params": [:]
        ])
    }

    private func sendExperimentalFeatureList() {
        let requestID = nextClientRequestID()
        pendingExperimentalFeatureRequestID = requestID
        appendDebugEvent("-> experimentalFeature/list #\(requestID)")
        sendJSON([
            "method": "experimentalFeature/list",
            "id": requestID,
            "params": [
                "limit": 100
            ]
        ])
    }

    private func sendThreadStart() {
        guard activeThreadID == nil, !hasSentThreadStart else { return }
        hasSentThreadStart = true
        var params: [String: Any] = [
            "model": normalizedCurrentActionModel,
            "approvalPolicy": "never",
            "sandbox": AppBundleConfiguration.stringValue(forKey: "CodexActionSandbox") ?? "danger-full-access",
            "cwd": NSHomeDirectory(),
            "serviceName": "orbit"
        ]
        if resolvedServiceTier == .fast {
            params["serviceTier"] = OrbitCodexServiceTier.fast.rawValue
        }
        appendDebugEvent("-> thread/start model=\(normalizedCurrentActionModel) effort=\(resolvedEffortForCurrentModel.rawValue) tier=\(resolvedServiceTier.rawValue)")
        sendJSON([
            "method": "thread/start",
            "id": 1,
            "params": params
        ])
    }

    private var setupResolutionReached: Bool {
        switch authState {
        case .authenticated, .authRequired, .loginInProgress, .authFailed, .runtimeUnavailable:
            return true
        case .unknown, .checking:
            return false
        }
    }

    private func notifyStateChanged() {
        stateDidChange?()
    }

    private func attemptPendingTurnStart(forceAfterTimeout: Bool = false) {
        guard activeThreadID != nil, pendingPrompt != nil, !isAwaitingTurnCompletion else { return }

        if browserToolStartupStillPending && !forceAfterTimeout {
            emitPhase(
                .startingCodex,
                detail: "connecting browser tools.",
                rawSource: "waiting for browser tools"
            )
            schedulePendingTurnStartRetryIfNeeded()
            return
        }

        pendingTurnStartRetryTask?.cancel()
        pendingTurnStartRetryTask = nil
        sendTurnStart()
    }

    private var browserToolStartupStillPending: Bool {
        Self.browserToolServerNames.contains { serverName in
            guard let state = mcpStartupStates[serverName] else { return false }
            return !state.isResolved
        }
    }

    private func schedulePendingTurnStartRetryIfNeeded() {
        guard pendingTurnStartRetryTask == nil else { return }
        pendingTurnStartRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            self.pendingTurnStartRetryTask = nil
            self.attemptPendingTurnStart(forceAfterTimeout: true)
        }
    }

    private var runtimeCapabilityNote: String? {
        let browserFailures = Self.browserToolServerNames.compactMap { serverName -> String? in
            guard case .failed(let errorMessage) = mcpStartupStates[serverName] else { return nil }
            let detail = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                return "- \(serverName) browser tools are unavailable in this Orbit session: \(detail)"
            }
            return "- \(serverName) browser tools are unavailable in this Orbit session"
        }

        guard !browserFailures.isEmpty else { return nil }

        return """
        Runtime capability note:
        \(browserFailures.joined(separator: "\n"))
        - do not claim browser control is available unless the tools actually work in this session
        """
    }

    private func sendTurnStart() {
        guard let threadID = activeThreadID, let pendingPrompt else { return }

        var inputItems: [[String: Any]] = []

        if let runtimeCapabilityNote {
            inputItems.append([
                "type": "text",
                "text": runtimeCapabilityNote
            ])
        }

        if let latestRequest,
           let screenshotPath = latestRequest.screenshotPath,
           !screenshotPath.isEmpty {
            inputItems.append([
                "type": "localImage",
                "path": screenshotPath
            ])

            if let visualContext = visualContextMessage(for: latestRequest) {
                inputItems.append([
                    "type": "text",
                    "text": visualContext
                ])
            }
        }

        let activeSkills = activeBundledSkillsForCurrentRequest()
        if !activeSkills.isEmpty {
            inputItems.append([
                "type": "text",
                "text": activeSkills.map { "$\($0.name)" }.joined(separator: " ")
            ])

            for skill in activeSkills {
                inputItems.append([
                    "type": "skill",
                    "name": skill.name,
                    "path": skill.path.path
                ])
            }
            appendDebugEvent("injecting skills: \(activeSkills.map(\.name).joined(separator: ", "))")
        }

        inputItems.append([
            "type": "text",
            "text": pendingPrompt
        ])

        var params: [String: Any] = [
            "threadId": threadID,
            "input": inputItems,
            "model": currentActionModel,
            "effort": resolvedEffortForCurrentModel.rawValue
        ]
        if resolvedServiceTier == .fast {
            params["serviceTier"] = OrbitCodexServiceTier.fast.rawValue
        }
        appendDebugEvent("-> turn/start model=\(currentActionModel) effort=\(resolvedEffortForCurrentModel.rawValue) tier=\(resolvedServiceTier.rawValue) inputItems=\(inputItems.count)")

        sendJSON([
            "method": "turn/start",
            "id": 2,
            "params": params
        ])
    }

    private func sendTurnSteer() {
        guard let threadID = activeThreadID,
              let activeTurnID,
              let pendingPrompt else {
            return
        }

        var inputItems: [[String: Any]] = []

        if let runtimeCapabilityNote {
            inputItems.append([
                "type": "text",
                "text": runtimeCapabilityNote
            ])
        }

        if let latestRequest,
           let screenshotPath = latestRequest.screenshotPath,
           !screenshotPath.isEmpty {
            inputItems.append([
                "type": "localImage",
                "path": screenshotPath
            ])

            if let visualContext = visualContextMessage(for: latestRequest) {
                inputItems.append([
                    "type": "text",
                    "text": visualContext
                ])
            }
        }

        let activeSkills = activeBundledSkillsForCurrentRequest()
        if !activeSkills.isEmpty {
            inputItems.append([
                "type": "text",
                "text": activeSkills.map { "$\($0.name)" }.joined(separator: " ")
            ])

            for skill in activeSkills {
                inputItems.append([
                    "type": "skill",
                    "name": skill.name,
                    "path": skill.path.path
                ])
            }
            appendDebugEvent("injecting skills on steer: \(activeSkills.map(\.name).joined(separator: ", "))")
        }

        inputItems.append([
            "type": "text",
            "text": pendingPrompt
        ])

        let requestID = nextClientRequestID()
        appendDebugEvent("-> turn/steer #\(requestID) turn=\(String(activeTurnID.suffix(6))) inputItems=\(inputItems.count)")
        sendJSON([
            "method": "turn/steer",
            "id": requestID,
            "params": [
                "threadId": threadID,
                "input": inputItems,
                "expectedTurnId": activeTurnID
            ]
        ])

        emitPhase(
            .thinking,
            detail: "steering the current codex turn.",
            rawSource: "steering the current codex turn"
        )
    }

    private func activeBundledSkillsForCurrentRequest() -> [OrbitBundledSkill] {
        guard let latestRequest else { return [] }
        return OrbitBundledSkills.activeSkills(
            for: latestRequest,
            preparedCodexHome: preparedCodexHome
        )
    }

    private func nextClientRequestID() -> Int {
        nextRequestID += 1
        return nextRequestID
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let stdinHandle else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        stdinHandle.write(data)
        stdinHandle.write(Data([0x0A]))
    }

    private func sendResponse(id: Int, result: [String: Any]) {
        appendDebugEvent("-> response #\(id)")
        sendJSON([
            "id": id,
            "result": result
        ])
    }

    private func beginStartupTimeoutWatch() {
        startupTimeoutTask?.cancel()
        startupTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                guard let self, !self.hasReceivedInitializeResponse else { return }
                let stderrText = String(data: self.stderrBuffer, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let message = stderrText?.isEmpty == false
                    ? "Orbit could not connect to Codex app-server. \(stderrText!)"
                    : "Orbit could not connect to Codex app-server."
                self.status = .failed(message)
                self.eventHandler?(.failed(message))
                self.teardownProcess()
            }
        }
    }

    private func handleProcessTermination(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        let wasHandlingSession = hasSentInitialize
            || hasSentThreadStart
            || hasReceivedInitializeResponse
            || activeThreadID != nil
            || status == .running
            || isAwaitingTurnCompletion

        if intentionalShutdownInProgress {
            teardownProcess()
            return
        }

        guard wasHandlingSession else {
            teardownProcess()
            return
        }

        let stderrText = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = stderrText?.isEmpty == false
            ? "Codex action process exited: \(stderrText!)"
            : "Codex action process exited unexpectedly."
        status = .failed(message)
        if isAwaitingTurnCompletion {
            eventHandler?(.failed(message))
        }
        teardownProcess()
    }

    private func summarizedCompletionMessage(from message: [String: Any]) -> String? {
        guard let params = message["params"] as? [String: Any],
              let turn = params["turn"] as? [String: Any] else {
            return nil
        }

        if let status = turn["status"] as? String, status == "failed",
           let error = turn["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        return nil
    }

    private func turnStatus(from message: [String: Any]) -> String? {
        guard let params = message["params"] as? [String: Any],
              let turn = params["turn"] as? [String: Any] else {
            return nil
        }

        return turn["status"] as? String
    }

    private func handleMcpElicitationRequest(_ message: [String: Any]) {
        guard let requestID = message["id"] as? Int,
              let params = message["params"] as? [String: Any] else {
            return
        }

        let messageText = params["message"] as? String ?? "Codex requested tool approval."
        status = .waitingForApproval(messageText)
        emitPhase(.waitingForApproval, rawSource: messageText)

        let meta = params["_meta"] as? [String: Any]
        let toolDescription = meta?["tool_description"] as? String
        let approvalDetail = toolDescription.map { "approving \($0.lowercased()) for this session." }

        sendResponse(
            id: requestID,
            result: [
                "action": "accept",
                "content": NSNull(),
                "_meta": [
                    "orbitAutoApproved": true
                ]
            ]
        )

        status = .running
        emitPhase(.thinking, detail: approvalDetail, rawSource: "codex tool access approved")
    }

    private func handleCommandApprovalRequest(_ message: [String: Any]) {
        guard let requestID = message["id"] as? Int else { return }
        status = .waitingForApproval("command approval")
        emitPhase(.waitingForApproval, detail: "approving command access for this session.", rawSource: "approving codex command execution")
        sendResponse(id: requestID, result: ["decision": "acceptForSession"])
        status = .running
        emitPhase(.thinking, rawSource: "command approval complete")
    }

    private func handleFileChangeApprovalRequest(_ message: [String: Any]) {
        guard let requestID = message["id"] as? Int else { return }
        status = .waitingForApproval("file approval")
        emitPhase(.waitingForApproval, detail: "approving file changes for this session.", rawSource: "approving codex file changes")
        sendResponse(id: requestID, result: ["decision": "acceptForSession"])
        status = .running
        emitPhase(.thinking, rawSource: "file approval complete")
    }

    private func handlePermissionsApprovalRequest(_ message: [String: Any]) {
        guard let requestID = message["id"] as? Int,
              let params = message["params"] as? [String: Any] else {
            return
        }

        let requestedPermissions = params["permissions"] as? [String: Any] ?? [:]
        status = .waitingForApproval("permissions approval")
        emitPhase(.waitingForApproval, detail: "granting requested permissions for this session.", rawSource: "granting codex requested permissions for this session")
        sendResponse(
            id: requestID,
            result: [
                "permissions": [
                    "network": requestedPermissions["network"] ?? NSNull(),
                    "fileSystem": requestedPermissions["fileSystem"] ?? NSNull()
                ],
                "scope": "session"
            ]
        )
        status = .running
        emitPhase(.thinking, rawSource: "permissions approval complete")
    }

    private func handleThreadStatusChanged(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any],
              let status = params["status"] as? [String: Any],
              let type = status["type"] as? String else {
            return
        }

        if type == "active",
           let flags = status["activeFlags"] as? [String],
           flags.contains("waitingOnApproval") {
            emitPhase(.waitingForApproval, rawSource: "waiting on a tool approval")
        } else if type == "idle", !isAwaitingTurnCompletion {
            lastEmittedProgress = nil
        }
    }

    private func handleMcpStartupStatus(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any],
              let serverName = params["name"] as? String,
              let status = params["status"] as? String else {
            return
        }

        if Self.browserToolServerNames.contains(serverName) {
            let errorMessage = (params["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch status {
            case "starting":
                mcpStartupStates[serverName] = .starting
            case "ready":
                mcpStartupStates[serverName] = .ready
            case "failed":
                mcpStartupStates[serverName] = .failed(errorMessage)
            default:
                break
            }
        }

        if status == "starting" {
            emitPhase(.startingCodex, detail: "starting \(serverName) tools.", rawSource: "starting \(serverName) tools")
        } else if status == "ready" && (serverName == "playwright" || serverName == "chrome-devtools") {
            emitPhase(.thinking, rawSource: "\(serverName) tools are ready")
        } else if status == "failed" && (serverName == "playwright" || serverName == "chrome-devtools") {
            let detail = {
                let trimmed = (params["error"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let trimmed, !trimmed.isEmpty {
                    return trimmed
                }
                return "browser tools failed to start."
            }()
            appendDebugEvent("\(serverName) tools failed: \(detail)")
        }

        if pendingPrompt != nil, activeThreadID != nil, !isAwaitingTurnCompletion {
            attemptPendingTurnStart()
        }
    }

    private func handleAccountUpdated(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any] else { return }
        let authMode = params["authMode"] as? String
        if authMode == nil {
            authState = .authRequired
            activeThreadID = nil
            hasSentThreadStart = false
        }
        if authMode == "chatgpt" || authMode == "chatgptAuthTokens" || authMode == "apikey" {
            sendAccountRead(refreshToken: false)
        }
        notifyStateChanged()
    }

    private func handleAccountLoginCompleted(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any] else { return }
        let success = params["success"] as? Bool ?? false
        let loginID = params["loginId"] as? String
        let errorMessage = params["error"] as? String

        if let loginID, loginID == lastLoginID || lastLoginID == nil {
            lastLoginID = loginID
        }

        if success {
            authState = .checking
            notifyStateChanged()
            sendAccountRead(refreshToken: true)
        } else {
            authState = .authFailed(errorMessage ?? "ChatGPT sign-in was cancelled.")
            notifyStateChanged()
        }
    }

    private func beginLoginTimeoutWatch(for requestID: Int) {
        loginRequestTimeoutTask?.cancel()
        loginRequestTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard pendingLoginRequestID == requestID else { return }
            appendDebugEvent("account/login/start timed out")
            pendingLoginRequestID = nil
            authState = .authFailed("Orbit did not receive the ChatGPT sign-in link. Try connecting again.")
            notifyStateChanged()
        }
    }

    @discardableResult
    private func openExternalURL(_ url: URL) -> Bool {
        if NSWorkspace.shared.open(url) {
            appendDebugEvent("opened login URL in browser")
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]

        do {
            try process.run()
            appendDebugEvent("opened login URL via /usr/bin/open")
            return true
        } catch {
            appendDebugEvent("failed to open login URL: \(error.localizedDescription)")
            return false
        }
    }

    private func updateAccountState(from result: [String: Any]) {
        if let account = result["account"] as? [String: Any] {
            authState = .authenticated(
                email: account["email"] as? String,
                plan: account["planType"] as? String
            )
            return
        }

        let requiresOpenaiAuth = result["requiresOpenaiAuth"] as? Bool ?? false
        authState = requiresOpenaiAuth ? .authRequired : .authenticated(email: nil, plan: nil)
    }

    private func handleItemStarted(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any],
              let item = params["item"] as? [String: Any],
              let type = item["type"] as? String else {
            return
        }

        switch type {
        case "mcpToolCall":
            let server = item["server"] as? String ?? "tool"
            let tool = item["tool"] as? String ?? "action"
            emitPhase(progressForTool(server: server, tool: tool), rawSource: "using \(server) \(tool)")
        case "commandExecution":
            if let command = item["command"] as? [String], !command.isEmpty {
                emitPhase(progressForCommand(command), rawSource: "running \(command.joined(separator: " "))")
            }
        case "fileChange":
            emitPhase(.editingFiles, detail: "editing files in the current session.", rawSource: "preparing changes")
        default:
            break
        }
    }

    private func handleAgentMessageDelta(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any] else { return }

        let phase = resolvedAgentMessagePhase(from: params)
        let deltaText = extractedAgentDeltaText(from: params)
        let fullText = extractedAgentText(from: params)

        if let fullText, !fullText.isEmpty {
            if phase == "final_answer" || phase == "finalAnswer" {
                latestFinalAnswerText = fullText
            } else {
                latestAgentMessageText = fullText
            }
        }

        guard phase != "final_answer",
              phase != "finalAnswer",
              let deltaText,
              !deltaText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        streamedCommentaryBuffer = Self.mergedCommentaryBuffer(
            existing: streamedCommentaryBuffer,
            incomingDelta: deltaText
        )

        if let update = Self.visibleCommentaryUpdate(from: streamedCommentaryBuffer),
           update != lastEmittedLiveCommentary {
            lastEmittedLiveCommentary = update
            eventHandler?(.liveUpdate(update))
        }

        guard !hasEmittedEarlyCommentary,
              let snippet = Self.speakableCommentarySnippet(from: streamedCommentaryBuffer) else {
            return
        }

        hasEmittedEarlyCommentary = true
        eventHandler?(.commentary(snippet))
    }

    private func emitCompletedCommentaryIfNeeded(text: String) {
        if let update = Self.visibleCommentaryUpdate(from: text),
           update != lastEmittedLiveCommentary {
            lastEmittedLiveCommentary = update
            eventHandler?(.liveUpdate(update))
        }

        guard !hasEmittedEarlyCommentary,
              let snippet = Self.speakableCommentarySnippet(from: text) else {
            return
        }

        hasEmittedEarlyCommentary = true
        eventHandler?(.commentary(snippet))
    }

    private func handleToolRequestUserInput(_ message: [String: Any]) {
        guard let requestID = message["id"] as? Int,
              let params = message["params"] as? [String: Any],
              let questions = params["questions"] as? [[String: Any]],
              let firstQuestion = questions.first,
              let options = firstQuestion["options"] as? [[String: Any]] else {
            return
        }

        let optionLabels = options.compactMap { $0["label"] as? String }
        let promptTitle = firstQuestion["question"] as? String
            ?? params["message"] as? String
            ?? "Codex needs your answer."
        let questionID = firstQuestion["id"] as? String ?? "choice"
        let detail = optionLabels.isEmpty ? nil : optionLabels.joined(separator: " · ")

        status = .waitingForApproval(promptTitle)
        emitPhase(.waitingForChoice, detail: promptTitle, rawSource: "waiting on your tool choice")
        eventHandler?(
            .toolPrompt(
                OrbitToolPrompt(
                    requestID: requestID,
                    title: promptTitle,
                    detail: detail,
                    questionID: questionID,
                    options: optionLabels
                )
            )
        )
    }

    private func handleMcpToolCallProgress(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any] else { return }

        let item = params["item"] as? [String: Any]
        let server = (item?["server"] as? String) ?? (params["server"] as? String) ?? "tool"
        let tool = (item?["tool"] as? String) ?? (params["tool"] as? String) ?? "action"
        let progressText = firstString(in: params["delta"])
            ?? firstString(in: params["message"])
            ?? firstString(in: item?["message"])
            ?? firstString(in: item?["delta"])

        emitPhase(progressForTool(server: server, tool: tool), rawSource: "using \(server) \(tool)")
        if let progressText {
            let cleaned = progressText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                appendDebugEvent("<- tool/progress \(cleaned)")
            }
        }
    }

    private func emitPhase(
        _ phase: OrbitActionPhase,
        detail: String? = nil,
        rawSource: String? = nil,
        force: Bool = false
    ) {
        let progress = OrbitActionProgress(phase: phase, detail: detail, rawSource: rawSource)
        if !force, progress == lastEmittedProgress {
            return
        }

        lastEmittedProgress = progress
        appendDebugEvent(
            "phase=\(phase.summaryText)"
                + (progress.resolvedDetail.map { " detail=\($0)" } ?? "")
        )
        eventHandler?(.phase(progress))
    }

    private func emitPhase(
        _ progress: OrbitActionProgress?,
        rawSource: String? = nil,
        force: Bool = false
    ) {
        guard let progress else { return }
        emitPhase(progress.phase, detail: progress.detail, rawSource: rawSource ?? progress.rawSource, force: force)
    }

    private func progressForTool(server: String, tool: String) -> OrbitActionProgress? {
        let normalizedServer = server.lowercased()
        let normalizedTool = tool.lowercased()

        if normalizedServer.contains("playwright") || normalizedServer.contains("chrome") {
            if !hasOpenedBrowserInCurrentTurn {
                hasOpenedBrowserInCurrentTurn = true
                return OrbitActionProgress(phase: .openingBrowser)
            }

            if normalizedTool.contains("navigate")
                || normalizedTool.contains("new_page")
                || normalizedTool.contains("newpage")
                || normalizedTool.contains("goto")
                || normalizedTool.contains("open") {
                return OrbitActionProgress(phase: .navigating)
            }

            if normalizedTool.contains("click")
                || normalizedTool.contains("drag")
                || normalizedTool.contains("hover")
                || normalizedTool.contains("select_option") {
                return OrbitActionProgress(phase: .clicking)
            }

            if normalizedTool.contains("fill")
                || normalizedTool.contains("type")
                || normalizedTool.contains("press_key")
                || normalizedTool.contains("press") {
                return OrbitActionProgress(phase: .typing)
            }

            if normalizedTool.contains("snapshot")
                || normalizedTool.contains("screenshot")
                || normalizedTool.contains("evaluate")
                || normalizedTool.contains("wait")
                || normalizedTool.contains("console")
                || normalizedTool.contains("network") {
                return OrbitActionProgress(phase: .readingScreen)
            }

            return OrbitActionProgress(phase: .usingTool, detail: "using browser tools in the current session.")
        }

        return OrbitActionProgress(phase: .usingTool, detail: "using \(server) \(tool).")
    }

    private func progressForCommand(_ command: [String]) -> OrbitActionProgress? {
        let joinedCommand = command.joined(separator: " ").lowercased()
        if joinedCommand.contains("open ")
            || joinedCommand.contains("xdg-open")
            || joinedCommand.contains("start ") {
            return OrbitActionProgress(phase: .openingBrowser)
        }

        return OrbitActionProgress(phase: .runningCommand, detail: "running \(command.joined(separator: " ")).")
    }

    private func visualContextMessage(for request: OrbitActionRequest?) -> String? {
        guard let request,
              let imagePixelSize = request.imagePixelSize,
              let cursorPoint = request.cursorPointInImagePixels else {
            return nil
        }

        let screenLabel = request.screenNumber.map { "screen \($0)" } ?? "current screen"
        let screenshotLabel = request.screenshotLabel ?? screenLabel

        return """
        Visual context:
        - attached image: \(screenLabel)
        - image size: \(Int(imagePixelSize.width))x\(Int(imagePixelSize.height)) pixels
        - cursor position in image pixels: \(Int(cursorPoint.x)),\(Int(cursorPoint.y))
        - focus priority: unless the user says otherwise, start with what is nearest the cursor position
        - note: \(screenshotLabel)
        """
    }

    private func wrappedPrompt(for request: OrbitActionRequest) -> String {
        let frontmostContextBlock: String = {
            let appName = request.frontmostApplicationName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let windowTitle = request.frontmostWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let appName, !appName.isEmpty, let windowTitle, !windowTitle.isEmpty {
                return """
                Frontmost desktop context:
                - active app: \(appName)
                - focused window: \(windowTitle)
                """
            }

            if let appName, !appName.isEmpty {
                return """
                Frontmost desktop context:
                - active app: \(appName)
                """
            }

            return "Frontmost desktop context: unavailable for this turn."
        }()

        return """
        \(frontmostContextBlock)

        User request:
        \(request.transcript)
        """
    }

    private var currentActionModel: String {
        normalizedCurrentActionModel
    }

    private var currentActionModelDisplayName: String {
        modelOption(for: normalizedCurrentActionModel)?.displayName
            ?? OrbitCodexModelOption.fallbackOption(for: normalizedCurrentActionModel)?.displayName
            ?? normalizedCurrentActionModel
    }

    private var resolvedEffortForCurrentModel: OrbitCodexReasoningEffort {
        let supported = supportedEffortsForSelectedModel
        if supported.contains(settings.codexReasoningEffort) {
            return settings.codexReasoningEffort
        }
        return modelOption(for: normalizedCurrentActionModel)?.defaultEffort
            ?? OrbitCodexModelOption.fallbackOption(for: normalizedCurrentActionModel)?.defaultEffort
            ?? supported.first
            ?? .low
    }

    private var normalizedCurrentActionModel: String {
        let normalized = settings.codexActionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? OrbitCodexModelOption.fallbackDefaultModel : normalized
    }

    private var resolvedServiceTier: OrbitCodexServiceTier {
        settings.codexServiceTier
    }

    private func resolvedAgentMessagePhase(from params: [String: Any]) -> String? {
        if let phase = params["phase"] as? String {
            return phase
        }

        if let item = params["item"] as? [String: Any],
           let phase = item["phase"] as? String {
            return phase
        }

        return nil
    }

    private func extractedAgentText(from params: [String: Any]) -> String? {
        if let text = params["text"] as? String {
            return text
        }

        if let item = params["item"] as? [String: Any],
           let text = item["text"] as? String {
            return text
        }

        return nil
    }

    private func extractedAgentDeltaText(from params: [String: Any]) -> String? {
        if let delta = params["delta"] as? String {
            return delta
        }

        if let text = params["textDelta"] as? String {
            return text
        }

        if let item = params["item"] as? [String: Any] {
            if let delta = item["delta"] as? String {
                return delta
            }
            if let text = item["textDelta"] as? String {
                return text
            }
        }

        if let delta = firstString(in: params["delta"]) {
            return delta
        }

        return nil
    }

    private func firstString(in value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let dictionary as [String: Any]:
            for key in ["text", "delta", "value", "content"] {
                if let found = firstString(in: dictionary[key]) {
                    return found
                }
            }
            for (_, nestedValue) in dictionary {
                if let found = firstString(in: nestedValue) {
                    return found
                }
            }
        case let array as [Any]:
            for item in array {
                if let found = firstString(in: item) {
                    return found
                }
            }
        default:
            break
        }

        return nil
    }

    static func mergedCommentaryBuffer(existing: String, incomingDelta: String) -> String {
        guard !incomingDelta.isEmpty else { return existing }
        guard !existing.isEmpty else { return incomingDelta }

        if existing.hasSuffix(incomingDelta) {
            return existing
        }

        if incomingDelta.hasPrefix(existing) {
            return incomingDelta
        }

        let maximumOverlap = min(existing.count, incomingDelta.count)
        if maximumOverlap > 0 {
            for overlapCount in stride(from: maximumOverlap, through: 1, by: -1) {
                let existingSuffix = String(existing.suffix(overlapCount))
                let incomingPrefix = String(incomingDelta.prefix(overlapCount))
                if existingSuffix == incomingPrefix {
                    return existing + incomingDelta.dropFirst(overlapCount)
                }
            }
        }

        return existing + incomingDelta
    }

    static func speakableCommentarySnippet(from text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count >= 28 else { return nil }

        if let firstCompletedSentence = firstCompletedSentence(in: cleaned) {
            let candidate = firstCompletedSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.split(separator: " ").count >= 4 else { return nil }
            return candidate
        }

        guard cleaned.count >= 42, cleaned.split(separator: " ").count >= 7 else { return nil }

        let maximumLength = 120
        let wasTruncated = cleaned.count > maximumLength
        let prefix = String(cleaned.prefix(maximumLength))
        let trimmed = (wasTruncated
            ? prefix.replacingOccurrences(of: "\\s+\\S*$", with: "", options: .regularExpression)
            : prefix)
            .replacingOccurrences(
                of: "\\b(?:and|or|to|for|with|of|in|on|at|by|from|about|into|over|after|before|without|using)$",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.split(separator: " ").count >= 4 else { return nil }
        return trimmed.hasSuffix(".") ? trimmed : "\(trimmed)."
    }

    static func visibleCommentaryUpdate(from text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 10 else { return nil }

        let firstSentence = cleaned
            .split(whereSeparator: { ".!?".contains($0) })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? cleaned

        guard firstSentence.split(separator: " ").count >= 3 else { return nil }
        if firstSentence.count <= 96 {
            return firstSentence
        }

        let prefix = String(firstSentence.prefix(93))
        let trimmed = prefix
            .replacingOccurrences(of: "\\s+\\S*$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : "\(trimmed)..."
    }

    private static func firstCompletedSentence(in text: String) -> String? {
        guard let terminatorIndex = text.firstIndex(where: { ".!?".contains($0) }) else {
            return nil
        }

        let sentence = String(text[...terminatorIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? nil : sentence
    }

    private func updateModelCatalog(from result: [String: Any]) {
        let parsedModels = Self.parseModelCatalog(from: result)
        guard !parsedModels.isEmpty else { return }
        availableModelOptions = parsedModels
    }

    private func updateCollaborationModes(from result: [String: Any]) {
        let data = result["data"] as? [[String: Any]] ?? []
        collaborationModes = data.compactMap {
            ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func updateExperimentalFeatures(from result: [String: Any]) {
        let data = result["data"] as? [[String: Any]] ?? []
        experimentalFeatures = data.compactMap {
            ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func appendDebugEvent(_ event: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formattedEvent = "[\(timestamp)] \(event)"
        debugEvents.append(formattedEvent)
        if debugEvents.count > 60 {
            debugEvents.removeFirst(debugEvents.count - 60)
        }
        OrbitSupportLog.append("codex", formattedEvent)
        notifyStateChanged()
    }

    private func modelOption(for model: String) -> OrbitCodexModelOption? {
        availableModelOptions.first(where: { $0.model == model })
    }

    static func parseModelCatalog(from result: [String: Any]) -> [OrbitCodexModelOption] {
        let rawItems = (result["data"] as? [[String: Any]]) ?? (result["models"] as? [[String: Any]]) ?? []

        let parsedModels = rawItems.compactMap { item -> (option: OrbitCodexModelOption, priority: Int)? in
            let normalizedModel = (
                (item["model"] as? String)
                ?? (item["id"] as? String)
                ?? (item["slug"] as? String)
                ?? ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedModel.isEmpty else { return nil }

            let visibility = ((item["visibility"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let hidden = (item["hidden"] as? Bool) ?? (visibility == "hide" || visibility == "hidden")
            guard !hidden else { return nil }

            if let supportedInAPI = item["supported_in_api"] as? Bool, !supportedInAPI {
                return nil
            }

            let inputModalities = (item["inputModalities"] as? [String])
                ?? (item["input_modalities"] as? [String])
                ?? ["text", "image"]
            let normalizedModalities = inputModalities.map { $0.lowercased() }
            guard normalizedModalities.contains("text"), normalizedModalities.contains("image") else {
                return nil
            }

            let effortEntries = (item["supportedReasoningEfforts"] as? [[String: Any]])
                ?? (item["supported_reasoning_levels"] as? [[String: Any]])
                ?? []
            let supportedEfforts = effortEntries.compactMap { entry -> OrbitCodexReasoningEffort? in
                let rawValue = (
                    (entry["reasoningEffort"] as? String)
                    ?? (entry["effort"] as? String)
                    ?? ""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                return OrbitCodexReasoningEffort(rawValue: rawValue)
            }

            let defaultEffort = OrbitCodexReasoningEffort(rawValue: (
                (item["defaultReasoningEffort"] as? String)
                ?? (item["default_reasoning_level"] as? String)
                ?? ""
            ).trimmingCharacters(in: .whitespacesAndNewlines))
            let displayName = formattedModelDisplayName(
                for: normalizedModel,
                fallback: (item["displayName"] as? String) ?? (item["display_name"] as? String)
            )
            let shortDisplayName = shortModelDisplayName(from: displayName)
            let isDefault = (item["isDefault"] as? Bool ?? false) || normalizedModel == OrbitCodexModelOption.fallbackDefaultModel

            return (
                OrbitCodexModelOption(
                    model: normalizedModel,
                    displayName: displayName,
                    shortDisplayName: shortDisplayName,
                    supportedEfforts: supportedEfforts.isEmpty ? OrbitCodexReasoningEffort.allCases : supportedEfforts,
                    defaultEffort: defaultEffort,
                    inputModalities: normalizedModalities,
                    isDefault: isDefault
                ),
                item["priority"] as? Int ?? Int.max
            )
        }

        return parsedModels.sorted { lhs, rhs in
            if lhs.option.isDefault != rhs.option.isDefault {
                return lhs.option.isDefault && !rhs.option.isDefault
            }
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            return lhs.option.displayName.localizedCaseInsensitiveCompare(rhs.option.displayName) == .orderedAscending
        }.map { $0.option }
    }

    private static func formattedModelDisplayName(for model: String, fallback: String?) -> String {
        let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized {
        case "gpt-5.4":
            return "GPT-5.4"
        case "gpt-5.4-mini":
            return "GPT-5.4 Mini"
        case "gpt-5.3-codex":
            return "GPT-5.3 Codex"
        case "gpt-5.2":
            return "GPT-5.2"
        default:
            break
        }

        let fallbackValue = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fallbackValue.isEmpty {
            return fallbackValue
                .replacingOccurrences(of: "^gpt-", with: "GPT-", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "-mini", with: " Mini", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "-codex", with: " Codex", options: [.regularExpression, .caseInsensitive])
        }

        return normalized.uppercased()
    }

    private static func shortModelDisplayName(from displayName: String) -> String {
        let cleaned = displayName
            .replacingOccurrences(of: "GPT-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? displayName : cleaned
    }

    private func resolveCodexExecutable() throws -> String {
        if let bundledPath = bundledCodexExecutablePath() {
            return bundledPath
        }

        if let configuredPath = AppBundleConfiguration.stringValue(forKey: "CodexCLIPath"),
           FileManager.default.isExecutableFile(atPath: configuredPath) {
            return configuredPath
        }

        if let envPath = ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
           FileManager.default.isExecutableFile(atPath: envPath) {
            return envPath
        }

        let commonCandidates = [
            "\(NSHomeDirectory())/.nvm/versions/node/v22.22.1/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        if let resolvedPath = commonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return resolvedPath
        }

        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let lookupProcess = Process()
        lookupProcess.executableURL = URL(fileURLWithPath: loginShell)
        lookupProcess.arguments = ["-lc", "command -v codex"]
        let outputPipe = Pipe()
        lookupProcess.standardOutput = outputPipe
        lookupProcess.standardError = Pipe()
        try lookupProcess.run()
        lookupProcess.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let output, !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
            return output
        }

        throw NSError(
            domain: "CodexAppServerActionProvider",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Orbit could not find its bundled Codex runtime or an external Codex CLI."
            ]
        )
    }

    private func bundledCodexExecutablePath() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let runtimeRoot = resourceURL
            .appendingPathComponent("CodexRuntime", isDirectory: true)
        let nativeBundledPath = runtimeRoot
            .appendingPathComponent("vendor", isDirectory: true)
            .appendingPathComponent("aarch64-apple-darwin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
            .appendingPathComponent("codex")
            .path
        if FileManager.default.isExecutableFile(atPath: nativeBundledPath) {
            return nativeBundledPath
        }

        let bundledWrapperPath = runtimeRoot
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex")
            .path
        return FileManager.default.isExecutableFile(atPath: bundledWrapperPath) ? bundledWrapperPath : nil
    }

    private func teardownProcess() {
        intentionalShutdownInProgress = false
        loginRequestTimeoutTask?.cancel()
        loginRequestTimeoutTask = nil
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        pendingTurnStartRetryTask?.cancel()
        pendingTurnStartRetryTask = nil
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        try? stderrHandle?.close()
        stdoutHandle = nil
        stderrHandle = nil
        stdinHandle = nil
        process = nil
        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
        activeThreadID = nil
        activeTurnID = nil
        pendingPrompt = nil
        latestAgentMessageText = nil
        latestFinalAnswerText = nil
        hasReceivedInitializeResponse = false
        hasSentInitialize = false
        hasSentThreadStart = false
        isAwaitingTurnCompletion = false
        hasOpenedBrowserInCurrentTurn = false
        streamedCommentaryBuffer = ""
        hasEmittedEarlyCommentary = false
        lastEmittedLiveCommentary = nil
        pendingModelCatalogRequestID = nil
        pendingCollaborationModeRequestID = nil
        pendingExperimentalFeatureRequestID = nil
        pendingAccountReadRequestID = nil
        pendingLoginRequestID = nil
        pendingLogoutRequestID = nil
        lastLoginURL = nil
        lastLoginID = nil
        mcpStartupStates = Self.makeInitialMcpStartupStates()
        authState = .unknown
        lastEmittedProgress = nil
        notifyStateChanged()
    }

    private func restartServerForRecovery() {
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil

        if let process, process.isRunning {
            intentionalShutdownInProgress = true
            process.terminationHandler = nil
            process.terminate()
        }

        teardownProcess()
    }
}
