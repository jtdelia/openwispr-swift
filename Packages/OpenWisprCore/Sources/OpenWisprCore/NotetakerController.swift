import Foundation
import Observation

/// Who the meeting app shows talking, polled from its window through Accessibility.
public struct SpeakersReport: Sendable, Equatable {
    public var platform: MeetingPlatform?
    public var speaking: [String]
    /// Epoch ms.
    public var timestamp: Double

    public init(platform: MeetingPlatform?, speaking: [String], timestamp: Double) {
        self.platform = platform
        self.speaking = speaking
        self.timestamp = timestamp
    }
}

/// How Google Meet marks tiles: a class on the audio indicator present only while that participant
/// talks, and controls that only the user's own tile has. Meet's class names are minified and change.
public struct MeetTileMarkers: Sendable, Equatable {
    public var speakingClasses: [String]
    public var selfLabels: [String]

    public static let current = MeetTileMarkers(speakingClasses: ["BlxGDf"], selfLabels: ["Backgrounds and effects", "Reframe"])
}

/// A stretch of one source's audio, cut at a pause.
public struct MeetingChunk: Sendable {
    public var session: Int
    public var source: TranscriptSource
    /// Offsets from the start of this recording segment, shared by both sources.
    public var startMs: Double
    public var endMs: Double
    /// Epoch ms at `startMs`, to line the audio up with speaker observations.
    public var wallClockMs: Double
    public var wav: Data

    public init(session: Int, source: TranscriptSource, startMs: Double, endMs: Double, wallClockMs: Double, wav: Data) {
        self.session = session
        self.source = source
        self.startMs = startMs
        self.endMs = endMs
        self.wallClockMs = wallClockMs
        self.wav = wav
    }
}

/// Records the microphone and the Mac's audio. After `start` it reports `recorderStarted` or
/// `recorderFailed`, hands chunks to `handleChunk`, and reports `recorderStopped` once `stop` has flushed.
@MainActor
public protocol MeetingRecorder: AnyObject {
    func start(session: Int, deviceId: String)
    func stop(session: Int)
    /// The speaker changed: end the current chunk at the next short pause so it holds one voice.
    func cut(session: Int, source: TranscriptSource)
}

@MainActor
public protocol SpeakerDetector: AnyObject {
    func startPolling(markers: MeetTileMarkers, report: @escaping @MainActor (SpeakersReport) -> Void)
    func stopPolling()
}

private let stopFlushTimeout = Duration.seconds(5)
private let retryDelay = Duration.milliseconds(1500)
private let summaryTimeout: TimeInterval = 180
private let titleAttempts = 3

/// Records meetings (microphone plus system audio), transcribes them in chunks, then titles and summarizes.
@Observable
@MainActor
public final class NotetakerController {
    private final class Segment {
        let session: Int
        let meetingId: String
        let baseRecordedMs: Double
        var queues: [TranscriptSource: Task<Void, Never>] = [:]
        var previousText: [TranscriptSource: String] = [.mic: "", .system: ""]
        let timeline = SpeakerTimeline()

        init(session: Int, meetingId: String, baseRecordedMs: Double) {
            self.session = session
            self.meetingId = meetingId
            self.baseRecordedMs = baseRecordedMs
        }
    }

    /// What the controller has learned about a meeting's voices; kept across resumed recordings.
    private final class SpeakerMemory {
        let voices: VoiceBank
        let identities = SpeakerIdentityMap()
        let selfName = SelfName()
        var lastCallSpeaker: String?

        init(voices: VoiceBank) { self.voices = voices }
    }

    public private(set) var state: NotetakerState = .idle()

    @ObservationIgnored public weak var recorder: MeetingRecorder?
    @ObservationIgnored public var onStateChange: ((NotetakerState) -> Void)?
    @ObservationIgnored private let store: DataStore
    @ObservationIgnored private let models: Models
    @ObservationIgnored private let meetings: MeetingStore
    @ObservationIgnored private let speakers: SpeakerDetector?
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var segment: Segment?
    @ObservationIgnored private var onStopped: (() -> Void)?
    @ObservationIgnored private var memories: [String: SpeakerMemory] = [:]
    @ObservationIgnored private var lastSpeaking: [String] = []

    public init(store: DataStore, models: Models, meetings: MeetingStore, speakers: SpeakerDetector?, now: @escaping () -> Double = epochMs) {
        self.store = store
        self.models = models
        self.meetings = meetings
        self.speakers = speakers
        self.now = now
    }

    public func start(_ meetingId: String) throws {
        if case let .recording(recording) = state, recording.meetingId == meetingId { return }
        guard case .idle = state else { throw AppError("Another meeting is still being recorded") }
        guard let meeting = meetings.get(meetingId) else { throw AppError("Meeting not found") }
        if case let .unavailable(reason) = models.availability(.speechToText) { throw AppError(reason) }

        session += 1
        segment = Segment(session: session, meetingId: meetingId, baseRecordedMs: meeting.recordedMs)
        setState(.recording(.init(
            meetingId: meetingId, startedAt: now(), baseRecordedMs: meeting.recordedMs, systemAudio: .starting, speakers: LiveSpeakers(), error: nil
        )))
        speakers?.startPolling(markers: .current) { [weak self] report in self?.handleSpeakers(report) }
        recorder?.start(session: session, deviceId: store.settings.microphoneId)
    }

    public func stop() async {
        guard case let .recording(recording) = state else { return }
        let segment = segment
        meetings.update(recording.meetingId) { $0.recordedMs = recording.baseRecordedMs + (self.now() - recording.startedAt) }
        setState(.finishing(meetingId: recording.meetingId))
        speakers?.stopPolling()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let resume = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            let timer = Task {
                try? await Task.sleep(for: stopFlushTimeout)
                resume()
            }
            onStopped = {
                timer.cancel()
                resume()
            }
            recorder?.stop(session: session)
        }
        onStopped = nil
        if let segment {
            for source in TranscriptSource.allCases { await segment.queues[source]?.value }
        }
        self.segment = nil
        setState(.idle())
        await afterMeeting(recording.meetingId)
    }

    /// Stops without waiting for pending audio, e.g. when the meeting being recorded is deleted.
    public func discard(_ meetingId: String) {
        memories[meetingId] = nil
        guard state.meetingId == meetingId else { return }
        speakers?.stopPolling()
        recorder?.stop(session: session)
        session += 1
        segment = nil
        onStopped?()
        setState(.idle())
    }

    public func recorderStarted(session: Int, systemAudioError: String?) {
        guard session == self.session, case var .recording(recording) = state else { return }
        recording.systemAudio = systemAudioError.map { .unavailable($0) } ?? .capturing
        setState(.recording(recording))
    }

    public func recorderFailed(session: Int, message: String) {
        guard session == self.session else { return }
        if case .idle = state { return }
        print("openwispr: meeting recorder failed: \(message)")
        speakers?.stopPolling()
        segment = nil
        setState(.idle(error: "Couldn't start recording: \(message)"))
    }

    public func recorderStopped(session: Int) {
        guard session == self.session else { return }
        onStopped?()
    }

    public func handleSpeakers(_ report: SpeakersReport) {
        guard let segment, case var .recording(recording) = state else { return }
        let selfName = memory(segment.meetingId).selfName.current
        let changed = report.speaking != lastSpeaking
        lastSpeaking = report.speaking
        segment.timeline.push(SpeakerObservation(at: report.timestamp, speaking: report.speaking))
        recording.speakers = LiveSpeakers(platform: report.platform, speaking: report.speaking.filter { $0 != selfName })
        setState(.recording(recording))
        if changed {
            // Cutting the microphone too keeps its chunks to one turn, which is how the user's own name is learned.
            for source in TranscriptSource.allCases { recorder?.cut(session: segment.session, source: source) }
        }
    }

    /// Saves the names the user gave speakers and relabels the existing summary to match.
    public func setSpeakerNames(_ meetingId: String, names: [String: String]) {
        guard let detail = meetings.detail(meetingId) else { return }
        let userName = store.settings.userName
        var seen: Set<String> = []
        let keys = detail.transcript.map(Speakers.key).filter { seen.insert($0).inserted }
        let renames = keys.map {
            SpeakerRename(from: Speakers.label($0, names: detail.meeting.speakerNames, userName: userName), to: Speakers.label($0, names: names, userName: userName))
        }
        meetings.update(meetingId) { meeting in
            meeting.speakerNames = names
            if let summary = meeting.summary { meeting.summary = relabelSummary(summary, renames: renames) }
        }
    }

    public func handleChunk(_ chunk: MeetingChunk) {
        guard let segment, chunk.session == segment.session else { return }
        let previous = segment.queues[chunk.source]
        segment.queues[chunk.source] = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await transcribeChunk(segment, chunk)
            } catch {
                print("openwispr: chunk transcription failed: \(error)")
                if case var .recording(recording) = state, self.segment === segment {
                    recording.error = errorMessage(error)
                    setState(.recording(recording))
                }
            }
        }
    }

    private func transcribeChunk(_ segment: Segment, _ chunk: MeetingChunk) async throws {
        let userName = store.settings.userName
        let dictionary = store.dictionary
        let memory = memory(segment.meetingId)
        let prompt = chunkPrompt(vocabularyPrompt: transcriptionPrompt(dictionary: dictionary, userName: userName), previousText: segment.previousText[chunk.source] ?? "")
        let known = chunk.source == .system ? memory.voices.knownSpeakers() : nil
        let durationMs = chunk.endMs - chunk.startMs
        let parts: [TranscriptSegment]
        do {
            parts = try await models.transcribeSegments(chunk.wav, durationMs: durationMs, prompt: prompt, known: known)
        } catch {
            try await Task.sleep(for: retryDelay)
            parts = try await models.transcribeSegments(chunk.wav, durationMs: durationMs, prompt: prompt, known: known)
        }
        let voices = chunk.source == .system ? memory.voices.assign(parts, wav: chunk.wav) : [:]

        var appended = false
        for part in parts {
            if isLikelyHallucination(part.text) { continue }
            let text = applyReplacements(part.text, dictionary: dictionary)
            if chunk.source == .mic {
                let from = chunk.wallClockMs + part.startMs
                memory.selfName.vote(segment.timeline.dominant(from, chunk.wallClockMs + part.endMs, ignore: memory.selfName.remoteNames))
            }
            let speaker = chunk.source == .system ? attribute(segment, memory, chunk, part, voices) : nil
            let startMs = segment.baseRecordedMs + chunk.startMs
            let entry = TranscriptEntry(
                source: chunk.source, text: text, startMs: startMs + part.startMs, endMs: startMs + max(part.startMs, part.endMs), speaker: speaker
            )
            guard meetings.appendTranscript(segment.meetingId, entry) != nil else { return }
            segment.previousText[chunk.source] = "\(segment.previousText[chunk.source] ?? "") \(text)".jsSlice(-400)
            appended = true
        }
        if appended, case var .recording(recording) = state, recording.error != nil {
            recording.error = nil
            setState(.recording(recording))
        }
    }

    /// Who said a call-audio segment: whoever the meeting app showed talking through it, else the name the
    /// segment's voice has earned from earlier segments, else just the voice.
    private func attribute(_ segment: Segment, _ memory: SpeakerMemory, _ chunk: MeetingChunk, _ part: TranscriptSegment, _ voices: [String: Int]) -> String? {
        let from = chunk.wallClockMs + part.startMs
        let selfName = memory.selfName.current
        let credit = segment.timeline.credit(from, chunk.wallClockMs + part.endMs, hints: OverlapHints(
            ignore: selfName.map { [$0] } ?? [], previous: memory.lastCallSpeaker, isRemote: { memory.selfName.isRemote($0) }
        ))
        if let credit, credit.clear { memory.selfName.heardOnCall(credit.name) }
        let shown = credit?.name
        let voice = part.speaker.flatMap { voices[$0] }
        let observed = credit?.clear == true ? credit?.name : nil
        let named = voice.map { memory.identities.resolve(Speakers.voice($0), observedName: observed, nowMs: from) ?? shown } ?? shown
        if let named {
            memory.lastCallSpeaker = named
            return Speakers.app(named)
        }
        return voice.map(Speakers.voice)
    }

    private func memory(_ meetingId: String) -> SpeakerMemory {
        if let memory = memories[meetingId] { return memory }
        let used = meetings.transcript(meetingId).map { $0.speaker.flatMap(Speakers.voiceId) ?? 0 }
        let memory = SpeakerMemory(voices: VoiceBank(nextId: max(0, used.max() ?? 0) + 1))
        memories[meetingId] = memory
        return memory
    }

    private func afterMeeting(_ meetingId: String) async {
        guard let meeting = meetings.get(meetingId) else { return }
        if meeting.title.trimmed.isEmpty { await generateTitle(meetingId) }
        if meeting.summary == nil, meeting.transcriptWords >= minSummaryWords { await generateSummary(meetingId) }
    }

    private func generateTitle(_ meetingId: String) async {
        guard models.availability(.chat) == .available, let detail = meetings.detail(meetingId) else { return }
        let transcript = formatTranscript(detail.transcript, names: detail.meeting.speakerNames, userName: store.settings.userName)
        if transcript.isEmpty && detail.meeting.notes.trimmed.isEmpty { return }
        for attempt in 1...titleAttempts {
            do {
                let title = try await titleMeeting(models, transcript: transcript, notes: detail.meeting.notes)
                // The user may have typed a title while the request was in flight.
                if !title.isEmpty, meetings.get(meetingId)?.title.trimmed.isEmpty == true {
                    meetings.update(meetingId) { $0.title = title }
                }
                return
            } catch {
                print("openwispr: title attempt \(attempt) failed: \(error)")
            }
        }
    }

    public func generateSummary(_ meetingId: String) async {
        guard let meeting = meetings.get(meetingId), !meeting.summaryGenerating else { return }
        guard models.availability(.chat) == .available else {
            meetings.update(meetingId) { $0.summaryError = "Set up a chat model in Settings to generate summaries" }
            return
        }
        meetings.setGenerating(meetingId, true)
        meetings.update(meetingId) { $0.summaryError = nil }
        defer { meetings.setGenerating(meetingId, false) }
        guard let detail = meetings.detail(meetingId) else { return }
        do {
            let userName = store.settings.userName
            let summary = try await summarizeMeeting(models, SummaryInput(
                title: detail.meeting.title,
                transcript: formatTranscript(detail.transcript, names: detail.meeting.speakerNames, userName: userName),
                notes: detail.meeting.notes, userName: userName, dictionary: store.dictionary, recordedAt: detail.meeting.createdAt
            ), timeout: summaryTimeout)
            if summary.isEmpty { throw AppError("The model returned an empty summary") }
            meetings.update(meetingId) { meeting in
                meeting.summary = summary
                meeting.summaryRecordedMs = detail.meeting.recordedMs
                meeting.summaryError = nil
            }
        } catch {
            print("openwispr: summary failed: \(error)")
            meetings.update(meetingId) { $0.summaryError = errorMessage(error) }
        }
    }

    private func setState(_ next: NotetakerState) {
        let kindChanged = next.kind != state.kind
        state = next
        if kindChanged { onStateChange?(next) }
    }
}

extension NotetakerState {
    fileprivate enum Kind { case idle, recording, finishing }

    fileprivate var kind: Kind {
        switch self {
        case .idle: .idle
        case .recording: .recording
        case .finishing: .finishing
        }
    }
}
