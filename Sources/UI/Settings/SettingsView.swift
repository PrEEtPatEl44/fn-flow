import AppKit
import Combine
import SwiftUI

enum SettingsTab: String, Hashable {
    case general, models, dictionary, permissions
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private let selection = TabSelection()

    final class TabSelection: ObservableObject {
        @Published var tab: SettingsTab = .general
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Nemotron Flow"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(selection: selection))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var selection: SettingsWindowController.TabSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "keyboard") }
                .tag(SettingsTab.general)
            ModelsSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(SettingsTab.models)
            DictionarySettings()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag(SettingsTab.dictionary)
            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
        }
        .padding()
        .frame(width: 620, height: 520)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Push-to-talk hotkey") {
                    HotkeyRecorder(hotkey: $settings.hotkey)
                }
                Text("Hold the hotkey and speak, then release to paste the text wherever your text cursor is. Press Esc while holding to cancel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if settings.hotkey.keyCode == 0x3F {
                    Text("Tip: set System Settings › Keyboard › “Press 🌐 key to” › Do Nothing, so macOS doesn't also react to Fn.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section("Output") {
                Picker("After dictation", selection: $settings.outputMode) {
                    ForEach(OutputMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Restore my previous clipboard after pasting", isOn: $settings.restoreClipboard)
                    .disabled(settings.outputMode == .clipboardOnly)
            }
            Section("Overlay") {
                Picker("Position", selection: $settings.overlayPlacement) {
                    ForEach(OverlayPlacement.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press a shortcut (a lone modifier like Right ⌥, an F-key, or a combo).
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var isRecording = false

    var body: some View {
        HStack {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press a shortcut… (Esc to cancel)" : hotkey.displayName)
                    .frame(minWidth: 170)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            .disabled(!HotkeyManager.shared.isRunning)
            .help(HotkeyManager.shared.isRunning ? "Click to record a new hotkey" : "Grant Accessibility permission first")

            Menu("Presets") {
                ForEach(presets, id: \.1.keyCode) { name, preset in
                    Button(name) { hotkey = preset }
                }
            }
            .fixedSize()
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

// MARK: - Models

private struct ModelsSettings: View {
    @ObservedObject private var runtime = RuntimeManager.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Local AI runtime (runs entirely on this Mac)") {
                    StatusRow(title: "Speech-to-text", detail: "NVIDIA Parakeet TDT 0.6B (MLX)", status: runtime.asrStatus)
                    StatusRow(title: "Text cleanup", detail: "NVIDIA Nemotron via Ollama", status: runtime.llmStatus)
                    Toggle("Clean up with Nemotron (fillers, self-corrections, formatting)", isOn: $settings.refineWithLLM)
                    TextField("Ollama model", text: $settings.llmModel)
                        .onSubmit { Task { await runtime.refreshLLM() } }
                }
            }
            .formStyle(.grouped)
            .frame(height: 240)

            HStack {
                Button(runtime.isInstalled ? "Repair / Update Models" : "Install Models") {
                    runtime.install()
                }
                .disabled(runtime.isInstalling)
                .buttonStyle(.borderedProminent)
                if runtime.isInstalling {
                    Button("Cancel") { runtime.cancelInstall() }
                    ProgressView().controlSize(.small)
                } else {
                    Button("Restart Runtime") {
                        runtime.stopASR()
                        Task { await runtime.bootstrap() }
                    }
                }
                Spacer()
                Text("~5 GB download, one time").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(runtime.installLog.isEmpty ? "Installer output appears here." : runtime.installLog)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(runtime.installLog.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .onChange(of: runtime.installLog) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .padding(.horizontal)
        }
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let status: RuntimeManager.Status

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(status.label).foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private var color: Color {
        switch status {
        case .ready: .green
        case .checking, .starting, .installing: .yellow
        case .notInstalled, .failed: .red
        }
    }
}

// MARK: - Dictionary

private struct DictionarySettings: View {
    @ObservedObject private var dictionary = PersonalDictionary.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var newTerm = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        Form {
            Section {
                Toggle("Learn from my manual corrections", isOn: $settings.learnFromCorrections)
                Text("After pasting, Nemotron Flow watches that text field for a minute. If you fix a misheard word, the fix is saved here and applied to future dictations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Names & terms (spelled exactly as written)") {
                ForEach(dictionary.terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button(role: .destructive) {
                            dictionary.terms.removeAll { $0 == term }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Add a term, e.g. Kubernetes", text: $newTerm)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm).disabled(newTerm.isEmpty)
                }
            }
            Section("Replacements") {
                ForEach(dictionary.replacements) { r in
                    HStack {
                        Text(r.from).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption)
                        Text(r.to)
                        if r.learned {
                            Text("learned").font(.caption2).padding(.horizontal, 5)
                                .background(Capsule().fill(.blue.opacity(0.2)))
                        }
                        Spacer()
                        Button(role: .destructive) {
                            dictionary.replacements.removeAll { $0.id == r.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Heard", text: $newFrom)
                    Image(systemName: "arrow.right").font(.caption)
                    TextField("Should be", text: $newTo)
                        .onSubmit(addReplacement)
                    Button("Add", action: addReplacement).disabled(newFrom.isEmpty || newTo.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addTerm() {
        dictionary.addTerm(newTerm)
        newTerm = ""
    }

    private func addReplacement() {
        dictionary.addReplacement(from: newFrom, to: newTo, learned: false)
        newFrom = ""
        newTo = ""
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @State private var accessibility = AccessibilityManager.shared.isTrusted
    @State private var microphone = RecordingManager.micAuthorized
    @State private var hotkeyActive = HotkeyManager.shared.isRunning
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Accessibility",
                    detail: "Needed for the global hotkey and to paste into other apps.",
                    granted: accessibility
                ) {
                    AccessibilityManager.shared.promptForTrust()
                    AccessibilityManager.shared.openAccessibilitySettings()
                }
                PermissionRow(
                    title: "Microphone",
                    detail: "Needed to hear you. Audio never leaves this Mac.",
                    granted: microphone
                ) {
                    Task {
                        if await !RecordingManager.requestMicAccess() {
                            AccessibilityManager.shared.openMicrophoneSettings()
                        }
                    }
                }
                LabeledContent("Hotkey listener") {
                    Text(hotkeyActive ? "Active" : "Waiting for Accessibility")
                        .foregroundStyle(hotkeyActive ? .green : .orange)
                }
            }
            Section {
                Text("If you rebuilt the app and the hotkey stopped working, remove Nemotron Flow from Accessibility and add it again: macOS ties the grant to the app's code signature.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            accessibility = AccessibilityManager.shared.isTrusted
            microphone = RecordingManager.micAuthorized
            hotkeyActive = HotkeyManager.shared.isRunning
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Grant…", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
