import Foundation

/// Local store of custom terms (names, jargon) and word replacements. Terms steer the
/// Nemotron prompt; replacements are applied deterministically to every dictation.
/// Replacements are learned automatically from manual edits (see `CorrectionTracker`).
@MainActor
final class PersonalDictionary: ObservableObject {
    static let shared = PersonalDictionary()

    struct Replacement: Codable, Hashable, Identifiable {
        var from: String
        var to: String
        var learned: Bool
        var id: String { from.lowercased() }
    }

    private struct Storage: Codable {
        var terms: [String]
        var replacements: [Replacement]
    }

    @Published var terms: [String] = [] { didSet { save() } }
    @Published var replacements: [Replacement] = [] { didSet { save() } }

    private let fileURL = AppSettings.supportDirectory.appendingPathComponent("dictionary.json")
    private var loading = false

    private init() {
        loading = true
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode(Storage.self, from: data) {
            terms = stored.terms
            replacements = stored.replacements
        }
        loading = false
    }

    func addTerm(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !terms.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        terms.append(term)
    }

    func addReplacement(from: String, to: String, learned: Bool) {
        let from = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        replacements.removeAll { $0.id == from.lowercased() }
        replacements.append(Replacement(from: from, to: to, learned: learned))
        addTerm(to)
    }

    /// Applies replacements; returns the new text and a note per replacement applied.
    func apply(to text: String) -> (text: String, notes: [String]) {
        var result = text
        var notes: [String] = []
        for r in replacements {
            let pattern = #"(?i)(?<![\w'])"# + NSRegularExpression.escapedPattern(for: r.from) + #"(?![\w'])"#
            guard result.range(of: pattern, options: .regularExpression) != nil else { continue }
            result = result.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: r.to),
                options: .regularExpression
            )
            notes.append("Dictionary: \(r.from) → \(r.to)")
        }
        return (result, notes)
    }

    private func save() {
        guard !loading else { return }
        let storage = Storage(terms: terms, replacements: replacements)
        if let data = try? JSONEncoder().encode(storage) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
