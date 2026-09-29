import Foundation

/// Per-day totals behind Insights (words, dictations, and which apps they went to), kept
/// locally in Application Support/NemotronFlow/usage.json. History keeps only the last 200
/// dictations; these small aggregates cover the whole year the activity heatmap shows.
@MainActor
final class UsageStats: ObservableObject {
    static let shared = UsageStats()

    struct Day: Codable, Equatable {
        var words = 0
        var dictations = 0
        var apps: [String: Int] = [:]
    }

    /// Keyed by local calendar day, "yyyy-MM-dd".
    @Published private(set) var days: [String: Day] = [:]

    private let fileURL: URL
    private let calendar = Calendar.current

    init(fileURL: URL = AppSettings.supportDirectory.appendingPathComponent("usage.json"), seed: [DictationHistory.Entry]? = nil) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([String: Day].self, from: data) {
            days = stored
        } else {
            // First run with Insights: start from the history that's already there.
            for entry in (seed ?? DictationHistory.shared.entries) {
                add(text: entry.text, app: entry.app, date: entry.date)
            }
            if !days.isEmpty { save() }
        }
    }

    func record(text: String, app: String?, date: Date = Date()) {
        add(text: text, app: app, date: date)
        save()
    }

    func reset() {
        days = [:]
        save()
    }

    // MARK: Queries

    func day(_ date: Date) -> Day { days[Self.key(date, calendar)] ?? Day() }

    /// The last `count` days, oldest first, ending today.
    func recent(_ count: Int, until today: Date = Date()) -> [(date: Date, day: Day)] {
        (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: today).map { ($0, day($0)) }
        }
    }

    /// Consecutive days with at least one dictation, ending today, or yesterday if nothing
    /// has been dictated yet today (the streak isn't lost until the day is over).
    func streak(until today: Date = Date()) -> Int {
        var date = today
        if day(date).dictations == 0, let yesterday = calendar.date(byAdding: .day, value: -1, to: date) {
            date = yesterday
        }
        var count = 0
        while day(date).dictations > 0, let previous = calendar.date(byAdding: .day, value: -1, to: date) {
            count += 1
            date = previous
        }
        return count
    }

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalDictations: Int { days.values.reduce(0) { $0 + $1.dictations } }

    /// Apps by number of dictations, most used first.
    var rankedApps: [(app: String, count: Int)] {
        var totals: [String: Int] = [:]
        for day in days.values {
            for (app, count) in day.apps { totals[app, default: 0] += count }
        }
        let ranked: [(app: String, count: Int)] = totals.map { (app: $0.key, count: $0.value) }
        return ranked.sorted { a, b in a.count != b.count ? a.count > b.count : a.app < b.app }
    }

    // MARK: Helpers

    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }.count
    }

    /// Most frequent words across `texts`, skipping short and common ones.
    nonisolated static func topWords(in texts: [String], limit: Int = 6) -> [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        for text in texts {
            for token in text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
                let word = token.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                guard word.count > 2, !stopWords.contains(word) else { continue }
                counts[word, default: 0] += 1
            }
        }
        let ranked: [(word: String, count: Int)] = counts.map { (word: $0.key, count: $0.value) }
        return Array(ranked.sorted { a, b in a.count != b.count ? a.count > b.count : a.word < b.word }.prefix(limit))
    }

    nonisolated static func key(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func add(text: String, app: String?, date: Date) {
        var day = days[Self.key(date, calendar)] ?? Day()
        day.words += Self.wordCount(TextCleaner.stripUnknownTokens(text))
        day.dictations += 1
        if let app { day.apps[app, default: 0] += 1 }
        days[Self.key(date, calendar)] = day
    }

    private func save() {
        if let data = try? JSONEncoder().encode(days) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private nonisolated static let stopWords: Set<String> = [
        "the", "and", "for", "this", "that", "with", "your", "you", "are", "was", "will", "have", "has",
        "can", "our", "into", "from", "where", "what", "when", "then", "than", "there", "their", "they",
        "them", "just", "not", "but", "all", "also", "about", "been", "were", "would", "could", "should",
        "some", "any", "out", "get", "got", "its", "it's", "i'm", "i'll", "let's", "don't", "we're",
        "you're", "that's", "which", "who", "how", "why", "his", "her", "she", "him", "one", "two",
        "like", "yeah", "okay", "so", "very", "really", "more", "most", "other", "here", "these",
        "those", "over", "again", "until", "because", "only", "make", "need", "want", "going",
    ]
}
