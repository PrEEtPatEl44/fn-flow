import AVFoundation
import Foundation
import Testing
@testable import fn_flow

/// Latency + quality benchmark. Needs the runtime (Parakeet server + Ollama) up.
///
/// Dataset: bench/data/dataset.json if it exists (your own, git-ignored because it's built
/// from personal dictations), otherwise the public synthetic sample bench/dataset.sample.json.
/// FN_FLOW_BENCH_DATASET=path overrides both.
///
///   FN_FLOW_BENCH=1 FN_FLOW_BENCH_LABEL=run1 swift test --filter BenchmarkTests
///   python3 bench/compare.py run1-baseline run1-optimized
///
/// Each case's `speech` is spoken with macOS `say` to make the audio (cached in
/// bench/data/audio). Latency is the wait after the user finishes speaking: the time from
/// the end of the recording until the text is ready to paste.
///
/// Variants (FN_FLOW_BENCH_VARIANTS, default both) run interleaved on every case, so they
/// share the same thermal conditions (this MacBook Air throttles under sustained load):
/// - baseline: the original pipeline. Whole file at release, Nemotron on every chunk, no cap.
/// - optimized: streaming. Audio is fed in at real-time speed (FN_FLOW_BENCH_SPEED > 1
///   feeds faster, a harsher test), and only the wait after the last sample is measured.
/// Other knobs: FN_FLOW_BENCH_RUNS (default 3), FN_FLOW_BENCH_ONLY=id1,id2.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FN_FLOW_BENCH"] == "1"))
@MainActor
struct BenchmarkTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let dataDir = root.appendingPathComponent("bench/data")
    static let env = ProcessInfo.processInfo.environment

    static var datasetURL: URL {
        if let path = env["FN_FLOW_BENCH_DATASET"] { return URL(fileURLWithPath: path, relativeTo: root) }
        let personal = dataDir.appendingPathComponent("dataset.json")
        return FileManager.default.fileExists(atPath: personal.path)
            ? personal
            : root.appendingPathComponent("bench/dataset.sample.json")
    }

    @Test func benchmark() async throws {
        let dataset = try JSONDecoder().decode(BenchDataset.self, from: Data(contentsOf: Self.datasetURL))
        print("BENCH dataset: \(Self.datasetURL.path) (\(dataset.cases.count) cases)")
        let label = Self.env["FN_FLOW_BENCH_LABEL"] ?? "run"
        let runs = Int(Self.env["FN_FLOW_BENCH_RUNS"] ?? "") ?? 3
        let variants = (Self.env["FN_FLOW_BENCH_VARIANTS"] ?? "baseline,optimized").split(separator: ",").map(String.init)
        let speed = Double(Self.env["FN_FLOW_BENCH_SPEED"] ?? "") ?? 1
        let only = Self.env["FN_FLOW_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let cases = dataset.cases.filter { only?.contains($0.id) ?? true }

        // Warm both models so the numbers reflect steady-state use.
        let warmup = try audio(for: cases.first { $0.category == "small" && !($0.expect.empty ?? false) } ?? cases[0])
        for variant in variants {
            _ = await BenchPipeline.run(variant: variant, audio: warmup, speed: 8)
            _ = await BenchPipeline.run(variant: variant, audio: warmup, speed: 8)
        }

        var results: [String: [BenchCaseResult]] = [:]
        for benchCase in cases {
            let url = try audio(for: benchCase)
            var samples: [String: [BenchPipeline.Sample]] = [:]
            for _ in 0..<runs {
                for variant in variants { // interleaved: same conditions for each
                    samples[variant, default: []].append(await BenchPipeline.run(variant: variant, audio: url, speed: speed))
                }
            }
            for variant in variants {
                let runs = samples[variant]!
                let first = runs[0]
                let grade = BenchGrader.grade(benchCase, output: first.output, raw: first.raw, nothingHeard: first.nothingHeard)
                let result = BenchCaseResult(
                    id: benchCase.id, category: benchCase.category, words: benchCase.speech.split(separator: " ").count,
                    audio: try Self.duration(of: url),
                    total: DictationTimings.median(runs.map(\.total)) ?? 0,
                    transcription: DictationTimings.median(runs.map(\.transcription)) ?? 0,
                    cleanup: DictationTimings.median(runs.map(\.cleanup)) ?? 0,
                    runs: runs.map(\.total), engine: first.engine, raw: first.raw, output: first.output, grade: grade,
                    backgroundSegments: first.backgroundSegments, backgroundChunks: first.backgroundChunks
                )
                results[variant, default: []].append(result)
                print(String(format: "BENCH %-9@ %-24@ %-6@ %5.1fs audio  total %6.3fs (asr %.3f, cleanup %.3f)  correct %5.1f  format %5.1f",
                             variant, result.id, result.category, result.audio, result.total, result.transcription,
                             result.cleanup, grade.correctness, grade.formatting))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        for variant in variants {
            let report = BenchReport(label: "\(label)-\(variant)", date: Date(), runsPerCase: runs, speed: speed, cases: results[variant] ?? [])
            let out = Self.root.appendingPathComponent("bench/results/\(report.label).json")
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(report).write(to: out)
            for line in report.summaryLines { print("SUMMARY \(variant) \(line)") }
            print("Wrote \(out.path)")
        }
    }

    /// Cached `say` rendering of the case's speech, 16 kHz mono 16-bit (what the app records).
    private func audio(for benchCase: BenchCase) throws -> URL {
        let url = Self.dataDir.appendingPathComponent("audio/\(benchCase.id).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@16000", benchCase.speech.isEmpty ? "mm hmm" : benchCase.speech]
        try say.run()
        say.waitUntilExit()
        return url
    }

    static func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}

// MARK: - Pipeline under test

@MainActor
enum BenchPipeline {
    struct Sample {
        var raw = ""
        var output = ""
        var engine = ""
        var nothingHeard = false
        var transcription: TimeInterval = 0
        var cleanup: TimeInterval = 0
        var total: TimeInterval = 0
        /// Streaming only: work already done in the background before the user finished.
        var backgroundSegments = 0
        var backgroundChunks = 0
    }

    /// The wait after the user stops speaking, as the app experiences it.
    static func run(variant: String, audio: URL, speed: Double) async -> Sample {
        var sample = Sample()
        do {
            let result: DictationResult
            let start: ContinuousClock.Instant
            switch variant {
            case "baseline":
                AIBridge.skipLLMWhenClean = false
                AIBridge.capOutput = false
                start = .now
                result = try await AIBridge.shared.process(audioURL: audio)
            default:
                AIBridge.skipLLMWhenClean = true
                AIBridge.capOutput = true
                let dictation = StreamingDictation()
                let samples = WAV.decode(try Data(contentsOf: audio))
                let step = 1_600 // 100 ms, like the recorder's buffers
                for offset in stride(from: 0, to: samples.count, by: step) {
                    dictation.append(Array(samples[offset..<min(offset + step, samples.count)]))
                    try await Task.sleep(for: .milliseconds(100.0 / speed))
                }
                sample.backgroundSegments = dictation.segmentsTranscribed
                sample.backgroundChunks = dictation.chunksCleaned
                start = .now
                result = try await dictation.finish()
            }
            sample.total = (ContinuousClock.now - start).seconds
            sample.raw = result.raw
            sample.output = result.text
            sample.engine = result.engine.rawValue
            sample.transcription = result.transcriptionTime
            sample.cleanup = result.cleanupTime
        } catch FlowError.nothingHeard {
            sample.nothingHeard = true
        } catch {
            sample.output = "ERROR: \(error.localizedDescription)"
        }
        return sample
    }
}

// MARK: - Dataset, grading, report

struct BenchDataset: Decodable {
    let cases: [BenchCase]
}

struct BenchCase: Decodable {
    struct Expect: Decodable {
        var list: Bool?
        var question: Bool?
        var empty: Bool?
        var incomplete: Bool?
        var mustContain: [String]?
        var mustNotContain: [String]?
    }

    let id: String
    let category: String
    let speech: String
    let gold: String
    let expect: Expect
}

struct BenchGrade: Codable {
    /// Word error rate of the final output against the gold output (0 = perfect).
    var wer: Double
    var checks: [String: Bool]
    /// 100 × (1 − WER), floored at 0.
    var correctness: Double
    /// Percentage of formatting checks passed.
    var formatting: Double
}

enum BenchGrader {
    static func grade(_ c: BenchCase, output: String, raw: String, nothingHeard: Bool) -> BenchGrade {
        if c.expect.empty == true {
            return BenchGrade(wer: nothingHeard ? 0 : 1, checks: ["nothingPasted": nothingHeard],
                              correctness: nothingHeard ? 100 : 0, formatting: nothingHeard ? 100 : 0)
        }
        var checks: [String: Bool] = [:]
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        checks["noFillers"] = trimmed.range(of: #"(?i)\b(um+|uh+|erm|er|ah)\b"#, options: .regularExpression) == nil
        checks["noReplyPreamble"] = trimmed.range(of: #"(?i)^(sure|certainly|here's what|here is what|i'm sorry|as an)\b"#, options: .regularExpression) == nil
        checks["capitalized"] = trimmed.first.map { !$0.isLetter || $0.isUppercase } ?? false
        let goldHasList = c.gold.contains("\n- ")
        let bullets = trimmed.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count
        if goldHasList || c.expect.list == true {
            checks["list"] = bullets >= 2
        } else {
            checks["noUnwantedList"] = bullets == 0
            if c.expect.incomplete != true {
                checks["terminalPunctuation"] = trimmed.last.map { ".?!".contains($0) } ?? false
            }
        }
        if c.expect.question == true { checks["questionMark"] = trimmed.contains("?") }
        for phrase in c.expect.mustContain ?? [] { checks["contains:\(phrase)"] = trimmed.contains(phrase) }
        for phrase in c.expect.mustNotContain ?? [] {
            checks["excludes:\(phrase)"] = trimmed.range(of: phrase, options: .caseInsensitive) == nil
        }
        let wer = wordErrorRate(trimmed, reference: c.gold)
        return BenchGrade(
            wer: wer, checks: checks, correctness: max(0, 1 - wer) * 100,
            formatting: Double(checks.values.filter { $0 }.count) / Double(max(checks.count, 1)) * 100
        )
    }

    static func normalize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9'$ ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }

    static func wordErrorRate(_ hypothesis: String, reference: String) -> Double {
        let h = normalize(hypothesis), r = normalize(reference)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var prev = Array(0...h.count)
        for i in 1...r.count {
            var cur = [i] + Array(repeating: 0, count: h.count)
            for j in stride(from: 1, through: h.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return Double(prev[h.count]) / Double(r.count)
    }
}

struct BenchCaseResult: Codable {
    var id: String
    var category: String
    var words: Int
    var audio: TimeInterval
    /// Medians over the runs.
    var total: TimeInterval
    var transcription: TimeInterval
    var cleanup: TimeInterval
    var runs: [TimeInterval]
    var engine: String
    var raw: String
    var output: String
    var grade: BenchGrade
    var backgroundSegments = 0
    var backgroundChunks = 0
}

struct BenchReport: Codable {
    var label: String
    var date: Date
    var runsPerCase: Int
    var speed: Double
    var cases: [BenchCaseResult]

    var summaryLines: [String] {
        ["small", "medium", "large", "all"].compactMap { category in
            let group = category == "all" ? cases : cases.filter { $0.category == category }
            guard !group.isEmpty else { return nil }
            let median = DictationTimings.median(group.map(\.total)) ?? 0
            let mean = group.map(\.total).reduce(0, +) / Double(group.count)
            let correctness = group.map(\.grade.correctness).reduce(0, +) / Double(group.count)
            let formatting = group.map(\.grade.formatting).reduce(0, +) / Double(group.count)
            return String(format: "%-6@ n=%2d  median %.3fs  mean %.3fs  correctness %.1f  formatting %.1f",
                          category, group.count, median, mean, correctness, formatting)
        }
    }
}
