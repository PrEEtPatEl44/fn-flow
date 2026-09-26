import ApplicationServices
import Foundation

/// Manual correction sync: after a paste, watches the focused text field for a short
/// while. If the user fixes a word the model got wrong ("Jon" -> "John"), that edit is a
/// gold label and is saved to the personal dictionary.
@MainActor
final class CorrectionTracker {
    static let shared = CorrectionTracker()

    /// Called with each learned (from, to) pair, e.g. to show a toast.
    var onLearn: ((String, String) -> Void)?

    private var element: AXUIElement?
    private var pasted = ""
    private var timer: Timer?
    private var deadline = Date.distantPast
    private var lastFound: [CorrectionDiff.Substitution] = []

    func track(pasted text: String, in element: AXUIElement?) {
        stop()
        guard AppSettings.shared.learnFromCorrections, let element else { return }
        self.element = element
        pasted = text
        deadline = Date().addingTimeInterval(60)
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { _ in
            MainActor.assumeIsolated { CorrectionTracker.shared.poll() }
        }
    }

    /// A new dictation is starting: settle whatever edits were made so far.
    func flush() {
        if !lastFound.isEmpty { learn(lastFound) }
        stop()
    }

    private func poll() {
        guard let element, Date() < deadline,
              let current = AccessibilityManager.shared.textValue(of: element),
              let found = CorrectionDiff.substitutions(pasted: pasted, current: current) else {
            flush()
            return
        }
        // Only learn once the edit has been stable across two polls (not mid-typing).
        if !found.isEmpty, found == lastFound {
            learn(found)
            stop()
        } else {
            lastFound = found
        }
    }

    private func learn(_ subs: [CorrectionDiff.Substitution]) {
        for sub in subs {
            PersonalDictionary.shared.addReplacement(from: sub.from, to: sub.to, learned: true)
            onLearn?(sub.from, sub.to)
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        element = nil
        lastFound = []
    }
}

/// Pure word-level diff between pasted text and the field's current contents.
enum CorrectionDiff {
    struct Substitution: Equatable, Sendable {
        let from: String
        let to: String
    }

    /// Returns nil when the pasted text can no longer be located (so tracking should stop),
    /// [] when it's unchanged or only changed in ways that aren't vocabulary fixes.
    static func substitutions(pasted: String, current: String) -> [Substitution]? {
        let p = tokens(pasted)
        let v = tokens(current)
        guard !p.isEmpty else { return nil }
        if contains(v, p) { return [] }

        // Locate the pasted region: anchored on its first word (or second, if the first was edited).
        let starts = v.indices.filter { i in
            v[i].lowercased() == p[0].lowercased()
                || (p.count > 1 && i + 1 < v.count && v[i + 1].lowercased() == p[1].lowercased())
        }
        var best: [Substitution]?
        var bestCost = Int.max
        for start in starts {
            let window = Array(v[start..<min(v.count, start + p.count + 3)])
            let diff = window.difference(from: p)
            let removed = runs(diff.removals.map(offset), in: p)
            let inserted = runs(diff.insertions.map(offset), in: window)
            let cost = removed.count + inserted.count
            guard cost < bestCost else { continue }
            bestCost = cost
            // Pair removed/inserted runs in order; unpaired trailing insertions are just the
            // text that follows the pasted region.
            best = zip(removed, inserted).map { Substitution(from: $0, to: $1) }
        }
        guard let subs = best, !subs.isEmpty else { return best == nil ? nil : [] }

        // A real vocabulary fix is small and sounds alike; anything else is a content edit.
        let accepted = subs.filter { sub in
            sub.from.split(separator: " ").count <= 3 && sub.to.split(separator: " ").count <= 3
                && soundsAlike(sub.from, sub.to)
        }
        return accepted.count <= max(1, p.count / 4) ? accepted : []
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard haystack.count >= needle.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<$0 + needle.count]) == needle }
    }

    private static func offset(_ change: CollectionDifference<String>.Change) -> Int {
        switch change {
        case .insert(let offset, _, _), .remove(let offset, _, _): offset
        }
    }

    /// Groups sorted offsets into contiguous runs and joins their words.
    private static func runs(_ offsets: [Int], in words: [String]) -> [String] {
        var result: [[Int]] = []
        for o in offsets.sorted() {
            if let last = result.last?.last, last + 1 == o { result[result.count - 1].append(o) } else { result.append([o]) }
        }
        return result.map { $0.map { words[$0] }.joined(separator: " ") }
    }

    /// Misheard words keep their consonant skeleton ("cooper netties" ~ "Kubernetes",
    /// "Jon" ~ "John") while edits change it ("Tuesday" -> "Wednesday").
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let ka = phoneticKey(a), kb = phoneticKey(b)
        guard let fa = ka.first, fa == kb.first else { return false }
        return similarity(ka, kb) >= 0.75 || similarity(a, b) >= 0.6
    }

    static func phoneticKey(_ word: String) -> String {
        let groups: [Character: Character] = [
            "c": "k", "q": "k", "g": "k", "b": "p", "d": "t", "z": "s", "x": "s", "v": "f", "j": "j",
        ]
        var key = ""
        for (i, ch) in word.lowercased().filter(\.isLetter).enumerated() {
            if "aeiouyhw".contains(ch) {
                if i == 0 { key.append("a") }
                continue
            }
            let mapped = groups[ch] ?? ch
            if key.last != mapped { key.append(mapped) }
        }
        return key
    }

    /// 1 - normalized Levenshtein distance over lowercased letters.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { !$0.isWhitespace })
        let y = Array(b.lowercased().filter { !$0.isWhitespace })
        guard !x.isEmpty, !y.isEmpty else { return x.count == y.count ? 1 : 0 }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}
