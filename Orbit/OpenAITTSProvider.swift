import AVFoundation
import Foundation

@MainActor
final class OpenAITTSProvider: NSObject, TextToSpeechProvider, AVAudioPlayerDelegate {
    private let resolvedAPIKey = OrbitOpenAIKeychainStore.resolvedAPIKey()
    private let modelName = AppBundleConfiguration.stringValue(forKey: "OpenAITTSModel")
        ?? "gpt-4o-mini-tts"
    private let voicePreset: OrbitVoicePreset
    private let session: URLSession
    private let endpointURL = URL(string: "https://api.openai.com/v1/audio/speech")!
    private var audioPlayer: AVAudioPlayer?
    private var currentSpeakContinuation: CheckedContinuation<Void, Error>?

    init(voicePreset: OrbitVoicePreset) {
        self.voicePreset = voicePreset
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: configuration)
        super.init()
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
        stopPlayback()

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

        try await withCheckedThrowingContinuation { continuation in
            do {
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                audioPlayer = player
                currentSpeakContinuation = continuation
                if !player.play() {
                    audioPlayer = nil
                    currentSpeakContinuation = nil
                    continuation.resume(
                        throwing: NSError(
                            domain: "OpenAITTSProvider",
                            code: -3,
                            userInfo: [NSLocalizedDescriptionKey: "OpenAI voice could not start playback."]
                        )
                    )
                }
            } catch {
                audioPlayer = nil
                currentSpeakContinuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func stopPlayback() {
        if audioPlayer?.isPlaying == true {
            audioPlayer?.stop()
        }
        audioPlayer = nil
        if let currentSpeakContinuation {
            self.currentSpeakContinuation = nil
            currentSpeakContinuation.resume()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let continuation = self.currentSpeakContinuation
            self.currentSpeakContinuation = nil
            self.audioPlayer = nil
            if flag {
                continuation?.resume()
            } else {
                continuation?.resume(
                    throwing: NSError(
                        domain: "OpenAITTSProvider",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "OpenAI voice playback was interrupted."]
                    )
                )
            }
        }
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
