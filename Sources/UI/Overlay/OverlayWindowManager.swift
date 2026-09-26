import AppKit
import SwiftUI

/// Hosts `FlowOverlay` in a non-activating panel that floats above every app (and
/// full-screen spaces). It takes the resting pill's place at a screen edge, or glides after
/// the mouse cursor. Only the visible pill/notice takes clicks; the rest of the panel is
/// click-through. Clicking it never takes focus from the app being dictated into.
@MainActor
final class OverlayWindowManager {
    static let shared = OverlayWindowManager()

    private let model = OverlayModel()
    private var panel: NSPanel?
    private var followTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var position: CGPoint?
    private lazy var mouseTracker = MouseRegionTracker { [weak self] in self?.updateClickThrough() }

    /// Tall enough for the upright pill on the side edges.
    private let size = CGSize(width: 420, height: 200)

    func show(_ phase: OverlayPhase) {
        present()
        model.notice = nil
        model.phase = phase
    }

    /// Shows a notice in the overlay's spot; it dismisses itself after `notice.duration`.
    func notify(_ notice: OverlayNotice) {
        present()
        model.phase = .hidden
        model.notice = notice
        hide(after: notice.duration)
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            model.phase = .hidden
            model.notice = nil
            // Let the spring-out transition play before removing the window.
            let fadeOut = DispatchWorkItem { [weak self] in
                guard let self, model.phase == .hidden, model.notice == nil else { return }
                panel?.orderOut(nil)
                followTimer?.invalidate()
                followTimer = nil
                mouseTracker.stop()
                IdlePillController.shared.resume()
            }
            hideWork = fadeOut
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: fadeOut)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func present() {
        hideWork?.cancel()
        let panel = panel ?? makePanel()
        guard !panel.isVisible else { return }
        model.alignment = OverlayLayout.contentAlignment(for: AppSettings.shared.overlayPlacement)
        position = nil
        moveTowardTarget(snap: true)
        IdlePillController.shared.suspend()
        panel.orderFrontRegardless()
        mouseTracker.start()
        startFollowing()
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
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let overlay = FlowOverlay(model: model, recorder: RecordingManager.shared) { [weak self] in
            // A notice action that started something new (e.g. Undo -> processing) keeps
            // the overlay; otherwise dismiss right away.
            guard let self, model.phase == .hidden else { return }
            hide()
        }
        let host = OverlayHostingView(rootView: overlay)
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Take clicks only while the pointer is over the visible pill/notice.
    private func updateClickThrough() {
        guard let panel, panel.isVisible else { return }
        let hit = OverlayLayout.screenRect(model.interactiveRect, inPanelFrame: panel.frame).insetBy(dx: -2, dy: -2)
        let over = model.phase != .hidden || model.notice != nil ? hit.contains(NSEvent.mouseLocation) : false
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
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
        let settings = AppSettings.shared
        guard settings.overlayPlacement == .followCursor else {
            let visible = NSScreen.overlayScreen()?.visibleFrame ?? NSRect(origin: .zero, size: size)
            return OverlayLayout.panelOrigin(for: settings.overlayPlacement, in: visible, size: size)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        // Pill hangs just below the pointer; flip above it near the bottom edge.
        var origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        if origin.y < visible.minY { origin.y = mouse.y + 24 }
        return OverlayLayout.clamp(origin, size: size, in: visible)
    }
}
