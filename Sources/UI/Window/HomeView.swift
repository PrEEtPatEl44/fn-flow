import AppKit
import SwiftUI

/// Recent dictations (searchable, filterable by app, expandable to what Parakeet heard) and
/// a preview of Insights.
struct HomeView: View {
    @ObservedObject var navigation: AppNavigation
    @State private var query = ""
    @State private var appFilter: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Home") { EmptyView() }
                Greeting()
            }
            AdaptiveStack(breakpoint: 740) { wide in
                if wide {
                    HStack(alignment: .top, spacing: 32) {
                        RecentDictations(query: $query, appFilter: $appFilter)
                        InsightsPreview(navigation: navigation).frame(width: 272)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        InsightsPreview(navigation: navigation)
                        RecentDictations(query: $query, appFilter: $appFilter)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// "Good morning, Preet": by time of day, with the first name from the Mac account.
private struct Greeting: View {
    private static let firstName = NSFullUserName().split(separator: " ").first.map(String.init)

    var body: some View {
        // Re-evaluated every minute, so it turns to "Good afternoon" without reopening.
        TimelineView(.everyMinute) { context in
            Text([Self.salutation(at: context.date), Self.firstName].compactMap { $0 }.joined(separator: ", "))
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.6)
                .foregroundStyle(Theme.paneText)
        }
    }

    static func salutation(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Working late"
        }
    }
}

// MARK: - Recent dictations

/// Search and the app filter (with Clear History), on the first day header's line.
private struct HistoryTools: View {
    @Binding var query: String
    @Binding var appFilter: String?
    /// Brings the tools into view when ⌘F is pressed while they're scrolled away.
    let reveal: () -> Void
    @ObservedObject private var history = DictationHistory.shared
    @State private var searching = false
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var apps: [String] {
        Array(Set(history.entries.compactMap(\.app))).sorted()
    }

    var body: some View {
        HStack(spacing: 6) {
            if searching {
                TextField("Search dictations", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.paneText)
                    .focused($searchFocused)
                    .padding(.horizontal, 10)
                    .frame(width: 210, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paneChip))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.paneChipLine, lineWidth: 1))
                    .onExitCommand { closeSearch() }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            IconButton(symbol: searching ? "xmark" : "magnifyingglass", help: searching ? "Close search (Esc)" : "Search dictations (⌘F)") {
                searching ? closeSearch() : openSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            Menu {
                Picker("App", selection: $appFilter) {
                    Text("All apps").tag(String?.none)
                    ForEach(apps, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Clear History…", role: .destructive) { confirmClear = true }
                    .disabled(history.entries.isEmpty)
            } label: {
                Image(systemName: appFilter == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(appFilter == nil ? Theme.paneMuted : Theme.paneText)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .help(appFilter.map { "Showing \($0) only. Filter by app, or clear history" } ?? "Filter by app, or clear history")
        }
        .confirmationDialog("Delete all \(history.entries.count) dictations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("This also resets Insights. It can't be undone.")
        }
    }

    private func openSearch() {
        reveal()
        withAnimation(.snappy(duration: 0.19)) { searching = true }
        DispatchQueue.main.async { searchFocused = true }
    }

    private func closeSearch() {
        withAnimation(.snappy(duration: 0.19)) {
            searching = false
            query = ""
        }
    }
}

/// Dictations grouped under "Today", "Yesterday", then dates. The only part of Home that scrolls.
private struct RecentDictations: View {
    @Binding var query: String
    @Binding var appFilter: String?
    @ObservedObject private var history = DictationHistory.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var expanded: UUID?

    private var rows: [DictationHistory.Entry] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return history.entries.filter { entry in
            (appFilter == nil || entry.app == appFilter)
                && (term.isEmpty || "\(entry.text) \(entry.raw) \(entry.app ?? "")".lowercased().contains(term))
        }
    }

    /// Newest day first; entries keep their order within a day.
    private var days: [(day: Date, entries: [DictationHistory.Entry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day]!.sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy (history holds at most 200), so the tools keep their state and ⌘F
                // after scrolling past them.
                VStack(alignment: .leading, spacing: 0) {
                    let tools = HistoryTools(query: $query, appFilter: $appFilter) {
                        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(Self.top, anchor: .top) }
                    }
                    if rows.isEmpty {
                        HStack { Spacer(); tools }.id(Self.top).padding(.bottom, 10)
                        emptyState
                    } else {
                        ForEach(days, id: \.day) { group in
                            let first = group.day == days.first?.day
                            HStack(spacing: 6) {
                                header(group.day)
                                if first {
                                    Spacer()
                                    tools
                                }
                            }
                            .frame(minHeight: first ? 32 : nil)
                            .padding(.top, first ? 0 : 26)
                            .padding(.bottom, 4)
                            .id(first ? AnyHashable(Self.top) : AnyHashable(group.day))
                            ForEach(group.entries) { entry in
                                HistoryRow(entry: entry, expanded: expanded == entry.id) {
                                    withAnimation(.snappy(duration: 0.2)) { expanded = expanded == entry.id ? nil : entry.id }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 44)
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private static let top = "top"

    private func header(_ day: Date) -> some View {
        Text(Self.title(for: day))
            .font(Theme.Font.label)
            .foregroundStyle(Theme.paneDim)
    }

    @ViewBuilder private var emptyState: some View {
        let filtered = !query.isEmpty || appFilter != nil
        VStack(spacing: 6) {
            Image(systemName: filtered ? "magnifyingglass" : "waveform")
                .font(.system(size: 20))
            Text(filtered ? "No dictations match." : "No dictations yet.")
                .font(Theme.Font.body.weight(.semibold))
            Text(filtered ? "Try another search or app." : "Hold \(settings.hotkey.displayName) and speak. Each dictation shows up here.")
                .font(Theme.Font.small)
        }
        .foregroundStyle(Theme.paneMuted)
        .frame(maxWidth: .infinity)
        .padding(30)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.paneLine, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    /// "Today", "Yesterday", "Wednesday, Sep 24", or with the year once it's a past year.
    static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return day.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct HistoryRow: View {
    let entry: DictationHistory.Entry
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(entry.text)
                        .font(Theme.Font.body)
                        .lineSpacing(3)
                        .foregroundStyle(Theme.paneText)
                        .lineLimit(expanded ? nil : 3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        if let app = entry.app { Text(app) }
                        Chip(text: entry.engine.rawValue, surface: .pane).help(engineHelp)
                        if let timings = entry.timings {
                            Text(DictationTimings.format(timings.total))
                                .monospacedDigit()
                                .help("From finishing the dictation to the text being \(entry.pasted ? "pasted" : "copied")")
                        }
                        if !entry.pasted { Text("Copied only") }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.paneDim)
                    if expanded { details }
                }

                HStack(spacing: 2) {
                    IconButton(symbol: expanded ? "chevron.up" : "chevron.down", help: expanded ? "Hide details" : "Show what Parakeet heard", action: toggle)
                    IconButton(symbol: "doc.on.doc", help: "Copy text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    }
                    IconButton(symbol: "trash", help: "Delete this dictation") { DictationHistory.shared.delete(entry) }
                }
                .opacity(hovering || expanded ? 1 : 0.45)
            }
            .padding(.vertical, 16)
            Rectangle().fill(Theme.paneLine).frame(height: 1)
        }
        .onHover { hovering = $0 }
    }

    /// What Parakeet heard, anything the dictionary changed, and where the time went.
    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: "Heard").foregroundStyle(Theme.paneDim)
                Text(entry.raw.isEmpty ? "—" : entry.raw)
                    .font(Theme.Font.body)
                    .lineSpacing(3)
                    .foregroundStyle(Theme.paneMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !entry.notes.isEmpty {
                Text(entry.notes.joined(separator: " · "))
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.paneMuted)
            }
            if let t = entry.timings {
                let f = DictationTimings.format
                Text("Speech-to-text \(f(t.transcription)) · Cleanup \(f(t.cleanup)) · \(entry.pasted ? "Paste" : "Copy") \(f(t.delivery)) · \(String(format: "%.1f s", t.audio)) of audio")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.paneDim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paneHover))
        .transition(.opacity)
    }

    private var engineHelp: String {
        switch entry.engine {
        case .nemotron: "Cleaned up by Nemotron"
        case .mixed: "Nemotron cleaned up part of this; rules handled sections where its output wasn't faithful"
        case .rules: "Rule-based cleanup (Nemotron off, unavailable, or its output wasn't faithful)"
        }
    }
}

// MARK: - Insights preview

private struct InsightsPreview: View {
    @ObservedObject var navigation: AppNavigation
    @ObservedObject private var stats = UsageStats.shared
    @Environment(\.accent) private var accent
    @State private var hovering = false

    var body: some View {
        let week = stats.recent(7)
        let most = max(1, week.map(\.day.words).max() ?? 1)
        Button { navigation.section = .insights } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Insights").font(.system(size: 12, weight: .bold))
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent.onCard)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Words today").font(.system(size: 10)).foregroundStyle(Theme.cardMuted)
                    Text(stats.day(Date()).words.formatted())
                        .font(.system(size: 42, weight: .semibold))
                        .tracking(-1.5)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .padding(.top, 26)
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(week.enumerated()), id: \.offset) { index, item in
                        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 1, bottomTrailingRadius: 1, topTrailingRadius: 3)
                            .fill(accent.color.opacity(index == week.count - 1 ? 1 : 0.54))
                            .frame(height: max(3, 43 * CGFloat(item.day.words) / CGFloat(most)))
                            .help("\(item.date.formatted(.dateTime.weekday(.wide))) · \(item.day.words) words")
                    }
                }
                .frame(height: 43, alignment: .bottom)
                .padding(.top, 12)
                .padding(.bottom, 18)
                Rectangle().fill(Theme.cardLine).frame(height: 1)
                HStack {
                    Text("\(Text("\(stats.streak())").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.cardText)) day streak")
                    Spacer()
                    if let top = stats.rankedApps.first { Text("\(top.app) · top app") }
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.cardMuted)
                .padding(.top, 12)
            }
            .padding(19)
            .foregroundStyle(Theme.cardText)
            .background(CardBackground())
            .environment(\.colorScheme, .dark)
            .offset(y: hovering ? -2 : 0)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerCursor()
        .help("Open Insights")
        .accessibilityLabel("Open Insights")
    }
}
