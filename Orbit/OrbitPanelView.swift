//
//  OrbitPanelView.swift
//  Orbit
//
//  Compact menu bar panel for Orbit. Orbit is a Codex-native macOS voice
//  shell, so the panel focuses on permissions, voice mode, Codex state,
//  and lightweight controls.
//

import AVFoundation
import AppKit
import SwiftUI

struct OrbitPanelView: View {
    @ObservedObject var orbitManager: OrbitManager
    @ObservedObject private var orbitSettings = OrbitSettings.shared
    @State private var openAIAPIKeyDraft = ""
    @State private var showAPIKeyDialog = false
    @State private var showAboutPopover = false

    private let panelShape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    private let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if orbitManager.setupStage == .permissions {
                permissionsCard
            } else if orbitManager.setupStage == .auth {
                authCard
            } else if orbitManager.setupStage == .voiceChoice {
                voiceChoiceCard
            } else if orbitManager.setupStage == .cloudKey {
                cloudVoiceCard
            } else if orbitManager.setupStage == .setupComplete {
                setupCompleteCard
            } else {
                controlsCard
            }

            footer
        }
        .padding(13)
        .frame(width: 312)
        .background(panelBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            OrbitMarkView(size: 17)
                .shadow(color: Color.white.opacity(0.14), radius: 7, x: 0, y: 0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Orbit")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("|")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary.opacity(0.55))

                    Text("@4xiom_")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(DS.Colors.textTertiary.opacity(0.72))
                }

                Text(headerSubtitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            DSQuietStatusChip(title: statusText, tint: statusDotColor)

            Button {
                NotificationCenter.default.post(name: .orbitDismissPanel, object: nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(width: 28, height: 28)
                    .orbitGlassCard(
                        shape: Circle(),
                        fillOpacity: 0.26,
                        borderOpacity: 0.14,
                        highlightOpacity: 0.18,
                        shadowOpacity: 0.14,
                        glowOpacity: 0.02
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 2)
        .padding(.top, 1)
    }

    private var permissionsCard: some View {
        sectionCard {
            sectionHeader(title: "Permissions", subtitle: "Grant desktop access once, then Orbit is ready to talk, point, and act.")

            VStack(spacing: 0) {
                microphonePermissionRow
                    .padding(.vertical, 4)
                rowDivider
                accessibilityPermissionRow
                    .padding(.vertical, 4)
                rowDivider
                screenAccessPermissionRow
                    .padding(.vertical, 4)
            }

            if shouldShowPermissionRecoveryHint {
                Text("If you installed a fresh Orbit build, macOS may treat it as a new app. Re-enable Orbit in Privacy & Security, then relaunch Orbit.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            if let diagnostic = orbitManager.screenAccessDiagnosticSummary,
               !orbitManager.hasUsableScreenAccessPermission {
                Text(diagnostic)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

        }
    }

    private var controlsCard: some View {
        sectionCard {
            sectionHeader(title: "Controls", subtitle: "One Codex session for voice and actions.")

            authStatusRow
            rowDivider

            if orbitManager.setupStage == .onboarding {
                compactSetupRow
                rowDivider
            }

            voicePresetRow
            rowDivider
            codexCard
            rowDivider
            codexModelRow
            rowDivider
            codexServiceTierRow
            rowDivider
            codexReasoningEffortRow
            rowDivider
            providerRow(icon: "waveform.badge.mic", title: "Speech to Text", value: panelSpeechToTextLabel)
            rowDivider
            speechOutputRow
            if orbitSettings.voicePreset == .cloudVoice {
                rowDivider
                openAIKeyRow
            }
            rowDivider
            showOrbitToggleRow
        }
    }

    private var authCard: some View {
        sectionCard {
            sectionHeader(title: "Connect", subtitle: "Sign in with ChatGPT so Orbit can start its live Codex session.")

            VStack(alignment: .leading, spacing: 10) {
                Text(authCardMessage)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if orbitManager.codexAuthState == .loginInProgress {
                    HStack(spacing: 8) {
                        primaryButton("Open ChatGPT Login") {
                            orbitManager.reopenCodexLogin()
                        }

                        secondaryCapsuleButton("Reconnect") {
                            orbitManager.reconnectCodexSession()
                        }
                    }
                } else {
                    primaryButton(primaryAuthButtonTitle) {
                        orbitManager.connectCodexAccount()
                    }
                }

                if shouldShowAuthRetry {
                    secondaryCapsuleButton("Retry Codex") {
                        orbitManager.reconnectCodexSession()
                    }
                }
            }
        }
    }

    private var voiceChoiceCard: some View {
        sectionCard {
            sectionHeader(title: "Voice", subtitle: "Choose whether Orbit should use your Mac or OpenAI voice for speech.")

            VStack(spacing: 10) {
                voiceChoiceOption(
                    title: "Use Local Voice",
                    subtitle: "Apple speech on this Mac. No API key needed.",
                    isSelected: orbitSettings.voicePreset == .localVoice
                ) {
                    orbitManager.selectVoicePreset(.localVoice)
                }

                voiceChoiceOption(
                    title: "Use Cloud Voice",
                    subtitle: "OpenAI speech with your own API key.",
                    isSelected: orbitSettings.voicePreset == .cloudVoice
                ) {
                    orbitManager.selectVoicePreset(.cloudVoice)
                }
            }
        }
    }

    private var cloudVoiceCard: some View {
        sectionCard {
            sectionHeader(title: "Cloud Voice", subtitle: "Add an OpenAI API key to enable cloud speech.")

            VStack(alignment: .leading, spacing: 10) {
                SecureField("OpenAI API Key", text: $openAIAPIKeyDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .orbitGlassCard(
                        shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                        fillOpacity: 0.20,
                        borderOpacity: 0.12,
                        highlightOpacity: 0.16,
                        shadowOpacity: 0.08,
                        glowOpacity: 0.01
                    )

                HStack(spacing: 8) {
                    DSQuietStatusChip(
                        title: orbitManager.openAICloudCredentialState.summaryText,
                        tint: cloudVoiceStatusTint
                    )

                    Text(orbitManager.openAICloudCredentialState.detailText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    primaryButton("Save OpenAI Key") {
                        let draft = openAIAPIKeyDraft
                        Task {
                            let didConnect = await orbitManager.saveOpenAIAPIKey(draft)
                            if didConnect {
                                openAIAPIKeyDraft = ""
                            }
                        }
                    }
                    .opacity(canSubmitOpenAIKey ? 1.0 : 0.55)
                    .disabled(!canSubmitOpenAIKey)

                    secondaryCapsuleButton("Use Local") {
                        orbitManager.selectVoicePreset(.localVoice)
                    }
                }
            }
        }
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitGlassCard(
            shape: cardShape,
            fillOpacity: 0.34,
            borderOpacity: 0.15,
            highlightOpacity: 0.24,
            shadowOpacity: 0.18,
            glowOpacity: 0.03
        )
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func voiceChoiceOption(
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? Color.white.opacity(0.90) : DS.Colors.textTertiary.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .orbitGlassCard(
                shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                fillOpacity: isSelected ? 0.24 : 0.16,
                borderOpacity: isSelected ? 0.18 : 0.10,
                highlightOpacity: 0.18,
                shadowOpacity: 0.08,
                glowOpacity: 0.01
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var compactSetupRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Hold Control+Option to talk")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Run the intro once to see Orbit speak and point.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Start Tour") {
                orbitManager.triggerOnboarding()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.Colors.accent)
            )
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var setupCompleteCard: some View {
        sectionCard {
            VStack(alignment: .center, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(DS.Colors.success)

                Text("You're all set")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT ORBIT CAN DO")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)

                bulletItem("Learn any software on your screen")
                bulletItem("Control your browser hands-free")
                bulletItem("Create documents and presentations")
                bulletItem("Get pointed to the right button")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("TRY THIS FIRST")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)

                Text("Hold Control+Option and ask\n\"what's on my screen?\"")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryButton("Get Started") {
                orbitManager.dismissSetupComplete()
            }
        }
    }

    private func bulletItem(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(DS.Colors.textTertiary)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    private var voicePresetRow: some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(
                icon: "waveform",
                title: "Voice Mode",
                subtitle: orbitSettings.voicePreset == .cloudVoice
                    ? "OpenAI cloud voice"
                    : "Apple local voice"
            )

            Spacer(minLength: 12)

            segmentedControl {
                ForEach(OrbitVoicePreset.allCases) { preset in
                    settingOptionButton(
                        label: preset.displayName,
                        isSelected: orbitSettings.voicePreset == preset
                    ) {
                        orbitManager.selectVoicePreset(preset)
                    }
                }
            }
        }
    }

    private var codexCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                OrbitMarkView(size: 14)
                    .shadow(color: Color.white.opacity(0.10), radius: 4, x: 0, y: 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Session")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("Live local session")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    orbitManager.reconnectCodexSession()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 28, height: 28)
                        .orbitGlassCard(
                            shape: Circle(),
                            fillOpacity: 0.24,
                            borderOpacity: 0.12,
                            highlightOpacity: 0.16,
                            shadowOpacity: 0.08,
                            glowOpacity: 0.01
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Reconnect Codex")

                DSQuietStatusChip(title: actionStatusLabel, tint: codexStatusColor)
            }

            Text(codexSummaryLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)

            if let detailLine = codexDetailLine {
                Text(detailLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var codexModelRow: some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(
                icon: "cpu",
                title: "Model",
                subtitle: nil
            )

            Spacer(minLength: 12)

            modelSelectorMenu
        }
    }

    private var codexReasoningEffortRow: some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(icon: "dial.medium", title: "Codex Effort", subtitle: nil)

            Spacer(minLength: 8)

            segmentedControl(spacing: 2) {
                ForEach(orbitManager.availableCodexEfforts) { effort in
                    effortOptionButton(
                        effort: effort,
                        isSelected: orbitSettings.codexReasoningEffort == effort
                    ) {
                        orbitSettings.codexReasoningEffort = effort
                    }
                }
            }
        }
    }

    private var codexServiceTierRow: some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(icon: "bolt", title: "Fast Mode", subtitle: nil)

            Spacer(minLength: 8)

            segmentedControl(spacing: 2) {
                settingOptionButton(
                    label: "Off",
                    isSelected: orbitSettings.codexServiceTier == .standard
                ) {
                    orbitSettings.codexServiceTier = .standard
                }

                settingOptionButton(
                    label: "Fast",
                    isSelected: orbitSettings.codexServiceTier == .fast
                ) {
                    orbitSettings.codexServiceTier = .fast
                }
            }
        }
    }

    private func providerRow(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(icon: icon, title: title, subtitle: nil)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .orbitGlassCard(
                    shape: Capsule(style: .continuous),
                    fillOpacity: 0.22,
                    borderOpacity: 0.12,
                    highlightOpacity: 0.16,
                    shadowOpacity: 0.08,
                    glowOpacity: 0.01
                )
        }
    }

    private var authStatusRow: some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(
                icon: "person.crop.circle",
                title: "ChatGPT",
                subtitle: orbitManager.codexAccountSummary ?? "Connected"
            )

            Spacer(minLength: 8)

            Button("Sign Out") {
                orbitManager.signOutCodexAccount()
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(DS.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .orbitGlassCard(
                shape: Capsule(style: .continuous),
                fillOpacity: 0.18,
                borderOpacity: 0.12,
                highlightOpacity: 0.16,
                shadowOpacity: 0.08,
                glowOpacity: 0.01
            )
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var modelSelectorMenu: some View {
        Menu {
            ForEach(orbitManager.availableCodexModels) { model in
                Button {
                    orbitSettings.codexActionModel = model.model
                } label: {
                    if orbitSettings.codexActionModel == model.model {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedModelShortLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .orbitGlassCard(
                shape: Capsule(style: .continuous),
                fillOpacity: 0.22,
                borderOpacity: 0.12,
                highlightOpacity: 0.16,
                shadowOpacity: 0.08,
                glowOpacity: 0.01
            )
        }
        .menuStyle(.borderlessButton)
        .pointerCursor()
    }

    private var speechOutputRow: some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(
                icon: "speaker.wave.2.fill",
                title: "Voice",
                subtitle: orbitSettings.voicePreset == .localVoice ? "System speech" : "OpenAI speech"
            )

            Spacer(minLength: 8)

            if orbitSettings.voicePreset == .localVoice {
                Text(orbitManager.selectedAppleVoiceSummary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .orbitGlassCard(
                        shape: Capsule(style: .continuous),
                        fillOpacity: 0.22,
                        borderOpacity: 0.12,
                        highlightOpacity: 0.16,
                        shadowOpacity: 0.08,
                        glowOpacity: 0.01
                    )
            } else {
                Text(panelTextToSpeechLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .orbitGlassCard(
                        shape: Capsule(style: .continuous),
                        fillOpacity: 0.22,
                        borderOpacity: 0.12,
                        highlightOpacity: 0.16,
                        shadowOpacity: 0.08,
                        glowOpacity: 0.01
                    )
            }
        }
    }

    private var openAIKeyRow: some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(
                icon: "key",
                title: "OpenAI Key",
                subtitle: orbitManager.openAICloudCredentialState.detailText
            )

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                DSQuietStatusChip(
                    title: orbitManager.openAICloudCredentialState.summaryText,
                    tint: cloudVoiceStatusTint
                )

                Button("Replace") {
                    openAIAPIKeyDraft = ""
                    showAPIKeyDialog = true
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .orbitGlassCard(
                    shape: Capsule(style: .continuous),
                    fillOpacity: 0.18,
                    borderOpacity: 0.12,
                    highlightOpacity: 0.16,
                    shadowOpacity: 0.08,
                    glowOpacity: 0.01
                )
                .buttonStyle(.plain)
                .pointerCursor()
                .popover(isPresented: $showAPIKeyDialog, arrowEdge: .bottom) {
                    apiKeyDialogContent
                }
            }
        }
    }

    private var apiKeyDialogContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace OpenAI Key")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)

            SecureField("sk-...", text: $openAIAPIKeyDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 240)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    showAPIKeyDialog = false
                    openAIAPIKeyDraft = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

                Button("Save") {
                    let draft = openAIAPIKeyDraft
                    Task {
                        let didConnect = await orbitManager.saveOpenAIAPIKey(draft)
                        if didConnect {
                            openAIAPIKeyDraft = ""
                            showAPIKeyDialog = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 12, weight: .semibold))
                .disabled(openAIAPIKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private var showOrbitToggleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(icon: "cursorarrow.motionlines", title: "Show Orbit", subtitle: "Keep the cursor visible")

            Spacer(minLength: 8)

            Toggle(
                "",
                isOn: Binding(
                    get: { orbitManager.isOrbitCursorEnabled },
                    set: { orbitManager.setOrbitCursorEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(Color.white.opacity(0.8))
            .scaleEffect(0.8)
        }
    }

    private func rowLabel(icon: String, title: String, subtitle: String?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
        }
    }

    private func segmentedControl<Content: View>(
        spacing: CGFloat = 4,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: spacing) {
            content()
        }
        .padding(2)
        .orbitGlassCard(
            shape: Capsule(style: .continuous),
            fillOpacity: 0.18,
            borderOpacity: 0.12,
            highlightOpacity: 0.16,
            shadowOpacity: 0.10,
            glowOpacity: 0.01
        )
    }

    private var footer: some View {
        HStack(alignment: .center) {
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Orbit", systemImage: "power")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer()

            if orbitManager.hasCompletedOnboarding {
                Button {
                    orbitManager.replayOnboarding()
                } label: {
                    Label("Replay Tour", systemImage: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Spacer()

            Button {
                showAboutPopover.toggle()
            } label: {
                Label("About", systemImage: "info.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .popover(isPresented: $showAboutPopover, arrowEdge: .bottom) {
                aboutPopoverContent
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var aboutPopoverContent: some View {
        VStack(alignment: .center, spacing: 12) {
            OrbitMarkView()
                .frame(width: 32, height: 32)
                .foregroundColor(.primary)

            VStack(spacing: 2) {
                Text("Orbit")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("by @4xiom_")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                aboutLink(icon: "globe", title: "Website", url: "https://www.orbitcodex.com")
                aboutLink(icon: "chevron.left.forwardslash.chevron.right", title: "GitHub", url: "https://github.com/4xiomdev")
                aboutLink(icon: "at", title: "X / Twitter", url: "https://x.com/4xiom_")
                aboutLink(icon: "envelope", title: "Email", url: "mailto:4xiomdev@gmail.com")
                aboutLink(icon: "heart", title: "Sponsor", url: "https://github.com/sponsors/4xiomdev")
                aboutLink(icon: "cup.and.saucer", title: "Buy Me a Coffee", url: "https://buymeacoffee.com/4xiom")
            }

            Divider()

            Text("Open source under MIT license")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(width: 200)
    }

    private func aboutLink(icon: String, title: String, url: String) -> some View {
        Button {
            if let linkURL = URL(string: url) {
                NSWorkspace.shared.open(linkURL)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.secondary.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var selectedModelShortLabel: String {
        orbitManager.availableCodexModels.first(where: { $0.model == orbitSettings.codexActionModel })?.shortDisplayName
            ?? OrbitCodexModelOption.fallbackOption(for: orbitSettings.codexActionModel)?.shortDisplayName
            ?? orbitSettings.codexActionModel
    }

    private func effortOptionButton(
        effort: OrbitCodexReasoningEffort,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            EffortGlyph(level: effort.level, isSelected: isSelected)
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(Text(effort.displayName))
    }

    private func settingOptionButton(
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule(style: .continuous)
                        .fill(DS.Colors.accent)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func secondaryCapsuleButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .orbitGlassCard(
                    shape: Capsule(style: .continuous),
                    fillOpacity: 0.18,
                    borderOpacity: 0.12,
                    highlightOpacity: 0.16,
                    shadowOpacity: 0.08,
                    glowOpacity: 0.01
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 26)
    }

    private var panelBackground: some View {
        panelShape
            .fill(Color.clear)
            .orbitGlassCard(
                shape: panelShape,
                fillOpacity: 0.55,
                borderOpacity: 0.18,
                highlightOpacity: 0.27,
                shadowOpacity: 0.24,
                glowOpacity: 0.03
            )
    }

    private var headerSubtitle: String {
        if orbitManager.isRunningOnboardingTour {
            return "Orbit intro in progress"
        }
        switch orbitManager.setupStage {
        case .permissions:
            return "Codex voice shell"
        case .auth:
            return "Connect ChatGPT"
        case .voiceChoice:
            return "Choose your voice mode"
        case .cloudKey:
            return "Connect OpenAI voice"
        case .onboarding:
            return "Orbit setup"
        case .setupComplete:
            return "Setup complete"
        case .ready:
            break
        }
        switch orbitManager.activeActionStatus {
        case .idle:
            return "Codex voice shell"
        case .failed:
            return "Codex needs attention"
        case .running, .waitingForApproval, .completed:
            return "Live Codex session"
        }
    }

    private var statusDotColor: Color {
        if orbitManager.isRunningOnboardingTour {
            return Color.white.opacity(0.88)
        }

        switch orbitManager.activeActionStatus {
        case .running:
            return Color.white.opacity(0.88)
        case .waitingForApproval:
            return DS.Colors.warning
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructive
        case .idle:
            break
        }

        if !orbitManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }

        switch orbitManager.voiceState {
        case .idle:
            return Color.white.opacity(0.82)
        case .listening, .processing, .responding:
            return Color.white.opacity(0.96)
        }
    }

    private var statusText: String {
        if orbitManager.isRunningOnboardingTour {
            return "Tour"
        }

        switch orbitManager.setupStage {
        case .permissions, .auth, .voiceChoice, .cloudKey, .onboarding, .setupComplete:
            return "Setup"
        case .ready:
            break
        }

        switch orbitManager.activeActionStatus {
        case .running:
            return "Working"
        case .waitingForApproval:
            return "Waiting"
        case .completed:
            return "Done"
        case .failed:
            return "Issue"
        case .idle:
            break
        }

        if !orbitManager.isOverlayVisible {
            return "Ready"
        }

        switch orbitManager.voiceState {
        case .idle:
            return "Ready"
        case .listening:
            return "Listening"
        case .processing:
            return "Thinking"
        case .responding:
            return "Speaking"
        }
    }

    private var actionStatusLabel: String {
        switch orbitManager.activeActionStatus {
        case .idle:
            return "Live"
        case .running:
            return "Working"
        case .waitingForApproval:
            return "Waiting"
        case .completed:
            return "Done"
        case .failed:
            return "Issue"
        }
    }

    private var codexStatusColor: Color {
        switch orbitManager.activeActionStatus {
        case .idle:
            return Color.white.opacity(0.70)
        case .running:
            return Color.white.opacity(0.92)
        case .waitingForApproval:
            return DS.Colors.warning
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructive
        }
    }

    private var codexDetailLine: String? {
        if let detail = orbitManager.activeActionDetailLine {
            return detail
        }

        if orbitManager.isRunningOnboardingTour {
            return "showing how Orbit points and speaks."
        }

        switch orbitManager.activeActionStatus {
        case .idle:
            if let accountSummary = orbitManager.codexAccountSummary,
               !accountSummary.isEmpty {
                return accountSummary.lowercased()
            }
            if orbitManager.codexSessionSummary.localizedCaseInsensitiveContains("ready in session")
                || orbitManager.codexSessionSummary.localizedCaseInsensitiveContains("connected to codex") {
                return "live codex session connected."
            }
            if orbitManager.codexSessionSummary.localizedCaseInsensitiveContains("starting codex") {
                return "starting the live codex session."
            }
            return nil
        case .running, .waitingForApproval, .completed, .failed:
            return nil
        }
    }

    private var codexSummaryLine: String {
        if orbitManager.isRunningOnboardingTour {
            return "orbit intro in progress"
        }

        if let summary = orbitManager.activeActionStatusSummary, !summary.isEmpty {
            return summary
        }

        switch orbitManager.activeActionStatus {
        case .idle:
            return "ready"
        case .running:
            return "thinking"
        case .waitingForApproval:
            return "waiting for approval"
        case .completed:
            return "done"
        case .failed:
            return "failed"
        }
    }

    private var authCardMessage: String {
        switch orbitManager.codexAuthState {
        case .unknown, .checking:
            return "Orbit is checking whether your shared Codex setup is already signed in."
        case .authRequired:
            return "Orbit uses Codex app-server with your ChatGPT account. Connect once and future launches can reuse that shared auth state."
        case .loginInProgress:
            return "Finish the ChatGPT browser sign-in, then come back to Orbit."
        case .authFailed(let message):
            return message
        case .runtimeUnavailable(let message):
            return message
        case .authenticated(let email, let plan):
            let emailPart = email ?? "Connected"
            if let plan, !plan.isEmpty {
                return "\(emailPart) · ChatGPT \(plan.capitalized)"
            }
            return emailPart
        }
    }

    private var primaryAuthButtonTitle: String {
        switch orbitManager.codexAuthState {
        case .authFailed, .runtimeUnavailable:
            return "Connect ChatGPT"
        case .loginInProgress:
            return "Open ChatGPT Login"
        default:
            return "Connect ChatGPT"
        }
    }

    private var shouldShowAuthRetry: Bool {
        switch orbitManager.codexAuthState {
        case .authFailed, .runtimeUnavailable:
            return true
        default:
            return false
        }
    }

    private var panelSpeechToTextLabel: String {
        switch orbitManager.orbitDictationManager.transcriptionProviderDisplayName {
        case "OpenAI Transcribe":
            return "OpenAI"
        default:
            return orbitManager.orbitDictationManager.transcriptionProviderDisplayName
        }
    }

    private var panelTextToSpeechLabel: String {
        switch orbitManager.textToSpeechProviderDisplayName {
        case "OpenAI Voice":
            return "OpenAI"
        case "Apple Speech":
            return "Siri"
        default:
            return orbitManager.textToSpeechProviderDisplayName
        }
    }

    private var cloudVoiceStatusTint: Color {
        switch orbitManager.openAICloudCredentialState {
        case .connected:
            return DS.Colors.success
        case .validating:
            return Color.white.opacity(0.88)
        case .missing:
            return DS.Colors.textTertiary
        case .invalid, .networkError:
            return DS.Colors.warning
        }
    }

    private var canSubmitOpenAIKey: Bool {
        let trimmed = openAIAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if orbitManager.openAICloudCredentialState == .validating {
            return false
        }
        return true
    }

    private var accessibilityPermissionRow: some View {
        permissionRow(
            label: "Accessibility",
            iconName: "hand.raised",
            isGranted: orbitManager.hasAccessibilityPermission,
            subtitle: orbitManager.hasAccessibilityPermission
                ? nil
                : "If Orbit is missing, use Find App.",
            action: {
                WindowPositionManager.requestAccessibilityPermission()
            },
            alternateAction: {
                WindowPositionManager.revealAppInFinder()
                WindowPositionManager.openAccessibilitySettings()
            },
            alternateTitle: "Find App"
        )
    }

    private var screenAccessPermissionRow: some View {
        permissionRow(
            label: "Screen Access",
            iconName: "rectangle.dashed.badge.record",
            isGranted: orbitManager.hasUsableScreenAccessPermission,
            subtitle: orbitManager.hasUsableScreenAccessPermission
                ? "Only captures the active screen when you use the hotkey"
                : "Grant once so Orbit can see your current screen.",
            action: {
                orbitManager.requestScreenContentPermission()
            },
            alternateAction: {
                WindowPositionManager.openScreenRecordingSettings()
            },
            alternateTitle: "Open Settings"
        )
    }

    private var shouldShowPermissionRecoveryHint: Bool {
        orbitManager.hasMicrophonePermission
            && (!orbitManager.hasAccessibilityPermission || !orbitManager.hasUsableScreenAccessPermission)
    }

    private func relaunchOrbit() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
            .deletingLastPathComponent().deletingLastPathComponent()
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private var microphonePermissionRow: some View {
        permissionRow(
            label: "Microphone",
            iconName: "mic",
            isGranted: orbitManager.hasMicrophonePermission,
            subtitle: nil
        ) {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        subtitle: String?,
        action: @escaping () -> Void,
        alternateAction: (() -> Void)? = nil,
        alternateTitle: String? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rowLabel(icon: iconName, title: label, subtitle: subtitle)

            Spacer(minLength: 8)

            if isGranted {
                DSQuietStatusChip(title: "Granted", tint: DS.Colors.success)
            } else {
                VStack(alignment: .trailing, spacing: 8) {
                    Button(action: action) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    if let alternateAction, let alternateTitle {
                        Button(action: alternateAction) {
                            Text(alternateTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundColor(DS.Colors.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .orbitGlassCard(
                                    shape: Capsule(style: .continuous),
                                    fillOpacity: 0.18,
                                    borderOpacity: 0.12,
                                    highlightOpacity: 0.16,
                                    shadowOpacity: 0.08,
                                    glowOpacity: 0.01
                                )
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }
        }
    }
}

private struct EffortGlyph: View {
    let level: Int
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(barColor(for: index))
                    .frame(width: 3, height: CGFloat(5 + (index * 3)))
            }
        }
    }

    private func barColor(for index: Int) -> Color {
        if index < level {
            return isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary
        }
        return Color.white.opacity(isSelected ? 0.18 : 0.10)
    }
}
