import OpenWisprCore
import SwiftUI

struct NotetakerPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.openMeetingId, model.meetings.get(id) != nil {
            MeetingView(id: id).id(id)
        } else {
            MeetingList()
        }
    }
}

private struct MeetingList: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let meetings = model.meetings.meetings
        let needle = query.trimmed.lowercased()
        let visible = meetings.filter { meeting in
            needle.isEmpty || [meeting.title, meeting.notes, meeting.summary ?? ""].contains { $0.lowercased().contains(needle) }
        }
        let recordingId = model.notetaker.state.meetingId

        PageScaffold(title: "Notetaker") {
            HStack(alignment: .top) {
                Text("Takes notes in your meetings. It transcribes your microphone and the call audio, and writes a summary with action items when the meeting ends.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 20)
                Button("New note", systemImage: "plus") { model.newMeeting() }
                    .buttonStyle(.glassProminent)
                    .disabled(recordingId != nil)
                    .accessibilityIdentifier("new-note")
            }
            if !meetings.isEmpty {
                TextField("Search notes…", text: $query).textFieldStyle(.roundedBorder)
            }
            if meetings.isEmpty {
                Text("Start a note when a meeting begins. Always get consent before transcribing others.").foregroundStyle(.secondary)
            } else if visible.isEmpty {
                Text("No matching notes.").foregroundStyle(.secondary)
            }
            ForEach(Format.groupByDay(visible, \.createdAt), id: \.label) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.label).font(.headline).foregroundStyle(.secondary)
                    Card {
                        ForEach(group.items) { meeting in
                            MeetingRow(meeting: meeting, recording: meeting.id == recordingId)
                            if meeting.id != group.items.last?.id { Divider().padding(.vertical, 8) }
                        }
                    }
                }
            }
        }
    }
}

private struct MeetingRow: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let recording: Bool

    var body: some View {
        Button {
            model.openMeetingId = meeting.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(Format.time(meeting.createdAt)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title).bold()
                    if !preview.isEmpty { Text(preview).lineLimit(1).foregroundStyle(.secondary) }
                }
                Spacer()
                if recording {
                    Badge(text: "● Recording", tone: .recording)
                } else {
                    Text(formatClock(meeting.recordedMs)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("meeting-row")
    }

    private var preview: String {
        let summaryLine = meeting.summary?.components(separatedBy: .newlines)
            .map { $0.replacing(/^[#\-*\s\[\]xX]+/, with: "").replacing(/\*\*|__|`/, with: "").trimmed }
            .first { !$0.isEmpty && $0.range(of: #"^(summary|key points)$"#, options: [.regularExpression, .caseInsensitive]) == nil }
        return summaryLine ?? meeting.notes.trimmed.components(separatedBy: .newlines).first ?? ""
    }
}

struct MeetingView: View {
    @Environment(AppModel.self) private var model
    let id: String
    @State private var title = ""
    @State private var notes = ""
    @State private var titleEdited = false
    @State private var seeded = false
    @State private var transcript: [TranscriptEntry] = []
    @State private var showTranscript = true
    @State private var editingSpeakers = false
    @State private var confirmingDelete = false

    var body: some View {
        if let meeting = model.meetings.get(id) {
            content(meeting)
                .task(id: model.meetings.transcriptVersion) { transcript = model.meetings.transcript(id) }
                .onAppear { seed(meeting) }
                .onChange(of: meeting.title) { _, newTitle in if !titleEdited { title = newTitle } }
                .task(id: notes) { await save { $0.notes = notes } }
                .task(id: title) { await save { $0.title = title } }
        }
    }

    private func content(_ meeting: Meeting) -> some View {
        let recordingHere = model.notetaker.state.meetingId == id && model.notetaker.state.isRecording
        let turns = transcriptTurns(transcript)
        var seen = Set<String>()
        let speakers = turns.map(\.speaker).filter { $0 != Speakers.you && seen.insert($0).inserted }

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button("Notetaker", systemImage: "chevron.left") { model.openMeetingId = nil }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("meeting-back")
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Untitled meeting", text: $title)
                        .textFieldStyle(.plain)
                        .font(.largeTitle.weight(.semibold))
                        .onChange(of: title) { if seeded && title != meeting.title { titleEdited = true } }
                        .accessibilityIdentifier("meeting-title")
                    Text(Date(timeIntervalSince1970: meeting.createdAt / 1000).formatted(date: .abbreviated, time: .shortened))
                        .font(.callout).foregroundStyle(.secondary)
                }

                RecordBar(meeting: meeting)

                VStack(alignment: .leading, spacing: 8) {
                    Text("My notes").font(.headline)
                    TextEditor(text: $notes)
                        .font(.body)
                        .frame(minHeight: 110)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(.background.secondary, in: .rect(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            if notes.isEmpty {
                                Text("Write your notes here. We'll make a separate summary at the end.")
                                    .foregroundStyle(.tertiary).padding(13).allowsHitTesting(false)
                            }
                        }
                        .accessibilityIdentifier("meeting-notes")
                }

                SummarySection(meetingId: id, state: summaryState(meeting, recording: recordingHere))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Transcript").font(.headline)
                        Spacer()
                        if !speakers.isEmpty && !editingSpeakers {
                            Button("Assign speakers") { editingSpeakers = true }.buttonStyle(.link)
                        }
                        Button(showTranscript ? "Hide" : "Show") { showTranscript.toggle() }.buttonStyle(.link)
                    }
                    if editingSpeakers {
                        SpeakerEditor(speakers: speakers, names: meeting.speakerNames) { names in
                            editingSpeakers = false
                            let cleaned = names.compactMapValues { $0.trimmed.isEmpty ? nil : $0.trimmed }
                            model.notetaker.setSpeakerNames(id, names: cleaned)
                        } onCancel: {
                            editingSpeakers = false
                        }
                    }
                    if showTranscript {
                        TranscriptView(turns: turns, speakers: speakers, names: meeting.speakerNames, recording: recordingHere) {
                            editingSpeakers = true
                        }
                    }
                }

                Button("Delete meeting", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.link)
                    .foregroundStyle(.red)
                    .confirmationDialog("Delete this meeting, its notes and transcript?", isPresented: $confirmingDelete) {
                        Button("Delete", role: .destructive) { model.deleteMeeting(id) }
                    }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func seed(_ meeting: Meeting) {
        guard !seeded else { return }
        title = meeting.title
        notes = meeting.notes
        seeded = true
    }

    /// Saves shortly after the user stops typing; `task(id:)` cancels the wait on every keystroke.
    private func save(_ change: @escaping (inout Meeting) -> Void) async {
        guard seeded else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, let meeting = model.meetings.get(id) else { return }
        var updated = meeting
        change(&updated)
        guard updated.title != meeting.title || updated.notes != meeting.notes else { return }
        model.meetings.update(id, change)
    }
}

private struct RecordBar: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting

    var body: some View {
        let state = model.notetaker.state
        HStack(spacing: 14) {
            switch state {
            case let .recording(recording) where recording.meetingId == meeting.id:
                Circle().fill(.red).frame(width: 10, height: 10).symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 3) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = recording.baseRecordedMs + context.date.timeIntervalSince1970 * 1000 - recording.startedAt
                        Text("Listening · \(formatClock(elapsed))").bold().monospacedDigit()
                    }
                    switch recording.systemAudio {
                    case .capturing:
                        Text("Your microphone and the call audio").font(.callout).foregroundStyle(.secondary)
                        Text(liveSpeakersText(recording.speakers)).font(.callout).foregroundStyle(.secondary)
                    case .starting:
                        Text("Starting…").font(.callout).foregroundStyle(.secondary)
                    case let .unavailable(reason):
                        Text("Microphone only: the other participants are not being recorded").font(.callout).foregroundStyle(.secondary)
                        ErrorText(reason)
                    }
                    if let error = recording.error { ErrorText("Transcription failed: \(error)") }
                }
                Spacer()
                Button("Stop") { Task { await model.notetaker.stop() } }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("meeting-stop")
            case let .finishing(meetingId) where meetingId == meeting.id:
                VStack(alignment: .leading, spacing: 3) {
                    Text("Finishing up…").bold()
                    Text("Transcribing the last few seconds").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            default:
                let busyElsewhere = state.meetingId != nil && state.meetingId != meeting.id
                let error: String? = {
                    if let startError = model.meetingStartError { return startError }
                    if case let .idle(error) = state { return error }
                    return nil
                }()
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.recordedMs > 0 ? "Recorded \(formatClock(meeting.recordedMs))" : "Not recording").bold()
                    Text(busyElsewhere ? "Another meeting is being recorded." : "Always get consent when transcribing others.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let error { ErrorText(error) }
                }
                Spacer()
                Button(meeting.recordedMs > 0 ? "Resume" : "Start") { model.startRecording(meeting.id) }
                    .buttonStyle(.glassProminent)
                    .disabled(busyElsewhere)
                    .accessibilityIdentifier("meeting-start")
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("record-bar")
    }

    private func liveSpeakersText(_ speakers: LiveSpeakers) -> String {
        guard let platform = speakers.platform else {
            return "Speakers are named when the call is open in Zoom, Google Meet, Microsoft Teams or a Slack huddle"
        }
        if speakers.speaking.isEmpty { return "\(platform.label): naming speakers as they talk" }
        return "\(platform.label): \(speakers.speaking.joined(separator: ", ")) talking"
    }
}

private struct SummarySection: View {
    @Environment(AppModel.self) private var model
    let meetingId: String
    let state: SummaryState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary").font(.headline)
                Spacer()
                if let summary { Button("Copy") { Paster.copy(summary) }.buttonStyle(.link) }
            }
            Card { content }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("summary")
        }
    }

    private var summary: String? {
        switch state {
        case .notYetGeneratable, .tooShort, .readyToGenerate, .generating: nil
        case let .generated(summary), let .updateAvailable(summary), let .updating(summary): summary
        case let .failed(summary, _): summary
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .notYetGeneratable:
            Text("Summaries appear when a meeting ends.").foregroundStyle(.secondary)
        case let .tooShort(noAudio):
            Text(noAudio ? "No transcript yet. Start recording to get a summary." : "The meeting was too short to summarize.")
                .foregroundStyle(.secondary)
        case .readyToGenerate:
            Button("Generate summary", action: generate).buttonStyle(.glass)
        case .generating:
            HStack { ProgressView().controlSize(.small); Text("Generating summary…").foregroundStyle(.secondary) }
        case let .generated(summary):
            MarkdownView(text: summary)
        case let .updateAvailable(summary):
            HStack {
                Text("New recording since this summary.").font(.callout).foregroundStyle(.secondary)
                Button("Update summary", action: generate).buttonStyle(.link)
            }
            .padding(.bottom, 8)
            MarkdownView(text: summary)
        case let .updating(summary):
            Text("Updating summary…").font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
            MarkdownView(text: summary)
        case let .failed(summary, error):
            HStack {
                ErrorText(error)
                Button("Try again", action: generate).buttonStyle(.link)
            }
            .padding(.bottom, 8)
            if let summary { MarkdownView(text: summary) }
        }
    }

    private func generate() {
        Task { await model.notetaker.generateSummary(meetingId) }
    }
}

private let speakerColors: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]

private struct SpeakerEditor: View {
    let speakers: [String]
    let onSave: ([String: String]) -> Void
    let onCancel: () -> Void
    @State private var draft: [String: String]

    init(speakers: [String], names: [String: String], onSave: @escaping ([String: String]) -> Void, onCancel: @escaping () -> Void) {
        self.speakers = speakers
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: names)
    }

    var body: some View {
        Card {
            Text("Name each voice and we'll relabel the whole transcript and summary.").font(.callout).foregroundStyle(.secondary)
            ForEach(Array(speakers.enumerated()), id: \.element) { index, key in
                let label = Speakers.label(key, names: [:], userName: "")
                HStack {
                    Text(label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(speakerColors[index % speakerColors.count])
                        .frame(width: 120, alignment: .leading)
                    TextField("Type a name", text: Binding(get: { draft[key] ?? "" }, set: { draft[key] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name for \(label)")
                }
                .padding(.top, 8)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save names") { onSave(draft) }.buttonStyle(.glassProminent)
            }
            .padding(.top, 10)
        }
    }
}

private struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let turns: [TranscriptTurn]
    let speakers: [String]
    let names: [String: String]
    let recording: Bool
    let onRename: () -> Void

    var body: some View {
        if turns.isEmpty {
            Text(recording ? "Listening… text appears a few seconds after each pause." : "No transcript.").foregroundStyle(.secondary)
        } else {
            Card {
                ForEach(turns) { turn in
                    HStack(alignment: .top, spacing: 12) {
                        Text(formatClock(turn.startMs)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 50, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if turn.speaker == Speakers.you {
                                Text("You").font(.callout.weight(.semibold)).foregroundStyle(.green)
                            } else {
                                let index = speakers.firstIndex(of: turn.speaker) ?? 0
                                Button(Speakers.label(turn.speaker, names: names, userName: "")) { onRename() }
                                    .buttonStyle(.plain)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(speakerColors[index % speakerColors.count])
                                    .help("Rename speakers")
                            }
                            Text(turn.text).textSelection(.enabled)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("transcript-turn")
                    .padding(.vertical, 5)
                }
            }
        }
    }
}
