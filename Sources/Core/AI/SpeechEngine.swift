import FluidAudio
import Foundation

/// In-process speech-to-text: NVIDIA Parakeet TDT 0.6B v2 (English) as Core ML models on the
/// Apple Neural Engine, via FluidAudio. No Python, server, or port involved (#6).
@MainActor
final class SpeechEngine {
    static let shared = SpeechEngine()

    /// Parakeet v2: English-only, best English accuracy (the model the app has always used).
    static let version: AsrModelVersion = .v2
    nonisolated static let unknownToken = TextCleaner.unknownToken

    private var manager: AsrManager?
    /// 0.5 s at 16 kHz.
    nonisolated static let trailingSilence = 8_000

    var isLoaded: Bool { manager != nil }

    /// Loads (and on first use, compiles for the Neural Engine) the models in `directory`.
    func load(from directory: URL) async throws {
        let models = try await AsrModels.load(from: directory, version: Self.version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    func unload() {
        manager = nil
    }

    /// Transcribes 16 kHz mono audio, with word timings for streaming.
    ///
    /// Parakeet occasionally decodes a stretch as a run of `<unk>` tokens (a degenerate decode;
    /// the same audio transcribes fine moments later). Retry once and keep the better result,
    /// strip any `<unk>` left, and save the audio to Application Support/…/diagnostics so the
    /// cause can be reproduced.
    func transcribe(_ samples: [Int16]) async throws -> Transcription {
        guard let manager else { throw FlowError.runtimeNotReady }
        // A little trailing silence: without it, Parakeet can invent words when speech is cut
        // off abruptly (e.g. "…instead of just" → "…instead of adjusting the majority").
        let audio = samples.map { Float($0) / 32768 } + [Float](repeating: 0, count: Self.trailingSilence)
        var result = try await Self.run(manager, audio)
        var unknown = Self.unknownCount(result)
        if unknown > 0 {
            Self.saveDiagnostic(samples, unknown: unknown)
            let retry = try await Self.run(manager, audio)
            let retryUnknown = Self.unknownCount(retry)
            log.error("Parakeet produced \(unknown) <unk> tokens; the retry produced \(retryUnknown)")
            if retryUnknown < unknown {
                result = retry
                unknown = retryUnknown
            }
        }
        return Self.transcription(from: result, unknownTokens: unknown)
    }

    private static func run(_ manager: AsrManager, _ audio: [Float]) async throws -> ASRResult {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state)
    }

    nonisolated static func unknownCount(_ result: ASRResult) -> Int {
        if let timings = result.tokenTimings {
            return timings.filter { $0.token.contains(unknownToken) }.count
        }
        return result.text.components(separatedBy: unknownToken).count - 1
    }

    /// Our transcript format: text plus word timings, with any `<unk>` removed.
    nonisolated static func transcription(from result: ASRResult, unknownTokens: Int) -> Transcription {
        let timings = (result.tokenTimings ?? []).filter { !$0.token.contains(unknownToken) }
        let words = buildWordTimings(from: timings).map {
            Transcription.Span(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        return Transcription(
            text: TextCleaner.stripUnknownTokens(result.text).trimmingCharacters(in: .whitespacesAndNewlines),
            words: words,
            unknownTokens: unknownTokens
        )
    }

    /// Keeps the audio that produced `<unk>` (newest 10) so the cause can be reproduced.
    private static func saveDiagnostic(_ samples: [Int16], unknown: Int) {
        let directory = AppSettings.supportDirectory.appendingPathComponent("diagnostics", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        try? WAV.encode(samples[...]).write(to: directory.appendingPathComponent("unk-\(stamp)-\(unknown).wav"))
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("unk-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        files.dropLast(10).forEach { try? fm.removeItem(at: $0) }
    }
}
