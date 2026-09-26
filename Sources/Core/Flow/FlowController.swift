import AppKit

/// The dictation loop: hold hotkey -> record (overlay listening) -> release -> Parakeet +
/// Nemotron -> paste at cursor / copy -> watch for manual corrections.
@MainActor
final class FlowController: ObservableObject {
    static let shared = FlowController()

    enum Phase { case idle, listening, processing }

    @Published private(set) var phase: Phase = .idle

    private let overlay = OverlayWindowManager.shared
    private let minimumDuration: TimeInterval = 0.3

    func setUp() {
        let hotkeys = HotkeyManager.shared
        hotkeys.onPress = { [weak self] in self?.begin() }
        hotkeys.onRelease = { [weak self] in self?.finish() }
        hotkeys.onCancel = { [weak self] in self?.cancel() }
        CorrectionTracker.shared.onLearn = { [weak self] from, to in
            guard self?.phase == .idle else { return }
            OverlayWindowManager.shared.toast("Learned “\(from)” → “\(to)”")
        }
    }

    func begin() {
        log.notice("Hotkey pressed (phase: \(String(describing: self.phase), privacy: .public))")
        guard phase == .idle else { return }
        CorrectionTracker.shared.flush()

        guard RuntimeManager.shared.isReady else {
            log.error("Runtime not ready: \(RuntimeManager.shared.asrStatus.label, privacy: .public)")
            flashError(FlowError.runtimeNotReady.localizedDescription)
            if !RuntimeManager.shared.isInstalled { SettingsWindowController.shared.show(tab: .models) }
            return
        }
        guard RecordingManager.micAuthorized else {
            log.error("Microphone not authorized")
            Task {
                if await !RecordingManager.requestMicAccess() {
                    flashError(FlowError.microphonePermissionDenied.localizedDescription)
                    SettingsWindowController.shared.show(tab: .permissions)
                }
            }
            return
        }
        do {
            try RecordingManager.shared.start()
            phase = .listening
            overlay.show(.listening)
            log.notice("Recording started")
        } catch {
            log.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            flashError(FlowError.microphoneUnavailable.localizedDescription)
        }
    }

    func finish() {
        log.notice("Hotkey released (phase: \(String(describing: self.phase), privacy: .public))")
        guard phase == .listening, let recording = RecordingManager.shared.stop() else { return }
        log.notice("Recorded \(recording.duration, format: .fixed(precision: 2))s")
        guard recording.duration >= minimumDuration else {
            phase = .idle
            overlay.hide()
            return
        }
        phase = .processing
        overlay.show(.processing)
        // Remember where the text is going so later edits there can be learned from.
        let target = AccessibilityManager.shared.focusedElement()
        let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName

        Task {
            defer { phase = .idle }
            do {
                let result = try await AIBridge.shared.process(audioURL: recording.url)
                log.notice("Transcribed: \(result.raw, privacy: .private) -> \(result.text, privacy: .private)")
                let settings = AppSettings.shared
                DictationHistory.shared.add(result, app: targetApp, pasted: settings.outputMode == .pasteAtCursor)
                AccessibilityManager.shared.deliver(result.text, mode: settings.outputMode, restoreClipboard: settings.restoreClipboard)
                log.notice("Delivered \(result.text.count) chars via \(settings.outputMode.rawValue, privacy: .public), AX trusted: \(AccessibilityManager.shared.isTrusted)")
                let title = settings.outputMode == .pasteAtCursor ? "Pasted" : "Copied to clipboard"
                overlay.show(.success(title: title, notes: result.notes))
                overlay.hide(after: result.notes.isEmpty ? 0.9 : 2.2)
                if settings.outputMode == .pasteAtCursor {
                    CorrectionTracker.shared.track(pasted: result.text, in: target)
                }
            } catch {
                log.error("Pipeline failed: \(error.localizedDescription, privacy: .public)")
                flashError(error.localizedDescription)
            }
        }
    }

    func cancel() {
        log.notice("Dictation cancelled")
        guard phase == .listening else { return }
        RecordingManager.shared.cancel()
        phase = .idle
        overlay.hide()
    }

    func copyLastTranscript() {
        guard let last = DictationHistory.shared.entries.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.text, forType: .string)
    }

    private func flashError(_ message: String) {
        overlay.show(.error(message))
        overlay.hide(after: 2.2)
    }
}
