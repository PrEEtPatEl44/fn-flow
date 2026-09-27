import AppKit
import SwiftUI

/// Accent color, writing, overlay, the local models, and macOS permissions.
struct SettingsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageHeader(title: "Settings") { EmptyView() }
                .padding(.bottom, 14)
            AccentCard()
            WritingCard()
            OverlayCard()
            EngineCard().id(SettingsAnchor.engine)
            AccessCard().id(SettingsAnchor.access)
        }
        .frame(maxWidth: 820, alignment: .leading)
    }
}

// MARK: - Accent

private struct AccentCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accent) private var accent

    var body: some View {
        SettingsCard(title: "Accent color") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Eyebrow(text: "Choose an accent").foregroundStyle(Theme.cardMuted)
                    Spacer()
                    Text(accent.name).font(.system(size: 10)).foregroundStyle(Theme.cardMuted)
                }
                HStack(spacing: 10) {
                    ForEach(Accent.presets, id: \.rgb) { preset in
                        Button { settings.accentRGB = preset.rgb } label: {
                            Circle()
                                .fill(Color(rgb: preset.rgb))
                                .frame(width: 22, height: 22)
                                .padding(2)
                                .overlay(Circle().strokeBorder(
                                    settings.accentRGB == preset.rgb ? accent.onCard : Theme.cardLine,
                                    lineWidth: settings.accentRGB == preset.rgb ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                        .accessibilityLabel("\(preset.name) accent")
                        .accessibilityAddTraits(settings.accentRGB == preset.rgb ? .isSelected : [])
                    }
                    ColorPicker(selection: Binding(
                        get: { Color(rgb: settings.accentRGB) },
                        set: { if let rgb = Accent.rgb(of: $0) { settings.accentRGB = rgb } }
                    ), supportsOpacity: false) {
                        Text("Custom").font(.system(size: 10)).foregroundStyle(Theme.cardMuted)
                    }
                    .fixedSize()
                    .padding(.leading, 4)
                }
            }
            .padding(.vertical, 17)
        }
    }
}

// MARK: - Writing

private struct WritingCard: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsCard(title: "Writing") {
            SettingRow(title: "Push-to-talk shortcut",
                       detail: "Hold to speak, release to finish. Esc cancels.") {
                HotkeyRecorder(hotkey: $settings.hotkey)
            }
            if settings.hotkey.keyCode == 0x3F {
                Text("Tip: set System Settings › Keyboard › “Press 🌐 key to” › Do Nothing, so macOS doesn't also react to Fn.")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.warning)
                    .padding(.vertical, 10)
                Rectangle().fill(Theme.cardLineSoft).frame(height: 1)
            }
            // At least one stays on: the only enabled toggle can't be switched off.
            SettingRow(title: "Paste at the cursor", detail: "Deliver the text to the app you're typing in.") {
                Toggle("Paste at the cursor", isOn: $settings.pasteAtCursor)
                    .toggleStyle(FlowToggleStyle())
                    .labelsHidden()
                    .disabled(settings.pasteAtCursor && !settings.copyToClipboard)
            }
            SettingRow(title: "Copy to clipboard", detail: copyDetail, divider: false) {
                Toggle("Copy to clipboard", isOn: $settings.copyToClipboard)
                    .toggleStyle(FlowToggleStyle())
                    .labelsHidden()
                    .disabled(settings.copyToClipboard && !settings.pasteAtCursor)
            }
        }
    }

    private var copyDetail: String {
        switch (settings.pasteAtCursor, settings.copyToClipboard) {
        case (true, true): "Keep a copy on the clipboard too."
        case (true, false): "Off: your previous clipboard is restored after pasting."
        default: "Text is only copied; paste it yourself with ⌘V."
        }
    }
}

/// Click, then press a shortcut (a lone modifier like Right ⌥, an F-key, or a combo).
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press a shortcut…" : hotkey.displayName)
                    .frame(minWidth: 90)
            }
            .buttonStyle(FlowButtonStyle(kind: isRecording ? .primary : .secondary))
            .disabled(!HotkeyManager.shared.isRunning)
            .help(HotkeyManager.shared.isRunning ? "Click, then press a new shortcut (Esc to cancel)" : "Grant Accessibility permission first")

            Menu {
                ForEach(presets, id: \.1.keyCode) { name, preset in
                    Button(name) { hotkey = preset }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .menuStyle(.button)
            .buttonStyle(FlowButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Presets")
        }
        .onDisappear { if isRecording { stop() } }
    }

    private var presets: [(String, Hotkey)] {
        [
            ("Right ⌥ Option", Hotkey(keyCode: 0x3D, modifiers: 0)),
            ("Right ⌘ Command", Hotkey(keyCode: 0x36, modifiers: 0)),
            ("Fn 🌐", Hotkey(keyCode: 0x3F, modifiers: 0)),
            ("⌃⌥ Space", Hotkey(keyCode: 0x31, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue)),
            ("F5", Hotkey(keyCode: 0x60, modifiers: 0)),
        ]
    }

    private func start() {
        isRecording = true
        HotkeyManager.shared.beginCapture { captured in
            if let captured { hotkey = captured }
            isRecording = false
        }
    }

    private func stop() {
        HotkeyManager.shared.endCapture()
        isRecording = false
    }
}

// MARK: - Overlay

private struct OverlayCard: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        SettingsCard(title: "Overlay") {
            SettingRow(title: "Position",
                       detail: settings.overlayPlacement == .followCursor
                           ? "The overlay appears under your mouse pointer while you dictate."
                           : "You can also drag the resting pill to another edge, or right-click it.") {
                Picker("Position", selection: $settings.overlayPlacement) {
                    ForEach(OverlayPlacement.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingRow(title: "Resting pill", detail: "Keep a small pill on screen between dictations. Click it to dictate.", divider: false) {
                Toggle("Resting pill", isOn: $settings.showIdlePill)
                    .toggleStyle(FlowToggleStyle())
                    .labelsHidden()
                    .disabled(settings.overlayPlacement == .followCursor)
            }
        }
    }
}

// MARK: - Local engine

private struct EngineCard: View {
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var confirmRemoveLegacy = false

    var body: some View {
        SettingsCard(title: "Local engine") {
            Chip(text: "● \(overall)")
        } content: {
            ModelRow(
                title: "Parakeet speech-to-text",
                detail: "NVIDIA Parakeet TDT 0.6B · Core ML on the Neural Engine · \(ModelManager.speechModelSize), downloaded once",
                status: models.speechStatus
            ) {
                switch models.speechStatus {
                case .notInstalled:
                    Button("Download") { models.downloadSpeechModel() }.buttonStyle(FlowButtonStyle(kind: .primary))
                case .failed:
                    Button("Try Again") {
                        if models.isSpeechModelInstalled { Task { await models.loadSpeechModel() } }
                        else { models.downloadSpeechModel() }
                    }
                    .buttonStyle(FlowButtonStyle())
                default:
                    EmptyView()
                }
            }
            SettingRow(title: "Clean up with Nemotron",
                       detail: "Removes fillers and applies self-corrections without changing what you meant. Off: built-in rules only.") {
                Toggle("Clean up with Nemotron", isOn: $settings.refineWithLLM)
                    .toggleStyle(FlowToggleStyle())
                    .labelsHidden()
            }
            if settings.refineWithLLM {
                ModelRow(
                    title: "Nemotron via Ollama",
                    detail: "Optional. Runs in Ollama on this Mac; without it, the built-in rules handle cleanup.",
                    status: models.cleanupStatus
                ) {
                    switch models.cleanupStatus {
                    case .notInstalled:
                        Button("Download") { models.downloadCleanupModel() }.buttonStyle(FlowButtonStyle())
                    case .downloading:
                        Button("Cancel") { models.cancelCleanupDownload() }.buttonStyle(FlowButtonStyle(kind: .quiet))
                    case .unavailable:
                        Link("Get Ollama", destination: ModelManager.ollamaDownloadURL).buttonStyle(FlowButtonStyle())
                        Button("Check Again") { Task { await models.refreshCleanupModel() } }.buttonStyle(FlowButtonStyle(kind: .quiet))
                    case .failed:
                        Button("Try Again") { models.downloadCleanupModel() }.buttonStyle(FlowButtonStyle())
                    default:
                        EmptyView()
                    }
                }
                SettingRow(title: "Ollama model", detail: "Advanced: any chat model you've installed in Ollama.",
                           divider: models.legacyRuntimeSize != nil) {
                    TextField("nemotron-mini", text: $settings.llmModel)
                        .textFieldStyle(FlowFieldStyle())
                        .frame(width: 160)
                        .onSubmit { Task { await models.refreshCleanupModel() } }
                }
            }
            if let size = models.legacyRuntimeSize {
                let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                SettingRow(title: "Old Python runtime", detail: "\(formatted) from earlier versions, no longer used.", divider: false) {
                    Button("Remove…") { confirmRemoveLegacy = true }
                        .buttonStyle(FlowButtonStyle(kind: .danger))
                        .confirmationDialog("Remove the old Python runtime?", isPresented: $confirmRemoveLegacy) {
                            Button("Remove \(formatted)", role: .destructive) { models.removeLegacyRuntime() }
                        } message: {
                            Text("Speech-to-text now runs inside Fn-flow.")
                        }
                }
            }
        }
    }

    private var overall: String {
        switch models.speechStatus {
        case .ready: "Ready"
        case .downloading: "Downloading"
        case .loading, .checking: "Preparing"
        case .notInstalled: "Missing"
        default: "Needs attention"
        }
    }
}

private struct ModelRow<Actions: View>: View {
    let title: String
    let detail: String
    let status: ModelManager.Status
    @ViewBuilder var actions: Actions
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(title: title, detail: detail, divider: false) {
                HStack(spacing: 8) {
                    if !isDownloading {
                        Text(status.label.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(color)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 220, alignment: .trailing)
                    }
                    actions
                }
            }
            if case .downloading(let progress, let detail) = status {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(detail)
                        Spacer()
                        Text("\(Int(progress * 100))%").monospacedDigit()
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.cardMuted)
                    ProgressBar(value: progress)
                }
                .padding(.bottom, 14)
            } else if status == .loading {
                ProgressView().progressViewStyle(.linear).tint(accent.color).padding(.bottom, 14)
            }
            Rectangle().fill(Theme.cardLineSoft).frame(height: 1)
        }
    }

    private var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    private var color: Color {
        switch status {
        case .ready: accent.onCard
        case .checking, .downloading, .loading: Theme.cardMuted
        case .unavailable: Theme.cardDim
        case .notInstalled, .failed: Theme.warning
        }
    }
}

// MARK: - Mac access

private struct AccessCard: View {
    @ObservedObject private var permissions = PermissionsMonitor.shared

    var body: some View {
        SettingsCard(title: "Mac access") {
            SettingRow(title: "Microphone", detail: "To hear you. Audio is processed on this Mac and never leaves it.") {
                PermissionState(granted: permissions.microphone) {
                    Task {
                        if await !RecordingManager.requestMicAccess() {
                            AccessibilityManager.shared.openMicrophoneSettings()
                        }
                    }
                }
            }
            SettingRow(title: "Accessibility", detail: "For the global shortcut and pasting into other apps.") {
                PermissionState(granted: permissions.accessibility) {
                    AccessibilityManager.shared.promptForTrust()
                    AccessibilityManager.shared.openAccessibilitySettings()
                }
            }
            SettingRow(title: "Shortcut listener",
                       detail: "If you rebuilt the app and the shortcut stopped working, remove Fn-flow from Accessibility and add it again: macOS ties the grant to the app's signature.",
                       divider: false) {
                Text(permissions.hotkeyActive ? "ACTIVE" : "WAITING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(permissions.hotkeyActive ? Theme.cardMuted : Theme.warning)
            }
        }
    }
}

private struct PermissionState: View {
    let granted: Bool
    let grant: () -> Void
    @Environment(\.accent) private var accent

    var body: some View {
        if granted {
            Label("Granted", systemImage: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent.onCard)
        } else {
            Button("Grant…", action: grant).buttonStyle(FlowButtonStyle(kind: .primary))
        }
    }
}
