import Foundation
import Observation

/// Meeting metadata, notes and summaries live in `meetings.json`; each transcript is an append-only
/// NDJSON file in `meetings/<id>/`, so a crash mid-meeting loses at most the chunk being transcribed.
@Observable
@MainActor
public final class MeetingStore {
    private static let transcriptFile = "live.ndjson"

    /// Newest first.
    public private(set) var meetings: [Meeting]
    /// Bumped on every transcript append, so views showing a transcript know to reload it.
    public private(set) var transcriptVersion = 0

    @ObservationIgnored private let indexURL: URL
    @ObservationIgnored private let baseDir: URL
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private let indexWrite = Debouncer(delay: .milliseconds(250))

    public init(directory: URL, now: @escaping () -> Double = epochMs) {
        indexURL = directory.appending(path: "meetings.json")
        baseDir = directory.appending(path: "meetings")
        self.now = now
        meetings = readJson(indexURL, as: LenientArray<Meeting>.self)?.elements ?? []
    }

    public func get(_ id: String) -> Meeting? {
        meetings.first { $0.id == id }
    }

    public func detail(_ id: String) -> MeetingDetail? {
        get(id).map { MeetingDetail(meeting: $0, transcript: transcript(id)) }
    }

    public func create() -> Meeting {
        let meeting = Meeting(createdAt: now())
        meetings.insert(meeting, at: 0)
        saveIndex()
        return meeting
    }

    public func update(_ id: String, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index])
        meetings[index].modifiedAt = now()
        saveIndex()
    }

    public func delete(_ id: String) {
        meetings.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: baseDir.appending(path: id))
        saveIndex()
    }

    public func setGenerating(_ id: String, _ generating: Bool) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].summaryGenerating = generating
    }

    @discardableResult
    public func appendTranscript(_ id: String, _ entry: TranscriptEntry) -> TranscriptEntry? {
        guard get(id) != nil else { return nil }
        let dir = baseDir.appending(path: id)
        let file = dir.appending(path: Self.transcriptFile)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var line = try JSONEncoder().encode(entry)
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: file)
            }
        } catch {
            print("openwispr: could not append to the transcript: \(error)")
            return nil
        }
        update(id) { $0.transcriptWords += countWords(entry.text) }
        transcriptVersion += 1
        return entry
    }

    public func transcript(_ id: String) -> [TranscriptEntry] {
        guard let raw = try? String(contentsOf: baseDir.appending(path: id).appending(path: Self.transcriptFile), encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        // A torn final line from a crash mid-append fails to decode; the rest of the file is still valid.
        let entries = raw.split(separator: "\n").compactMap { line in
            try? decoder.decode(TranscriptEntry.self, from: Data(line.utf8))
        }
        return entries.sorted { $0.startMs < $1.startMs }
    }

    public func flush() {
        indexWrite.cancel()
        writeJsonAtomic(indexURL, meetings)
    }

    private func saveIndex() {
        indexWrite.schedule { [weak self] in self?.flush() }
    }
}
