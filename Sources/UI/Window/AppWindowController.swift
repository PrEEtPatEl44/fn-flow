import AppKit
import SwiftUI

/// The app window's sections, shown in the rail.
enum AppSection: String, CaseIterable, Identifiable {
    case home, insights, wordBook, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .insights: "Insights"
        case .wordBook: "Word Book"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .insights: "chart.bar.xaxis"
        case .wordBook: "book.closed"
        case .settings: "gearshape"
        }
    }
}

/// A card in Settings that other parts of the app can link to (e.g. an error's "Open Settings").
enum SettingsAnchor: String {
    case engine, access
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published var section: AppSection = .home
    @Published var settingsAnchor: SettingsAnchor?
    @Published var railExpanded = false
}

/// Owns the app window: Home (history), Insights, Word Book, and Settings.
@MainActor
final class AppWindowController {
    static let shared = AppWindowController()

    let navigation = AppNavigation()
    private var window: NSWindow?

    func show(_ section: AppSection? = nil, anchor: SettingsAnchor? = nil) {
        if let section { navigation.section = section }
        if let anchor {
            navigation.section = .settings
            navigation.settingsAnchor = anchor
        }
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Fn-flow"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title bar as tall as our top bar, which centers
        // the traffic lights in it.
        window.toolbar = NSToolbar(identifier: "main")
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(Theme.chrome)
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("FnFlowMainWindow")
        window.contentView = NSHostingView(rootView: AppShell(navigation: navigation))
        if !window.setFrameUsingName("FnFlowMainWindow") { window.center() }
        return window
    }
}
