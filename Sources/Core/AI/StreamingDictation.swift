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
/// together with it.
///
/// Speech-to-text and cleanup each have one worker, and the two overlap. Pending cuts are
/// coalesced, so if transcription falls behind, the backlog becomes a single larger window
/// rather than a queue that `finish()` must wait through. After release, cleanup gets
/// `releaseCleanupBudget`; past it, Nemotron is cancelled and the rules finish the job.
@MainActor
final class StreamingDictation {
    typealias Transcriber = @MainActor (Data) async throws -> Transcription
    typealias Cleaner = @MainActor (String) async -> (text: String, usedLLM: Bool)

    /// Everything recorded so far (16 kHz mono), e.g. to save the recording for Undo.
    private(set) var samples: [Int16] = []

    /// Background work so far: windows transcribed and chunks cleaned.
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
    /// How long the user waits for Nemotron after release before the rules take over.
    private let releaseCleanupBudget: Duration
    /// Transcribe at the next pause after 1.5 s of new audio, or every 3 s regardless:
    /// commits only keep words with speech after them, so windows needn't end at pauses.
    private let segmenter = PauseSegmenter(minSegment: 1.5, minPause: 0.2, maxSegment: 3)
    private let sampleRate = Double(PauseSegmenter.sampleRate)
    private let transcriber: Transcriber
    private let cleaner: Cleaner

    /// Where the segmenter looks for the next pause.
    private var segmentStart = 0
    /// Audio before this index is transcribed and committed.
    private var committedUntil = 0
    /// Committed transcript so far.
    private var transcript = ""
    /// Committed text not yet sent to cleanup.
    private var pending = ""
    private var parts: [Part] = []
    private var failure: Error?
    private var cancelled = false
    /// Windows in a row that came back with `<unk>` tokens (see `commit`).
    private var unknownTokenWindows = 0

    // Speech-to-text worker: transcribes up to the latest requested end.
    private var requestedEnd = 0
    private var transcribedEnd = 0
    private var finalRequested = false
    private var finalDone = false
    private var asrWorker: Task<Void, Never>?
    private var asrRequest: Task<Transcription, Error>?

    // Cleanup worker: cleans queued chunks in order.
    private var cleanupQueue: [(chunk: String, withPrevious: Bool)] = []
    private var cleanupWorker: Task<Void, Never>?
    private var cleanupRequest: Task<(text: String, usedLLM: Bool), Never>?
    /// After release, once the budget runs out: the rules clean what's left.
    private var rulesOnly = false

    private struct Part {
        var raw: String
        var cleaned: String
        var usedLLM: Bool
    }

    init(
        releaseCleanupBudget: Duration = .milliseconds(1500),
        transcriber: @escaping Transcriber = { try await AIBridge.shared.transcription(wav: $0) },
        cleaner: @escaping Cleaner = { await AIBridge.shared.cleanChunk($0) }
    ) {
        self.releaseCleanupBudget = releaseCleanupBudget
        self.transcriber = transcriber
        self.cleaner = cleaner
    }

    /// Feed newly recorded audio. Transcribes in the background at each pause.
    func append(_ newSamples: [Int16]) {
        guard !cancelled else { return }
        samples.append(contentsOf: newSamples)
        var cut: Int?
        while let next = segmenter.cutPoint(in: samples, from: segmentStart) {
            cut = next
            segmentStart = next
        }
        if let cut { requestTranscription(until: cut, final: false) }
    }

    /// The user finished: process what's left and return the result. The timings cover only
    /// this remaining work, which is the wait the user actually feels.
    func finish() async throws -> DictationResult {
        let clock = ContinuousClock()
        let start = clock.now
        segmentStart = samples.count
        requestTranscription(until: samples.count, final: true)
        while let worker = asrWorker { await worker.value }
        let transcribed = clock.now
        if let failure { throw failure }

        scheduleCleanup(final: true)
        // Don't let a slow or busy Nemotron hold the paste: past the budget, cancel it and
        // let the rules clean whatever is left.
        let budget = releaseCleanupBudget
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: budget)
            guard let self, !Task.isCancelled else { return }
            rulesOnly = true
            cleanupRequest?.cancel()
        }
        while let worker = cleanupWorker { await worker.value }
        deadline.cancel()

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

    /// Stops all work, including requests already in flight, so the next dictation doesn't
    /// queue behind this one.
    func cancel() {
        cancelled = true
        asrRequest?.cancel()
        cleanupRequest?.cancel()
        asrWorker?.cancel()
        cleanupWorker?.cancel()
    }

    // MARK: Speech-to-text worker

    private func requestTranscription(until end: Int, final: Bool) {
        requestedEnd = max(requestedEnd, end)
        if final { finalRequested = true }
        if asrWorker == nil {
            asrWorker = Task { [weak self] in await self?.runTranscription() }
        }
    }

    /// Transcribes up to the latest requested end, one window at a time. Cuts requested
    /// while a window is in flight collapse into the next window.
    private func runTranscription() async {
        while !cancelled, failure == nil {
            let end = requestedEnd
            let isFinal = finalRequested && end == requestedEnd
            guard end > transcribedEnd || (isFinal && !finalDone) else { break }
            transcribedEnd = end
            await transcribeWindow(until: end, final: isFinal)
            if isFinal, end == requestedEnd { finalDone = true }
        }
        asrWorker = nil
    }

    private func transcribeWindow(until end: Int, final: Bool) async {
        let start = committedUntil
        guard end > start else { return }
        let window = samples[start..<end]
        guard PauseSegmenter.containsSpeech(window) else {
            if final || Double(end - start) / sampleRate > maxUncommitted { committedUntil = end }
            return
        }
        let wav = WAV.encode(window)
        let transcriber = transcriber
        let request = Task { try await transcriber(wav) }
        asrRequest = request
        defer { asrRequest = nil }
        do {
            let result = try await request.value
            guard !cancelled else { return }
            segmentsTranscribed += 1
            commit(result, windowStart: start, windowEnd: end, final: final)
        } catch {
            if !cancelled { failure = error }
        }
    }

    private func commit(_ result: Transcription, windowStart: Int, windowEnd: Int, final: Bool) {
        // Parakeet occasionally decodes a stretch as <unk> (the server retries once and strips
        // what's left). Don't commit that window: its audio is transcribed again with the next
        // one. After two bad windows in a row, commit the stripped text so the dictation moves on.
        if let unknown = result.unknownTokens, unknown > 0 {
            log.error("Window of \(Double(windowEnd - windowStart) / self.sampleRate, format: .fixed(precision: 1))s had \(unknown) <unk> tokens")
            if !final, unknownTokenWindows < 2 {
                unknownTokenWindows += 1
                return
            }
        }
        unknownTokenWindows = 0
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

    // MARK: Cleanup worker

    /// Cleans committed text right away (speculatively). A chunk that opens with a
    /// correction is cleaned together with the chunk before it, replacing that result.
    private func scheduleCleanup(final: Bool) {
        guard final || TextCleaner.words(pending).count >= minChunkWords else { return }
        let text = pending
        pending = ""
        for chunk in TextCleaner.chunks(text) {
            cleanupQueue.append((chunk, TextCleaner.startsWithCorrection(chunk)))
        }
        if cleanupWorker == nil, !cleanupQueue.isEmpty {
            cleanupWorker = Task { [weak self] in await self?.runCleanup() }
        }
    }

    private func runCleanup() async {
        while !cancelled, !cleanupQueue.isEmpty {
            let item = cleanupQueue.removeFirst()
            var raw = item.chunk
            if item.withPrevious, let last = parts.popLast() {
                raw = last.raw.trimmingCharacters(in: .whitespaces) + " " + item.chunk
            }
            let cleaned: (text: String, usedLLM: Bool)
            if rulesOnly {
                cleaned = (TextCleaner.clean(TextCleaner.applyMidSentenceBacktracking(raw)), false)
            } else {
                let cleaner = cleaner
                let chunk = raw
                let request = Task { await cleaner(chunk) }
                cleanupRequest = request
                cleaned = await request.value
                cleanupRequest = nil
            }
            guard !cancelled else { break }
            parts.append(Part(raw: raw, cleaned: cleaned.text, usedLLM: cleaned.usedLLM))
            chunksCleaned += 1
        }
        cleanupWorker = nil
    }
}
