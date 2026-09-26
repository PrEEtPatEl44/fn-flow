import Foundation

/// Every dictation's raw Parakeet transcript next to the text that was actually delivered,
/// kept locally in Application Support/NemotronFlow/history.json.
@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()

    struct Entry: Codable, Identifiable, Hashable {
        let id: UUID
        let date: Date
        let raw: String
        let text: String
        let notes: [String]
        let engine: DictationResult.Engine
        /// The app that had focus when the text was delivered.
        let app: String?
        let pasted: Bool
    }

    @Published private(set) var entries: [Entry] = []

    private let limit = 200
    let fileURL = AppSettings.supportDirectory.appendingPathComponent("history.json")

    private init() {
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([Entry].self, from: data)) ?? []
        }
    }

    func add(_ result: DictationResult, app: String?, pasted: Bool) {
        entries.insert(Entry(
            id: UUID(), date: Date(), raw: result.raw, text: result.text,
            notes: result.notes, engine: result.engine, app: app, pasted: pasted
        ), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    func delete(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
