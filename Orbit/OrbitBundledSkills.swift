import Foundation

struct OrbitBundledSkill: Equatable {
    let name: String
    let path: URL
}

enum OrbitBundledSkills {
    static let orbitAssistantSkillName = "orbit-assistant"

    static let bundledSkillNames: [String] = [
        orbitAssistantSkillName,
        "doc",
        "pdf",
        "slides",
        "spreadsheet",
        "screenshot",
        "transcribe",
        "speech",
        "openai-docs"
    ]

    static func configuredSkillPaths(in skillsDirectory: URL) -> [String: URL] {
        var result: [String: URL] = [:]

        for name in bundledSkillNames {
            let skillURL = skillsDirectory.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: skillURL.appendingPathComponent("SKILL.md").path) {
                result[name] = skillURL
            }
        }

        return result
    }

    static func activeSkills(
        for request: OrbitActionRequest,
        preparedCodexHome: OrbitPreparedCodexHome?
    ) -> [OrbitBundledSkill] {
        guard let preparedCodexHome else { return [] }

        let availableSkillPaths = configuredSkillPaths(in: preparedCodexHome.skillsDirectory)
        let normalizedTranscript = request.transcript.lowercased()
        var requestedNames: [String] = [orbitAssistantSkillName]

        if matchesAnyKeyword(in: normalizedTranscript, keywords: [
            "docx", "document", "google doc", "google docs", "word document", "microsoft word"
        ]) {
            requestedNames.append("doc")
        }

        if matchesAnyKeyword(in: normalizedTranscript, keywords: [
            "pdf", "portable document", "extract from pdf", "read this pdf"
        ]) {
            requestedNames.append("pdf")
        }

        if matchesAnyKeyword(in: normalizedTranscript, keywords: [
            "slides", "slide deck", "deck", "presentation", "powerpoint", "ppt", "keynote"
        ]) {
            requestedNames.append("slides")
        }

        if matchesAnyKeyword(in: normalizedTranscript, keywords: [
            "spreadsheet", "excel", "csv", "sheet", "google sheet", "google sheets"
        ]) {
            requestedNames.append("spreadsheet")
        }

        if matchesAnyKeyword(in: normalizedTranscript, keywords: [
            "screenshot", "screen capture", "screen shot", "capture the screen"
        ]) {
            requestedNames.append("screenshot")
        }

        if matchesAnyKeyword(in: normalizedTranscript, keywords: [
            "transcribe", "transcript", "diarize", "audio file", "video file", "recording"
        ]) {
            requestedNames.append("transcribe")
        }

        if matchesAnyKeyword(in: normalizedTranscript, keywords: [
            "text to speech", "tts", "voiceover", "voice over", "narration", "read aloud", "speak this"
        ]) {
            requestedNames.append("speech")
        }

        if matchesAnyKeyword(in: normalizedTranscript, keywords: [
            "openai", "chatgpt", "codex", "responses api", "openai api", "openai docs", "developer docs", "sdk"
        ]) {
            requestedNames.append("openai-docs")
        }

        let uniqueNames = Array(NSOrderedSet(array: requestedNames)).compactMap { $0 as? String }
        return uniqueNames.compactMap { name in
            guard let path = availableSkillPaths[name] else { return nil }
            return OrbitBundledSkill(name: name, path: path)
        }
    }

    private static func matchesAnyKeyword(in text: String, keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
    }
}
