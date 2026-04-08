import AVFoundation
import Foundation

@MainActor
final class OpenAITTSProvider: TextToSpeechProvider {
    private let resolvedAPIKey = OrbitOpenAIKeychainStore.resolvedAPIKey()
    private let modelName = AppBundleConfiguration.stringValue(forKey: "OpenAITTSModel")
        ?? "gpt-4o-mini-tts"
    private let voicePreset: OrbitVoicePreset
    private let session: URLSession
    private let endpointURL = URL(string: "https://api.openai.com/v1/audio/speech")!
    private var audioPlayer: AVAudioPlayer?

    init(voicePreset: OrbitVoicePreset) {
        self.voicePreset = voicePreset
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: configuration)
    }

    var displayName: String {
        "OpenAI Voice"
    }

    var isConfigured: Bool {
        resolvedAPIKey != nil
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "OpenAI voice is not configured. Add your OpenAI API key in Orbit."
    }

    var isPlaying: Bool {
        audioPlayer?.isPlaying ?? false
    }

    func speakText(_ text: String) async throws {
        guard let resolvedAPIKey else {
            throw NSError(
                domain: "OpenAITTSProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: unavailableExplanation ?? "OpenAI voice is not configured."]
            )
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(resolvedAPIKey.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": modelName,
            "voice": preferredVoiceName,
            "input": text,
            "instructions": speechInstructions,
            "response_format": "wav"
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenAITTSProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI voice returned an invalid response."]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenAITTSProvider",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "OpenAI voice failed: \(errorText)"]
            )
        }

        let player = try AVAudioPlayer(data: data)
        audioPlayer = player
        player.play()
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    private var preferredVoiceName: String {
        switch voicePreset {
        case .localVoice, .cloudVoice:
            return "marin"
        }
    }

    private var speechInstructions: String {
        switch voicePreset {
        case .localVoice, .cloudVoice:
            return "Speak clearly, naturally, and briefly."
        }
    }
}
