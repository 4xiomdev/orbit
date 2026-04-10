import AppKit
import Foundation

protocol TextToSpeechProvider: AnyObject {
    var displayName: String { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }
    var isPlaying: Bool { get }

    func speakText(_ text: String) async throws
    func stopPlayback()
}

struct OrbitAppleVoiceOption: Identifiable, Equatable {
    let identifier: String
    let name: String
    let language: String
    let displayName: String

    var id: String { identifier }
}

enum OrbitAppleVoiceCatalog {
    private static let siriVoiceIdentifierPrefix = "com.apple.speech.synthesis.voice.custom.siri."
    private static let assistantVoiceMapPath = "/System/Library/PrivateFrameworks/SiriTTSService.framework/Versions/A/Resources/AssistantVoiceMap.plist"
    private static let voiceServicesPrefsPath = "\(NSHomeDirectory())/Library/Preferences/com.apple.voiceservices.plist"
    private static let noveltyVoiceNames: Set<String> = [
        "bad news", "bahh", "bells", "boing", "bubbles", "cellos", "fred",
        "good news", "jester", "junior", "organ", "superstar", "trinoids",
        "whisper", "wobble", "zarvox"
    ]

    static func availableVoices(for localeIdentifier: String = Locale.autoupdatingCurrent.identifier) -> [OrbitAppleVoiceOption] {
        let subscribedIdentifier = subscribedSiriVoiceIdentifier(for: localeIdentifier)
        let candidates = assistantVoiceMapCandidates(for: localeIdentifier)
        let resolvedCandidates = candidates.isEmpty
            ? fallbackSiriCandidates(for: localeIdentifier)
            : candidates
        let finalCandidates: [OrbitAppleVoiceCandidate]
        if resolvedCandidates.isEmpty, let subscribedIdentifier,
           let subscribedCandidate = assistantVoiceCandidate(for: subscribedIdentifier) {
            finalCandidates = [subscribedCandidate]
        } else {
            finalCandidates = resolvedCandidates
        }

        return finalCandidates.map { voice in
            OrbitAppleVoiceOption(
                identifier: voice.identifier,
                name: voice.name,
                language: voice.language,
                displayName: voice.displayName
            )
        }
    }

    static func resolvedVoice(
        preferredIdentifier: String?,
        localeIdentifier: String = Locale.autoupdatingCurrent.identifier
    ) -> String? {
        if let preferredIdentifier = normalizedPreferredIdentifier(preferredIdentifier),
           let resolved = bestReachableIdentifier(for: preferredIdentifier) {
            return resolved
        }

        if let subscribedIdentifier = subscribedSiriVoiceIdentifier(for: localeIdentifier),
           let resolved = bestReachableIdentifier(for: subscribedIdentifier) {
            return resolved
        }

        if let automaticVoice = availableVoices(for: localeIdentifier).first,
           let resolved = bestReachableIdentifier(for: automaticVoice.identifier) {
            return resolved
        }

        return nil
    }

    static func currentSelectionSummary(
        preferredIdentifier: String?,
        localeIdentifier: String = Locale.autoupdatingCurrent.identifier
    ) -> String {
        let automatic = normalizedPreferredIdentifier(preferredIdentifier) == nil
        let candidates = availableVoices(for: localeIdentifier)
        guard let identifier = resolvedVoice(preferredIdentifier: preferredIdentifier, localeIdentifier: localeIdentifier),
              let voice = candidates.first(where: { $0.identifier == identifier })
                ?? assistantVoiceOption(for: identifier) else {
            return automatic ? "Auto: Unavailable" : "Unavailable"
        }

        return automatic ? "Auto · \(voice.name)" : voice.displayName
    }

    static func normalizedPreferredIdentifier(_ preferredIdentifier: String?) -> String? {
        guard let preferredIdentifier else { return nil }
        let trimmed = preferredIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if isReachableSiriVoiceIdentifier(trimmed) {
            return trimmed
        }
        let baseIdentifier = baseSiriIdentifier(from: trimmed)
        return isReachableSiriVoiceIdentifier(baseIdentifier) ? baseIdentifier : nil
    }

    static func makeSynthesizer(for identifier: String?) -> NSSpeechSynthesizer? {
        let trimmedIdentifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedIdentifier.isEmpty {
            return NSSpeechSynthesizer()
        }

        return NSSpeechSynthesizer(voice: NSSpeechSynthesizer.VoiceName(rawValue: trimmedIdentifier))
    }

    private static func allVoiceCandidates() -> [OrbitAppleVoiceCandidate] {
        let standardCandidates = NSSpeechSynthesizer.availableVoices.map(\.rawValue)
        let extraCandidates = discoveredInstalledVoiceIdentifiers()
        let identifiers = Array(Set(standardCandidates + extraCandidates))

        return identifiers.compactMap { identifier in
            makeVoiceCandidate(for: identifier)
        }
    }

    private static func siriVoiceCandidates() -> [OrbitAppleVoiceCandidate] {
        allVoiceCandidates().filter { voice in
            voice.identifier.hasPrefix(siriVoiceIdentifierPrefix)
        }
    }

    private static func fallbackSiriCandidates(for localeIdentifier: String) -> [OrbitAppleVoiceCandidate] {
        let normalizedLocale = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        let baseLanguageCode = Locale(identifier: localeIdentifier).language.languageCode?.identifier

        let exactMatches = siriVoiceCandidates().filter { voice in
            voice.language == normalizedLocale
        }

        let baseMatches = siriVoiceCandidates().filter { voice in
            guard let baseLanguageCode else { return false }
            return voice.language == baseLanguageCode || voice.language.hasPrefix("\(baseLanguageCode)-")
        }

        return deduplicatedAndSortedVoices(exactMatches + baseMatches + siriVoiceCandidates())
    }

    private static func deduplicatedAndSortedVoices(_ voices: [OrbitAppleVoiceCandidate]) -> [OrbitAppleVoiceCandidate] {
        voices
            .reduce(into: [String: OrbitAppleVoiceCandidate]()) { partialResult, voice in
                if let existing = partialResult[voice.identifier] {
                    if voiceScore(voice) > voiceScore(existing) {
                        partialResult[voice.identifier] = voice
                    }
                } else {
                    partialResult[voice.identifier] = voice
                }
            }
            .values
            .sorted { lhs, rhs in
                if let lhsOrder = lhs.order, let rhsOrder = rhs.order, lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                let lhsScore = voiceScore(lhs)
                let rhsScore = voiceScore(rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private static func isReachableSiriVoiceIdentifier(_ identifier: String) -> Bool {
        if identifier.hasPrefix(siriVoiceIdentifierPrefix), makeSynthesizer(for: identifier) != nil {
            return true
        }
        let baseIdentifier = baseSiriIdentifier(from: identifier)
        return baseIdentifier.hasPrefix(siriVoiceIdentifierPrefix) && makeSynthesizer(for: baseIdentifier) != nil
    }

    private static func baseSiriIdentifier(from identifier: String) -> String {
        guard identifier.hasPrefix(siriVoiceIdentifierPrefix) else { return identifier }
        if identifier.hasSuffix(".premium") {
            return String(identifier.dropLast(".premium".count))
        }
        return identifier
    }

    private static func discoveredInstalledVoiceIdentifiers() -> [String] {
        let prefsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.speech.voice.prefs.plist")

        guard let prefs = NSDictionary(contentsOf: prefsURL) as? [String: Any] else {
            return []
        }

        var identifiers: Set<String> = []

        if let installationLog = prefs["SpeechDataInstallationLog"] as? [String: Any] {
            for key in installationLog.keys {
                if let stripped = key.split(separator: ":", maxSplits: 1).last, key.hasPrefix("VOICEID:") {
                    identifiers.insert(String(stripped))
                }
            }
        }

        if let voiceStatistics = prefs["VoiceStatistics"] as? [String: Any],
           let perVoiceTable = voiceStatistics["PerVoiceTable"] as? [String: Any] {
            for key in perVoiceTable.keys {
                identifiers.insert(key)
            }
        }

        return Array(identifiers)
    }

    private static func installedVariants(for identifier: String) -> [String] {
        let targetBase = baseSiriIdentifier(from: identifier)
        let installed = discoveredInstalledVoiceIdentifiers()
        let variants = installed.filter { installedIdentifier in
            let normalizedInstalled = baseSiriIdentifier(from: installedIdentifier)
            return normalizedInstalled == targetBase
        }
        if variants.isEmpty, targetBase != identifier {
            return [identifier, targetBase].filter { isReachableSiriVoiceIdentifier($0) }
        }
        return variants
    }

    private static func bestReachableIdentifier(for identifier: String) -> String? {
        let candidates = Array(Set(installedVariants(for: identifier) + [identifier, baseSiriIdentifier(from: identifier)]))
            .filter { isReachableSiriVoiceIdentifier($0) }
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            siriIdentifierScore(lhs) < siriIdentifierScore(rhs)
        }
    }

    private static func siriIdentifierScore(_ identifier: String) -> Int {
        let lowered = identifier.lowercased()
        var score = 100
        if lowered.contains(".premiumhigh") {
            score += 400
        } else if lowered.contains(".premium") {
            score += 300
        }
        if lowered.contains(".neuralax.") {
            score += 120
        } else if lowered.contains(".neural.") {
            score += 100
        } else if lowered.contains(".natural.") {
            score += 80
        } else if lowered.contains(".gryphon.") {
            score += 60
        }
        return score
    }

    private static func assistantVoiceMapCandidates(for localeIdentifier: String) -> [OrbitAppleVoiceCandidate] {
        guard let voiceMap = NSDictionary(contentsOfFile: assistantVoiceMapPath) as? [String: Any] else {
            return []
        }

        let requestedLocale = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        let requestedBaseLanguage = Locale(identifier: localeIdentifier).language.languageCode?.identifier

        let exactLocale = voiceMap.keys.first(where: { $0.caseInsensitiveCompare(requestedLocale) == .orderedSame })
        let baseMatches = voiceMap.keys
            .filter { locale in
                guard let requestedBaseLanguage else { return false }
                return locale.hasPrefix("\(requestedBaseLanguage)-")
            }
            .sorted()
        let matchedLocale = exactLocale
            ?? preferredLocaleMatch(from: baseMatches, requestedLocale: requestedLocale)

        guard let matchedLocale,
              let entries = voiceMap[matchedLocale] as? [[String: Any]] else {
            return []
        }

        let candidates = entries.compactMap { entry -> OrbitAppleVoiceCandidate? in
            guard let identifier = entry["identifier"] as? String,
                  isReachableSiriVoiceIdentifier(identifier) else {
                return nil
            }

            let order = entry["order"] as? Int
            let rawName = (entry["name"] as? String) ?? parsedCustomSiriName(from: identifier) ?? "Siri"
            let displayName = order.map { "Voice \($0) · \(formattedVoiceName(rawName))" } ?? formattedVoiceName(rawName)

            return OrbitAppleVoiceCandidate(
                identifier: bestReachableIdentifier(for: identifier) ?? identifier,
                name: formattedVoiceName(rawName),
                language: matchedLocale,
                displayName: premiumAwareDisplayName(displayName, identifier: bestReachableIdentifier(for: identifier) ?? identifier),
                order: order
            )
        }

        return deduplicatedAndSortedVoices(candidates)
    }

    private static func preferredLocaleMatch(from candidates: [String], requestedLocale: String) -> String? {
        guard !candidates.isEmpty else { return nil }
        if candidates.contains("en-US") {
            return "en-US"
        }
        let normalizedRequested = requestedLocale.replacingOccurrences(of: "_", with: "-")
        if let regionMatch = candidates.first(where: { $0.caseInsensitiveCompare(normalizedRequested) == .orderedSame }) {
            return regionMatch
        }
        return candidates.first
    }

    private static func subscribedSiriVoiceIdentifier(for localeIdentifier: String) -> String? {
        guard let prefs = NSDictionary(contentsOfFile: voiceServicesPrefsPath) as? [String: Any],
              let subscribedAssets = prefs["subscribedAssets"] as? [String: Any] else {
            return nil
        }

        let requestedLocale = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        let requestedBaseLanguage = Locale(identifier: localeIdentifier).language.languageCode?.identifier

        for serviceGroup in subscribedAssets.values {
            guard let serviceMap = serviceGroup as? [String: Any] else { continue }
            for assets in serviceMap.values {
                guard let entries = assets as? [[String: Any]] else { continue }
                for entry in entries {
                    let languages = (entry["Languages"] as? [String])?.map { $0.replacingOccurrences(of: "_", with: "-") } ?? []
                    let matchesLocale = languages.contains { $0.caseInsensitiveCompare(requestedLocale) == .orderedSame }
                        || languages.contains { language in
                            guard let requestedBaseLanguage else { return false }
                            return language.hasPrefix("\(requestedBaseLanguage)-")
                        }
                    guard matchesLocale, let name = entry["Name"] as? String else { continue }
                    let identifier = "\(siriVoiceIdentifierPrefix)\(name.lowercased())"
                    if isReachableSiriVoiceIdentifier(identifier) {
                        return identifier
                    }
                }
            }
        }

        return nil
    }

    private static func assistantVoiceCandidate(for identifier: String) -> OrbitAppleVoiceCandidate? {
        guard let voiceMap = NSDictionary(contentsOfFile: assistantVoiceMapPath) as? [String: Any] else {
            return nil
        }

        let targetIdentifier = baseSiriIdentifier(from: identifier)
        for (locale, rawEntries) in voiceMap {
            guard let entries = rawEntries as? [[String: Any]] else { continue }
            for entry in entries {
                guard let entryIdentifier = entry["identifier"] as? String,
                      baseSiriIdentifier(from: entryIdentifier) == targetIdentifier,
                      isReachableSiriVoiceIdentifier(entryIdentifier) else {
                    continue
                }

                let order = entry["order"] as? Int
                let rawName = (entry["name"] as? String) ?? parsedCustomSiriName(from: targetIdentifier) ?? "Siri"
                let displayName = order.map { "Voice \($0) · \(formattedVoiceName(rawName))" } ?? formattedVoiceName(rawName)
                return OrbitAppleVoiceCandidate(
                    identifier: bestReachableIdentifier(for: targetIdentifier) ?? targetIdentifier,
                    name: formattedVoiceName(rawName),
                    language: locale,
                    displayName: premiumAwareDisplayName(displayName, identifier: bestReachableIdentifier(for: targetIdentifier) ?? targetIdentifier),
                    order: order
                )
            }
        }

        return nil
    }

    private static func assistantVoiceOption(for identifier: String) -> OrbitAppleVoiceOption? {
        guard let candidate = assistantVoiceCandidate(for: identifier) else { return nil }
        return OrbitAppleVoiceOption(
            identifier: candidate.identifier,
            name: candidate.name,
            language: candidate.language,
            displayName: candidate.displayName
        )
    }

    private static func makeVoiceCandidate(for identifier: String) -> OrbitAppleVoiceCandidate? {
        guard makeSynthesizer(for: identifier) != nil else {
            return nil
        }

        let attributes = NSSpeechSynthesizer.attributes(
            forVoice: NSSpeechSynthesizer.VoiceName(rawValue: identifier)
        )

        let localeKey = NSSpeechSynthesizer.VoiceAttributeKey(rawValue: "VoiceLocaleIdentifier")
        let nameKey = NSSpeechSynthesizer.VoiceAttributeKey(rawValue: "VoiceName")

        let language = (attributes[localeKey] as? String)?.replacingOccurrences(of: "_", with: "-")
            ?? Locale.autoupdatingCurrent.identifier.replacingOccurrences(of: "_", with: "-")
        let reportedName = attributes[nameKey] as? String

        let displayName = displayName(for: identifier, reportedName: reportedName)
        let name = compactName(for: identifier, reportedName: reportedName)

        return OrbitAppleVoiceCandidate(
            identifier: identifier,
            name: name,
            language: language,
            displayName: displayName,
            order: nil
        )
    }

    private static func isPreferredNaturalVoice(_ voice: OrbitAppleVoiceCandidate) -> Bool {
        let identifier = voice.identifier.lowercased()
        let name = voice.name.lowercased()

        if identifier.contains("eloquence") {
            return false
        }

        if noveltyVoiceNames.contains(name) {
            return false
        }

        return true
    }

    private static func voiceScore(_ voice: OrbitAppleVoiceCandidate) -> Int {
        var score = 100
        let identifier = voice.identifier.lowercased()
        let name = voice.name.lowercased()

        if identifier.contains("custom.siri") && identifier.contains("premium") {
            score += 300
        } else if identifier.contains("custom.siri") {
            score += 220
        } else if identifier.contains("alex") {
            score += 180
        } else if identifier.contains("enhanced") {
            score += 120
        } else if identifier.contains("super-compact") {
            score -= 30
        } else if identifier.contains("compact") {
            score -= 15
        }

        if name == "samantha" {
            score += 5
        }

        return score
    }

    private static func compactName(for identifier: String, reportedName: String?) -> String {
        if identifier.contains("custom.siri") {
            let parsedName = parsedCustomSiriName(from: identifier) ?? (reportedName ?? "Siri")
            let name = formattedVoiceName(parsedName)
            return premiumAwareDisplayName(name, identifier: identifier)
        }

        if identifier.localizedCaseInsensitiveContains("Alex") {
            return "Alex"
        }

        return reportedName ?? identifier
    }

    private static func displayName(for identifier: String, reportedName: String?) -> String {
        if identifier.contains("custom.siri") {
            let parsedName = parsedCustomSiriName(from: identifier) ?? "Siri"
            let name = formattedVoiceName(parsedName)
            return premiumAwareDisplayName(name, identifier: identifier)
        }

        if identifier.localizedCaseInsensitiveContains("Alex") {
            return "Alex"
        }

        return reportedName ?? identifier
    }

    private static func parsedCustomSiriName(from identifier: String) -> String? {
        let components = identifier.split(separator: ".")
        guard let siriIndex = components.firstIndex(of: "siri"),
              components.count > siriIndex + 1 else {
            return nil
        }

        let rawName = String(components[siriIndex + 1])
        guard !rawName.isEmpty else {
            return nil
        }

        return rawName.prefix(1).uppercased() + rawName.dropFirst()
    }

    private static func formattedVoiceName(_ rawName: String) -> String {
        rawName
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { part in
                let value = String(part)
                return value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: "-")
    }

    private static func premiumAwareDisplayName(_ name: String, identifier: String) -> String {
        let lowered = identifier.lowercased()
        if lowered.contains(".premiumhigh") {
            return "\(name) Premium+"
        }
        if lowered.contains(".premium") {
            return "\(name) Premium"
        }
        return name
    }
}

private struct OrbitAppleVoiceCandidate: Hashable {
    let identifier: String
    let name: String
    let language: String
    let displayName: String
    let order: Int?
}

enum OrbitTTSProviderFactory {
    static func makePrimaryProvider(for voicePreset: OrbitVoicePreset) -> any TextToSpeechProvider {
        switch voicePreset {
        case .localVoice:
            return AppleSystemTTSProvider()
        case .cloudVoice:
            return OpenAITTSProvider(voicePreset: voicePreset)
        }
    }

    static func makeFallbackProvider() -> any TextToSpeechProvider {
        AppleSystemTTSProvider()
    }
}

@MainActor
final class AppleSystemTTSProvider: NSObject, TextToSpeechProvider, NSSpeechSynthesizerDelegate {
    let displayName = "Apple Speech"
    let isConfigured = true
    let unavailableExplanation: String? = nil

    private var synthesizer: NSSpeechSynthesizer?
    private var currentSpeakContinuation: CheckedContinuation<Void, Error>?
    private var lastLoggedVoiceIdentifier: String?

    override init() {
        super.init()
    }

    var isPlaying: Bool {
        synthesizer?.isSpeaking ?? false
    }

    func speakText(_ text: String) async throws {
        stopPlayback()

        try await withCheckedThrowingContinuation { continuation in
            currentSpeakContinuation = continuation
            let synthesizer = NSSpeechSynthesizer()

            self.synthesizer = synthesizer
            synthesizer.delegate = self
            synthesizer.usesFeedbackWindow = false
            logVoiceSelectionIfNeeded(synthesizer)

            if !synthesizer.startSpeaking(text) {
                currentSpeakContinuation = nil
                self.synthesizer = nil
                continuation.resume(
                    throwing: NSError(
                        domain: "AppleSystemTTSProvider",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Apple system speech could not start."]
                    )
                )
            }
        }
    }

    func stopPlayback() {
        if synthesizer?.isSpeaking == true {
            synthesizer?.stopSpeaking()
        }
        synthesizer = nil

        if let continuation = currentSpeakContinuation {
            currentSpeakContinuation = nil
            continuation.resume()
        }
    }

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor [weak self] in
            if finishedSpeaking {
                self?.finishCurrentSpeech()
            } else {
                self?.failCurrentSpeech()
            }
        }
    }

    private func finishCurrentSpeech() {
        guard let continuation = currentSpeakContinuation else { return }
        synthesizer = nil
        currentSpeakContinuation = nil
        continuation.resume()
    }

    private func failCurrentSpeech() {
        guard let continuation = currentSpeakContinuation else { return }
        synthesizer = nil
        currentSpeakContinuation = nil
        continuation.resume(
            throwing: NSError(
                domain: "AppleSystemTTSProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Apple system speech was interrupted."]
            )
        )
    }

    private func logVoiceSelectionIfNeeded(_ synthesizer: NSSpeechSynthesizer) {
        let voiceIdentifier = synthesizer.voice()?.rawValue ?? "system-default"
        guard lastLoggedVoiceIdentifier != voiceIdentifier else { return }
        lastLoggedVoiceIdentifier = voiceIdentifier

        var label = "System Default"
        if let voiceName = synthesizer.voice() {
            let attributes = NSSpeechSynthesizer.attributes(forVoice: voiceName)
            let nameKey = NSSpeechSynthesizer.VoiceAttributeKey(rawValue: "VoiceName")
            if let systemName = attributes[nameKey] as? String, !systemName.isEmpty {
                label = systemName
            }
        }

        print("🗣️ Apple Speech voice: \(label) [\(voiceIdentifier)]")
    }
}
