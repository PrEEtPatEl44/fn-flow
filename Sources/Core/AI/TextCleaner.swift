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

    static func hasBacktrackCue(_ text: String) -> Bool {
        backtrackCues.contains { text.range(of: #"\b\#($0)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
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

    /// Guards against the LLM acting like an assistant instead of a cleanup step. Output is
    /// rejected if it adds words the speaker didn't say (an answer or refusal), drops the
    /// speaker's content (a summary, outline, or truncation), or opens with a reply
    /// preamble ("Sure, here's…").
    static func isFaithful(_ output: String, to raw: String) -> Bool {
        // Compare word stems so "here is" -> "here's" or "I am" -> "I'm" isn't a change.
        let outWords = words(output).map(stripContraction)
        let rawWords = words(raw).map(stripContraction)
        guard !outWords.isEmpty else { return false }

        // Doesn't add: built almost entirely from the speaker's words.
        let rawSet = Set(rawWords)
        let known = outWords.filter { rawSet.contains($0) }.count
        guard Double(known) / Double(outWords.count) >= 0.75, outWords.count <= rawWords.count + 3 else { return false }

        // Doesn't drop: keeps the speaker's content words. Self-corrections legitimately
        // remove the replaced part, so allow more loss when the speaker corrected themselves.
        let content = rawWords.filter { $0.count >= 4 && !nonContentWords.contains($0) }
        if !content.isEmpty {
            let outSet = Set(outWords)
            let kept = Double(content.filter { outSet.contains($0) }.count) / Double(content.count)
            if kept < (hasCorrectionHint(raw) ? 0.5 : 0.85) { return false }
        }

        // Not a reply: unless the speaker actually started that way.
        if let first = outWords.first, replyOpeners.contains(first), first != rawWords.first(where: { !isFiller($0) }) {
            return false
        }
        return true
    }

    private static let replyOpeners: Set<String> = ["sure", "certainly", "here", "sorry", "as", "absolutely"]

    private static func stripContraction(_ word: String) -> String {
        word.replacingOccurrences(of: #"'(?:s|m|re|ll|ve|d)$"#, with: "", options: .regularExpression)
    }

    /// Fillers and function words the cleanup may drop or change without losing meaning.
    private static let nonContentWords: Set<String> = [
        "like", "basically", "actually", "literally", "really", "just", "okay", "yeah", "right",
        "kind", "sort", "know", "mean", "gonna", "wanna", "well", "sure", "stuff", "thing", "things",
        "that", "this", "then", "than", "there", "they", "them", "their", "with", "have", "been",
        "from", "what", "when", "will", "would", "could", "should", "also", "into", "some", "were",
        "your", "yours", "it's", "that's", "there's", "we're", "they're", "i'm", "don't", "doesn't",
        "very", "much", "more", "only", "even", "about", "along",
    ]

    private static func isFiller(_ word: String) -> Bool {
        word.range(of: #"^(?:u+m+|u+h+|uhm|erm|e+r+|a+h+|hm+|mm+|okay|so|like)$"#, options: .regularExpression) != nil
    }

    static func hasCorrectionHint(_ text: String) -> Bool {
        let lower = text.lowercased()
        return correctionHints.contains { lower.range(of: #"\b\#($0)\b"#, options: .regularExpression) != nil }
    }

    /// Splits a transcript into chunks of whole sentences (~`maxWords` each) for the LLM.
    /// A sentence that starts with a correction cue stays with the one before it, so
    /// "…Tuesday. Actually no, Wednesday." is cleaned up as one piece.
    static func chunks(_ text: String, maxWords: Int = 45) -> [String] {
        let sentences = text.matches(of: #/[^.!?]+[.!?]*\s*/#).map { String($0.output) }
        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            let startsWithCorrection = sentence.trimmingCharacters(in: .whitespaces).lowercased()
                .range(of: #"^(?:uh,?\s+|um,?\s+)?(?:actually|no wait|wait no|scratch that|never mind|i mean|sorry)\b"#, options: .regularExpression) != nil
            if !current.isEmpty, !startsWithCorrection, words(current + sentence).count > maxWords {
                chunks.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            current += sentence
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespaces))
        }
        return chunks.isEmpty ? [text] : chunks
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
