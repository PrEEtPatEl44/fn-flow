import CoreGraphics
import SwiftUI

/// Pure geometry for overlay placement. Both overlay panels (resting pill, active
/// overlay) sit flush against the screen's visible edge; their content is inset by
/// `edgeInset`, so that one constant is the gap between the pill and the edge.
/// All rects/points are in screen coordinates (origin bottom-left).
enum OverlayLayout {
    /// Gap between the pill and the screen's visible edge (the dock or screen border).
    static let edgeInset: CGFloat = 6

    /// The thin resting pill; upright on the side edges.
    static func restingPillSize(for placement: OverlayPlacement) -> CGSize {
        placement.isVertical ? CGSize(width: 9, height: 44) : CGSize(width: 44, height: 9)
    }

    /// Center of the resting pill, used to decide which edge a drag lands on.
    static func pillCenter(for placement: OverlayPlacement, in visible: CGRect) -> CGPoint {
        let pill = restingPillSize(for: placement)
        switch placement {
        case .bottomCenter, .followCursor:
            return CGPoint(x: visible.midX, y: visible.minY + edgeInset + pill.height / 2)
        case .leftCenter:
            return CGPoint(x: visible.minX + edgeInset + pill.width / 2, y: visible.midY)
        case .rightCenter:
            return CGPoint(x: visible.maxX - edgeInset - pill.width / 2, y: visible.midY)
        }
    }

    /// Where content sits inside a panel: against the screen edge, growing inward.
    static func contentAlignment(for placement: OverlayPlacement) -> Alignment {
        switch placement {
        case .bottomCenter: .bottom
        case .leftCenter: .leading
        case .rightCenter: .trailing
        case .followCursor: .top
        }
    }

    /// Origin of a panel of `size` hugging the placement's edge, centered along it.
    static func panelOrigin(for placement: OverlayPlacement, in visible: CGRect, size: CGSize) -> CGPoint {
        let origin: CGPoint
        switch placement {
        case .bottomCenter, .followCursor:
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY)
        case .leftCenter:
            origin = CGPoint(x: visible.minX, y: visible.midY - size.height / 2)
        case .rightCenter:
            origin = CGPoint(x: visible.maxX - size.width, y: visible.midY - size.height / 2)
        }
        return clamp(origin, size: size, in: visible)
    }

    /// The pill only lives on the edge centers: a drop anywhere snaps to the nearest one.
    static func edge(nearest point: CGPoint, in visible: CGRect) -> OverlayPlacement {
        OverlayPlacement.edges.min { a, b in
            let pa = pillCenter(for: a, in: visible), pb = pillCenter(for: b, in: visible)
            return hypot(pa.x - point.x, pa.y - point.y) < hypot(pb.x - point.x, pb.y - point.y)
        } ?? .bottomCenter
    }

    static func clamp(_ origin: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, visible.minX), visible.maxX - size.width),
                y: min(max(origin.y, visible.minY), visible.maxY - size.height))
    }

    /// A SwiftUI rect in a panel's content (top-left origin) converted to screen coordinates.
    static func screenRect(_ rect: CGRect, inPanelFrame panel: CGRect) -> CGRect {
        CGRect(x: panel.minX + rect.minX, y: panel.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
