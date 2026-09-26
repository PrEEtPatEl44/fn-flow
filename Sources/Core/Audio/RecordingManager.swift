import AVFoundation
import Foundation

/// Captures the microphone as live 16 kHz mono 16-bit audio (what Parakeet expects),
/// delivering it about every 100 ms so dictation can be transcribed while it's spoken.
/// Also publishes the input level for the overlay waveform, and saves the recording as a
/// WAV when it stops (for Undo after a cancel, and as the fallback if streaming fails).
@MainActor
final class RecordingManager: ObservableObject {
    static let shared = RecordingManager()

    @Published private(set) var isRecording = false
    /// Normalized 0...1 input level, updated with each buffer while recording.
    @Published private(set) var level: Float = 0

    private var engine: AVAudioEngine?
    /// Audio converted on the real-time thread and not yet delivered (see `drain`).
    private var buffer: SampleBuffer?
    private var samples: [Int16] = []
    private var onSamples: (([Int16]) -> Void)?
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

    /// Starts capturing; `onSamples` receives each new batch of audio on the main actor.
    func start(onSamples: @escaping ([Int16]) -> Void) throws {
        stopEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let buffer = SampleBuffer()
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let tap = AudioTap(inputFormat: inputFormat, buffer: buffer) else {
            throw FlowError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inputFormat.sampleRate / 10),
                         format: inputFormat, block: AudioTap.block(for: tap))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw FlowError.microphoneUnavailable
        }
        self.engine = engine
        attach(buffer, onSamples: onSamples)
    }

    /// Begins a recording session fed by `buffer`. Split out so tests can drive a session
    /// without a microphone.
    func attach(_ buffer: SampleBuffer, onSamples: @escaping ([Int16]) -> Void) {
        self.buffer = buffer
        self.onSamples = onSamples
        samples = []
        startedAt = Date()
        isRecording = true
    }

    /// Stops recording and saves it. Returns the WAV file and its duration in seconds.
    /// Audio the tap had already captured is included: the engine stops first, then
    /// everything still buffered is delivered, so the last words aren't lost.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard isRecording else { return nil }
        let duration = Date().timeIntervalSince(startedAt)
        stopEngine()
        drain()
        isRecording = false
        level = 0
        onSamples = nil
        buffer = nil
        try? WAV.encode(samples[...]).write(to: fileURL, options: .atomic)
        return (fileURL, duration)
    }

    /// Delivers everything the tap has captured since the last drain.
    func drain() {
        guard isRecording, let (batch, batchLevel) = buffer?.take(), !batch.isEmpty else { return }
        samples.append(contentsOf: batch)
        level = level * 0.5 + batchLevel * 0.5
        onSamples?(batch)
    }

    private func stopEngine() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }
}

/// Thread-safe hand-off from the real-time audio thread to the main actor. The tap appends
/// here and asks the main actor to drain; `stop()` drains whatever is left, so a batch
/// captured just before stopping can't be dropped.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int16] = []
    private var level: Float = 0

    func append(_ batch: [Int16], level: Float) {
        lock.lock()
        pending.append(contentsOf: batch)
        self.level = level
        lock.unlock()
    }

    func take() -> ([Int16], Float) {
        lock.lock()
        defer {
            pending = []
            lock.unlock()
        }
        return (pending, level)
    }
}

/// Runs on the real-time audio thread, so it's deliberately not main-actor isolated:
/// converts each buffer to 16 kHz mono Int16, then hands it over via `SampleBuffer`.
private final class AudioTap: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let buffer: SampleBuffer

    init?(inputFormat: AVAudioFormat, buffer: SampleBuffer) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else { return nil }
        self.converter = converter
        self.target = target
        self.buffer = buffer
    }

    /// Built outside any actor so the closure isn't main-actor isolated.
    nonisolated static func block(for tap: AudioTap) -> AVAudioNodeTapBlock {
        { buffer, _ in tap.process(buffer) }
    }

    private func process(_ input: AVAudioPCMBuffer) {
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.int16ChannelData?[0], output.frameLength > 0 else { return }
        let batch = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))

        // Map roughly -50 dB...0 dB onto 0...1 for the waveform.
        let meanSquare = batch.reduce(Float(0)) { $0 + (Float($1) / 32768) * (Float($1) / 32768) } / Float(batch.count)
        let db = 10 * log10(max(meanSquare, 1e-10))
        buffer.append(batch, level: max(0, min(1, (db + 50) / 50)))
        DispatchQueue.main.async {
            MainActor.assumeIsolated { RecordingManager.shared.drain() }
        }
    }
}
