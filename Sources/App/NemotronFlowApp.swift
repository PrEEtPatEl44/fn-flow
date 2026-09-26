import AppKit
import SwiftUI

@main
struct NemotronFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            MenuBarIcon()
        }
    }
}

private struct MenuBarIcon: View {
    @ObservedObject private var flow = FlowController.shared

    var body: some View {
        switch flow.phase {
        case .idle: Image(systemName: "waveform")
        case .listening: Image(systemName: "mic.fill")
        case .processing: Image(systemName: "ellipsis.circle")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject private var flow = FlowController.shared
    @ObservedObject private var runtime = RuntimeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = DictationHistory.shared

    var body: some View {
        Text("Hold \(settings.hotkey.displayName) to dictate")
        Text("Speech-to-text: \(runtime.asrStatus.label)")
        Text("Nemotron cleanup: \(settings.refineWithLLM ? runtime.llmStatus.label : "Off")")
        Divider()
        Button("Copy Last Transcript") { flow.copyLastTranscript() }
            .disabled(history.entries.isEmpty)
        if !history.entries.isEmpty {
            Menu("Recent") {
                ForEach(history.entries.prefix(10)) { item in
                    Button(item.text.count > 60 ? item.text.prefix(60) + "…" : item.text) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                    }
                }
            }
        }
        Button("History…") { SettingsWindowController.shared.show(tab: .history) }
        Divider()
        Button("Settings…") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Button("Quit Nemotron Flow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FlowController.shared.setUp()

        if !HotkeyManager.shared.start() {
            // No Accessibility yet: ask, and start listening as soon as it's granted.
            AccessibilityManager.shared.promptForTrust()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    if AccessibilityManager.shared.isTrusted, HotkeyManager.shared.start() {
                        self?.permissionTimer?.invalidate()
                        self?.permissionTimer = nil
                    }
                }
            }
        }

        // Don't let the mic prompt (which waits on the user) delay starting the models.
        Task { _ = await RecordingManager.requestMicAccess() }
        Task {
            await RuntimeManager.shared.bootstrap()
            // First run: guide the user through whatever is still missing.
            if !RuntimeManager.shared.isInstalled {
                SettingsWindowController.shared.show(tab: .models)
            } else if !AccessibilityManager.shared.isTrusted || !RecordingManager.micAuthorized {
                SettingsWindowController.shared.show(tab: .permissions)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RuntimeManager.shared.stopASR()
    }
}
