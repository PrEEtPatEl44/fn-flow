import SwiftUI

/// A year of dictation activity, where it went, and the words used most.
struct InsightsView: View {
    @ObservedObject private var stats = UsageStats.shared
    @ObservedObject private var history = DictationHistory.shared
    @Environment(\.accent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Insights") {
                HStack(spacing: 6) {
                    Text("✳").font(.system(size: 14))
                    Text("\(stats.streak())").font(.system(size: 14, weight: .bold)).monospacedDigit()
                    Text("day streak").font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .foregroundStyle(accent.onPane)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.paneChip))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.paneChipLine, lineWidth: 1))
            }
            .padding(.bottom, 12)

            ActivityCard(stats: stats)

            AdaptiveStack(breakpoint: 640) { wide in
                let texts = history.entries.map { TextCleaner.stripUnknownTokens($0.text) }
                if wide {
                    HStack(alignment: .top, spacing: 15) {
                        AppsCard(apps: stats.rankedApps)
                        WordsCard(texts: texts)
                    }
                } else {
                    VStack(spacing: 15) {
                        AppsCard(apps: stats.rankedApps)
                        WordsCard(texts: texts)
                    }
                }
            }
        }
    }
}

private struct ActivityCard: View {
    @ObservedObject var stats: UsageStats
    @State private var detail: String?
    @Environment(\.accent) private var accent

    private static let weeks = 53

    var body: some View {
        let columns = Self.columns()
        Card(padding: 21) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Daily activity").font(Theme.Font.cardTitle)
                        if let first = columns.first?.first, let last = columns.last?.last {
                            Text("\(first.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted)) · words per day")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.cardMuted)
                        }
                    }
                    Spacer()
                    HStack(spacing: 23) {
                        total(stats.totalWords, "words")
                        total(stats.totalDictations, "dictations")
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(0..<7, id: \.self) { row in
                                    Text(row == 1 ? "M" : row == 3 ? "W" : row == 5 ? "F" : " ")
                                        .font(.system(size: 8))
                                        .foregroundStyle(Theme.cardDim)
                                        .frame(height: 12)
                                }
                            }
                            HStack(spacing: 3) {
                                ForEach(Array(columns.enumerated()), id: \.offset) { index, week in
                                    VStack(spacing: 3) {
                                        ForEach(week, id: \.self) { date in cell(date) }
                                        if week.count < 7 { Spacer(minLength: 0) }
                                    }
                                    .frame(height: 12 * 7 + 3 * 6, alignment: .top)
                                    .id(index)
                                }
                            }
                        }
                        .padding(.vertical, 20)
                    }
                    .onAppear { proxy.scrollTo(columns.count - 1, anchor: .trailing) }
                }
                HStack {
                    Text(detail ?? "Hover over a day to see its activity.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.cardMuted)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Fewer")
                        ForEach(0..<5, id: \.self) { level in
                            RoundedRectangle(cornerRadius: 2).fill(accent.level(level)).frame(width: 9, height: 9)
                        }
                        Text("More")
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.cardDim)
                }
            }
        }
    }

    private func total(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted()).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(Theme.cardDim)
        }
    }

    private func cell(_ date: Date) -> some View {
        let day = stats.day(date)
        let text = "\(date.formatted(date: .abbreviated, time: .omitted)) · \(day.dictations) dictation\(day.dictations == 1 ? "" : "s") · \(day.words.formatted()) words"
        return RoundedRectangle(cornerRadius: 2)
            .fill(accent.level(Self.level(words: day.words)))
            .frame(width: 12, height: 12)
            .help(text)
            .onHover { inside in
                if inside { detail = text } else if detail == text { detail = nil }
            }
            .accessibilityLabel(text)
    }

    /// Sunday-first weeks covering the past year, ending today.
    static func columns(until today: Date = Date()) -> [[Date]] {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: today)
        guard let yearAgo = calendar.date(byAdding: .day, value: -364, to: end) else { return [] }
        let weekday = calendar.component(.weekday, from: yearAgo) - 1
        guard let start = calendar.date(byAdding: .day, value: -weekday, to: yearAgo) else { return [] }
        var columns: [[Date]] = []
        var date = start
        while date <= end {
            if columns.isEmpty || columns[columns.count - 1].count == 7 { columns.append([]) }
            columns[columns.count - 1].append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return columns
    }

    static func level(words: Int) -> Int {
        switch words {
        case 0: 0
        case ..<150: 1
        case ..<350: 2
        case ..<600: 3
        default: 4
        }
    }
}

private struct AppsCard: View {
    let apps: [(app: String, count: Int)]
    @Environment(\.accent) private var accent

    var body: some View {
        Card(padding: 21) {
            VStack(alignment: .leading, spacing: 15) {
                Text("Where you write").font(Theme.Font.cardTitle)
                if apps.isEmpty {
                    Text("No app activity yet.").font(Theme.Font.small).foregroundStyle(Theme.cardMuted)
                }
                ForEach(apps.prefix(6), id: \.app) { item in
                    HStack(spacing: 10) {
                        Text(item.app).font(Theme.Font.small).lineLimit(1).frame(width: 90, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.cardLineSoft)
                                Capsule().fill(accent.color)
                                    .frame(width: geo.size.width * CGFloat(item.count) / CGFloat(max(apps[0].count, 1)))
                            }
                        }
                        .frame(height: 7)
                        Text(item.count.formatted()).font(.system(size: 10)).foregroundStyle(Theme.cardDim)
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }
}

private struct WordsCard: View {
    let texts: [String]
    @Environment(\.accent) private var accent

    var body: some View {
        let words = UsageStats.topWords(in: texts)
        Card(padding: 21) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Words you reach for").font(Theme.Font.cardTitle)
                if let first = words.first {
                    Text("Most used · \(Text(first.word).bold().foregroundColor(Theme.cardText))")
                        .font(Theme.Font.small)
                        .foregroundStyle(Theme.cardMuted)
                    FlowLayout(spacing: 8) {
                        ForEach(words, id: \.word) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(item.word)
                                Text("×\(item.count)").font(.system(size: 10)).foregroundStyle(accent.onCard)
                            }
                            .font(Theme.Font.small)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardLine, lineWidth: 1))
                        }
                    }
                } else {
                    Text("No words to show yet.").font(Theme.Font.small).foregroundStyle(Theme.cardMuted)
                }
                Text("From your recent dictations.").font(.system(size: 10)).foregroundStyle(Theme.cardDim)
            }
        }
    }
}
