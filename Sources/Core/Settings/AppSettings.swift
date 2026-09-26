import Foundation

enum OverlayPlacement: String, CaseIterable, Identifiable, Sendable {
    case bottomCenter, leftCenter, rightCenter, followCursor

    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomCenter: "Bottom center"
        case .leftCenter: "Left side"
        case .rightCenter: "Right side"
        case .followCursor: "Follow mouse cursor"
        }
    }

    /// The fixed spots on the screen's edges. No top spot: it would sit under the notch.
    static let edges: [OverlayPlacement] = [.bottomCenter, .leftCenter, .rightCenter]

    /// On the side edges the pill stands upright.
    var isVertical: Bool { self == .leftCenter || self == .rightCenter }
}

/// User preferences, persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey { didSet { save(hotkey, "hotkey") } }
    /// Where dictated text goes. Both can be on; at least one always is (turning off the
    /// last one is ignored). Paste without copy restores the previous clipboard afterwards.
    @Published var pasteAtCursor: Bool {
        didSet {
            if !pasteAtCursor, !copyToClipboard { pasteAtCursor = true; return }
            defaults.set(pasteAtCursor, forKey: "pasteAtCursor")
        }
    }
    @Published var copyToClipboard: Bool {
        didSet {
            if !copyToClipboard, !pasteAtCursor { copyToClipboard = true; return }
            defaults.set(copyToClipboard, forKey: "copyToClipboard")
        }
    }
    @Published var overlayPlacement: OverlayPlacement { didSet { defaults.set(overlayPlacement.rawValue, forKey: "overlayPlacement") } }
    /// Keep a small pill on screen between dictations (not in follow-cursor mode).
    @Published var showIdlePill: Bool { didSet { defaults.set(showIdlePill, forKey: "showIdlePill") } }
    @Published var refineWithLLM: Bool { didSet { defaults.set(refineWithLLM, forKey: "refineWithLLM") } }
    @Published var llmModel: String { didSet { defaults.set(llmModel, forKey: "llmModel") } }
    @Published var learnFromCorrections: Bool { didSet { defaults.set(learnFromCorrections, forKey: "learnFromCorrections") } }
    @Published var asrPort: Int { didSet { defaults.set(asrPort, forKey: "asrPort") } }

    private init() {
        defaults.register(defaults: [
            "pasteAtCursor": true,
            "copyToClipboard": true,
            "overlayPlacement": OverlayPlacement.bottomCenter.rawValue,
            "showIdlePill": true,
            "refineWithLLM": true,
            "llmModel": "nemotron-mini",
            "learnFromCorrections": true,
            "asrPort": 8765,
        ])
        hotkey = (defaults.data(forKey: "hotkey")).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) } ?? .default
        Self.migrateOutputMode(defaults)
        pasteAtCursor = defaults.bool(forKey: "pasteAtCursor")
        copyToClipboard = defaults.bool(forKey: "copyToClipboard") || !defaults.bool(forKey: "pasteAtCursor")
        overlayPlacement = OverlayPlacement(rawValue: defaults.string(forKey: "overlayPlacement") ?? "") ?? .bottomCenter
        showIdlePill = defaults.bool(forKey: "showIdlePill")
        refineWithLLM = defaults.bool(forKey: "refineWithLLM")
        llmModel = defaults.string(forKey: "llmModel") ?? "nemotron-mini"
        learnFromCorrections = defaults.bool(forKey: "learnFromCorrections")
        asrPort = defaults.integer(forKey: "asrPort")
    }

    /// Earlier versions had one "outputMode" (paste / clipboard only) plus "restoreClipboard".
    static func migrateOutputMode(_ defaults: UserDefaults) {
        guard let mode = defaults.string(forKey: "outputMode") else { return }
        if mode == "clipboardOnly" {
            defaults.set(false, forKey: "pasteAtCursor")
            defaults.set(true, forKey: "copyToClipboard")
        } else {
            // Restoring the old clipboard == not keeping the dictation in it.
            let restore = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
            defaults.set(true, forKey: "pasteAtCursor")
            defaults.set(!restore, forKey: "copyToClipboard")
        }
        defaults.removeObject(forKey: "outputMode")
        defaults.removeObject(forKey: "restoreClipboard")
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
