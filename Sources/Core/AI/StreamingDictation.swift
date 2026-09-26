import Foundation

/// Transcribes and cleans up a dictation *while it's being spoken*, so that when the user
/// finishes only the last few seconds are left to process. This keeps the wait after
/// release roughly constant instead of growing with dictation length (#7).
///
/// Speech-to-text runs on a rolling window:
/// - Every few seconds (at a pause if there is one, see `PauseSegmenter`), the audio since
///   the last committed point is transcribed with word timings.
/// - Words are committed up to the last good boundary (a sentence end, a comma, or a gap
///   between words) that has at least `rightContext` of speech after it. Those words were
///   heard with what followed them, so Parakeet transcribed and punctuated them correctly,
///   even in run-on speech without sentence breaks.
/// - The rest is re-transcribed with the next window. At release, the final window is
///   committed whole.
///
/// Cleanup runs speculatively on committed text, a few clauses at a time. If later text
/// starts with a correction ("Actually no, …"), the previous chunk is cleaned again
/// together with it. Speech-to-text and cleanup each run in their own ordered queue, and
/// the two overlap.
@MainActor
final class StreamingDictation {
    /// Everything recorded so far (16 kHz mono), e.g. to save the recording for Undo.
    private(set) var samples: [Int16] = []

    /// Background work so far: windows transcribed and chunks cleaned while recording.
    private(set) var segmentsTranscribed = 0
    private(set) var chunksCleaned = 0

    /// Words need this much speech after them in the window before they're committed.
    private let rightContext: TimeInterval = 1.0
    /// A gap between words this long counts as a boundary.
    private let wordGap: TimeInterval = 0.12
    /// Commit at any word boundary once the uncommitted audio gets this long without a
    /// good one (run-on speech rarely pauses).
    private let maxUncommitted: TimeInterval = 6
    /// Don't send tiny pieces to cleanup while more speech is coming.
    private let minChunkWords = 10
    /// Transcribe at the next pause after 1.5 s of new audio, or every 3 s regardless:
    /// commits only keep words with speech after them, so windows needn't end at pauses.
    private let segmenter = PauseSegmenter(minSegment: 1.5, minPause: 0.2, maxSegment: 3)
    private let sampleRate = Double(PauseSegmenter.sampleRate)

    /// Where the segmenter looks for the next pause.
    private var segmentStart = 0
    /// Audio before this index is transcribed and committed.
    private var committedUntil = 0
    /// Committed transcript so far.
    private var transcript = ""
    /// Committed text not yet sent to cleanup.
    private var pending = ""
    private var parts: [Part] = []
    private var asrQueue: Task<Void, Never>?
    private var cleanupQueue: Task<Void, Never>?
    private var failure: Error?
    private var cancelled = false

    private struct Part {
        var raw: String
        var cleaned: String
        var usedLLM: Bool
    }

    /// Feed newly recorded audio. Transcribes in the background at each pause.
    func append(_ newSamples: [Int16]) {
        guard !cancelled else { return }
        samples.append(contentsOf: newSamples)
        while let cut = segmenter.cutPoint(in: samples, from: segmentStart) {
            transcribeWindow(until: cut, final: false)
            segmentStart = cut
        }
    }

    /// The user finished: process what's left and return the result. The timings cover only
    /// this remaining work, which is the wait the user actually feels.
    func finish() async throws -> DictationResult {
        let clock = ContinuousClock()
        let start = clock.now
        segmentStart = samples.count
        transcribeWindow(until: samples.count, final: true)
        await asrQueue?.value
        let transcribed = clock.now
        if let failure { throw failure }

        scheduleCleanup(final: true)
        await cleanupQueue?.value
        guard !TextCleaner.words(transcript).isEmpty else { throw FlowError.nothingHeard }
        return try AIBridge.shared.finalize(
            raw: transcript,
            cleaned: TextCleaner.joinCleaned(parts.map { ($0.raw, $0.cleaned) }),
            engine: AIBridge.engine(llmChunks: parts.filter(\.usedLLM).count,
                                    ruleChunks: parts.filter { !$0.usedLLM }.count),
            transcriptionTime: (transcribed - start).seconds,
            cleanupTime: (clock.now - transcribed).seconds
        )
    }

    func cancel() {
        cancelled = true
        asrQueue?.cancel()
        cleanupQueue?.cancel()
    }

    // MARK: Speech-to-text queue

    /// Transcribes the audio from the last committed point up to `end`. The window's start
    /// is read when the job runs, after earlier windows have committed.
    private func transcribeWindow(until end: Int, final: Bool) {
        let previous = asrQueue
        asrQueue = Task { [weak self] in
            await previous?.value
            guard let self, !cancelled, failure == nil else { return }
            let start = committedUntil
            guard end > start else { return }
            let window = samples[start..<end]
            guard PauseSegmenter.containsSpeech(window) else {
                if final || Double(end - start) / sampleRate > maxUncommitted { committedUntil = end }
                return
            }
            do {
                let result = try await AIBridge.shared.transcription(wav: WAV.encode(window))
                segmentsTranscribed += 1
                commit(result, windowStart: start, windowEnd: end, final: final)
            } catch {
                failure = error
            }
        }
    }

    private func commit(_ result: Transcription, windowStart: Int, windowEnd: Int, final: Bool) {
        let words = result.words ?? []
        // Older servers don't report word timings: take the whole window.
        guard !final, !words.isEmpty else {
            append(committed: result.text)
            committedUntil = windowEnd
            return
        }
        let windowLength = Double(windowEnd - windowStart) / sampleRate
        let latest = windowLength - rightContext
        let isBoundary = { (i: Int) -> Bool in
            let word = words[i].text
            return word.last.map { ".?!,;:".contains($0) } == true || words[i + 1].start - words[i].end >= self.wordGap
        }
        // The last good boundary with enough speech after it; if the speaker never leaves
        // one, any word boundary will do once the window gets long.
        let candidates = words.indices.dropLast().filter { words[$0].end <= latest }
        guard let cut = candidates.last(where: isBoundary)
                ?? (windowLength > maxUncommitted ? candidates.last : nil) else { return }
        append(committed: words[...cut].map(\.text).joined(separator: " "))
        let resume = max(words[cut].end, words[cut + 1].start - 0.05)
        committedUntil = windowStart + Int(resume * sampleRate)
    }

    private func append(committed text: String) {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // A window that starts mid-sentence gets a capital letter from Parakeet: undo it.
        if let last = transcript.last, !".?!".contains(last) {
            text = TextCleaner.continuing(text)
        }
        transcript += (transcript.isEmpty ? "" : " ") + text
        pending += (pending.isEmpty ? "" : " ") + text
        scheduleCleanup(final: false)
    }

    // MARK: Cleanup queue

    /// Cleans committed text right away (speculatively). A chunk that opens with a
    /// correction is cleaned together with the chunk before it, replacing that result.
    private func scheduleCleanup(final: Bool) {
        guard final || TextCleaner.words(pending).count >= minChunkWords else { return }
        let text = pending
        pending = ""
        for chunk in TextCleaner.chunks(text) {
            cleanChunk(chunk, withPrevious: TextCleaner.startsWithCorrection(chunk))
        }
    }

    private func cleanChunk(_ chunk: String, withPrevious: Bool) {
        let previous = cleanupQueue
        cleanupQueue = Task { [weak self] in
            await previous?.value
            guard let self, !cancelled else { return }
            var raw = chunk
            if withPrevious, let last = parts.popLast() {
                raw = last.raw.trimmingCharacters(in: .whitespaces) + " " + chunk
            }
            let (text, usedLLM) = await AIBridge.shared.cleanChunk(raw)
            parts.append(Part(raw: raw, cleaned: text, usedLLM: usedLLM))
            chunksCleaned += 1
        }
    }
}
