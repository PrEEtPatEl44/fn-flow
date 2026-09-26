import SwiftUI

/// A transient notification shown in the overlay's spot: a message, an optional action
/// button (e.g. "Undo"), and a countdown bar, after which it dismisses itself. Used for
/// "Transcript cancelled", errors, learned corrections, and anything similar later.
struct OverlayNotice: Identifiable, Equatable {
    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }

    let id = UUID()
    var message: String
    /// Optional SF Symbol shown before the message, with its tint.
    var icon: String?
    var tint: Color = .white
    var action: Action?
    var duration: TimeInterval = 4

    static func == (a: OverlayNotice, b: OverlayNotice) -> Bool { a.id == b.id }
}

struct OverlayNoticeView: View {
    let notice: OverlayNotice
    /// Called after the action runs, so the notice can dismiss immediately.
    let onAction: () -> Void

    @State private var remaining: CGFloat = 1

    /// Squared-off card rather than a pill.
    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        HStack(spacing: 12) {
            if let icon = notice.icon {
                Image(systemName: icon).foregroundStyle(notice.tint)
            }
            Text(notice.message)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action = notice.action {
                Button {
                    action.perform()
                    onAction()
                } label: {
                    Text(action.title)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, notice.action == nil ? 16 : 8)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(shape.fill(Color(white: 0.08)))
        .overlay(alignment: .bottom) {
            // Countdown: drains over the notice's lifetime.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.18))
                    Rectangle().fill(.white.opacity(0.9)).frame(width: geo.size.width * remaining)
                }
            }
            .frame(height: 3)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
        .onAppear {
            remaining = 1
            withAnimation(.linear(duration: notice.duration)) { remaining = 0 }
        }
    }
}
