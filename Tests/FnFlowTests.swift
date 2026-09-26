import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import fn_flow

struct TextCleanerTests {
    @Test func removesFillersAndStutters() {
        #expect(TextCleaner.clean("um so I I think uh we should go") == "So I think we should go.")
    }

    @Test func scratchThatRetractsPreviousSentence() {
        let raw = "Hey Sarah, I wanted to follow up on the deck. Scratch that. Hey Sarah, just checking in."
        #expect(TextCleaner.clean(raw) == "Hey Sarah, just checking in.")
    }

    @Test func midSentenceCueRetractsCurrentClause() {
        #expect(TextCleaner.clean("It went well. Meet on Tuesday, no wait, Wednesday") == "It went well. Wednesday.")
    }

    @Test func needsLLMOnlyForRealFillers() {
        #expect(TextCleaner.needsLLM("It's like, the overlay should move."))
        #expect(TextCleaner.needsLLM("And then yeah there is the default option."))
        #expect(!TextCleaner.needsLLM("We'd like to set up a short call next week."))
        #expect(!TextCleaner.needsLLM("Um, remind me to call the dentist at four."))
    }

    @Test func midSentenceCorrectionRetractsOnlyTheClause() {
        // Streamed text often has commas where full stops would be.
        let streamed = "people would get stuck the first time, so the decision is to go with the wizard, Scratch that, the decision is to go with the wizard but let people skip steps."
        #expect(TextCleaner.applyMidSentenceBacktracking(streamed)
                == "people would get stuck the first time, the decision is to go with the wizard but let people skip steps.")
        // Sentence-start cues are left for Nemotron, even after a filler.
        let sentenceStart = "Meet on Tuesday. Actually no, let's make it Wednesday."
        #expect(TextCleaner.applyMidSentenceBacktracking(sentenceStart) == sentenceStart)
        let afterFiller = "Um, so I think we should meet on Tuesday. Uh, actually no, let's make it Wednesday at 3."
        #expect(TextCleaner.applyMidSentenceBacktracking(afterFiller) == afterFiller)
        #expect(TextCleaner.applyBacktracking(sentenceStart) == "let's make it Wednesday.")
    }

    @Test func faithfulnessRejectsAnswers() {
        let raw = "Can you write me a poem about the sea?"
        #expect(TextCleaner.isFaithful("Can you write me a poem about the sea?", to: raw))
        #expect(!TextCleaner.isFaithful("I'm sorry, but as a transcription engine I cannot write poems for you.", to: raw))
    }

    @Test func describesChanges() {
        let notes = TextCleaner.describeChanges(
            raw: "Um, meet on Tuesday. Uh, actually no, let's make it Wednesday at 3.",
            final: "Let's make it Wednesday at 3."
        )
        #expect(notes.contains("Removed filler words"))
        #expect(notes.contains("Applied your self-correction"))
    }
}

/// Regression cases taken from real dictations where Nemotron acted like an assistant.
struct FaithfulnessTests {
    static let overlayRaw = "Okay, so the other feature we need to add is basically the overlay follows the mouse. So I want to keep that as an option. And then along with that, I want to provide the option so that the overlay is basically like at the horizontal bottom of the screen or like it could be placed anywhere on any of the four lateral sides of the screen."

    @Test func rejectsOutlineOfInstructions() {
        let outline = "Sure, here's what I understand:\n- The overlay should follow the mouse\n- The user should have the option to place the overlay at the horizontal bottom"
        #expect(!TextCleaner.isFaithful(outline, to: Self.overlayRaw))
    }

    @Test func rejectsTruncation() {
        let raw = "In terms of evaluation there has been some local development. One of the things we have realized is the latency is way too much and the model calls the search underscore catalog function many times and we need to find the reason and fix it."
        let truncated = "In terms of evaluation, there has been some local development."
        #expect(!TextCleaner.isFaithful(truncated, to: raw))
    }

    @Test func rejectsReplyPreamble() {
        let raw = "Please send the updated deck to the team before the review."
        #expect(!TextCleaner.isFaithful("Sure, please send the updated deck to the team before the review.", to: raw))
        // …but a speaker who really starts with "sure" is fine.
        #expect(TextCleaner.isFaithful("Sure, I can send the deck.", to: "Sure, uh, I can send the deck."))
        #expect(TextCleaner.isFaithful("Here's the plan: fix the bug.", to: "Here is the plan. Fix the bug."))
    }

    @Test func acceptsLightCleanup() {
        let cleaned = "The other feature we need to add is that the overlay follows the mouse. So I want to keep that as an option. Along with that, I want to provide the option so that the overlay is at the horizontal bottom of the screen, or it could be placed anywhere on any of the four lateral sides of the screen."
        #expect(TextCleaner.isFaithful(cleaned, to: Self.overlayRaw))
        #expect(TextCleaner.isFaithful("I think we should meet on Wednesday at 3.", to: "Um, so I think we should meet on Tuesday. Uh, actually no, let's make it Wednesday at 3."))
    }

    @Test func chunksKeepCorrectionsWithWhatTheyCorrect() {
        let text = String(repeating: "This is a filler sentence with several words in it. ", count: 4)
            + "We meet on Tuesday. Actually no, Wednesday."
        let chunks = TextCleaner.chunks(text, maxWords: 12)
        #expect(chunks.contains { $0.contains("Tuesday") && $0.contains("Actually no, Wednesday") })
        #expect(chunks.joined(separator: " ") == text.trimmingCharacters(in: .whitespaces))
    }
}

struct FormattingTests {
    @Test func enumeratedSteps() {
        let text = "Here's the plan. First, fix the login bug. Second, update the docs. And finally, ship it. Thanks everyone."
        #expect(TextCleaner.format(text) == "Here's the plan:\n- Fix the login bug\n- Update the docs\n- Ship it\n\nThanks everyone.")
    }

    @Test func numberedSteps() {
        let text = "To set it up, step one, install the models, step two, grant permissions, step three, hold the hotkey."
        #expect(TextCleaner.format(text) == "To set it up:\n- Install the models\n- Grant permissions\n- Hold the hotkey")
    }

    @Test func cuedInlineSeries() {
        #expect(TextCleaner.format("I need to buy eggs, milk, bread, and coffee.") == "I need to buy:\n- Eggs\n- Milk\n- Bread\n- Coffee")
        #expect(TextCleaner.format("Things to pack: warm socks, a jacket and boots.") == "Things to pack:\n- Warm socks\n- A jacket\n- Boots")
        #expect(TextCleaner.format("For the trip, I need to pack socks, a jacket, my charger, and boots.") == "For the trip, I need to pack:\n- Socks\n- A jacket\n- My charger\n- Boots")
        // No Oxford comma: Parakeet often transcribes lists this way.
        #expect(TextCleaner.format("The grocery list includes oranges, bananas and pineapples.") == "The grocery list includes:\n- Oranges\n- Bananas\n- Pineapples")
    }

    @Test func textAfterListBecomesNewParagraph() {
        #expect(TextCleaner.format("Please grab apples, pears, and plums. See you soon.") == "Please grab:\n- Apples\n- Pears\n- Plums\n\nSee you soon.")
    }

    @Test func proseIsLeftAlone() {
        for text in [
            "I went home, ate dinner, and slept.",
            "We need to talk about pricing, hiring, and the roadmap for next quarter.",
            "At first I was unsure, but second thoughts helped.",
            "The first time we met was great.",
        ] {
            #expect(TextCleaner.format(text) == text)
        }
    }

    @Test func normalizesLLMBullets() {
        #expect(TextCleaner.format("Groceries:\n* Eggs\n* Milk") == "Groceries:\n- Eggs\n- Milk")
        #expect(TextCleaner.format("Steps:\n1. Build.\n2. Ship.") == "Steps:\n- Build\n- Ship")
    }

    @Test func questionMarksFromStructure() {
        #expect(TextCleaner.format("Can you send me the deck. Thanks.") == "Can you send me the deck? Thanks.")
        #expect(TextCleaner.format("What is the status of the launch.") == "What is the status of the launch?")
        #expect(TextCleaner.format("Is there a meeting tomorrow") == "Is there a meeting tomorrow?")
    }

    @Test func statementsAndCommandsKeepPeriods() {
        for text in ["Do it now.", "What I mean is we should wait.", "Will do.", "How to fix it is unclear."] {
            #expect(TextCleaner.format(text) == text)
        }
    }
}

struct CorrectionDiffTests {
    @Test func unchangedTextYieldsNothing() {
        #expect(CorrectionDiff.substitutions(pasted: "Send it to Jon.", current: "Hi. Send it to Jon. Bye") == [])
    }

    @Test func learnsMisheardName() {
        let subs = CorrectionDiff.substitutions(
            pasted: "Please send the report to Jon by Friday.",
            current: "Notes: Please send the report to John by Friday. Thanks"
        )
        #expect(subs == [.init(from: "Jon", to: "John")])
    }

    @Test func learnsMisheardJargon() {
        let subs = CorrectionDiff.substitutions(
            pasted: "We deploy it on cooper netties next week.",
            current: "We deploy it on Kubernetes next week."
        )
        #expect(subs == [.init(from: "cooper netties", to: "Kubernetes")])
    }

    @Test func ignoresContentRewrites() {
        let subs = CorrectionDiff.substitutions(
            pasted: "Let's meet on Tuesday at noon.",
            current: "Let's meet on Wednesday at noon."
        )
        #expect(subs == [])
    }

    @Test func lostTextStopsTracking() {
        #expect(CorrectionDiff.substitutions(pasted: "Hello there friend", current: "something else entirely") == nil)
    }
}

struct HotkeyTests {
    @Test func modifierOnlyDetection() {
        let rightOption = Hotkey.default
        #expect(rightOption.isModifierOnly)
        #expect(rightOption.isModifierHeld(in: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)))
        // Left option held must not trigger a Right Option hotkey.
        #expect(!rightOption.isModifierHeld(in: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)))
    }

    @Test func comboMatchingIgnoresUnrelatedFlags() {
        let combo = Hotkey(keyCode: 0x31, modifiers: CGEventFlags([.maskControl, .maskAlternate]).rawValue)
        #expect(combo.displayName == "⌃⌥Space")
        #expect(combo.matches(keyCode: 0x31, flags: [.maskControl, .maskAlternate, .maskNonCoalesced]))
        #expect(!combo.matches(keyCode: 0x31, flags: [.maskControl]))
    }

    @Test func plainLettersAreRejected() {
        #expect(!Hotkey(keyCode: 0x00, modifiers: 0).isAcceptable)
        #expect(Hotkey(keyCode: 0x60, modifiers: 0).isAcceptable) // F5
    }
}

/// End-to-end against the real local runtime (Parakeet server + Ollama). Opt-in:
///   FN_FLOW_INTEGRATION=1 swift test --filter PipelineIntegrationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FN_FLOW_INTEGRATION"] == "1"))
@MainActor
struct PipelineIntegrationTests {
    private func speak(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nf-\(UUID().uuidString).wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEI16@16000", text]
        try say.run()
        say.waitUntilExit()
        return url
    }

    @Test func selfCorrectionAndFillers() async throws {
        let audio = try speak("Um, so I think we should meet on Tuesday, uh, actually no, let's make it Wednesday at three")
        let result = try await AIBridge.shared.process(audioURL: audio)
        print("RAW:", result.raw, "\nFINAL:", result.text, "\nNOTES:", result.notes)
        #expect(result.text.contains("Wednesday"))
        #expect(!result.text.contains("Tuesday"))
        #expect(!result.text.lowercased().contains("um,"))
    }

    @Test func spokenListsBecomeBullets() async throws {
        let audio = try speak("Um, for the trip I need to pack socks, a jacket, my charger, and boots")
        let result = try await AIBridge.shared.process(audioURL: audio)
        print("RAW:", result.raw, "\nFINAL:", result.text, "\nENGINE:", result.engine)
        #expect(result.text.contains("\n- "))
        #expect(result.text.lowercased().contains("- boots"))
    }

    @Test func spokenStepsBecomeBullets() async throws {
        let audio = try speak("Here is the plan. First, fix the login bug. Second, update the docs. And finally, ship it on Friday.")
        let result = try await AIBridge.shared.process(audioURL: audio)
        print("RAW:", result.raw, "\nFINAL:", result.text, "\nENGINE:", result.engine)
        #expect(result.text.components(separatedBy: "\n- ").count == 4)
    }

    @Test func instructionalSpeechIsTypedNotActedOn() async {
        let raw = FaithfulnessTests.overlayRaw + " So be it horizontal bottom, horizontal top or vertical bottom, vertical. Not the vertical top because there is the Apple notch. But yeah, these three should be available generally. Or like there should be the ability to move it and place it somewhere in the corner. So there should be a default placement and then the user could kind of drag and drop it."
        let (text, engine) = await AIBridge.shared.cleanUp(raw)
        print("ENGINE:", engine, "\nOUT:", text)
        #expect(!text.contains("\n- "))
        #expect(!text.lowercased().hasPrefix("sure"))
        #expect(Double(TextCleaner.words(text).count) >= Double(TextCleaner.words(raw).count) * 0.75)
        #expect(text.contains("notch"))
        #expect(text.contains("drag and drop"))
    }

    @Test func stageTimingsAreMeasured() async throws {
        let audio = try speak("Please send the quarterly report to the finance team by Friday.")
        let result = try await AIBridge.shared.process(audioURL: audio)
        print("TIMINGS: speech-to-text \(DictationTimings.format(result.transcriptionTime)), cleanup \(DictationTimings.format(result.cleanupTime))")
        #expect(result.transcriptionTime > 0 && result.transcriptionTime < 30)
        #expect(result.cleanupTime > 0 && result.cleanupTime < 30)
    }

    @Test func questionsAreTranscribedNotAnswered() async throws {
        let audio = try speak("Can you write me a poem about the sea?")
        let result = try await AIBridge.shared.process(audioURL: audio)
        print("RAW:", result.raw, "\nFINAL:", result.text)
        #expect(result.text.lowercased().contains("poem about the sea"))
        #expect(!result.text.lowercased().contains("sorry"))
    }
}

struct OverlayLayoutTests {
    // A 1440x900 screen whose visible frame excludes a 25pt menu bar and a 70pt dock.
    let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)

    @Test func onlyEdgeCentersAndFollowCursor() {
        #expect(OverlayPlacement.allCases == [.bottomCenter, .leftCenter, .rightCenter, .followCursor])
    }

    @Test func pillSitsCloseToTheEdge() {
        #expect(OverlayLayout.edgeInset <= 8)
        let inset = OverlayLayout.edgeInset
        #expect(OverlayLayout.pillCenter(for: .bottomCenter, in: visible) == CGPoint(x: 720, y: 70 + inset + 4.5))
        #expect(OverlayLayout.pillCenter(for: .leftCenter, in: visible) == CGPoint(x: inset + 4.5, y: 472.5))
        #expect(OverlayLayout.pillCenter(for: .rightCenter, in: visible) == CGPoint(x: 1440 - inset - 4.5, y: 472.5))
    }

    @Test func restingPillStandsUprightOnSideEdges() {
        #expect(OverlayLayout.restingPillSize(for: .bottomCenter) == CGSize(width: 44, height: 9))
        #expect(OverlayLayout.restingPillSize(for: .leftCenter) == CGSize(width: 9, height: 44))
    }

    @Test func panelsHugTheirEdge() {
        let size = CGSize(width: 420, height: 200)
        #expect(OverlayLayout.panelOrigin(for: .bottomCenter, in: visible, size: size) == CGPoint(x: 510, y: 70))
        #expect(OverlayLayout.panelOrigin(for: .leftCenter, in: visible, size: size) == CGPoint(x: 0, y: 372.5))
        #expect(OverlayLayout.panelOrigin(for: .rightCenter, in: visible, size: size) == CGPoint(x: 1020, y: 372.5))
    }

    @Test func anyDropSnapsToTheNearestEdgeCenter() {
        #expect(OverlayLayout.edge(nearest: CGPoint(x: 200, y: 600), in: visible) == .leftCenter)
        #expect(OverlayLayout.edge(nearest: CGPoint(x: 1300, y: 300), in: visible) == .rightCenter)
        #expect(OverlayLayout.edge(nearest: CGPoint(x: 700, y: 150), in: visible) == .bottomCenter)
        #expect(OverlayPlacement.edges.contains(OverlayLayout.edge(nearest: CGPoint(x: 720, y: 850), in: visible)))
    }

    @Test func clickableAreaMapsToScreenCoordinates() {
        // SwiftUI frames are top-left based inside the panel; the screen is bottom-left based.
        let panel = CGRect(x: 510, y: 70, width: 420, height: 200)
        let pill = CGRect(x: 150, y: 154, width: 120, height: 40) // near the panel's bottom
        #expect(OverlayLayout.screenRect(pill, inPanelFrame: panel) == CGRect(x: 660, y: 76, width: 120, height: 40))
    }

    @Test func contentGrowsAwayFromTheEdge() {
        #expect(OverlayLayout.contentAlignment(for: .bottomCenter) == .bottom)
        #expect(OverlayLayout.contentAlignment(for: .leftCenter) == .leading)
        #expect(OverlayLayout.contentAlignment(for: .rightCenter) == .trailing)
    }
}

@MainActor
struct OutputSettingsTests {
    @Test func pasteAndCopyCannotBothBeOff() {
        let settings = AppSettings.shared
        let saved = (settings.pasteAtCursor, settings.copyToClipboard)
        defer { settings.pasteAtCursor = true; settings.copyToClipboard = saved.1; settings.pasteAtCursor = saved.0 }

        settings.pasteAtCursor = true
        settings.copyToClipboard = false
        settings.pasteAtCursor = false // the last one on: ignored
        #expect(settings.pasteAtCursor)

        settings.copyToClipboard = true
        settings.pasteAtCursor = false // fine, copy is still on
        #expect(!settings.pasteAtCursor && settings.copyToClipboard)
        settings.copyToClipboard = false // the last one on: ignored
        #expect(settings.copyToClipboard)
    }

    @Test func migratesTheOldSingleOutputMode() throws {
        func migrated(_ old: [String: Any]) throws -> (Bool, Bool) {
            let suite = "fn-flow-tests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            old.forEach { defaults.set($1, forKey: $0) }
            AppSettings.migrateOutputMode(defaults)
            #expect(defaults.object(forKey: "outputMode") == nil)
            return (defaults.bool(forKey: "pasteAtCursor"), defaults.bool(forKey: "copyToClipboard"))
        }
        #expect(try migrated(["outputMode": "clipboardOnly"]) == (false, true))
        #expect(try migrated(["outputMode": "pasteAtCursor", "restoreClipboard": true]) == (true, false))
        #expect(try migrated(["outputMode": "pasteAtCursor", "restoreClipboard": false]) == (true, true))
    }
}

struct DictationTimingsTests {
    @Test func formatsMillisecondsAndSeconds() {
        #expect(DictationTimings.format(0.0844) == "84 ms")
        #expect(DictationTimings.format(0.21) == "210 ms")
        #expect(DictationTimings.format(1.44) == "1.4 s")
        #expect(DictationTimings.format(12.06) == "12.1 s")
    }

    @Test func median() {
        #expect(DictationTimings.median([]) == nil)
        #expect(DictationTimings.median([3, 1, 2]) == 2)
        #expect(DictationTimings.median([4, 1, 3, 2]) == 2.5)
    }

    @Test func durationToSeconds() {
        #expect(Duration.milliseconds(1500).seconds == 1.5)
    }

    /// history.json written before timings existed must still load.
    @Test func legacyHistoryEntriesDecode() throws {
        let legacy = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"2026-09-26T06:15:31Z","raw":"Hello","text":"Hello.",
          "notes":[],"engine":"Nemotron","app":"Notes","pasted":true}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([DictationHistory.Entry].self, from: Data(legacy.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].timings == nil)
    }

    @Test func timingsRoundTrip() throws {
        let timings = DictationTimings(audio: 18.9, transcription: 0.21, cleanup: 1.02, delivery: 0.004, total: 1.31)
        let data = try JSONEncoder().encode(timings)
        #expect(try JSONDecoder().decode(DictationTimings.self, from: data) == timings)
    }
}

struct ChunkingTests {
    @Test func runOnSentencesSplitIntoCleanupUnits() {
        let runOn = "Okay so instead of allowing the free dragging and positioning it anyway only allow it to be positioned on the three centers of the edges so bottom right and left and then just the option to follow the cursor so I think that will be better."
        let units = TextCleaner.cleanupUnits(runOn)
        #expect(units.count >= 2)
        #expect(units.allSatisfy { TextCleaner.words($0).count <= 24 })
        #expect(units.joined() == runOn) // nothing lost or reordered
    }

    @Test func joinsChunksCleanedMidSentence() {
        let joined = TextCleaner.joinCleaned([
            (raw: "we finished migrating the build runners,", cleaned: "We finished migrating the build runners."),
            (raw: "and the build time went down.", cleaned: "And the build time went down."),
            (raw: "Next week we test it.", cleaned: "Next week we test it."),
        ])
        #expect(joined == "We finished migrating the build runners, and the build time went down. Next week we test it.")
        // Names aren't lowercased when continuing a sentence.
        #expect(TextCleaner.continuing("Sarah said yes.") == "Sarah said yes.")
        #expect(TextCleaner.continuing("To the new cluster.") == "to the new cluster.")
    }
}

/// Serialized: several tests measure timing and share the main actor.
@Suite(.serialized)
struct StreamingTests {
    /// 16 kHz "speech" (a square wave) the segmenter treats as voice.
    static func speech(seconds: Double) -> [Int16] {
        (0..<Int(seconds * 16_000)).map { Int16(truncatingIfNeeded: ($0 % 40 < 20) ? 8_000 : -8_000) }
    }

    /// Review on #9: a batch captured just before stop() must reach both the stream and the WAV.
    @MainActor
    @Test func stopDeliversAudioStillQueued() throws {
        let recorder = RecordingManager.shared
        let buffer = SampleBuffer()
        var delivered: [Int16] = []
        recorder.attach(buffer) { delivered += $0 }
        buffer.append([1, 2, 3], level: 0.5)
        recorder.drain()
        // The final batch arrives from the audio thread, and its drain hasn't run yet.
        let final: [Int16] = [4, 5, 6, 7]
        let appended = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { buffer.append(final, level: 0.5); appended.signal() }
        appended.wait()
        let recording = try #require(recorder.stop())
        #expect(delivered == [1, 2, 3, 4, 5, 6, 7])
        #expect(WAV.decode(try Data(contentsOf: recording.url)) == [1, 2, 3, 4, 5, 6, 7])
        #expect(!recorder.isRecording)
    }

    /// Review on #9: cuts requested while transcription is busy collapse into one window.
    @MainActor
    @Test func pendingCutsAreCoalesced() async throws {
        var calls = 0
        let dictation = StreamingDictation(
            transcriber: { _ in
                calls += 1
                try await Task.sleep(for: .milliseconds(300))
                return Transcription(text: "word", sentences: nil, words: nil)
            },
            cleaner: { ($0, false) }
        )
        // 30 s of speech arrives far faster than it can be transcribed: ~10 cuts.
        let audio = Self.speech(seconds: 30)
        for offset in stride(from: 0, to: audio.count, by: 1_600) {
            dictation.append(Array(audio[offset..<min(offset + 1_600, audio.count)]))
        }
        let started = ContinuousClock.now
        _ = try await dictation.finish()
        // One window already in flight + one coalesced window + the final one.
        #expect(calls <= 3)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    /// Review on #9: cancelling stops the request already in flight, not just queued ones.
    @MainActor
    @Test func cancelStopsTheInFlightRequest() async throws {
        var sawCancellation = false
        var started = false
        let dictation = StreamingDictation(
            transcriber: { _ in
                started = true
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    sawCancellation = true
                    throw error
                }
                return Transcription(text: "late", sentences: nil, words: nil)
            },
            cleaner: { ($0, false) }
        )
        dictation.append(Self.speech(seconds: 4)) // enough for a cut
        while !started { try await Task.sleep(for: .milliseconds(10)) }
        dictation.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sawCancellation)
    }

    /// A busy Nemotron can't hold the paste: past the budget, the rules finish the job.
    @MainActor
    @Test func slowCleanupFallsBackToRulesAfterRelease() async throws {
        let dictation = StreamingDictation(
            releaseCleanupBudget: .milliseconds(200),
            transcriber: { _ in Transcription(text: "Um, send it on Friday.", sentences: nil, words: nil) },
            cleaner: { chunk in
                try? await Task.sleep(for: .seconds(3))
                return Task.isCancelled ? (TextCleaner.clean(chunk), false) : ("slow", true)
            }
        )
        dictation.append(Self.speech(seconds: 1))
        let started = ContinuousClock.now
        let result = try await dictation.finish()
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(result.engine == .rules)
        #expect(result.text == "Send it on Friday.")
    }

    @Test func unknownTokensAreStripped() {
        #expect(TextCleaner.stripUnknownTokens("Uh hey, <unk><unk><unk> how are you<unk>?") == "Uh hey, how are you?")
        #expect(TextCleaner.stripUnknownTokens("<unk> <unk>") == "")
        #expect(TextCleaner.stripUnknownTokens("Nothing to strip.") == "Nothing to strip.")
    }

    @MainActor
    @Test func unknownTokensNeverReachTheOutput() throws {
        let result = try AIBridge.shared.finalize(
            raw: "Uh hey, <unk><unk> how are you?", cleaned: "Hey, <unk><unk> how are you?",
            engine: .rules, transcriptionTime: 0, cleanupTime: 0
        )
        #expect(!result.text.contains("<unk>") && !result.raw.contains("<unk>"))
        #expect(result.text.contains("how are you"))
        // A transcript that was nothing but <unk> pastes nothing.
        #expect(throws: FlowError.self) {
            try AIBridge.shared.finalize(raw: "<unk><unk>", cleaned: "<unk><unk>", engine: .rules, transcriptionTime: 0, cleanupTime: 0)
        }
    }

    @Test func decodesUnknownTokenCount() throws {
        let json = #"{"text":"hey","sentences":[],"words":[],"unk_tokens":4}"#
        let t = try JSONDecoder().decode(Transcription.self, from: Data(json.utf8))
        #expect(t.unknownTokens == 4)
        // Older servers don't send it.
        #expect(try JSONDecoder().decode(Transcription.self, from: Data(#"{"text":"hey"}"#.utf8)).unknownTokens == nil)
    }

    @Test func segmenterCutsAtPauses() {
        // 5 s of "speech", a 0.3 s pause, then 2 s more.
        let tone = (0..<80_000).map { Int16(truncatingIfNeeded: ($0 % 40 < 20) ? 8_000 : -8_000) }
        let samples = tone + [Int16](repeating: 0, count: 4_800) + Array(tone.prefix(32_000))
        let segmenter = PauseSegmenter(minSegment: 4, minPause: 0.2, maxSegment: 12)
        let cut = segmenter.cutPoint(in: samples, from: 0)
        #expect(cut != nil && cut! > 80_000 && cut! < 84_800)
        // Not before the minimum segment length.
        #expect(segmenter.cutPoint(in: Array(samples.prefix(40_000)), from: 0) == nil)
        // Continuous speech still gets cut at the maximum length, past the minimum.
        let fast = PauseSegmenter(minSegment: 1.5, minPause: 0.2, maxSegment: 3)
        let forced = fast.cutPoint(in: tone, from: 0)
        #expect(forced != nil && forced! >= 24_000 && forced! <= 48_000)
        // Regression: the quietest frame being the first one must not return `start` (that
        // made the caller loop forever).
        let quietStart = [Int16](repeating: 0, count: 320) + Array(tone.prefix(48_000))
        let cut2 = fast.cutPoint(in: quietStart, from: 0)
        #expect(cut2 != nil && cut2! > 0)
        // Driving it like StreamingDictation does always terminates and advances.
        var start = 0, cuts = 0
        while let next = fast.cutPoint(in: tone, from: start), cuts < 100 {
            #expect(next > start)
            start = next
            cuts += 1
        }
        #expect(cuts < 100)
    }

    @Test func wavRoundTrip() {
        let samples: [Int16] = [0, 1, -1, 32_767, -32_768, 1_234]
        #expect(WAV.decode(WAV.encode(samples[...])) == samples)
    }
}
