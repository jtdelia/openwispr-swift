import SwiftUI

enum Format {
    static func dayLabel(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSince1970: timestamp / 1000)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func groupByDay<T>(_ items: [T], _ timestamp: (T) -> Double) -> [(label: String, items: [T])] {
        var groups: [(label: String, items: [T])] = []
        for item in items {
            let label = dayLabel(timestamp(item))
            if let index = groups.firstIndex(where: { $0.label == label }) {
                groups[index].items.append(item)
            } else {
                groups.append((label, [item]))
            }
        }
        return groups
    }

    static func time(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp / 1000).formatted(date: .omitted, time: .shortened)
    }

    static func bytes(_ bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1e9 { return String(format: value < 1e10 ? "%.2f GB" : "%.1f GB", value / 1e9) }
        if value >= 1e6 { return "\(Int((value / 1e6).rounded())) MB" }
        return "\(max(0, Int((value / 1e3).rounded()))) KB"
    }

    static func percent(_ done: Int64, _ total: Int64) -> Int {
        total > 0 ? Int((Double(done) / Double(total) * 100).rounded(.down)) : 0
    }

    static func languageName(_ code: String) -> String {
        guard !code.isEmpty else { return "your Mac’s language" }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

/// A page's scrolling column, with its title and description.
struct PageScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.largeTitle.weight(.semibold))
                    if let subtitle { Text(subtitle).foregroundStyle(.secondary) }
                }
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

struct ErrorText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
    }
}

struct Badge: View {
    enum Tone { case plain, ok, warn, recording }

    let text: String
    var tone: Tone = .plain

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .capsule)
    }

    private var color: Color {
        switch tone {
        case .plain: .secondary
        case .ok: .green
        case .warn: .orange
        case .recording: .red
        }
    }
}

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .rect(cornerRadius: 5))
    }
}

/// Renders the Markdown chat models write for meeting notes: headings, bullets, checkboxes and paragraphs.
struct MarkdownView: View {
    private enum Block: Hashable {
        case heading(level: Int, text: String)
        case bullet(text: String, indent: Int, checked: Bool?)
        case paragraph(String)
    }

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, text):
                    Self.inline(text)
                        .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, 4)
                case let .bullet(text, indent, checked):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        switch checked {
                        case .some(true): Image(systemName: "checkmark.square").foregroundStyle(.secondary)
                        case .some(false): Image(systemName: "square").foregroundStyle(.secondary)
                        case .none: Text("•").foregroundStyle(.secondary)
                        }
                        Self.inline(text)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case let .paragraph(text):
                    Self.inline(text)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ text: String) -> Text {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(attributed)
    }

    private static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let indent = raw.prefix { $0 == " " }.count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                endParagraph()
            } else if let match = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                endParagraph()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if let match = line.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.*)$/) {
                endParagraph()
                blocks.append(.bullet(text: String(match.2), indent: indent, checked: match.1 != " "))
            } else if let match = line.firstMatch(of: /^(?:[-*+]|\d+[.)])\s+(.*)$/) {
                endParagraph()
                blocks.append(.bullet(text: String(match.1), indent: indent, checked: nil))
            } else {
                paragraph.append(line)
            }
        }
        endParagraph()
        return blocks
    }
}
