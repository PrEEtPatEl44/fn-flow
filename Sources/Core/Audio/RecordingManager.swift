import AVFoundation
import Foundation

/// Records 16 kHz mono 16-bit PCM WAV (what Parakeet expects) and publishes the live
/// input level for the overlay waveform.
@MainActor
final class RecordingManager: ObservableObject {
    static let shared = RecordingManager()

    @Published private(set) var isRecording = false
    /// Normalized 0...1 input level, updated ~30x per second while recording.
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startedAt = Date.distantPast

    private let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("fn-flow-recording.wav")

    static var micAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start() throws {
        stopMeter()
        recorder?.stop()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw FlowError.microphoneUnavailable
        }
        self.recorder = recorder
        startedAt = Date()
        isRecording = true
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { RecordingManager.shared.updateMeter() }
        }
    }

    /// Stops recording and returns the file plus its duration in seconds.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, isRecording else { return nil }
        let duration = Date().timeIntervalSince(startedAt)
        recorder.stop()
        self.recorder = nil
        isRecording = false
        stopMeter()
        return (fileURL, duration)
    }

    private func updateMeter() {
        guard let recorder else { return }
        recorder.updateMeters()
        // Map roughly -50 dB...0 dB onto 0...1, smoothed.
        let db = recorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (db + 50) / 50))
        level = level * 0.5 + normalized * 0.5
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }
}
