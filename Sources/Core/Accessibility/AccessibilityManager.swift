import AppKit
import ApplicationServices

/// Accessibility permission handling, focused-element access, and text delivery
/// (paste at the text cursor of whatever app is focused, or clipboard only).
@MainActor
final class AccessibilityManager {
    static let shared = AccessibilityManager()

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system "allow accessibility" prompt if not yet trusted.
    func promptForTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, "AXFocusedUIElement" as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func textValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXValue" as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Puts `text` on the clipboard and, in paste mode, sends ⌘V to the focused app.
    /// When `restoreClipboard` is set, the previous clipboard contents come back afterwards.
    func deliver(_ text: String, mode: OutputMode, restoreClipboard: Bool) {
        let pasteboard = NSPasteboard.general
        let shouldRestore = mode == .pasteAtCursor && restoreClipboard
        let saved = shouldRestore ? snapshot(pasteboard) : []

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if shouldRestore {
            // Ask clipboard managers to ignore this temporary entry.
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        guard mode == .pasteAtCursor else { return }

        sendPasteShortcut()

        guard shouldRestore else { return }
        let changeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Don't clobber anything the user copied in the meantime.
            guard pasteboard.changeCount == changeCount else { return }
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private func sendPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }
}
