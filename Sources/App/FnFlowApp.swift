import AppKit
import SwiftUI

@main
struct FnFlowApp: App {
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
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var history = DictationHistory.shared

    var body: some View {
        Text("Hold \(settings.hotkey.displayName) to dictate")
        Text("Speech: \(models.speechStatus.label) · Cleanup: \(settings.refineWithLLM ? models.cleanupStatus.label : "Rules")")
        Divider()
        Button("Open Fn-flow") { AppWindowController.shared.show(.home) }
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
        Divider()
        Button("Settings…") { AppWindowController.shared.show(.settings) }
            .keyboardShortcut(",")
        Button("Quit Fn-flow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var permissionTimer: Timer?

    /// Opening Fn-flow again (Finder, Spotlight, Launchpad) while it's running shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppWindowController.shared.show()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        FlowController.shared.setUp()
        IdlePillController.shared.start()

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
            await ModelManager.shared.bootstrap()
            // First run: guide the user through whatever is still missing.
            if !ModelManager.shared.isSpeechModelInstalled {
                AppWindowController.shared.show(anchor: .engine)
            } else if !AccessibilityManager.shared.isTrusted || !RecordingManager.micAuthorized {
                AppWindowController.shared.show(anchor: .access)
            }
        }
    }
}
