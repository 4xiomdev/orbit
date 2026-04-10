import Foundation

struct OrbitPreparedCodexHome {
    let homeDirectory: URL
    let configPath: URL
    let logDirectory: URL
    let sqliteDirectory: URL
    let skillsDirectory: URL
}

enum OrbitCodexEnvironment {
    private static let homeDirectoryName = "CodexHome"
    private static let bundledSkillResourceDirectoryName = "OrbitBundledSkills"
    private static let bundledModelInstructionsFileName = "OrbitModelInstructions.md"

    private static let chromeEnabledTools = [
        "click",
        "drag",
        "fill",
        "fill_form",
        "handle_dialog",
        "hover",
        "press_key",
        "type_text",
        "upload_file",
        "close_page",
        "list_pages",
        "navigate_page",
        "new_page",
        "select_page",
        "wait_for",
        "get_network_request",
        "list_network_requests",
        "evaluate_script",
        "get_console_message",
        "list_console_messages",
        "take_screenshot",
        "take_snapshot"
    ]

    private static let playwrightEnabledTools = [
        "browser_tabs",
        "browser_navigate",
        "browser_navigate_back",
        "browser_snapshot",
        "browser_click",
        "browser_hover",
        "browser_drag",
        "browser_type",
        "browser_fill_form",
        "browser_select_option",
        "browser_press_key",
        "browser_wait_for",
        "browser_take_screenshot",
        "browser_console_messages",
        "browser_network_requests",
        "browser_evaluate",
        "browser_close",
        "browser_resize"
    ]

    static func prepareHome(
        model: String = OrbitCodexModelOption.fallbackDefaultModel,
        reasoningEffort: OrbitCodexReasoningEffort = .medium,
        serviceTier: OrbitCodexServiceTier = .fast
    ) throws -> OrbitPreparedCodexHome {
        let fileManager = FileManager.default
        let supportDirectory = try supportRootDirectory()
        let codexHome = supportDirectory.appendingPathComponent(homeDirectoryName, isDirectory: true)
        let logDirectory = codexHome.appendingPathComponent("log", isDirectory: true)
        let sqliteDirectory = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        let skillsDirectory = codexHome.appendingPathComponent("skills", isDirectory: true)
        let configPath = codexHome.appendingPathComponent("config.toml")

        try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sqliteDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)

        let configuredSkillPaths = try syncBundledSkills(into: skillsDirectory)
        let configContents = makeConfigContents(
            logDirectory: logDirectory,
            sqliteDirectory: sqliteDirectory,
            configuredSkillPaths: configuredSkillPaths,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )

        let existingContents = try? String(contentsOf: configPath, encoding: .utf8)
        if existingContents != configContents {
            try configContents.write(to: configPath, atomically: true, encoding: .utf8)
        }

        OrbitSupportLog.append("codex", "prepared isolated codex home at \(codexHome.path)")

        return OrbitPreparedCodexHome(
            homeDirectory: codexHome,
            configPath: configPath,
            logDirectory: logDirectory,
            sqliteDirectory: sqliteDirectory,
            skillsDirectory: skillsDirectory
        )
    }

    private static func supportRootDirectory() throws -> URL {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "OrbitCodexEnvironment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Orbit could not resolve Application Support."]
            )
        }

        return baseURL.appendingPathComponent("Orbit", isDirectory: true)
    }

    static func makeConfigContents(
        logDirectory: URL,
        sqliteDirectory: URL,
        configuredSkillPaths: [String: URL],
        modelInstructionsPath: String? = nil,
        model: String = OrbitCodexModelOption.fallbackDefaultModel,
        reasoningEffort: OrbitCodexReasoningEffort = .medium,
        serviceTier: OrbitCodexServiceTier = .fast
    ) -> String {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = [
            "model = \(tomlString(normalizedModel.isEmpty ? OrbitCodexModelOption.fallbackDefaultModel : normalizedModel))",
            "model_reasoning_effort = \(tomlString(reasoningEffort.rawValue))",
            "service_tier = \(tomlString(serviceTier.rawValue))",
            "approval_policy = \"never\"",
            "sandbox_mode = \"danger-full-access\"",
            "cli_auth_credentials_store = \"file\"",
            "mcp_oauth_credentials_store = \"file\"",
            "log_dir = \(tomlString(logDirectory.path))",
            "sqlite_home = \(tomlString(sqliteDirectory.path))",
            "history.persistence = \"save-all\""
        ]

        // `model_instructions_file` is a top-level key. If it appears after
        // `[features]`, TOML nests it under that table and Codex rejects the
        // config because `features.*` entries must be booleans.
        if let instructionsPath = modelInstructionsPath ?? bundledModelInstructionsPath()?.path {
            lines += [
                "",
                "model_instructions_file = \(tomlString(instructionsPath))",
            ]
        } else {
            OrbitSupportLog.append("codex", "bundled Orbit model instructions were not found in the app bundle.")
        }

        lines += [
            "",
            "[features]",
            "apps = true",
            "fast_mode = true",
            "multi_agent = false",
            ""
        ]

        if let chromeDevToolsCommand = bundledBrowserCommand(named: "chrome-devtools-mcp") {
            lines += [
                "[mcp_servers.chrome-devtools]",
                "command = \(tomlString(chromeDevToolsCommand.path))",
                "args = [\"--autoConnect\", \"--no-usage-statistics\"]",
                "env = { CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS = \"1\" }",
                "enabled_tools = \(tomlArray(chromeEnabledTools))",
                "startup_timeout_sec = 20.0",
                ""
            ]
        } else {
            OrbitSupportLog.append("codex", "bundled chrome-devtools-mcp was not found in the app bundle.")
        }

        if let playwrightCommand = bundledBrowserCommand(named: "playwright-mcp") {
            lines += [
                "[mcp_servers.playwright]",
                "command = \(tomlString(playwrightCommand.path))",
                "args = [\"--browser\", \"chrome\"]",
                "enabled_tools = \(tomlArray(playwrightEnabledTools))",
                "startup_timeout_sec = 20.0",
                ""
            ]
        } else {
            OrbitSupportLog.append("codex", "bundled playwright-mcp was not found in the app bundle.")
        }

        lines += [
            "[mcp_servers.openaiDeveloperDocs]",
            "url = \"https://developers.openai.com/mcp\"",
            ""
        ]

        for skillName in OrbitBundledSkills.bundledSkillNames {
            guard let path = configuredSkillPaths[skillName] else { continue }
            lines += [
                "[[skills.config]]",
                "path = \(tomlString(path.path))",
                "enabled = true",
                ""
            ]
        }

        return lines.joined(separator: "\n")
    }

    private static func syncBundledSkills(into destinationDirectory: URL) throws -> [String: URL] {
        guard let bundledSkillsRoot = bundledSkillsSourceDirectory() else {
            OrbitSupportLog.append("codex", "bundled Orbit skills were not found in the app bundle.")
            return [:]
        }

        let fileManager = FileManager.default
        var configuredPaths: [String: URL] = [:]

        for skillName in OrbitBundledSkills.bundledSkillNames {
            let sourceURL = bundledSkillsRoot.appendingPathComponent(skillName, isDirectory: true)
            let sourceSkillURL = sourceURL.appendingPathComponent("SKILL.md")
            guard fileManager.fileExists(atPath: sourceSkillURL.path) else {
                OrbitSupportLog.append("codex", "skipping bundled skill \(skillName); SKILL.md missing.")
                continue
            }

            let destinationURL = destinationDirectory.appendingPathComponent(skillName, isDirectory: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try copyDirectory(from: sourceURL, to: destinationURL)
            configuredPaths[skillName] = destinationURL
        }

        return configuredPaths
    }

    private static func bundledSkillsSourceDirectory() -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent(bundledSkillResourceDirectoryName, isDirectory: true)
    }

    private static func bundledModelInstructionsPath() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let path = resourceURL.appendingPathComponent(bundledModelInstructionsFileName)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    private static func bundledBrowserCommand(named commandName: String) -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let commandURL = resourceURL
            .appendingPathComponent("CodexRuntime", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(commandName)
        return FileManager.default.isExecutableFile(atPath: commandURL.path) ? commandURL : nil
    }

    private static func copyDirectory(from sourceURL: URL, to destinationURL: URL) throws {
        guard let parentDirectory = destinationURL.deletingLastPathComponent() as URL? else { return }
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    nonisolated private static func tomlArray(_ values: [String]) -> String {
        "[" + values.map(tomlString).joined(separator: ", ") + "]"
    }

    nonisolated private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
