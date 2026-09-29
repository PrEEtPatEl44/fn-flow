import AppKit
import Combine
import SwiftUI

/// The small "resting pill" that stays on screen between dictations (like Wispr's Flow
/// bar). Hovering expands it into a mic button with a "Dictate fn" hint; clicking starts a
/// hands-free dictation (finish with ✓ or the hotkey). It lives only on the bottom/left/right
/// edge centers; dragging it switches edges, snapping to the nearest one on release.
@MainActor
final class IdlePillController {
    static let shared = IdlePillController()

    private var panel: NSPanel?
    private let model = IdlePillModel()
    private var cancellables: Set<AnyCancellable> = []
    private var suspended = false
    private lazy var mouseTracker = MouseRegionTracker { [weak self] in self?.updateHover() }

    private var settings: AppSettings { .shared }

    private var shouldShow: Bool {
        settings.showIdlePill && settings.overlayPlacement != .followCursor && !suspended
    }

    /// Room for the expanded mic button plus its hint, beside or above it.
    static func panelSize(for placement: OverlayPlacement) -> CGSize {
        placement.isVertical ? CGSize(width: 200, height: 110) : CGSize(width: 220, height: 104)
    }

    func start() {
        // @Published fires in willSet, so hop to the next main-queue turn to read new values.
        Publishers.Merge3(
            settings.$overlayPlacement.map { _ in () },
            settings.$showIdlePill.map { _ in () },
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { _ in MainActor.assumeIsolated { IdlePillController.shared.refresh() } }
        .store(in: &cancellables)
        refresh()
    }

    /// Hidden while the active overlay is up; it takes the pill's place.
    func suspend() {
        suspended = true
        refresh()
    }

    func resume() {
        suspended = false
        refresh()
    }

    func refresh() {
        guard shouldShow else {
            model.isHovering = false
            panel?.orderOut(nil)
            mouseTracker.stop()
            return
        }
        let panel = panel ?? makePanel()
        moveToEdge(animated: panel.isVisible)
        panel.orderFrontRegardless()
        mouseTracker.start()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize(for: settings.overlayPlacement)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = PillHostingView(rootView: IdlePillView(model: model))
        host.onClick = { FlowController.shared.begin(mode: .handsFree) }
        host.onDrop = { [weak self] point in self?.drop(at: point) }
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func moveToEdge(animated: Bool) {
        guard let panel, let screen = NSScreen.overlayScreen() else { return }
        let size = Self.panelSize(for: settings.overlayPlacement)
        let origin = OverlayLayout.panelOrigin(for: settings.overlayPlacement, in: screen.visibleFrame, size: size)
        let frame = NSRect(origin: origin, size: size)
        if frame != panel.frame { panel.setFrame(frame, display: true, animate: animated) }
    }

    /// Hover (and clickability) follows the pointer: the thin pill has a generous hot zone,
    /// and once expanded the whole button + hint stays active.
    private func updateHover() {
        guard let panel, panel.isVisible, NSEvent.pressedMouseButtons == 0 else { return }
        let rect = model.isHovering ? model.expandedRect.insetBy(dx: -8, dy: -8) : model.restingRect.insetBy(dx: -12, dy: -12)
        let hovering = OverlayLayout.screenRect(rect, inPanelFrame: panel.frame).contains(NSEvent.mouseLocation)
        if hovering != model.isHovering { model.isHovering = hovering }
        if panel.ignoresMouseEvents == hovering { panel.ignoresMouseEvents = !hovering }
    }

    /// Wherever it's dropped, the pill snaps to the nearest edge center.
    private func drop(at point: CGPoint) {
        guard let screen = NSScreen.overlayScreen() else { return }
        let edge = OverlayLayout.edge(nearest: point, in: screen.visibleFrame)
        if edge == settings.overlayPlacement { moveToEdge(animated: true) } // same edge: slide back
        settings.overlayPlacement = edge
    }
}

extension NSScreen {
    /// Edge placements use the primary (menu bar) screen.
    static func overlayScreen() -> NSScreen? { screens.first }
}

@MainActor
final class IdlePillModel: ObservableObject {
    @Published var isHovering = false
    /// Content frames in panel coordinates, for hover hit-testing.
    var restingRect: CGRect = .zero
    var expandedRect: CGRect = .zero
}

/// A click starts dictation; a drag (past a few points) moves the pill and drops it.
/// Right-click falls through to SwiftUI's context menu.
private final class PillHostingView: OverlayHostingView<IdlePillView> {
    var onClick: (() -> Void)?
    var onDrop: ((CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        let origin = window.frame.origin
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type != .leftMouseUp {
            let p = NSEvent.mouseLocation
            if !dragged, hypot(p.x - start.x, p.y - start.y) > 4 { dragged = true }
            if dragged { window.setFrameOrigin(CGPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y)) }
        }
        if dragged { onDrop?(NSEvent.mouseLocation) } else { onClick?() }
    }
}

private struct IdlePillView: View {
    @ObservedObject var model: IdlePillModel
    @ObservedObject private var settings = AppSettings.shared

    private var placement: OverlayPlacement { settings.overlayPlacement }

    var body: some View {
        Group {
            if model.isHovering {
                expanded
                    .transition(.scale(scale: 0.7, anchor: anchor).combined(with: .opacity))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.expandedRect = $0 }
            } else {
                resting
                    .transition(.opacity)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.restingRect = $0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: OverlayLayout.contentAlignment(for: placement))
        .padding(OverlayLayout.edgeInset)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.isHovering)
        .contextMenu {
            Picker("Position", selection: $settings.overlayPlacement) {
                ForEach(OverlayPlacement.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            Button("Hide Resting Pill") { settings.showIdlePill = false }
            Button("Settings…") { AppWindowController.shared.show(.settings) }
        }
    }

    private var anchor: UnitPoint {
        switch placement {
        case .leftCenter: .leading
        case .rightCenter: .trailing
        default: .bottom
        }
    }

    private var resting: some View {
        let size = OverlayLayout.restingPillSize(for: placement)
        return Capsule()
            .fill(.black.opacity(0.6))
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .frame(width: size.width, height: size.height)
    }

    /// The mic button against the edge, with the hint on the screen-center side.
    @ViewBuilder private var expanded: some View {
        switch placement {
        case .leftCenter: HStack(spacing: 6) { micButton; hint }
        case .rightCenter: HStack(spacing: 6) { hint; micButton }
        default: VStack(spacing: 6) { hint; micButton }
        }
    }

    private var micButton: some View {
        let vertical = placement.isVertical
        return Image(systemName: "mic.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: vertical ? 30 : 48, height: vertical ? 48 : 30)
            .background(Capsule().fill(Color(white: 0.16)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }

    private var hint: some View {
        (Text("Dictate ") + Text(hotkeyLabel).fontWeight(.bold))
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.08)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .fixedSize()
    }

    /// "fn" for the Globe key, like the keycap; otherwise the hotkey's display name.
    private var hotkeyLabel: String {
        settings.hotkey.keyCode == 0x3F ? "fn" : settings.hotkey.displayName
    }
}
