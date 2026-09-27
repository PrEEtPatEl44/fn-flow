import AppKit
import SwiftUI

/// Recent dictations (searchable, filterable by app, expandable to what Parakeet heard) and
/// a preview of Insights.
struct HomeView: View {
    @ObservedObject var navigation: AppNavigation
    @ObservedObject private var history = DictationHistory.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PageHeader(title: "Home") {
                DictateButton(hotkey: settings.hotkey.displayName)
            }
            AdaptiveStack(breakpoint: 740) { wide in
                if wide {
                    HStack(alignment: .top, spacing: 32) {
                        RecentDictations()
                        InsightsPreview(navigation: navigation).frame(width: 272)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        InsightsPreview(navigation: navigation)
                        RecentDictations()
                    }
                }
            }
        }
    }
}

/// Starts a hands-free dictation into the app you were using before this window.
private struct DictateButton: View {
    let hotkey: String

    var body: some View {
        Button {
            // Hand focus back to the previous app, so the text lands there.
            NSApp.hide(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                FlowController.shared.begin(mode: .handsFree)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                Text("Dictate")
                Kbd(text: hotkey)
            }
            .fixedSize()
        }
        .buttonStyle(FlowButtonStyle(kind: .primary))
        .help("Dictate into the app you were using. Click ✓ or press the hotkey to finish.")
    }
}

// MARK: - Recent dictations

private struct RecentDictations: View {
    @ObservedObject private var history = DictationHistory.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""
    @State private var searching = false
    @State private var appFilter: String?
    @State private var expanded: UUID?
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var apps: [String] {
        Array(Set(history.entries.compactMap(\.app))).sorted()
    }

    private var rows: [DictationHistory.Entry] {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        return history.entries.filter { entry in
            (appFilter == nil || entry.app == appFilter)
                && (term.isEmpty || "\(entry.text) \(entry.raw) \(entry.app ?? "")".lowercased().contains(term))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading
            VStack(spacing: 0) {
                Rectangle().fill(Theme.paneLine).frame(height: 1)
                if rows.isEmpty {
                    emptyState.padding(.top, 18)
                } else {
                    ForEach(rows) { entry in
                        HistoryRow(entry: entry, expanded: expanded == entry.id) {
                            withAnimation(.snappy(duration: 0.2)) { expanded = expanded == entry.id ? nil : entry.id }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Delete all \(history.entries.count) dictations?", isPresented: $confirmClear) {
            Button("Delete All", role: .destructive) { history.clear() }
        } message: {
            Text("This also resets Insights. It can't be undone.")
        }
    }

    private var heading: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Recent dictations").font(Theme.Font.heading)
                    Text("\(history.entries.count)").font(Theme.Font.small).foregroundStyle(Theme.paneDim)
                }
                if let median = history.medianLatency() {
                    Text("Median \(DictationTimings.format(median.seconds)) from finishing to text delivered")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.paneDim)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(Theme.paneText)
            Spacer()
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
            IconButton(symbol: searching ? "xmark" : "magnifyingglass", help: searching ? "Close search" : "Search dictations") {
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
            .help("Filter by app, or clear history")
        }
        .frame(minHeight: 43)
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

    private func openSearch() {
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

private struct HistoryRow: View {
    let entry: DictationHistory.Entry
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 15) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.day(entry.date))
                    Text(entry.date, format: .dateTime.hour().minute())
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.paneDim)
                .frame(width: 80, alignment: .leading)
                .padding(.top, 2)

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
                    IconButton(symbol: "doc.on.doc", help: "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.text, forType: .string)
                    }
                    IconButton(symbol: "trash", help: "Delete") { DictationHistory.shared.delete(entry) }
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

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "TODAY" }
        if calendar.isDateInYesterday(date) { return "YESTERDAY" }
        return date.formatted(.dateTime.month(.abbreviated).day()).uppercased()
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
        .accessibilityLabel("Open Insights")
    }
}
