import AVFoundation
import Foundation

struct OpenAITranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

final class OpenAITranscriptionProvider: SpeechToTextProvider {
    private let resolvedAPIKey = OrbitOpenAIKeychainStore.resolvedAPIKey()
    private let modelName = AppBundleConfiguration.stringValue(forKey: "OpenAITranscriptionModel")
        ?? "gpt-4o-mini-transcribe"

    let displayName = "OpenAI Transcribe"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool {
        resolvedAPIKey != nil
    }

    var unavailableExplanation: String? {
        guard !isConfigured else { return nil }
        return "OpenAI transcription is not configured. Add your OpenAI API key in Orbit."
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any SpeechToTextStreamingSession {
        guard let resolvedAPIKey else {
            throw OpenAITranscriptionProviderError(
                message: unavailableExplanation ?? "OpenAI transcription is not configured."
            )
        }

        return OpenAITranscriptionSession(
            apiKey: resolvedAPIKey.value,
            modelName: modelName,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class OpenAITranscriptionSession: SpeechToTextStreamingSession {
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 6.0

    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private static let transcriptionURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let targetSampleRate = 16_000

    private let apiKey: String
    private let modelName: String
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void
    private let stateQueue = DispatchQueue(label: "com.orbit.openai.transcription")
    private let audioPCM16Converter = OrbitPCM16AudioConverter(targetSampleRate: Double(targetSampleRate))
    private let urlSession: URLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        apiKey: String,
        modelName: String,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: configuration)
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let pcmData = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !pcmData.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(pcmData)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionUploadTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        transcriptionUploadTask?.cancel()
        urlSession.invalidateAndCancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let shouldSkip = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if shouldSkip {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = OrbitWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try await requestTranscription(for: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            onError(error)
        }
    }

    private func requestTranscription(for wavAudioData: Data) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Self.transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartRequestBody(boundary: boundary, wavAudioData: wavAudioData)

        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAITranscriptionProviderError(
                message: "OpenAI transcription returned an invalid response."
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw OpenAITranscriptionProviderError(
                message: "OpenAI transcription failed: \(responseText)"
            )
        }

        if let transcriptionResponse = try? JSONDecoder().decode(TranscriptionResponse.self, from: responseData) {
            return transcriptionResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let responseText = String(data: responseData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !responseText.isEmpty {
            return responseText
        }

        throw OpenAITranscriptionProviderError(message: "OpenAI transcription returned an empty transcript.")
    }

    private func makeMultipartRequestBody(boundary: String, wavAudioData: Data) -> Data {
        var data = Data()

        func append(_ string: String) {
            data.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        data.append(wavAudioData)
        append("\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(modelName)\r\n")

        if !keyterms.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
            append(keyterms.joined(separator: ", "))
            append("\r\n")
        }

        append("--\(boundary)--\r\n")
        return data
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }
}
