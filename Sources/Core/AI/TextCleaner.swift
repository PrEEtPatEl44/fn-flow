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

    /// Whether a chunk needs Nemotron, i.e. has something the rules can't safely fix:
    /// soft fillers ("like", "basically", "you know"), soft correction cues ("actually",
    /// "I mean"), or a long unpunctuated run-on. Plain um/uh and stutters are handled by
    /// `clean`, so a chunk with only those skips the LLM (saving ~1 s per chunk).
    static func needsLLM(_ text: String) -> Bool {
        let lower = text.lowercased()
        // "like" only as a filler (", like,", "it's like", "so like"), not "we'd like to" or
        // "things like that".
        let fillerLike = #"(?:^|[,.]\s*|\b(?:is|was|it's|so|and|basically|just|um|uh|or)\s+)like\b|\blike,"#
        if lower.range(of: fillerLike, options: .regularExpression) != nil { return true }
        let softFillers = #"\b(basically|literally|kind of|sort of|you know|i guess|right[,.?]|okay so|yeah)\b"#
        if lower.range(of: softFillers, options: .regularExpression) != nil { return true }
        if hasCorrectionHint(text) { return true }
        // Parakeet punctuates as it goes; a very long stretch without any is a run-on.
        let longestRun = text.components(separatedBy: CharacterSet(charactersIn: ".!?,;:")).map { words($0).count }.max() ?? 0
        return longestRun > 30
    }

    static let unknownToken = "<unk>"

    /// Removes Parakeet's `<unk>` tokens (see runtime/server.py) and the gaps they leave.
    static func stripUnknownTokens(_ text: String) -> String {
        guard text.contains(unknownToken) else { return text }
        return text.replacingOccurrences(of: unknownToken, with: " ")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// A cue at a sentence start retracts the previous sentence; mid-sentence it retracts
    /// the clause just before it ("send it to John, no wait, to Mary" → "to Mary").
    static func applyBacktracking(_ input: String) -> String {
        retract(input, midSentenceOnly: false)
    }

    /// Only the mid-sentence retractions. Nemotron handles sentence-start cues more
    /// naturally but tends to keep both versions when the cue is mid-sentence, e.g. in
    /// streamed text where Parakeet used commas instead of full stops.
    static func applyMidSentenceBacktracking(_ input: String) -> String {
        retract(input, midSentenceOnly: true)
    }

    private static func retract(_ input: String, midSentenceOnly: Bool) -> String {
        var text = input
        var searchFrom = text.startIndex
        while let cue = backtrackCues.compactMap({ c in
            text.range(of: #"\b\#(c)\b"#, options: [.regularExpression, .caseInsensitive], range: searchFrom..<text.endIndex)
        }).min(by: { $0.lowerBound < $1.lowerBound }) {
            // Fillers between a sentence end and the cue ("Tuesday. Uh, actually no, …") don't
            // make it mid-sentence.
            let trimmedPrefix = String(text[..<cue.lowerBound])
                .replacingOccurrences(of: #"(?i)(?:[\s,]*\b(?:u+h+|u+m+|er|ah|oh|well)\b)+[\s,]*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let atSentenceStart = trimmedPrefix.isEmpty || ".!?".contains(trimmedPrefix.last!)
            if midSentenceOnly, atSentenceStart {
                searchFrom = cue.upperBound
                continue
            }
            // Drop the punctuation that ended the retracted part, then cut back to the
            // previous boundary: the sentence before (at a sentence start) or the clause
            // before (mid-sentence).
            var prefix = String(trimmedPrefix.dropLast(trimmedPrefix.last.map { ".!?,;".contains($0) } == true ? 1 : 0))
            let boundaries: String = atSentenceStart ? ".!?\n" : ".!?\n,;"
            if let boundary = prefix.lastIndex(where: { boundaries.contains($0) }) {
                prefix = String(prefix[...boundary]) + " "
            } else {
                prefix = ""
            }
            // Trim only the punctuation right after the cue; keep the sentence's own ending.
            let suffix = String(text[cue.upperBound...].drop { " ,.;:!?-".contains($0) })
            text = prefix + suffix
            searchFrom = text.index(text.startIndex, offsetBy: prefix.count)
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

    /// Sentences with their trailing punctuation and whitespace, so joining them restores the text.
    static func sentences(_ text: String) -> [String] {
        text.matches(of: #/[^.!?]+[.!?]*\s*/#).map { String($0.output) }
    }

    /// Sentences, with run-on sentences (common in dictation: Parakeet doesn't punctuate
    /// them) split into pieces of at most `maxWords`, at commas or before a conjunction.
    static func cleanupUnits(_ text: String, maxWords: Int = 24) -> [String] {
        sentences(text).flatMap { sentence in
            words(sentence).count <= maxWords ? [sentence] : splitRunOn(sentence, maxWords: maxWords)
        }
    }

    private static func splitRunOn(_ sentence: String, maxWords: Int) -> [String] {
        // Break points: after a comma, or before "and", "so", "but", "then", "because".
        let pieces = sentence.matches(of: #/.+?(?:,\s+|\s+(?=(?:and|so|but|then|because)\b)|$)/#).map { String($0.output) }
        var units: [String] = []
        var current = ""
        for piece in pieces {
            if !current.isEmpty, words(current + piece).count > maxWords {
                units.append(current)
                current = ""
            }
            current += piece
        }
        if !current.isEmpty { units.append(current) }
        // Anything still too long (no break points at all) is cut every `maxWords` words.
        return units.flatMap { unit -> [String] in
            let tokens = unit.split(separator: " ", omittingEmptySubsequences: false)
            guard tokens.count > maxWords * 3 / 2 else { return [unit] }
            return stride(from: 0, to: tokens.count, by: maxWords).map {
                tokens[$0..<min($0 + maxWords, tokens.count)].joined(separator: " ") + ($0 + maxWords < tokens.count ? " " : "")
            }
        }
    }

    /// Text that continues a sentence begun earlier: undo the capital letter Parakeet or
    /// Nemotron put on its first word. Only common words are lowercased, so names stay.
    static func continuing(_ text: String) -> String {
        guard let first = text.split(separator: " ").first,
              lowercaseStarts.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters)) else {
            return text
        }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// Joins separately cleaned chunks. Where a chunk ended mid-sentence in the transcript,
    /// drop the full stop the cleanup added and continue the sentence in lowercase.
    static func joinCleaned(_ parts: [(raw: String, cleaned: String)]) -> String {
        var out = ""
        var previousRaw = ""
        for part in parts {
            var text = part.cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if !out.isEmpty {
                let rawEnd = previousRaw.trimmingCharacters(in: .whitespacesAndNewlines).last
                if let rawEnd, !".?!".contains(rawEnd) {
                    if out.hasSuffix(".") { out.removeLast() }
                    if rawEnd == ",", !out.hasSuffix(",") { out += "," }
                    text = continuing(text)
                }
                out += " "
            }
            out += text
            previousRaw = part.raw
        }
        return out
    }

    /// Common words that are only capitalized at the start of a sentence.
    private static let lowercaseStarts: Set<String> = [
        "a", "an", "the", "and", "but", "or", "so", "because", "which", "that", "who", "whom", "whose",
        "where", "when", "while", "although", "though", "then", "to", "with", "for", "of", "in", "on",
        "at", "as", "if", "than", "into", "from", "by", "about", "like", "just", "also", "now", "there",
        "here", "this", "these", "those", "it", "its", "it's", "we", "we're", "you", "your", "they",
        "their", "he", "she", "my", "our", "is", "are", "was", "were", "be", "been", "have", "has",
        "had", "do", "does", "did", "can", "could", "would", "should", "will", "not", "no", "all",
        "some", "any", "more", "most", "very", "really", "maybe", "let's", "let", "go", "get", "make",
        "want", "need", "think", "know", "see", "look", "use", "add", "move", "place", "allow",
        "provide", "create", "keep", "set", "find", "only", "even", "still", "yeah", "okay", "right",
        "what", "how", "why", "one", "two", "three", "other", "another", "each", "every", "both",
        "scratch", "actually", "sorry", "wait", "never", "um", "uh",
    ]

    /// "Actually no, …", "Scratch that, …": corrects whatever came right before it.
    static func startsWithCorrection(_ sentence: String) -> Bool {
        sentence.trimmingCharacters(in: .whitespaces).lowercased()
            .range(of: #"^(?:uh,?\s+|um,?\s+)?(?:actually|no wait|wait no|scratch that|never mind|i mean|sorry)\b"#, options: .regularExpression) != nil
    }

    /// Splits a transcript into chunks of whole sentences (~`maxWords` each) for the LLM.
    /// A sentence that starts with a correction cue stays with the one before it, so
    /// "…Tuesday. Actually no, Wednesday." is cleaned up as one piece.
    static func chunks(_ text: String, maxWords: Int = 45) -> [String] {
        var chunks: [String] = []
        var current = ""
        for sentence in cleanupUnits(text) {
            if !current.isEmpty, !startsWithCorrection(sentence), words(current + sentence).count > maxWords {
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
