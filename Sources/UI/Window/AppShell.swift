import AppKit
import SwiftUI

/// The window's frame: a top bar (sidebar toggle, engine status), the icon rail, and the
/// inset pane that shows the current section over the cloud sky.
struct AppShell: View {
    @ObservedObject var navigation: AppNavigation
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            TopBar(navigation: navigation)
            HStack(spacing: 0) {
                Rail(navigation: navigation)
                Pane(navigation: navigation)
            }
        }
        .background(Theme.chrome)
        .ignoresSafeArea()
        .environment(\.accent, Accent(rgb: settings.accentRGB))
        .tint(Accent(rgb: settings.accentRGB).color)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        HStack(spacing: 14) {
            // Room for the traffic lights.
            Spacer().frame(width: 72)
            ChromeButton(symbol: "sidebar.left", help: navigation.railExpanded ? "Collapse sidebar" : "Expand sidebar") {
                withAnimation(.snappy(duration: 0.18)) { navigation.railExpanded.toggle() }
            }
            Spacer()
            EngineIndicator(navigation: navigation)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(WindowDragArea())
    }
}

private struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 30, height: 30)
                .foregroundStyle(hovering ? Theme.chromeText : Theme.chromeMuted)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.railHover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

/// Lets the top bar drag the window like a title bar.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Rail

private struct Rail: View {
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                RailItem(section: section, shortcut: index + 1, selected: navigation.section == section, expanded: navigation.railExpanded) {
                    navigation.section = section
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Spacer()
            Button { navigation.section = .home } label: {
                Circle()
                    .fill(AngularGradient(colors: [
                        Color(rgb: 0xF16AB4), Color(rgb: 0x8683FB), Color(rgb: 0x47B6DD),
                        Color(rgb: 0x7BD493), Color(rgb: 0xF4D159), Color(rgb: 0xF16AB4),
                    ], center: .center))
                    .frame(width: 25, height: 25)
                    .shadow(color: Color(rgb: 0xDCC7EB).opacity(0.25), radius: 7)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Fn-flow Home")
            .frame(maxWidth: .infinity, alignment: navigation.railExpanded ? .leading : .center)
        }
        .padding(.horizontal, 7)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(width: navigation.railExpanded ? 184 : 58)
    }
}

private struct RailItem: View {
    let section: AppSection
    let shortcut: Int
    let selected: Bool
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: section.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 22)
                if expanded {
                    Text(section.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, expanded ? 11 : 0)
            .frame(width: expanded ? nil : 44, height: 44)
            .frame(maxWidth: expanded ? .infinity : nil)
            .foregroundStyle(selected || hovering ? .white : Theme.railIcon)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? Theme.railSelected : hovering ? Theme.railHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "⌘\(shortcut)" : "\(section.title) (⌘\(shortcut))")
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovering = $0 }
        .pointerCursor()
    }
}

// MARK: - Pane

private struct Pane: View {
    @ObservedObject var navigation: AppNavigation

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.window, style: .continuous)
        ZStack {
            CloudWallpaper()
            if navigation.section == .home {
                // Home keeps its header and Insights card in place and scrolls only the
                // dictation list, so it fills the pane instead of sitting in a scroll view.
                HomeView(navigation: navigation)
                    .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 44)
                    .padding(.top, 26)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        content
                            .frame(maxWidth: 1100)
                            .padding(.horizontal, 44)
                            .padding(.top, 26)
                            .padding(.bottom, 44)
                            .frame(maxWidth: .infinity)
                            .id(navigation.section)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: navigation.settingsAnchor) { _, anchor in
                        scroll(proxy, to: anchor)
                    }
                    .onAppear { scroll(proxy, to: navigation.settingsAnchor) }
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.frameLine, lineWidth: 1))
        // The sky is always bright, so text on it keeps its dark colors in dark mode too.
        // (Cards switch themselves to dark.)
        .environment(\.colorScheme, .light)
        .padding(.trailing, 9)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        switch navigation.section {
        case .home: EmptyView()
        case .insights: InsightsView()
        case .wordBook: WordBookView()
        case .settings: SettingsPage()
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to anchor: SettingsAnchor?) {
        guard let anchor else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(anchor, anchor: .top) }
            navigation.settingsAnchor = nil
        }
    }
}

// MARK: - Engine status

/// "Ready" / "Listening" / "Needs attention", with each part's state in a popover.
private struct EngineIndicator: View {
    @ObservedObject var navigation: AppNavigation
    @ObservedObject private var flow = FlowController.shared
    @ObservedObject private var models = ModelManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var permissions = PermissionsMonitor.shared
    @State private var showing = false
    @State private var hovering = false
    @State private var pulse = false
    @Environment(\.accent) private var accent

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(issues.isEmpty ? accent.color : Theme.warning)
                    .frame(width: 7, height: 7)
                    .shadow(color: issues.isEmpty ? accent.color : Theme.warning, radius: busy && pulse ? 6 : 3)
                Text(status).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .foregroundStyle(hovering || showing ? Theme.chromeText : Theme.chromeMuted)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering || showing ? Theme.railHover : Color(rgb: 0x2C3031)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help("Local engine status: click for details")
        .accessibilityLabel("Engine status: \(status)")
        .popover(isPresented: $showing, arrowEdge: .bottom) { popover }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Local engine").font(.system(size: 12, weight: .bold))
                Spacer()
                Button {
                    showing = false
                    navigation.settingsAnchor = .engine
                    navigation.section = .settings
                } label: {
                    Label("Settings", systemImage: "arrow.right").labelStyle(TrailingIcon())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent.onCard)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Open the Local engine settings")
            }
            .padding(.bottom, 8)
            step("Microphone", permissions.microphone ? "Ready" : "Permission needed")
            step("Speech · Parakeet", models.speechStatus.label)
            step("Cleanup · \(settings.refineWithLLM ? settings.llmModel : "Rules")",
                 settings.refineWithLLM ? models.cleanupStatus.label : "Built-in rules")
            step("Paste access", !settings.pasteAtCursor ? "Clipboard only" : permissions.accessibility ? "Ready" : "Permission needed")
            if !issues.isEmpty {
                Text(issues.joined(separator: " "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }
        }
        .padding(15)
        .frame(width: 300)
        .foregroundStyle(Theme.cardText)
        .background(Theme.card)
        .environment(\.colorScheme, .dark)
    }

    private func step(_ name: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.cardLineSoft).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text(name).foregroundStyle(Theme.cardMuted)
                Spacer()
                Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
            }
            .font(.system(size: 11))
            .padding(.vertical, 9)
        }
    }

    private var issues: [String] {
        var issues: [String] = []
        if !permissions.microphone { issues.append("Microphone permission is needed to dictate.") }
        switch models.speechStatus {
        case .notInstalled: issues.append("Download the speech model in Settings.")
        case .failed(let why): issues.append(why)
        default: break
        }
        if settings.pasteAtCursor, !permissions.accessibility { issues.append("Accessibility permission is needed to paste.") }
        return issues
    }

    private var busy: Bool {
        flow.phase != .idle || models.speechStatus.isBusy || (settings.refineWithLLM && models.cleanupStatus.isBusy)
    }

    private var status: String {
        if !issues.isEmpty { return "Needs attention" }
        switch flow.phase {
        case .listening: return "Listening"
        case .processing: return "Processing"
        case .idle: break
        }
        if case .downloading = models.speechStatus { return "Downloading" }
        if models.speechStatus.isBusy { return "Preparing" }
        return "Ready"
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.title; configuration.icon.imageScale(.small) }
    }
}

/// Polls the Accessibility and Microphone grants (macOS has no change notification for them)
/// while the app window is open.
@MainActor
final class PermissionsMonitor: ObservableObject {
    static let shared = PermissionsMonitor()

    @Published private(set) var accessibility = AccessibilityManager.shared.isTrusted
    @Published private(set) var microphone = RecordingManager.micAuthorized
    @Published private(set) var hotkeyActive = HotkeyManager.shared.isRunning
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { PermissionsMonitor.shared.refresh() }
        }
    }

    func refresh() {
        let accessibility = AccessibilityManager.shared.isTrusted
        let microphone = RecordingManager.micAuthorized
        let hotkeyActive = HotkeyManager.shared.isRunning
        if accessibility != self.accessibility { self.accessibility = accessibility }
        if microphone != self.microphone { self.microphone = microphone }
        if hotkeyActive != self.hotkeyActive { self.hotkeyActive = hotkeyActive }
    }
}
