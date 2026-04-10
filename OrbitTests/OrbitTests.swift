import Foundation
import Testing
@testable import Orbit

@MainActor
struct OrbitTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func modelInstructionsStayTopLevelInGeneratedCodexConfig() async throws {
        let config = OrbitCodexEnvironment.makeConfigContents(
            logDirectory: URL(fileURLWithPath: "/tmp/orbit-log"),
            sqliteDirectory: URL(fileURLWithPath: "/tmp/orbit-sqlite"),
            configuredSkillPaths: [:],
            modelInstructionsPath: "/tmp/OrbitModelInstructions.md",
            model: "gpt-5.4",
            reasoningEffort: .medium,
            serviceTier: .fast
        )

        let instructionsRange = try #require(config.range(of: "model_instructions_file"))
        let featuresRange = try #require(config.range(of: "\n[features]\n"))

        #expect(instructionsRange.lowerBound < featuresRange.lowerBound)
    }

    @Test func generatedCodexConfigMatchesRequestedRuntimeDefaults() async throws {
        let config = OrbitCodexEnvironment.makeConfigContents(
            logDirectory: URL(fileURLWithPath: "/tmp/orbit-log"),
            sqliteDirectory: URL(fileURLWithPath: "/tmp/orbit-sqlite"),
            configuredSkillPaths: [:],
            model: "gpt-5.4",
            reasoningEffort: .medium,
            serviceTier: .fast
        )

        #expect(config.contains("model = \"gpt-5.4\""))
        #expect(config.contains("model_reasoning_effort = \"medium\""))
        #expect(config.contains("service_tier = \"fast\""))
    }

    @Test func modelCatalogParsingSupportsSnakeCasePayload() async throws {
        let parsed = CodexAppServerActionProvider.parseModelCatalog(from: [
            "data": [
                [
                    "slug": "gpt-5.4",
                    "display_name": "gpt-5.4",
                    "visibility": "list",
                    "input_modalities": ["text", "image"],
                    "supported_reasoning_levels": [
                        ["effort": "low"],
                        ["effort": "medium"],
                        ["effort": "high"]
                    ],
                    "default_reasoning_level": "medium",
                    "priority": 1
                ],
                [
                    "slug": "gpt-5.4-mini",
                    "display_name": "GPT-5.4-Mini",
                    "visibility": "list",
                    "input_modalities": ["text", "image"],
                    "supported_reasoning_levels": [
                        ["effort": "low"],
                        ["effort": "medium"]
                    ],
                    "default_reasoning_level": "medium",
                    "priority": 2
                ]
            ]
        ])

        #expect(parsed.count == 2)
        #expect(parsed.first?.model == "gpt-5.4")
        #expect(parsed.first?.shortDisplayName == "5.4")
        #expect(parsed.last?.shortDisplayName == "5.4 Mini")
        #expect(parsed.last?.supportedEfforts == [.low, .medium])
    }

    @Test func modelCatalogParsingSupportsLegacyCamelCasePayload() async throws {
        let parsed = CodexAppServerActionProvider.parseModelCatalog(from: [
            "data": [
                [
                    "model": "gpt-5.4",
                    "displayName": "GPT-5.4",
                    "hidden": false,
                    "inputModalities": ["text", "image"],
                    "supportedReasoningEfforts": [
                        ["reasoningEffort": "medium"],
                        ["reasoningEffort": "high"]
                    ],
                    "defaultReasoningEffort": "medium",
                    "isDefault": true
                ]
            ]
        ])

        #expect(parsed.count == 1)
        #expect(parsed.first?.model == "gpt-5.4")
        #expect(parsed.first?.supportedEfforts == [.medium, .high])
        #expect(parsed.first?.defaultEffort == .medium)
    }
}
