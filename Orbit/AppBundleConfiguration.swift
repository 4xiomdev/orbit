//
//  AppBundleConfiguration.swift
//  Orbit
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    static func stringValue(forKey key: String) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment[environmentVariableName(for: key)] {
            let trimmedValue = environmentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        if let localSecretsPath = Bundle.main.path(forResource: "LocalSecrets", ofType: "plist"),
           let localSecrets = NSDictionary(contentsOfFile: localSecretsPath),
           let value = localSecrets[key] as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    static func boolValue(forKey key: String, defaultValue: Bool = false) -> Bool {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? Bool {
            return value
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? Bool else {
            return defaultValue
        }

        return value
    }

    private static func environmentVariableName(for key: String) -> String {
        switch key {
        case "OpenAIAPIKey":
            return "OPENAI_API_KEY"
        case "OpenAITranscriptionModel":
            return "OPENAI_TRANSCRIPTION_MODEL"
        case "OpenAITTSModel":
            return "OPENAI_TTS_MODEL"
        case "CodexActionModel":
            return "CODEX_ACTION_MODEL"
        default:
            return key
                .replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1_$2", options: .regularExpression)
                .uppercased()
        }
    }
}
