import Foundation

/// How long each stage of a dictation took, in seconds. `total` runs from the moment the
/// user finished (hotkey release, ✓, or Undo) until the text was pasted or copied, so it
/// is the wait the user actually feels. It also includes small gaps between stages.
struct DictationTimings: Codable, Hashable, Sendable {
    /// Length of the recording (not part of the wait).
    var audio: TimeInterval
    /// Parakeet speech-to-text, including the upload to the local server.
    var transcription: TimeInterval
    /// Nemotron or rule-based cleanup, formatting, and dictionary replacements.
    var cleanup: TimeInterval
    /// Putting the text on the clipboard and sending ⌘V.
    var delivery: TimeInterval
    /// Finish → text delivered.
    var total: TimeInterval

    /// "84 ms" under a second, otherwise "1.4 s".
    static func format(_ seconds: TimeInterval) -> String {
        seconds < 1
            ? "\(Int((seconds * 1000).rounded())) ms"
            : String(format: "%.1f s", seconds)
    }

    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

extension Duration {
    /// This duration in (fractional) seconds.
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
