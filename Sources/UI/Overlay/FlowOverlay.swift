import SwiftUI

enum OverlayPhase: Equatable {
    case hidden
    case listening
    case processing
    case success(title: String, notes: [String])
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var phase: OverlayPhase = .hidden
    /// Shown in place of the pill (e.g. "Transcript cancelled · Undo").
    @Published var notice: OverlayNotice?
    /// Where content sits in the panel: against the screen edge, growing inward.
    @Published var alignment: Alignment = .top
    /// The visible, clickable content in panel coordinates; everything else clicks through.
    var interactiveRect: CGRect = .zero
}

/// The "Flow bar". While listening: [✕] waveform [✓], where ✕ cancels and ✓ finishes. Then
/// processing -> result, with notes as mini-toasts. Horizontal at the bottom and under the
/// cursor; upright on the side edges, where text sits beside the pill (never rotated).
struct FlowOverlay: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var recorder: RecordingManager
    let onNoticeAction: () -> Void

    private var isVertical: Bool { model.alignment == .leading || model.alignment == .trailing }

    var body: some View {
        Group {
            if let notice = model.notice {
                OverlayNoticeView(notice: notice, onAction: onNoticeAction)
                    .id(notice.id)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .reportFrame(to: model)
            } else if isVertical {
                verticalLayout
            } else {
                horizontalLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.alignment)
        .padding(OverlayLayout.edgeInset)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: model.phase)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: model.notice)
    }

    private var horizontalLayout: some View {
        let notesAbove = model.alignment == .bottom
        return VStack(spacing: 6) {
            if model.phase != .hidden {
                if notesAbove { labels(notes, alignment: .center) }
                pill
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .reportFrame(to: model)
                if !notesAbove { labels(notes, alignment: .center) }
            }
        }
    }

    /// Pill hugs the screen edge; status text and notes sit beside it, toward the center.
    private var verticalLayout: some View {
        let onLeft = model.alignment == .leading
        return HStack(spacing: 8) {
            if model.phase != .hidden {
                if !onLeft { labels(sideLabels, alignment: .trailing) }
                pill
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .reportFrame(to: model)
                if onLeft { labels(sideLabels, alignment: .leading) }
            }
        }
    }

    private func labels(_ texts: [String], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            ForEach(texts, id: \.self) { text in
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.7)))
                    .transition(.opacity)
            }
        }
    }

    private var notes: [String] {
        if case .success(_, let notes) = model.phase { return notes }
        return []
    }

    /// In the upright layout the pill has no room for text, so the status moves out too.
    private var sideLabels: [String] {
        switch model.phase {
        case .processing: ["Transcribing…"]
        case .success(let title, let notes): [title] + notes
        case .listening, .hidden: []
        }
    }

    // MARK: Pill

    private var pill: some View {
        let stack = isVertical
            ? AnyLayout(VStackLayout(spacing: 7))
            : AnyLayout(HStackLayout(spacing: 7))
        return stack {
            switch model.phase {
            case .listening:
                circleButton("xmark", help: "Cancel (Esc)", filled: false) {
                    FlowController.shared.cancel(notify: true)
                }
                Waveform(level: recorder.level, axis: isVertical ? .vertical : .horizontal)
                    .frame(width: isVertical ? 16 : 54, height: isVertical ? 54 : 16)
                circleButton("checkmark", help: "Finish and paste", filled: true) {
                    FlowController.shared.finish()
                }
            case .processing:
                ProgressView().controlSize(.mini).tint(.white)
                    .frame(width: 15, height: 15)
                if !isVertical { label("Transcribing…") }
            case .success(let title, _):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .frame(width: 15, height: 15)
                if !isVertical { label(title) }
            case .hidden:
                EmptyView()
            }
        }
        .padding(model.phase == .listening ? 4 : 8)
        .padding(isVertical ? .vertical : .horizontal, model.phase == .listening ? 0 : 4)
        .background {
            Capsule().fill(Color(white: 0.08))
            Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .background {
            // Glow: breathes with the voice level while listening.
            Capsule()
                .fill(accent)
                .blur(radius: 10)
                .opacity(model.phase == .listening ? 0.25 + Double(recorder.level) * 0.5 : 0.3)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: recorder.level)
        }
        .fixedSize()
    }

    private func circleButton(_ symbol: String, help: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(filled ? .black : .white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(filled ? .white : .white.opacity(0.22)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .contentTransition(.opacity)
    }

    private var accent: Color {
        switch model.phase {
        case .listening: Accent(rgb: AppSettings.shared.accentRGB).color
        case .processing: .purple
        case .success: .green
        case .hidden: .clear
        }
    }
}

private extension View {
    /// Records this view's frame (panel coordinates) as the overlay's clickable area.
    func reportFrame(to model: OverlayModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.interactiveRect = $0 }
    }
}

/// Live bars driven by mic level, with a traveling wobble so it never looks static.
/// Horizontal: vertical bars side by side. Vertical: horizontal bars stacked.
struct Waveform: View {
    let level: Float
    let axis: Axis
    private let bars = 11

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 2))
                : AnyLayout(VStackLayout(alignment: .center, spacing: 2))
            layout {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = (sin(t * 9 + Double(i) * 0.8) + 1) / 2
                    let center = 1 - abs(Double(i) - Double(bars - 1) / 2) / Double(bars)
                    let length = 3 + CGFloat(Double(level) * center * (0.45 + 0.55 * wobble)) * 12
                    Capsule()
                        .fill(.white)
                        .frame(width: axis == .horizontal ? 2.5 : length, height: axis == .horizontal ? length : 2.5)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
