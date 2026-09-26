import Foundation

/// Deterministic formatting passes applied to every dictation (after Nemotron or the
/// rule-based cleanup): bulleted lists and missed question marks.
extension TextCleaner {
    /// Final formatting pass. Question marks first so list items get them too.
    static func format(_ text: String) -> String {
        formatLists(fixQuestionMarks(normalizeBullets(text)))
    }

    // MARK: - Lists

    static func formatLists(_ text: String) -> String {
        if text.range(of: #"(?m)^- "#, options: .regularExpression) != nil { return text } // already a list
        if let enumerated = formatEnumeratedList(text) { return enumerated }
        return formatInlineLists(text)
    }

    /// The LLM sometimes uses "* ", "• " or "1. " bullets; standardize on "- ".
    static func normalizeBullets(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?m)^[ \t]*(?:[*•]|\d{1,2}[.)])[ \t]+"#, with: "- ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^(- .*?)\.[ \t]*$"#, with: "$1", options: .regularExpression)
    }

    private static let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
    private static let cardinals = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]

    private static func markerWords(_ n: Int) -> [String] {
        var words = [ordinals[n - 1]]
        if n <= 3 { words.append(ordinals[n - 1] + "ly") }
        for prefix in ["number", "step", "point", "item"] {
            words += ["\(prefix) \(cardinals[n - 1])", "\(prefix) \(n)"]
        }
        return words
    }

    /// Matches a list marker only at the start of a clause, so "at first" or "the first
    /// time" don't count. The match includes the separator ("and", "then", commas).
    private static func markerRegex(_ words: [String]) -> NSRegularExpression {
        let alternatives = words
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
            .joined(separator: "|")
        let pattern = #"(?:^|(?<=[.!?:;,\n]))\s*(?:(?:and|then)\s+)?\b(?:"# + alternatives + #")\b(?:\s+of\s+all)?[,:]?\s*"#
        return try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    /// "Here's the plan. First, fix the bug. Second, update docs. Finally, ship it."
    /// -> "Here's the plan:\n- Fix the bug\n- Update docs\n- Ship it"
    static func formatEnumeratedList(_ text: String) -> String? {
        let ns = text as NSString
        var markers: [NSRange] = []
        var searchFrom = 0
        for n in 1...ordinals.count {
            let range = NSRange(location: searchFrom, length: ns.length - searchFrom)
            guard let match = markerRegex(markerWords(n)).firstMatch(in: text, range: range) else { break }
            markers.append(match.range)
            searchFrom = match.range.upperBound
        }
        if markers.count >= 2 {
            let range = NSRange(location: searchFrom, length: ns.length - searchFrom)
            let finalWords = ["finally", "lastly", "last but not least"]
            if let match = markerRegex(finalWords).firstMatch(in: text, range: range) {
                markers.append(match.range)
            }
        }
        guard markers.count >= 2 else { return nil }

        var items: [String] = []
        for (i, marker) in markers.enumerated() {
            let end = i + 1 < markers.count ? markers[i + 1].location : ns.length
            items.append(ns.substring(with: NSRange(location: marker.upperBound, length: end - marker.upperBound)))
        }
        // The last item runs to the end of its sentence; anything after is a new paragraph.
        var trailing = ""
        if let last = items.last,
           let stop = last.range(of: #"[.!?](?=\s+\S)"#, options: .regularExpression) {
            trailing = String(last[stop.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            items[items.count - 1] = String(last[..<stop.upperBound])
        }

        let intro = ns.substring(to: markers[0].location)
        return assemble(intro: intro, items: items, trailing: trailing)
    }

    private static let listCues = [
        "list", "following", "items", "things", "buy", "grab", "pick up", "bring", "pack",
        "grocer", "shopping", "agenda", "to do", "todo", "to-do", "steps", "options", "include",
        "including",
    ]
    private static let seriesLeadIns = [
        "include", "includes", "including", "are", "is", "buy", "get", "grab", "pick up", "bring",
        "pack", "need", "needs", "want", "add", "like", "following",
    ]

    /// "I need to buy eggs, milk, bread, and coffee." -> "I need to buy:\n- Eggs\n- Milk…"
    /// Requires 3+ short items and either a colon or a list cue, so ordinary prose with
    /// commas ("I went home, ate, and slept") is left alone.
    static func formatInlineLists(_ text: String) -> String {
        let sentences = text.matches(of: #/[^.!?\n]+[.!?]*\s*/#).map { String($0.output) }
        guard !sentences.isEmpty else { return text }

        var output = ""
        var changed = false
        for (index, sentence) in sentences.enumerated() {
            guard let (intro, items) = inlineSeries(sentence) else {
                output += sentence
                continue
            }
            changed = true
            let rest = sentences[(index + 1)...].joined().trimmingCharacters(in: .whitespacesAndNewlines)
            output += assemble(intro: intro, items: items, trailing: "")
            if !rest.isEmpty { output += "\n\n" + formatInlineLists(rest) }
            break
        }
        return changed ? output : text
    }

    private static func inlineSeries(_ sentence: String) -> (intro: String, items: [String])? {
        let body = sentence.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!")))
        guard !body.hasSuffix("?") else { return nil }

        var intro: String
        var chunks: [String]
        if let colon = body.firstIndex(of: ":") {
            intro = String(body[..<colon])
            chunks = body[body.index(after: colon)...].components(separatedBy: ",")
        } else {
            chunks = body.components(separatedBy: ",")
            // The series starts in the chunk holding the list cue: "For the trip, I need to
            // pack socks, a jacket…" has its cue in the second chunk.
            guard let cueIndex = chunks.firstIndex(where: { chunk in
                listCues.contains { chunk.lowercased().range(of: #"\b\#($0)"#, options: .regularExpression) != nil }
            }) else { return nil }
            let leading = chunks[..<cueIndex].joined(separator: ",")
            chunks = Array(chunks[cueIndex...])
            guard chunks.count >= 3 else { return nil }
            // Split "I need to buy eggs" into intro "I need to buy" + first item "eggs".
            let lower = chunks[0].lowercased()
            if let leadIn = seriesLeadIns
                .compactMap({ lower.range(of: #"\b\#($0)\b"#, options: [.regularExpression, .backwards]) })
                .max(by: { $0.upperBound < $1.upperBound }) {
                let cut = chunks[0].index(chunks[0].startIndex, offsetBy: lower.distance(from: lower.startIndex, to: leadIn.upperBound))
                intro = String(chunks[0][..<cut])
                chunks[0] = String(chunks[0][cut...])
            } else {
                let words = chunks[0].split(separator: " ")
                let take = min(2, max(1, words.count - 1))
                intro = words.dropLast(take).joined(separator: " ")
                chunks[0] = words.suffix(take).joined(separator: " ")
            }
            if !leading.isEmpty { intro = leading + "," + (intro.hasPrefix(" ") ? intro : " " + intro) }
        }

        // "milk and bread" at the end without an Oxford comma is two items.
        var items = chunks.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if var last = items.popLast() {
            last = last.replacingOccurrences(of: #"^(?:and|or)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            let parts = last.components(separatedBy: " and ")
            if parts.count == 2, parts.allSatisfy({ $0.split(separator: " ").count <= 3 }) {
                items += parts
            } else {
                items.append(last)
            }
        }
        guard items.count >= 3,
              items.allSatisfy({ (1...6).contains($0.split(separator: " ").count) }),
              items[0].split(separator: " ").count <= 4,
              !intro.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (intro, items)
    }

    private static func assemble(intro: String, items: [String], trailing: String) -> String {
        let bullets = items.map { item -> String in
            var s = item.trimmingCharacters(in: .whitespacesAndNewlines)
            s = s.replacingOccurrences(of: #"^[,:;\s]+"#, with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(?:[,;]|\s+(?:and|then))*[\s.]*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            return "- " + s.prefix(1).uppercased() + s.dropFirst()
        }.filter { $0 != "- " }

        var head = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        head = head.replacingOccurrences(of: #"(?:[,;]|\s+(?:and|then))*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        if head.hasSuffix(".") { head.removeLast() }
        if !head.isEmpty, !head.hasSuffix(":"), !head.hasSuffix("?"), !head.hasSuffix("!") { head += ":" }

        var result = head.isEmpty ? "" : head + "\n"
        result += bullets.joined(separator: "\n")
        if !trailing.isEmpty { result += "\n\n" + trailing }
        return result
    }

    // MARK: - Question marks

    /// Parakeet predicts punctuation from the audio (so rising intonation usually already
    /// gives "?"). This catches clear questions it ended with ".": subject-auxiliary
    /// inversion ("can you…", "is there…") and wh-questions ("what is…", "how do…").
    static func fixQuestionMarks(_ text: String) -> String {
        let pronouns = "you|i|we|they|he|she"
        let patterns = [
            #"(?:can|could|would|will|should|shall|may|might)\s+(?:\#(pronouns)|it)\b"#,
            #"(?:do|does|did|have|has)\s+(?:\#(pronouns))\b"#,
            #"(?:is|are|was|were|am)\s+(?:\#(pronouns)|it|this|that|there|the)\b"#,
            #"(?:what|why|how|when|where|who|which|whose)(?:'s|’s|\s+(?:is|are|was|were|do|does|did|can|could|would|will|should|have|has))\b"#,
        ]
        let questionStart = try! NSRegularExpression(pattern: "^(?:" + patterns.joined(separator: "|") + ")", options: .caseInsensitive)

        var result = ""
        for sentence in text.matches(of: #/[^.!?\n]+[.!?]*\s*/#).map({ String($0.output) }) {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if trimmed.hasSuffix(".") || !trimmed.contains(where: { ".!?".contains($0) }),
               questionStart.firstMatch(in: trimmed, range: range) != nil,
               let dot = sentence.lastIndex(where: { !$0.isWhitespace }) {
                var fixed = sentence
                if fixed[dot] == "." { fixed.replaceSubrange(dot...dot, with: "?") } else { fixed.insert("?", at: fixed.index(after: dot)) }
                result += fixed
            } else {
                result += sentence
            }
        }
        // Preserve newlines/spacing that the sentence split didn't capture.
        return result.isEmpty ? text : result
    }
}
