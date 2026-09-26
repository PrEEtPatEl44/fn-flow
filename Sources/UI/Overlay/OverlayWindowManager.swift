import AppKit
import SwiftUI

/// Hosts `FlowOverlay` in a click-through, non-activating panel that floats above every
/// app (and full-screen spaces) and glides after the mouse cursor.
@MainActor
final class OverlayWindowManager {
    static let shared = OverlayWindowManager()

    private let model = OverlayModel()
    private var panel: NSPanel?
    private var followTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var position: CGPoint?

    private let size = CGSize(width: 420, height: 170)

    func show(_ phase: OverlayPhase) {
        hideWork?.cancel()
        let panel = panel ?? makePanel()
        if !panel.isVisible {
            position = nil
            moveTowardTarget(snap: true)
            panel.orderFrontRegardless()
        }
        model.phase = phase
        startFollowing()
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            model.phase = .hidden
            // Let the spring-out transition play before removing the window.
            let fadeOut = DispatchWorkItem { [weak self] in
                guard let self, model.phase == .hidden else { return }
                panel?.orderOut(nil)
                followTimer?.invalidate()
                followTimer = nil
            }
            hideWork = fadeOut
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: fadeOut)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Show a transient message (e.g. "Learned …") and fade it away.
    func toast(_ message: String) {
        show(.toast(message))
        hide(after: 2.0)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: FlowOverlay(model: model, recorder: RecordingManager.shared))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func startFollowing() {
        guard followTimer == nil, AppSettings.shared.overlayPlacement == .followCursor else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { OverlayWindowManager.shared.moveTowardTarget(snap: false) }
        }
    }

    /// Spring-ish follow: ease the panel toward the target each frame.
    private func moveTowardTarget(snap: Bool) {
        guard let panel else { return }
        let target = targetOrigin()
        var next = target
        if !snap, let current = position {
            next = CGPoint(x: current.x + (target.x - current.x) * 0.25,
                           y: current.y + (target.y - current.y) * 0.25)
        }
        position = next
        panel.setFrameOrigin(next)
    }

    private func targetOrigin() -> CGPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)

        var origin: CGPoint
        switch AppSettings.shared.overlayPlacement {
        case .followCursor:
            // Pill hangs just below the pointer.
            origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
            if origin.y < visible.minY { origin.y = mouse.y + 24 } // flip above near the bottom edge
        case .bottomCenter:
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 30)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }
}
