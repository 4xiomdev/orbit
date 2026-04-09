import Foundation
import Security

enum OrbitOpenAIAPIKeySource: Equatable {
    case keychain

    var summaryText: String {
        switch self {
        case .keychain:
            return "Connected"
        }
    }
}

struct OrbitResolvedOpenAIAPIKey: Equatable {
    let value: String
    let source: OrbitOpenAIAPIKeySource
}

enum OrbitOpenAICloudCredentialState: Equatable {
    case missing
    case validating
    case connected(source: OrbitOpenAIAPIKeySource)
    case invalid
    case networkError

    var summaryText: String {
        switch self {
        case .missing:
            return "Missing"
        case .validating:
            return "Validating"
        case .connected(let source):
            return source.summaryText
        case .invalid:
            return "Invalid Key"
        case .networkError:
            return "Network Issue"
        }
    }

    var detailText: String {
        switch self {
        case .missing:
            return "Add an OpenAI API key to use Cloud voice."
        case .validating:
            return "Checking your OpenAI API key."
        case .connected(let source):
            switch source {
            case .keychain:
                return "Stored in your Mac keychain."
            }
        case .invalid:
            return "That OpenAI API key was rejected."
        case .networkError:
            return "Orbit could not validate the key right now."
        }
    }

    var isReadyForCloudVoice: Bool {
        switch self {
        case .connected:
            return true
        case .missing, .validating, .invalid, .networkError:
            return false
        }
    }
}

enum OrbitOpenAIKeychainStore {
    private static let service = "com.orbit.codex.openai.voice"
    private static let account = "default"

    static func resolvedAPIKey() -> OrbitResolvedOpenAIAPIKey? {
        if let keychainKey = keychainAPIKey() {
            return OrbitResolvedOpenAIAPIKey(value: keychainKey, source: .keychain)
        }

        return nil
    }

    static func hasConfiguredAPIKey() -> Bool {
        resolvedAPIKey() != nil
    }

    static func keychainAPIKey() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }

        query.removeAll()
        return string
    }

    static func saveAPIKey(_ value: String) throws {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmedValue.data(using: .utf8), !trimmedValue.isEmpty else {
            throw NSError(
                domain: "OrbitOpenAIKeychainStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI API key cannot be empty."]
            )
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(updateStatus),
                userInfo: [NSLocalizedDescriptionKey: "Orbit could not update the OpenAI API key in Keychain."]
            )
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(addStatus),
                userInfo: [NSLocalizedDescriptionKey: "Orbit could not save the OpenAI API key in Keychain."]
            )
        }
    }

    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum OrbitOpenAIKeyValidator {
    enum Result: Equatable {
        case connected
        case invalid
        case networkError
    }

    static func validate(apiKey: String) async -> Result {
        guard let url = URL(string: "https://api.openai.com/v1/models") else {
            return .networkError
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30

        do {
            let (_, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError
            }

            switch httpResponse.statusCode {
            case 200...299:
                return .connected
            case 401, 403:
                return .invalid
            default:
                return .networkError
            }
        } catch {
            return .networkError
        }
    }
}
