import CoreGraphics
import Foundation
import Testing
@testable import nemotron_flow

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
///   NEMOTRON_FLOW_INTEGRATION=1 swift test --filter PipelineIntegrationTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NEMOTRON_FLOW_INTEGRATION"] == "1"))
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

    @Test func questionsAreTranscribedNotAnswered() async throws {
        let audio = try speak("Can you write me a poem about the sea?")
        let result = try await AIBridge.shared.process(audioURL: audio)
        print("RAW:", result.raw, "\nFINAL:", result.text)
        #expect(result.text.lowercased().contains("poem about the sea"))
        #expect(!result.text.lowercased().contains("sorry"))
    }
}
