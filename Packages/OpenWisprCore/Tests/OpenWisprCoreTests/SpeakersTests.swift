import Foundation
import Testing
@testable import OpenWisprCore

func entry(_ source: TranscriptSource, _ startMs: Double, _ text: String, speaker: String? = nil, length: Double = 2000) -> TranscriptEntry {
    TranscriptEntry(id: "\(source)-\(startMs)", source: source, text: text, startMs: startMs, endMs: startMs + length, speaker: speaker)
}

func silentWavData(ms: Double) -> Data {
    encodeWav(samples: [Float](repeating: 0, count: Int((ms / 1000 * 16_000).rounded())))
}

struct SpeakerTimelineTests {
    let timeline: SpeakerTimeline = {
        let timeline = SpeakerTimeline()
        timeline.push(SpeakerObservation(at: 1000, speaking: ["Alice"]))
        timeline.push(SpeakerObservation(at: 5000, speaking: []))
        timeline.push(SpeakerObservation(at: 6000, speaking: ["Bob"]))
        timeline.push(SpeakerObservation(at: 8000, speaking: ["Alice", "Bob"]))
        return timeline
    }()

    @Test func creditsASegmentToWhoeverWasShownTalkingThroughMostOfIt() {
        #expect(timeline.dominant(1000, 5500) == "Alice")
        #expect(timeline.dominant(4500, 7900) == "Bob")
    }

    @Test func leavesMixedUncoveredOrUnobservedSegmentsUnattributed() {
        #expect(timeline.dominant(3500, 7500) == nil)
        #expect(timeline.dominant(0, 900) == nil)
        #expect(timeline.dominant(4800, 6100) == nil)
    }
}

struct SelfNameTests {
    @Test func takesTheUserToBeWhoeverIsShownTalkingDuringTheirMicrophoneSpeech() {
        let me = SelfName()
        me.vote("Noh Wan")
        #expect(me.current == nil)
        me.vote(nil)
        me.vote("Noh Wan")
        #expect(me.current == "Noh Wan")
        me.vote("John")
        me.vote("John")
        #expect(me.current == nil)
    }

    @Test func letsTheTimelineIgnoreTheUserWhenCreditingCallAudio() {
        let timeline = SpeakerTimeline()
        timeline.push(SpeakerObservation(at: 0, speaking: ["Noh Wan"]))
        timeline.push(SpeakerObservation(at: 4000, speaking: ["John"]))
        #expect(timeline.dominant(3000, 5000) == nil)
        #expect(timeline.dominant(3000, 5000, ignore: ["Noh Wan"]) == "John")
    }

    @Test func rulesOutPeopleTheCallAudioClearlyBelongedTo() {
        let me = SelfName()
        me.heardOnCall("John")
        #expect(!me.isRemote("John"))
        me.heardOnCall("John")
        #expect(me.remoteNames == ["John"])
        me.vote("John")
        me.vote("John")
        #expect(me.current == nil)
        me.vote("Noh Wan")
        me.vote("Noh Wan")
        #expect(me.current == "Noh Wan")
    }
}

struct OverlapCreditTests {
    let timeline: SpeakerTimeline = {
        let timeline = SpeakerTimeline()
        timeline.push(SpeakerObservation(at: 0, speaking: ["John"]))
        timeline.push(SpeakerObservation(at: 2000, speaking: ["John", "Noh Wan"]))
        timeline.push(SpeakerObservation(at: 4000, speaking: ["Noh Wan"]))
        return timeline
    }()

    func hints(previous: String? = nil, isRemote: @escaping (String) -> Bool = { _ in false }) -> OverlapHints {
        OverlapHints(ignore: [], previous: previous, isRemote: isRemote)
    }

    @Test func creditsAClearSpeakerAsClear() {
        #expect(timeline.credit(0, 2000, hints: hints()) == CallCredit(name: "John", clear: true))
    }

    @Test func keepsTheCallAudioWithWhoeverAlreadyHadIt() {
        #expect(timeline.credit(2000, 4000, hints: hints()) == nil)
        #expect(timeline.credit(2000, 4000, hints: hints(previous: "John")) == CallCredit(name: "John", clear: false))
    }

    @Test func otherwisePrefersTheOnlyConfirmedRemoteVoice() {
        #expect(timeline.credit(2000, 4000, hints: hints(isRemote: { $0 == "John" })) == CallCredit(name: "John", clear: false))
    }

    @Test func doesNotHandAMixToAPreviousSpeakerWhoIsNoLongerShown() {
        #expect(timeline.credit(2000, 4000, hints: hints(previous: "Alice")) == nil)
    }
}

struct SpeakerIdentityMapTests {
    @Test func namesAVoiceAfterRepeatedSightingsAndKeepsTheNameThroughGaps() {
        let map = SpeakerIdentityMap()
        #expect(map.resolve("voice:1", observedName: "Alice", nowMs: 0) == nil)
        #expect(map.resolve("voice:1", observedName: "Alice", nowMs: 1000) == nil)
        #expect(map.resolve("voice:1", observedName: "Alice", nowMs: 2000) == "Alice")
        #expect(map.resolve("voice:1", observedName: nil, nowMs: 3000) == "Alice")
    }

    @Test func needsSustainedConflictingEvidenceToRenameAndNotAgainWithinTheCooldown() {
        var config = IdentityConfig()
        config.promoteThreshold = 1
        config.remapThreshold = 2
        config.remapCooldownMs = 10_000
        let map = SpeakerIdentityMap(config: config)
        _ = map.resolve("voice:1", observedName: "Alice", nowMs: 0)
        #expect(map.resolve("voice:1", observedName: "Bob", nowMs: 1000) == "Alice")
        #expect(map.resolve("voice:1", observedName: "Bob", nowMs: 2000) == "Bob")
        #expect(map.resolve("voice:1", observedName: "Carol", nowMs: 3000) == "Bob")
        #expect(map.resolve("voice:1", observedName: "Carol", nowMs: 4000) == "Bob")
    }
}

struct VoiceBankTests {
    @Test func turnsNewLabelsIntoNumberedVoicesWithAReferenceClipThenRecognizesThem() throws {
        let bank = VoiceBank(nextId: 3)
        let ids = bank.assign([
            TranscriptSegment(startMs: 0, endMs: 2500, text: "Hello", speaker: "A"),
            TranscriptSegment(startMs: 2500, endMs: 3000, text: "Hi", speaker: "B"),
        ], wav: silentWavData(ms: 3000))
        #expect(ids == ["A": 3])
        let known = try #require(bank.knownSpeakers())
        #expect(known.names == ["speaker_3"])
        #expect(known.references[0].hasPrefix("data:audio/wav;base64,"))
        let again = bank.assign([TranscriptSegment(startMs: 0, endMs: 1000, text: "Yes", speaker: "speaker_3")], wav: silentWavData(ms: 1000))
        #expect(again["speaker_3"] == 3)
    }

    @Test func slicesWavAudioByTime() {
        let clip = sliceWav(silentWavData(ms: 3000), startMs: 1000, endMs: 2500)
        #expect(clip.count == 44 + 24_000 * 2)
        let dataSize = clip[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(dataSize == 48_000)
    }
}

struct TranscriptTurnTests {
    @Test func dropsMicrophoneEchoesOfTheCallAudio() {
        let entries = [
            entry(.system, 0, "We should ship the release on Friday", speaker: "app:Alice"),
            entry(.mic, 500, "we should ship the release on friday"),
            entry(.mic, 9000, "Sounds good to me, thanks"),
        ]
        #expect(withoutEchoes(entries).map(\.startMs) == [0, 9000])
    }

    @Test func startsANewTurnWhenTheSpeakerChangesWithinTheCallAudio() {
        let turns = transcriptTurns([
            entry(.system, 0, "One.", speaker: "app:Alice"),
            entry(.system, 2000, "Two.", speaker: "app:Alice"),
            entry(.system, 4000, "Three.", speaker: "voice:1"),
            entry(.system, 6000, "Four."),
        ])
        #expect(turns.map { [$0.speaker, $0.text] } == [["app:Alice", "One. Two."], ["voice:1", "Three."], ["others", "Four."]])
    }

    @Test func labelsSpeakers() {
        #expect(Speakers.label(Speakers.you, names: [:], userName: "") == "Me")
        #expect(Speakers.label(Speakers.you, names: [:], userName: " Ada ") == "Ada (me)")
        #expect(Speakers.label("app:Alice", names: [:], userName: "") == "Alice")
        #expect(Speakers.label("voice:2", names: ["voice:2": "Dana"], userName: "") == "Dana")
        #expect(Speakers.label("voice:2", names: ["voice:2": "  "], userName: "") == "Speaker 2")
        #expect(Speakers.label(Speakers.others, names: [:], userName: "") == "Others")
    }
}
