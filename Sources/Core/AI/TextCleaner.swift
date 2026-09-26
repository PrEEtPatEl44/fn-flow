import Foundation

/// Deterministic dictation cleanup. Used as the fallback when the Nemotron LLM is
/// unavailable or its output fails `isFaithful`, and to describe what changed for toasts.
enum TextCleaner {
    private static let fillerPattern = #"(?i)\b(?:u+m+|u+h+|uhm|erm|e+r+|a+h+|hm+|mm+)\b[,.]?\s*"#
    private static let repeatPattern = #"(?i)\b(\w+)(?:\s+\1\b)+"#
    private static let backtrackCues = [
        "scratch that", "never mind", "nevermind", "actually no", "no actually", "no wait", "wait no",
    ]
    /// Softer cues the LLM understands but rules can't safely act on.
    private static let correctionHints = backtrackCues + ["actually", "i mean", "sorry"]

    static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: fillerPattern, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: repeatPattern, with: "$1", options: .regularExpression)
        text = applyBacktracking(text)
        return tidy(text)
    }

    static func hasFillers(_ text: String) -> Bool {
        text.range(of: fillerPattern, options: .regularExpression) != nil
    }

    /// "…meet Tuesday. Scratch that. Meet Wednesday." -> "Meet Wednesday."
    /// A cue at a sentence start retracts the previous sentence; mid-sentence it retracts
    /// the current sentence up to the cue.
    static func applyBacktracking(_ input: String) -> String {
        var text = input
        while let cue = backtrackCues.compactMap({ c in
            text.range(of: #"\b\#(c)\b"#, options: [.regularExpression, .caseInsensitive])
        }).min(by: { $0.lowerBound < $1.lowerBound }) {
            var prefix = String(text[..<cue.lowerBound])
            let suffix = String(text[cue.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?-"))

            let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
            let atSentenceStart = trimmedPrefix.isEmpty || ".!?".contains(trimmedPrefix.last!)
            if atSentenceStart {
                prefix = String(trimmedPrefix.dropLast()) // drop the terminating punctuation
            }
            if let boundary = prefix.lastIndex(where: { ".!?\n".contains($0) }) {
                prefix = String(prefix[...boundary]) + " "
            } else {
                prefix = ""
            }
            text = prefix + suffix
        }
        return text
    }

    static func tidy(_ input: String) -> String {
        var text = input
        let fixes: [(String, String)] = [
            (#"[ \t]+"#, " "),
            (#" +([,.;:!?])"#, "$1"),
            (#"([,;:])(?=[.!?])"#, ""),
            (#",{2,}"#, ","),
            (#"^[\s,.;:]+"#, ""),
        ]
        for (pattern, template) in fixes {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        // Capitalize the first letter of each sentence.
        var result = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result += ch.uppercased()
                capitalizeNext = false
            } else {
                result.append(ch)
                if ".!?\n".contains(ch) { capitalizeNext = true }
            }
        }
        if let last = result.last, last.isLetter || last.isNumber {
            result += "."
        }
        return result
    }

    /// Guards against the LLM answering or rewriting instead of cleaning up: the output
    /// must be built almost entirely from words the speaker actually said.
    static func isFaithful(_ output: String, to raw: String) -> Bool {
        let outWords = words(output)
        let rawWords = words(raw)
        guard !outWords.isEmpty else { return false }
        let rawSet = Set(rawWords)
        let known = outWords.filter { rawSet.contains($0) }.count
        return Double(known) / Double(outWords.count) >= 0.75 && outWords.count <= rawWords.count + 3
    }

    /// Short human-readable notes for the "mini-toast" shown after pasting.
    static func describeChanges(raw: String, final: String) -> [String] {
        var notes: [String] = []
        if hasFillers(raw) || raw.range(of: repeatPattern, options: .regularExpression) != nil {
            notes.append("Removed filler words")
        }
        let lowerRaw = raw.lowercased()
        let hadCue = correctionHints.contains { lowerRaw.range(of: #"\b\#($0)\b"#, options: .regularExpression) != nil }
        if hadCue, Double(words(final).count) < Double(words(raw).count) * 0.8 {
            notes.append("Applied your self-correction")
        }
        if final.contains("\n- ") || final.hasPrefix("- ") || final.range(of: #"(?m)^\d+\. "#, options: .regularExpression) != nil {
            notes.append("Formatted as a list")
        }
        return notes
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "'")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }
}
