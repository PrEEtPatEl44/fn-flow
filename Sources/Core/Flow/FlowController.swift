import AppKit

/// The dictation loop: start (hold the hotkey, or click the resting pill for hands-free)
/// -> record (overlay listening) -> finish (release the hotkey, click ✓, or press the hotkey
/// again when hands-free) -> Parakeet + Nemotron -> paste / copy -> watch for manual
/// corrections. ✕ or Esc cancels, with an Undo that transcribes the recording after all.
@MainActor
final class FlowController: ObservableObject {
    static let shared = FlowController()

    enum Phase { case idle, listening, processing }

    /// How the current dictation was started, which decides how it ends.
    enum Mode {
        /// Hotkey held down: releasing it finishes.
        case hold
        /// Started by clicking the pill: runs until ✓, the hotkey, ✕, or Esc.
        case handsFree
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { HotkeyManager.shared.escapeCancels = phase == .listening }
    }
    private var mode: Mode = .hold
    /// Transcribes and cleans the current dictation while it's being spoken (#7).
    private var dictation: StreamingDictation?

    private let overlay = OverlayWindowManager.shared
    private let minimumDuration: TimeInterval = 0.3
    /// Kept after a cancel so "Undo" can still transcribe it.
    private let cancelledRecordingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("fn-flow-cancelled.wav")

    func setUp() {
        let hotkeys = HotkeyManager.shared
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onCancel = { [weak self] in self?.cancel(notify: true) }
        hotkeys.onAbort = { [weak self] in self?.cancel(notify: false) }
        CorrectionTracker.shared.onLearn = { [weak self] from, to in
            guard self?.phase == .idle else { return }
            OverlayWindowManager.shared.notify(OverlayNotice(
                message: "Learned “\(from)” → “\(to)”", icon: "sparkles", tint: .cyan, duration: 3
            ))
        }
    }

    private func hotkeyPressed() {
        log.notice("Hotkey pressed (phase: \(String(describing: self.phase), privacy: .public))")
        if phase == .listening, mode == .handsFree {
            finish()
        } else {
            begin(mode: .hold)
        }
    }

    private func hotkeyReleased() {
        log.notice("Hotkey released (phase: \(String(describing: self.phase), privacy: .public))")
        if mode == .hold { finish() }
    }

    func begin(mode: Mode) {
        guard phase == .idle else { return }
        CorrectionTracker.shared.flush()

        guard RuntimeManager.shared.isReady else {
            log.error("Runtime not ready: \(RuntimeManager.shared.asrStatus.label, privacy: .public)")
            showError(FlowError.runtimeNotReady.localizedDescription, settingsTab: .models)
            return
        }
        guard RecordingManager.micAuthorized else {
            log.error("Microphone not authorized")
            Task {
                if await !RecordingManager.requestMicAccess() {
                    showError(FlowError.microphonePermissionDenied.localizedDescription, settingsTab: .permissions)
                }
            }
            return
        }
        do {
            let dictation = StreamingDictation()
            try RecordingManager.shared.start { [weak dictation] samples in dictation?.append(samples) }
            self.dictation = dictation
            self.mode = mode
            phase = .listening
            overlay.show(.listening)
            log.notice("Recording started (\(mode == .hold ? "hold" : "hands-free", privacy: .public))")
        } catch {
            log.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
            showError(FlowError.microphoneUnavailable.localizedDescription)
        }
    }

    /// Stops recording and transcribes (hotkey release, ✓, or hotkey again when hands-free).
    func finish() {
        // The user's wait starts now; it's what History reports as the total.
        let finishedAt = ContinuousClock.now
        guard phase == .listening, let recording = RecordingManager.shared.stop() else { return }
        let streaming = dictation
        dictation = nil
        log.notice("Recorded \(recording.duration, format: .fixed(precision: 2))s")
        guard recording.duration >= minimumDuration else {
            streaming?.cancel()
            phase = .idle
            overlay.hide()
            return
        }
        transcribe(recording.url, streaming: streaming, audioLength: recording.duration, finishedAt: finishedAt)
    }

    /// ✕ / Esc (`notify`: offers Undo), or a silent abort when the hotkey was really part
    /// of a keyboard shortcut.
    func cancel(notify: Bool) {
        guard phase == .listening else { return }
        let recording = RecordingManager.shared.stop()
        dictation?.cancel()
        dictation = nil
        phase = .idle
        log.notice("Dictation cancelled")
        guard notify else {
            overlay.hide()
            return
        }
        var undo: OverlayNotice.Action?
        if let recording, recording.duration >= minimumDuration {
            try? FileManager.default.removeItem(at: cancelledRecordingURL)
            if (try? FileManager.default.copyItem(at: recording.url, to: cancelledRecordingURL)) != nil {
                undo = .init(title: "Undo") { [weak self] in
                    guard let self, phase == .idle else { return }
                    transcribe(cancelledRecordingURL, audioLength: recording.duration, finishedAt: .now)
                }
            }
        }
        overlay.notify(OverlayNotice(message: "Transcript cancelled", action: undo, duration: 5))
    }

    /// `finishedAt`: when the user finished (release, ✓, or Undo), the start of the wait.
    /// With `streaming`, most of the work already happened while the user spoke; if it
    /// fails, the saved recording is transcribed in full instead.
    private func transcribe(_ audioURL: URL, streaming: StreamingDictation? = nil,
                            audioLength: TimeInterval, finishedAt: ContinuousClock.Instant) {
        phase = .processing
        overlay.show(.processing)
        // Remember where the text is going so later edits there can be learned from.
        let target = AccessibilityManager.shared.focusedElement()
        let targetApp = NSWorkspace.shared.frontmostApplication?.localizedName

        Task {
            defer { phase = .idle }
            do {
                let result: DictationResult
                if let streaming {
                    do {
                        result = try await streaming.finish()
                    } catch FlowError.nothingHeard {
                        throw FlowError.nothingHeard
                    } catch {
                        log.error("Streaming failed (\(error.localizedDescription, privacy: .public)); transcribing the full recording")
                        result = try await AIBridge.shared.process(audioURL: audioURL)
                    }
                } else {
                    result = try await AIBridge.shared.process(audioURL: audioURL)
                }
                log.notice("Transcribed: \(result.raw, privacy: .private) -> \(result.text, privacy: .private)")
                let settings = AppSettings.shared
                let (paste, copy) = (settings.pasteAtCursor, settings.copyToClipboard)
                let deliveryStart = ContinuousClock.now
                AccessibilityManager.shared.deliver(result.text, paste: paste, copy: copy)
                let delivered = ContinuousClock.now
                let timings = DictationTimings(
                    audio: audioLength,
                    transcription: result.transcriptionTime,
                    cleanup: result.cleanupTime,
                    delivery: (delivered - deliveryStart).seconds,
                    total: (delivered - finishedAt).seconds
                )
                DictationHistory.shared.add(result, app: targetApp, pasted: paste, timings: timings)
                log.notice("Delivered \(result.text.count) chars (paste: \(paste), copy: \(copy)) in \(timings.total, format: .fixed(precision: 3))s [asr \(timings.transcription, format: .fixed(precision: 3))s, cleanup \(timings.cleanup, format: .fixed(precision: 3))s, deliver \(timings.delivery, format: .fixed(precision: 3))s] for \(audioLength, format: .fixed(precision: 1))s audio, AX trusted: \(AccessibilityManager.shared.isTrusted)")
                let title = switch (paste, copy) {
                case (true, true): "Pasted & copied"
                case (true, false): "Pasted"
                default: "Copied to clipboard"
                }
                overlay.show(.success(title: title, notes: result.notes))
                overlay.hide(after: result.notes.isEmpty ? 0.9 : 2.2)
                if paste {
                    CorrectionTracker.shared.track(pasted: result.text, in: target)
                }
            } catch {
                log.error("Pipeline failed: \(error.localizedDescription, privacy: .public)")
                showError(error.localizedDescription)
            }
        }
    }

    func copyLastTranscript() {
        guard let last = DictationHistory.shared.entries.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.text, forType: .string)
    }

    private func showError(_ message: String, settingsTab: SettingsTab? = nil) {
        let action = settingsTab.map { tab in
            OverlayNotice.Action(title: "Open Settings") { SettingsWindowController.shared.show(tab: tab) }
        }
        overlay.notify(OverlayNotice(
            message: message, icon: "exclamationmark.triangle.fill", tint: .yellow, action: action, duration: 4
        ))
    }
}
