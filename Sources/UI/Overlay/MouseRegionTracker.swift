import AppKit
import SwiftUI

/// Calls `update` whenever the mouse moves anywhere, over our windows or other apps. The
/// overlay panels use it to take clicks only over their visible content (toggling
/// `ignoresMouseEvents`) and to drive hover, since an ignored window gets no mouse events
/// of its own and this app is never frontmost.
@MainActor
final class MouseRegionTracker {
    private var monitors: [Any] = []
    private let update: @MainActor () -> Void

    init(update: @escaping @MainActor () -> Void) {
        self.update = update
    }

    func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [update] _ in
            MainActor.assumeIsolated { update() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [update] event in
            MainActor.assumeIsolated { update() }
            return event
        }) {
            monitors.append(local)
        }
        update()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

/// Hosting view for the overlay panels: the first click acts immediately (the panels are
/// never key), rather than just focusing the window.
class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
