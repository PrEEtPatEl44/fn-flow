import SwiftUI

enum OverlayPhase: Equatable {
    case hidden
    case listening
    case processing
    case success(title: String, notes: [String])
    case error(String)
    case toast(String)
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var phase: OverlayPhase = .hidden
}

/// The "Flow bar": a glowing pill that reacts to your voice, then morphs through
/// processing -> result, with notes shown as mini-toasts underneath.
struct FlowOverlay: View {
    @ObservedObject var model: OverlayModel
    @ObservedObject var recorder: RecordingManager

    var body: some View {
        VStack(spacing: 6) {
            if model.phase != .hidden {
                pill
                    .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.55)))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 14)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: model.phase)
        .allowsHitTesting(false)
    }

    private var notes: [String] {
        if case .success(_, let notes) = model.phase { return notes }
        return []
    }

    private var pill: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 18, height: 18)
            content
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
            Capsule()
                .fill(.black.opacity(0.35))
            Capsule()
                .strokeBorder(accent.opacity(0.6), lineWidth: 1)
        }
        .background {
            // Glow ring: breathes with the voice level while listening.
            Capsule()
                .fill(accent)
                .blur(radius: 18)
                .opacity(model.phase == .listening ? 0.35 + Double(recorder.level) * 0.5 : 0.35)
                .scaleEffect(model.phase == .listening ? 1.0 + CGFloat(recorder.level) * 0.15 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: recorder.level)
        }
        .fixedSize()
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .listening:
            Circle().fill(.red)
                .frame(width: 9, height: 9)
                .shadow(color: .red, radius: 4)
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .toast:
            Image(systemName: "sparkles").foregroundStyle(.cyan)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .listening:
            Waveform(level: recorder.level)
                .frame(width: 88, height: 22)
        case .processing:
            label("Transcribing…")
        case .success(let title, _):
            label(title)
        case .error(let message), .toast(let message):
            label(message)
        case .hidden:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .contentTransition(.opacity)
    }

    private var accent: Color {
        switch model.phase {
        case .listening: .blue
        case .processing: .purple
        case .success: .green
        case .error: .orange
        case .toast: .cyan
        case .hidden: .clear
        }
    }
}

/// Live bars driven by mic level, with a traveling wobble so it never looks static.
private struct Waveform: View {
    let level: Float
    private let bars = 11

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let wobble = (sin(t * 9 + Double(i) * 0.8) + 1) / 2
                    let center = 1 - abs(Double(i) - Double(bars - 1) / 2) / Double(bars)
                    let height = 3 + CGFloat(Double(level) * center * (0.45 + 0.55 * wobble)) * 19
                    Capsule()
                        .fill(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: height)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
