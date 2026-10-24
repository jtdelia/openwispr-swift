import OpenWisprCore
import SwiftUI

struct HomePage: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingClear = false

    var body: some View {
        let settings = model.store.settings
        PageScaffold(title: welcome(settings.userName)) {
            HStack(spacing: 4) {
                Text("Hold")
                Keycap(text: Key.comboLabel(settings.shortcuts.ptt))
                Text("and speak in any app. Press")
                Keycap(text: Key.comboLabel(settings.shortcuts.handsFree))
                Text("for hands-free mode.")
            }
            .foregroundStyle(.secondary)

            if !setupItems.isEmpty {
                Card {
                    Text("Finish setting up").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(setupItems, id: \.self) { Label($0, systemImage: "circle").font(.callout) }
                    }
                    .padding(.vertical, 10)
                    Button("Open Settings") { model.page = .settings }
                        .buttonStyle(.glassProminent)
                }
                .accessibilityIdentifier("setup-card")
            }

            stats

            HStack {
                Text("History").font(.title2.weight(.semibold))
                Spacer()
                if !model.store.history.isEmpty {
                    Button("Clear all") { confirmingClear = true }.buttonStyle(.link)
                }
            }
            .confirmationDialog("Delete all history?", isPresented: $confirmingClear) {
                Button("Delete all", role: .destructive) { model.store.clearHistory() }
            }

            if model.store.history.isEmpty {
                Text("Your dictations will show up here.").foregroundStyle(.secondary)
            }
            ForEach(Format.groupByDay(model.store.history, \.timestamp), id: \.label) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.label).font(.headline).foregroundStyle(.secondary)
                    Card {
                        ForEach(group.items) { entry in
                            HistoryRow(entry: entry)
                            if entry.id != group.items.last?.id { Divider().padding(.vertical, 8) }
                        }
                    }
                }
            }
        }
    }

    private func welcome(_ name: String) -> String {
        let first = name.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "Welcome back" : "Welcome back, \(first)"
    }

    private var setupItems: [String] {
        let permissions = model.permissions
        let speech = model.store.settings.speechToText
        var items: [String] = []
        if !permissions.accessibility { items.append("Grant Accessibility access so OpenWispr can hear your shortcut and paste text") }
        if !permissions.microphone { items.append("Allow microphone access") }
        if let endpoint = speech.endpoint, endpoint.apiKey.isEmpty, !isLocalEndpoint(endpoint.baseUrl) {
            items.append("Add a speech-to-text API key")
        }
        return items
    }

    private var stats: some View {
        let stats = model.store.stats
        return HStack(spacing: 12) {
            StatTile(value: stats.totalWords.formatted(), label: "words dictated")
            StatTile(value: "\(stats.averageWpm)", label: "words per minute")
            StatTile(value: stats.totalDictations.formatted(), label: "dictations")
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title.weight(.semibold)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

private struct HistoryRow: View {
    @Environment(AppModel.self) private var model
    let entry: HistoryEntry

    var body: some View {
        let text = entry.formattedText.isEmpty ? entry.asrText : entry.formattedText
        HStack(alignment: .top, spacing: 12) {
            Text(Format.time(entry.timestamp))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if text.isEmpty {
                    Text("No speech detected").foregroundStyle(.secondary)
                } else {
                    Text(text).textSelection(.enabled).accessibilityIdentifier("history-text")
                }
                if let error = entry.error { ErrorText(error) }
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !text.isEmpty {
                Button("Copy") { Paster.copy(text) }.buttonStyle(.link)
            }
            Button("Delete", role: .destructive) { model.store.deleteHistory(entry.id) }
                .buttonStyle(.link)
                .foregroundStyle(.red)
        }
    }

    private var meta: String {
        var parts = [entry.appName.isEmpty ? "Unknown app" : entry.appName]
        if entry.status == .copied { parts.append("copied to clipboard") }
        if entry.mode == .handsFree { parts.append("hands-free") }
        return parts.joined(separator: " · ")
    }
}
