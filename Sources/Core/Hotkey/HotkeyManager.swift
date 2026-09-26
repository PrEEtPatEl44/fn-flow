import AppKit
import CoreGraphics

/// Watches the keyboard through a CGEvent tap (requires Accessibility permission) and
/// reports hold-to-talk press/release of the configured hotkey. Also powers the
/// "record a shortcut" field in Settings via `captureHandler`.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Esc while dictating: a deliberate cancel.
    var onCancel: (() -> Void)?
    /// The modifier hotkey turned out to be part of a normal shortcut (e.g. ⌥←): drop the
    /// dictation silently.
    var onAbort: (() -> Void)?
    /// Set while dictating, so Esc cancels even when the hotkey isn't held (a dictation
    /// started by clicking the overlay).
    var escapeCancels = false

    /// While set, the next shortcut the user presses is delivered here (nil = cancelled
    /// with Esc) instead of triggering dictation.
    var captureHandler: ((Hotkey?) -> Void)?

    var isRunning: Bool { tap != nil }

    private var tap: CFMachPort?
    private var isHeld = false
    private var pressedAt = Date.distantPast
    private var captureModifier: UInt16?

    private static let escKeyCode: UInt16 = 0x35

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: nil
        ) else {
            log.error("Couldn't create event tap (Accessibility not granted?)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        log.notice("Hotkey listener active: \(AppSettings.shared.hotkey.displayName, privacy: .public)")
        return true
    }

    func beginCapture(_ handler: @escaping (Hotkey?) -> Void) {
        captureModifier = nil
        captureHandler = handler
    }

    func endCapture() {
        captureHandler = nil
        captureModifier = nil
    }

    /// Returns true when the event should be swallowed.
    fileprivate func handle(type: CGEventType, keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            log.error("Event tap was disabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if captureHandler != nil {
            return handleCapture(type: type, keyCode: keyCode, flags: flags)
        }

        let hotkey = AppSettings.shared.hotkey
        switch type {
        case .flagsChanged:
            guard hotkey.isModifierOnly, keyCode == hotkey.keyCode else { return false }
            let down = hotkey.isModifierHeld(in: flags)
            if down, !isHeld {
                isHeld = true
                pressedAt = Date()
                fire(onPress)
            } else if !down, isHeld {
                isHeld = false
                fire(onRelease)
            }
            return false // never swallow modifier changes

        case .keyDown:
            if escapeCancels, keyCode == Self.escKeyCode {
                isHeld = false
                fire(onCancel)
                return true
            }
            if isHeld {
                if keyCode == Self.escKeyCode {
                    isHeld = false
                    fire(onCancel)
                    return true
                }
                if hotkey.isModifierOnly {
                    // The modifier was really the start of a normal shortcut (e.g. ⌥←).
                    if Date().timeIntervalSince(pressedAt) < 0.5 {
                        isHeld = false
                        fire(onAbort)
                    }
                    return false
                }
                return keyCode == hotkey.keyCode // swallow auto-repeat of the hotkey
            }
            if !hotkey.isModifierOnly, !isRepeat, hotkey.matches(keyCode: keyCode, flags: flags) {
                isHeld = true
                pressedAt = Date()
                fire(onPress)
                return true
            }
            return false

        case .keyUp:
            if !hotkey.isModifierOnly, isHeld, keyCode == hotkey.keyCode {
                isHeld = false
                fire(onRelease)
                return true
            }
            return false

        default:
            return false
        }
    }

    private func handleCapture(type: CGEventType, keyCode: UInt16, flags: CGEventFlags) -> Bool {
        switch type {
        case .keyDown:
            let mods = flags.intersection(Hotkey.relevantModifiers).rawValue
            if keyCode == Self.escKeyCode, mods == 0 {
                finishCapture(nil)
                return true
            }
            let candidate = Hotkey(keyCode: keyCode, modifiers: mods)
            if candidate.isAcceptable { finishCapture(candidate) }
            return true
        case .keyUp:
            return true
        case .flagsChanged:
            guard let mod = Hotkey.modifierKeys[keyCode] else { return false }
            let down = flags.rawValue & mod.flag != 0
            if down {
                // A second modifier means the user is building a combo; wait for the key.
                captureModifier = captureModifier == nil ? keyCode : nil
            } else if captureModifier == keyCode {
                finishCapture(Hotkey(keyCode: keyCode, modifiers: 0))
            }
            return false
        default:
            return false
        }
    }

    /// Runs a callback after the tap returns. Starting the mic can take ~1s, and a tap that
    /// blocks that long is disabled by macOS, which silently drops the key-release event.
    private func fire(_ callback: (() -> Void)?) {
        guard let callback else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
    }

    private func finishCapture(_ hotkey: Hotkey?) {
        let handler = captureHandler
        endCapture()
        handler?(hotkey)
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    // The tap's run loop source is on the main run loop.
    let swallow = MainActor.assumeIsolated {
        HotkeyManager.shared.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
