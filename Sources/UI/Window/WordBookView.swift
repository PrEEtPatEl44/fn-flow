import SwiftUI

/// Names and terms to spell exactly, replacements for words Parakeet mishears, and the
/// switch for learning replacements from your own fixes.
struct WordBookView: View {
    @ObservedObject private var dictionary = PersonalDictionary.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Word Book") { EmptyView() }
                .padding(.bottom, 12)
            AdaptiveStack(breakpoint: 700) { wide in
                if wide {
                    HStack(alignment: .top, spacing: 16) {
                        TermsCard()
                        ReplacementsCard()
                    }
                } else {
                    VStack(spacing: 16) {
                        TermsCard()
                        ReplacementsCard()
                    }
                }
            }
            Card(padding: 21) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Learn from corrections").font(.system(size: 14, weight: .semibold))
                        Text("After pasting, Fn-flow watches that text field for a minute. Fix a misheard word, and the fix is saved here and used next time.")
                            .font(Theme.Font.small)
                            .foregroundStyle(Theme.cardMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Learn from corrections", isOn: $settings.learnFromCorrections)
                        .toggleStyle(FlowToggleStyle())
                        .labelsHidden()
                }
            }
            .frame(maxWidth: 590)
        }
    }
}

private struct TermsCard: View {
    @ObservedObject private var dictionary = PersonalDictionary.shared
    @State private var newTerm = ""

    var body: some View {
        Card(padding: 21) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Names & terms").font(Theme.Font.cardTitle)
                Text("Spelled exactly as written, and used as hints for cleanup.")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.cardMuted)
                    .padding(.top, 3)
                Group {
                    if dictionary.terms.isEmpty {
                        Text("No terms yet.").font(Theme.Font.small).foregroundStyle(Theme.cardDim)
                    } else {
                        FlowLayout(spacing: 7) {
                            ForEach(dictionary.terms, id: \.self) { term in
                                HStack(spacing: 7) {
                                    Text(term)
                                    Button {
                                        dictionary.terms.removeAll { $0 == term }
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                    }
                                    .buttonStyle(.plain)
                                    .pointerCursor()
                                    .foregroundStyle(Theme.cardMuted)
                                    .help("Remove \(term)")
                                    .accessibilityLabel("Remove \(term)")
                                }
                                .font(Theme.Font.small)
                                .padding(.leading, 11)
                                .padding(.trailing, 9)
                                .padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.cardHigh))
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
                HStack(spacing: 7) {
                    TextField("Add a term, e.g. Kubernetes", text: $newTerm)
                        .textFieldStyle(FlowFieldStyle())
                        .onSubmit(add)
                    Button("Add term", action: add)
                        .buttonStyle(FlowButtonStyle())
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() {
        dictionary.addTerm(newTerm)
        newTerm = ""
    }
}

private struct ReplacementsCard: View {
    @ObservedObject private var dictionary = PersonalDictionary.shared
    @State private var heard = ""
    @State private var written = ""
    @Environment(\.accent) private var accent

    var body: some View {
        Card(padding: 21) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Replacements").font(Theme.Font.cardTitle)
                Text("What Parakeet hears, and what to write instead. Remove a bad learned fix here.")
                    .font(Theme.Font.small)
                    .foregroundStyle(Theme.cardMuted)
                    .padding(.top, 3)
                VStack(spacing: 0) {
                    if dictionary.replacements.isEmpty {
                        Text("No replacements yet.").font(Theme.Font.small).foregroundStyle(Theme.cardDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 11)
                    }
                    ForEach(dictionary.replacements) { item in
                        HStack(spacing: 9) {
                            Text(item.from).foregroundStyle(Theme.cardMuted)
                            Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent.onCard)
                            Text(item.to).fontWeight(.semibold)
                            if item.learned { Chip(text: "Learned").help("Learned from one of your corrections") }
                            Spacer()
                            IconButton(symbol: "trash", help: "Remove this replacement", surface: .card) {
                                dictionary.replacements.removeAll { $0.id == item.id }
                            }
                        }
                        .font(Theme.Font.small)
                        .padding(.vertical, 7)
                        Rectangle().fill(Theme.cardLineSoft).frame(height: 1)
                    }
                }
                .padding(.top, 14)
                HStack(spacing: 7) {
                    TextField("Heard", text: $heard).textFieldStyle(FlowFieldStyle())
                    TextField("Write instead", text: $written)
                        .textFieldStyle(FlowFieldStyle())
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(FlowButtonStyle())
                        .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || written.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 18)
            }
        }
    }

    private func add() {
        dictionary.addReplacement(from: heard, to: written, learned: false)
        heard = ""
        written = ""
    }
}
