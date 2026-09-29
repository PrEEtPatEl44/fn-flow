import AppKit
import SwiftUI

// Building blocks for the app window, styled with `Theme` tokens.

/// A frosted card. Content inside renders in dark mode, so native controls (text fields,
/// pickers) match the dark-teal surface in both appearances.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Theme.cardText)
            .background(CardBackground())
            .environment(\.colorScheme, .dark)
    }
}

struct CardBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Theme.card)
            shape.strokeBorder(Theme.cardLine, lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .shadow(color: Color(rgb: 0x193638).opacity(0.14), radius: 14, y: 12)
    }
}

/// A settings card: a title bar, then rows separated by hairlines.
struct SettingsCard<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(title).font(Theme.Font.cardTitle)
                Spacer()
                trailing
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Rectangle().fill(Theme.cardLineSoft).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Theme.cardText)
        .background(CardBackground())
        .environment(\.colorScheme, .dark)
    }
}

extension SettingsCard where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// A row in a settings card: title and explanation on the left, a control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var divider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.Font.label)
                    if let detail {
                        Text(detail)
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.cardDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .frame(minHeight: 58)
            .padding(.vertical, 8)
            if divider { Rectangle().fill(Theme.cardLineSoft).frame(height: 1) }
        }
    }
}

/// "Fn-flow / Home" plus the page's actions.
struct PageHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 9) {
            Text("Fn-flow").font(Theme.Font.pageTitle).foregroundStyle(Theme.paneText)
            Text("/").font(Theme.Font.pageTitle).foregroundStyle(Theme.paneDim)
            Text(title).font(Theme.Font.pageTitle.weight(.semibold)).foregroundStyle(Theme.paneDim)
            Spacer()
            actions
        }
        .frame(minHeight: 40)
    }
}

/// An uppercase, monospaced label.
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.Font.micro).tracking(1.2)
    }
}

/// A small capsule label: an engine name, "Learned", a status.
struct Chip: View {
    enum Surface { case pane, card }
    let text: String
    var surface: Surface = .card
    @Environment(\.accent) private var accent

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(surface == .card ? accent.onCard : Theme.paneChipText)
            .background(Capsule().fill(surface == .card ? accent.soft : Theme.paneChip))
            .overlay(Capsule().strokeBorder(surface == .card ? accent.line : Theme.paneChipLine, lineWidth: 1))
    }
}

/// A keyboard key, e.g. the hotkey on the Dictate button.
struct Kbd: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(Theme.paneText)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
            .environment(\.colorScheme, .light)
    }
}

// MARK: - Buttons

struct FlowButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger }
    var kind: Kind = .secondary
    @Environment(\.accent) private var accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, accent: accent, isEnabled: isEnabled)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let accent: Accent
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 13)
                .frame(minHeight: 32)
                .foregroundStyle(foreground)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(background))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(border, lineWidth: 1))
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
                .pointerCursor(isEnabled)
        }

        private var foreground: Color {
            switch kind {
            case .primary: accent.ink
            case .danger: Theme.danger
            default: Theme.cardText
            }
        }

        private var background: Color {
            switch kind {
            case .primary: hovering ? Color(rgb: Accent.mix(accent.rgb, 0xFFFFFF, 0.82)) : accent.color
            case .quiet: hovering ? Theme.cardHigh : .clear
            case .danger: hovering ? Color(rgb: 0x3B2A27) : Theme.cardHigh
            case .secondary: hovering ? Color(rgb: 0x4A6466).opacity(0.95) : Theme.cardHigh
            }
        }

        private var border: Color {
            switch kind {
            case .primary: accent.color
            case .quiet: hovering ? Theme.cardLine : .clear
            case .danger: hovering ? Color(rgb: 0x6A443C) : Theme.cardLine
            case .secondary: hovering ? accent.line : Theme.cardLine
            }
        }
    }
}

/// A square icon button (copy, delete, search) with a hover wash.
struct IconButton: View {
    let symbol: String
    let help: String
    var surface: Chip.Surface = .pane
    var size: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(hovering ? (surface == .pane ? Theme.paneText : Theme.cardText) : (surface == .pane ? Theme.paneMuted : Theme.cardMuted))
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? (surface == .pane ? Theme.paneHover : Theme.cardHigh) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

extension View {
    /// Shows the pointing hand over a clickable element (not over native controls or text).
    func pointerCursor(_ enabled: Bool = true) -> some View {
        modifier(PointerCursor(enabled: enabled))
    }
}

private struct PointerCursor: ViewModifier {
    let enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(enabled ? .link : nil)
        } else {
            // Balance every push with a pop, even if the view goes away while hovered.
            content
                .onHover { set($0 && enabled) }
                .onChange(of: enabled) { _, on in if !on { set(false) } }
                .onDisappear { set(false) }
        }
    }

    private func set(_ on: Bool) {
        guard on != pushed else { return }
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        pushed = on
    }
}

// MARK: - Controls

/// The concept's switch: an accent-filled track when on.
struct FlowToggleStyle: ToggleStyle {
    @Environment(\.accent) private var accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? accent.color : Theme.cardLine)
                Circle()
                    .fill(configuration.isOn ? accent.ink : Color(rgb: 0xE8EDE3))
                    .padding(3)
            }
            .frame(width: 36, height: 21)
            .animation(.snappy(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// A text field on a card.
struct FlowFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 11)
            .frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.cardInput))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.cardLine, lineWidth: 1))
    }
}

/// A thin progress bar in the accent color.
struct ProgressBar: View {
    let value: Double
    @Environment(\.accent) private var accent

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.cardLine)
                Capsule().fill(accent.color).frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.15), value: value)
    }
}

/// Lays children out left to right, wrapping onto new lines (term chips, word chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].items.isEmpty
            rows[rows.count - 1].items.append(index)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

/// Side by side when the available width reaches `breakpoint`, stacked otherwise. (Unlike
/// `ViewThatFits`, this doesn't depend on ideal sizes, which for wrapping text are one long line.)
struct AdaptiveStack<Content: View>: View {
    let breakpoint: CGFloat
    @ViewBuilder var content: (_ wide: Bool) -> Content
    @State private var width: CGFloat?

    var body: some View {
        content((width ?? breakpoint) >= breakpoint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in width = new }
            })
    }
}
