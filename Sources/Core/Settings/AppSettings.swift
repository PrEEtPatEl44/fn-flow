import Foundation

enum OutputMode: String, CaseIterable, Identifiable, Sendable {
    case pasteAtCursor, clipboardOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pasteAtCursor: "Paste at cursor"
        case .clipboardOnly: "Copy to clipboard only"
        }
    }
}

enum OverlayPlacement: String, CaseIterable, Identifiable, Sendable {
    case followCursor, bottomCenter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .followCursor: "Follow mouse cursor"
        case .bottomCenter: "Bottom center of screen"
        }
    }
}

/// User preferences, persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey { didSet { save(hotkey, "hotkey") } }
    @Published var outputMode: OutputMode { didSet { defaults.set(outputMode.rawValue, forKey: "outputMode") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var overlayPlacement: OverlayPlacement { didSet { defaults.set(overlayPlacement.rawValue, forKey: "overlayPlacement") } }
    @Published var refineWithLLM: Bool { didSet { defaults.set(refineWithLLM, forKey: "refineWithLLM") } }
    @Published var llmModel: String { didSet { defaults.set(llmModel, forKey: "llmModel") } }
    @Published var learnFromCorrections: Bool { didSet { defaults.set(learnFromCorrections, forKey: "learnFromCorrections") } }
    @Published var asrPort: Int { didSet { defaults.set(asrPort, forKey: "asrPort") } }

    private init() {
        defaults.register(defaults: [
            "outputMode": OutputMode.pasteAtCursor.rawValue,
            "restoreClipboard": true,
            "overlayPlacement": OverlayPlacement.followCursor.rawValue,
            "refineWithLLM": true,
            "llmModel": "nemotron-mini",
            "learnFromCorrections": true,
            "asrPort": 8765,
        ])
        hotkey = (defaults.data(forKey: "hotkey")).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .default
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .pasteAtCursor
        restoreClipboard = defaults.bool(forKey: "restoreClipboard")
        overlayPlacement = OverlayPlacement(rawValue: defaults.string(forKey: "overlayPlacement") ?? "") ?? .followCursor
        refineWithLLM = defaults.bool(forKey: "refineWithLLM")
        llmModel = defaults.string(forKey: "llmModel") ?? "nemotron-mini"
        learnFromCorrections = defaults.bool(forKey: "learnFromCorrections")
        asrPort = defaults.integer(forKey: "asrPort")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NemotronFlow", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
