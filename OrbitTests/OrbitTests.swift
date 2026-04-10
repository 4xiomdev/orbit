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
            modelInstructionsPath: "/tmp/OrbitModelInstructions.md"
        )

        let instructionsRange = try #require(config.range(of: "model_instructions_file"))
        let featuresRange = try #require(config.range(of: "\n[features]\n"))

        #expect(instructionsRange.lowerBound < featuresRange.lowerBound)
    }
}
