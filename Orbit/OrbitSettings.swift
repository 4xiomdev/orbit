import Combine
import Foundation

enum OrbitVoicePreset: String, CaseIterable, Identifiable {
    case localVoice
    case cloudVoice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .localVoice:
            return "Local"
        case .cloudVoice:
            return "Cloud"
        }
    }
}

enum OrbitCodexReasoningEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "X-High"
        }
    }

    var level: Int {
        switch self {
        case .low:
            return 1
        case .medium:
            return 2
        case .high:
            return 3
        case .xhigh:
            return 4
        }
    }
}

enum OrbitCodexServiceTier: String, CaseIterable, Identifiable {
    case standard
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return "Standard"
        case .fast:
            return "Fast"
        }
    }
}

struct OrbitCodexModelOption: Identifiable, Equatable {
    let model: String
    let displayName: String
    let shortDisplayName: String
    let supportedEfforts: [OrbitCodexReasoningEffort]
    let defaultEffort: OrbitCodexReasoningEffort?
    let inputModalities: [String]
    let isDefault: Bool

    var id: String { model }

    static let fallbackPickerModels: [OrbitCodexModelOption] = [
        OrbitCodexModelOption(
            model: "gpt-5.4",
            displayName: "GPT-5.4",
            shortDisplayName: "5.4",
            supportedEfforts: OrbitCodexReasoningEffort.allCases,
            defaultEffort: .medium,
            inputModalities: ["text", "image"],
            isDefault: true
        ),
        OrbitCodexModelOption(
            model: "gpt-5.4-mini",
            displayName: "GPT-5.4 Mini",
            shortDisplayName: "5.4 Mini",
            supportedEfforts: OrbitCodexReasoningEffort.allCases,
            defaultEffort: .medium,
            inputModalities: ["text", "image"],
            isDefault: false
        )
    ]

    static let fallbackDefaultModel = "gpt-5.4"

    static func fallbackOption(for model: String) -> OrbitCodexModelOption? {
        fallbackPickerModels.first(where: { $0.model == model })
    }
}

@MainActor
final class OrbitSettings: ObservableObject {
    static let shared = OrbitSettings()

    @Published var voicePreset: OrbitVoicePreset {
        didSet { UserDefaults.standard.set(voicePreset.rawValue, forKey: Keys.voicePreset) }
    }

    @Published var showCursor: Bool {
        didSet { UserDefaults.standard.set(showCursor, forKey: Keys.showCursor) }
    }

    @Published var codexReasoningEffort: OrbitCodexReasoningEffort {
        didSet { UserDefaults.standard.set(codexReasoningEffort.rawValue, forKey: Keys.codexReasoningEffort) }
    }

    @Published var codexServiceTier: OrbitCodexServiceTier {
        didSet { UserDefaults.standard.set(codexServiceTier.rawValue, forKey: Keys.codexServiceTier) }
    }

    @Published var codexActionModel: String {
        didSet {
            let normalized = codexActionModel.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(
                normalized.isEmpty ? OrbitCodexModelOption.fallbackDefaultModel : normalized,
                forKey: Keys.codexActionModel
            )
        }
    }

    @Published var appleTTSVoiceIdentifier: String {
        didSet {
            if appleTTSVoiceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                UserDefaults.standard.removeObject(forKey: Keys.appleTTSVoiceIdentifier)
            } else {
                UserDefaults.standard.set(appleTTSVoiceIdentifier, forKey: Keys.appleTTSVoiceIdentifier)
            }
        }
    }

    private enum Keys {
        static let productDefaultsGeneration = "orbit.productDefaultsGeneration"
        static let voicePreset = "orbit.voicePreset"
        static let showCursor = "orbit.showCursor"
        static let codexReasoningEffort = "orbit.codexReasoningEffort"
        static let codexServiceTier = "orbit.codexServiceTier"
        static let codexActionModel = "orbit.codexActionModel"
        static let appleTTSVoiceIdentifier = "orbit.appleTTSVoiceIdentifier"
    }

    private static let currentProductDefaultsGeneration = 2

    private init() {
        Self.applyProductDefaultResetIfNeeded()

        voicePreset = OrbitVoicePreset(
            rawValue: UserDefaults.standard.string(forKey: Keys.voicePreset) ?? ""
        ) ?? .localVoice
        showCursor = UserDefaults.standard.object(forKey: Keys.showCursor) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Keys.showCursor)
        codexReasoningEffort = OrbitCodexReasoningEffort(
            rawValue: UserDefaults.standard.string(forKey: Keys.codexReasoningEffort) ?? ""
        ) ?? .medium
        codexServiceTier = OrbitCodexServiceTier(
            rawValue: UserDefaults.standard.string(forKey: Keys.codexServiceTier) ?? ""
        ) ?? {
            let bundledDefault = AppBundleConfiguration.stringValue(forKey: "CodexActionServiceTier") ?? ""
            return OrbitCodexServiceTier(rawValue: bundledDefault) ?? .fast
        }()
        codexActionModel = {
            let stored = UserDefaults.standard.string(forKey: Keys.codexActionModel)
                ?? AppBundleConfiguration.stringValue(forKey: "CodexActionModel")
                ?? ""
            let normalized = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? OrbitCodexModelOption.fallbackDefaultModel : normalized
        }()
        appleTTSVoiceIdentifier = UserDefaults.standard.string(forKey: Keys.appleTTSVoiceIdentifier)
            ?? AppBundleConfiguration.stringValue(forKey: "AppleTTSVoiceIdentifier")
            ?? ""
    }

    private static func applyProductDefaultResetIfNeeded() {
        let storedGeneration = UserDefaults.standard.integer(forKey: Keys.productDefaultsGeneration)
        guard storedGeneration < Self.currentProductDefaultsGeneration else { return }

        UserDefaults.standard.removeObject(forKey: Keys.voicePreset)
        UserDefaults.standard.removeObject(forKey: Keys.codexReasoningEffort)
        UserDefaults.standard.removeObject(forKey: Keys.codexServiceTier)
        UserDefaults.standard.removeObject(forKey: Keys.codexActionModel)
        UserDefaults.standard.removeObject(forKey: Keys.appleTTSVoiceIdentifier)
        UserDefaults.standard.set(Self.currentProductDefaultsGeneration, forKey: Keys.productDefaultsGeneration)
    }
}
