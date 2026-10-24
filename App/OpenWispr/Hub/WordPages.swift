import OpenWisprCore
import SwiftUI

struct DictionaryPage: View {
    @Environment(AppModel.self) private var model
    @State private var word = ""
    @State private var replaces = ""

    var body: some View {
        PageScaffold(
            title: "Dictionary",
            subtitle: "Names, jargon and acronyms OpenWispr should spell your way. Add what it mishears to replace it automatically."
        ) {
            Card {
                HStack {
                    TextField("Word or phrase, e.g. Kubernetes", text: $word)
                        .accessibilityIdentifier("dictionary-word")
                    TextField("Optional: replaces, e.g. cooper netties", text: $replaces)
                        .accessibilityIdentifier("dictionary-replaces")
                    Button("Add", action: add)
                        .buttonStyle(.glassProminent)
                        .disabled(word.trimmed.isEmpty)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("dictionary-add")
                }
                .textFieldStyle(.roundedBorder)
            }
            let entries = model.store.dictionary
            if entries.isEmpty {
                Text("No words yet.").foregroundStyle(.secondary)
            } else {
                Card {
                    ForEach(entries) { entry in
                        HStack {
                            Text(entry.word).bold()
                            if let replaces = entry.replaces { Text("← \(replaces)").foregroundStyle(.secondary) }
                            Spacer()
                            Button("Delete", role: .destructive) {
                                model.store.setDictionary(entries.filter { $0.id != entry.id })
                            }
                            .buttonStyle(.link)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("dictionary-delete")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dictionary-entry")
                        if entry.id != entries.last?.id { Divider().padding(.vertical, 8) }
                    }
                }
            }
        }
    }

    private func add() {
        guard !word.trimmed.isEmpty else { return }
        let entry = DictionaryEntry(word: word.trimmed, replaces: replaces.trimmed.isEmpty ? nil : replaces.trimmed)
        model.store.setDictionary([entry] + model.store.dictionary)
        word = ""
        replaces = ""
    }
}

struct SnippetsPage: View {
    @Environment(AppModel.self) private var model
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        PageScaffold(title: "Snippets", subtitle: "Say a trigger phrase and OpenWispr types the full text: links, addresses, sign-offs.") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Trigger, e.g. my calendar link", text: $trigger)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("snippet-trigger")
                    TextField(String("Expansion, e.g. https://cal.com/you"), text: $expansion, axis: .vertical)
                        .lineLimit(3...6)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("snippet-expansion")
                    Button("Add snippet", action: add)
                        .buttonStyle(.glassProminent)
                        .disabled(trigger.trimmed.isEmpty || expansion.isEmpty)
                        .accessibilityIdentifier("snippet-add")
                }
            }
            let snippets = model.store.snippets
            if snippets.isEmpty {
                Text("No snippets yet.").foregroundStyle(.secondary)
            } else {
                Card {
                    ForEach(snippets) { snippet in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("“\(snippet.trigger)”").bold()
                                Text(snippet.expansion).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Delete", role: .destructive) {
                                model.store.setSnippets(snippets.filter { $0.id != snippet.id })
                            }
                            .buttonStyle(.link)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("snippet-delete")
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("snippet-entry")
                        if snippet.id != snippets.last?.id { Divider().padding(.vertical, 8) }
                    }
                }
            }
        }
    }

    private func add() {
        guard !trigger.trimmed.isEmpty, !expansion.isEmpty else { return }
        model.store.setSnippets([Snippet(trigger: trigger.trimmed, expansion: expansion)] + model.store.snippets)
        trigger = ""
        expansion = ""
    }
}

struct StylePage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScaffold(
            title: "Style",
            subtitle: "OpenWispr adapts punctuation and tone to the app you’re dictating into. Requires Cleanup in Settings."
        ) {
            ForEach(StyleContext.allCases, id: \.self) { context in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(context.title).font(.title3.weight(.semibold))
                        Text(context.apps).font(.callout).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                        ForEach(Style.allCases, id: \.self) { style in
                            StyleCard(style: style, selected: model.store.settings.styles[context] == style) {
                                model.updateSettings { $0.styles[context] = style }
                            }
                            .accessibilityIdentifier("style-\(context.rawValue)-\(style.rawValue)")
                        }
                    }
                }
            }
        }
    }
}

private struct StyleCard: View {
    let style: Style
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(style.title).bold()
                Text(style.sample).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(), in: .rect(cornerRadius: 12))
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension StyleContext {
    var title: String {
        switch self {
        case .personal: "Personal messages"
        case .work: "Work messages"
        case .email: "Email"
        case .other: "Everything else"
        }
    }

    var apps: String {
        switch self {
        case .personal: "Messages, WhatsApp, Telegram, Signal, Discord"
        case .work: "Slack, Microsoft Teams"
        case .email: "Mail, Outlook, Superhuman, Gmail"
        case .other: "Docs, notes, AI chats, code editors"
        }
    }
}

extension Style {
    var title: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .excited: "Excited"
        }
    }

    var sample: String {
        switch self {
        case .formal: "Hey, are you free for lunch tomorrow? Let’s do 12 if that works for you."
        case .casual: "Hey are you free for lunch tomorrow? Let’s do 12 if that works for you"
        case .veryCasual: "hey are you free for lunch tomorrow? let’s do 12 if that works for you"
        case .excited: "Hey, are you free for lunch tomorrow? Let’s do 12 if that works for you!"
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
