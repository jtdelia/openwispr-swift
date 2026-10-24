import Foundation
import Testing
@testable import OpenWisprCore

private let chunkRate = 1000
private let chunkFrame = 100

private func feed(_ chunker: inout SpeechChunker, _ pattern: String) -> [SpeechChunk] {
    pattern.compactMap { c in
        chunker.push([Float](repeating: c == "s" ? 0.2 : 0, count: chunkFrame))
    }
}

private func chunker(requestedCutMinMs: Double? = nil, requestedCutPauseMs: Double? = nil) -> SpeechChunker {
    var options = ChunkerOptions(sampleRate: chunkRate)
    options.minChunkMs = 1000
    options.maxChunkMs = 3000
    options.pauseMs = 300
    options.prerollMs = 200
    options.minSpeechMs = 300
    if let requestedCutMinMs { options.requestedCutMinMs = requestedCutMinMs }
    if let requestedCutPauseMs { options.requestedCutPauseMs = requestedCutPauseMs }
    return SpeechChunker(options)
}

struct SpeechChunkerTests {
    @Test func neverEmitsPureSilence() {
        var c = chunker()
        #expect(feed(&c, String(repeating: ".", count: 80)).isEmpty)
        let flushed = c.flush()
        #expect(flushed == nil)
    }

    @Test func cutsAtTheFirstPauseAfterTheMinimumLengthKeepingAShortPreroll() throws {
        var c = chunker()
        let chunks = feed(&c, ".....ssssssss...")
        #expect(chunks.count == 1)
        let chunk = try #require(chunks.first)
        #expect(chunk.startSample == 300)
        #expect(chunk.endSample == 1600)
        #expect(chunk.samples.count == 1300)
    }

    @Test func doesNotCutAtPausesBeforeTheMinimumLength() {
        var c = chunker()
        #expect(feed(&c, "sss...s").isEmpty)
    }

    @Test func forcesACutAtTheMaximumLengthDuringContinuousSpeech() {
        var c = chunker()
        #expect(feed(&c, String(repeating: "s", count: 31)).map { [$0.startSample, $0.endSample] } == [[0, 3000]])
    }

    @Test func dropsChunksWithTooLittleSpeech() {
        var c = chunker()
        #expect(feed(&c, "ss" + String(repeating: ".", count: 15)).isEmpty)
        let flushed = c.flush()
        #expect(flushed == nil)
    }

    @Test func cutsAtAShortPauseWhenAsked() {
        var c = chunker(requestedCutMinMs: 300, requestedCutPauseMs: 100)
        #expect(feed(&c, "ssss").isEmpty)
        c.requestCut()
        #expect(feed(&c, ".sss").map { [$0.startSample, $0.endSample] } == [[0, 500]])
        #expect(feed(&c, ".sss.").isEmpty)
    }

    @Test func flushesBufferedSpeechWhenRecordingStops() throws {
        var c = chunker()
        _ = feed(&c, "ssss")
        let flushed = c.flush()
        let chunk = try #require(flushed)
        #expect(chunk.startSample == 0)
        #expect(chunk.endSample == 400)
        #expect(c.msAt(400) == 400)
    }
}

struct WavTests {
    @Test func roundTripsSamples() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let wav = encodeWav(samples: samples)
        #expect(wav.count == 44 + samples.count * 2)
        let decoded = try decodeWav(wav)
        #expect(decoded.sampleRate == 16_000)
        #expect(zip(decoded.samples, samples).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test func decodesTheDictationFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "dictation-en", withExtension: "wav", subdirectory: "Fixtures"))
        let audio = try decodeWav(Data(contentsOf: url))
        #expect(audio.durationMs > 1000)
        #expect(speechMs(audio.samples, sampleRate: audio.sampleRate) > minSpeechMs)
    }

    @Test func slicesAWav() throws {
        let wav = encodeWav(samples: [Float](repeating: 0.25, count: 16_000))
        let slice = sliceWav(wav, startMs: 250, endMs: 750)
        #expect(slice.count == 44 + 8000 * 2)
        #expect(try decodeWav(slice).samples.count == 8000)
    }

    @Test func measuresMinimumWavSize() {
        #expect(minWavBytes == 44 + 8000)
    }
}

private let echoFrame = 1024

private func run(_ mic: [Float], _ system: [Float], slowAnalysisMs: Double = .infinity) -> EchoDetector {
    var config = EchoDetectorConfig()
    config.slowAnalysisMs = slowAnalysisMs
    let detector = EchoDetector(config)
    for ((at, systemFrame), (_, micFrame)) in zip(frames(system, size: echoFrame), frames(mic, size: echoFrame)) {
        detector.push(.system, systemFrame, at: at)
        detector.push(.mic, micFrame, at: at)
    }
    return detector
}

private func seconds(_ detector: EchoDetector, _ from: Double, _ to: Double) -> Double {
    let start = Int(from * Double(rate))
    let end = Int(to * Double(rate))
    return Double(detector.spans(start, end).reduce(0) { $0 + min($1.end, end) - max($1.start, start) }) / Double(rate)
}

struct EchoDetectorTests {
    @Test func gccPhatFindsHowFarOneSignalTrailsTheOther() {
        let fft = Fft(size: 1024)
        let y = noise(1024 / Double(rate), 1, seed: 7).map(Double.init)
        var x = [Double](repeating: 0, count: 1024)
        for i in 40..<1024 { x[i] = y[i - 40] * 0.5 }
        let (score, lag) = gccPhat(fft, x, y)
        #expect(lag == 40)
        #expect(score > 0.5)
    }

    @Test func marksMicAudioThatRepeatsTheCallAMomentLater() throws {
        let system = noise(10, 0.1, seed: 1)
        let detector = run(mix(delayed(system, ms: 120, gain: 0.3), noise(10, 0.001, seed: 2)), system)
        #expect(seconds(detector, 2, 9) > 6)
        let lag = try #require(detector.stats.lagMs)
        #expect(abs(lag - 120) < 0.5)
    }

    @Test func keepsMarkingThroughShortPausesInTheCall() {
        var system = noise(10, 0.1, seed: 9)
        for at in stride(from: 2.0, to: 10, by: 1.5) { fill(&system, from: at, to: at + 0.3) }
        let detector = run(mix(delayed(system, ms: 120, gain: 0.3), noise(10, 0.001, seed: 10)), system)
        #expect(seconds(detector, 3, 9) > 5)
    }

    @Test func leavesIndependentSpeechOnBothSidesAlone() {
        let detector = run(noise(10, 0.1, seed: 3), noise(10, 0.1, seed: 4))
        #expect(detector.spans(0, 10 * rate).isEmpty)
    }

    @Test func stopsMarkingAsSoonAsTheCallGoesQuietAndTheUserAnswers() {
        var call = noise(10, 0.1, seed: 5)
        fill(&call, from: 6)
        var reply = noise(10, 0.1, seed: 6)
        fill(&reply, from: 0, to: 6.5)
        let detector = run(mix(delayed(call, ms: 120, gain: 0.3), reply), call)
        #expect(seconds(detector, 2, 6) > 3)
        #expect(seconds(detector, 7, 10) == 0)
    }

    @Test func letsGoAfterAQuietFreezeWhenTheMicStopsHearingTheCall() {
        let call = noise(10, 0.1, seed: 11)
        var echo = delayed(call, ms: 120, gain: 0.3)
        fill(&echo, from: 4)
        var reply = noise(10, 0.1, seed: 12)
        fill(&reply, from: 0, to: 5)
        let detector = run(mix(echo, reply), call)
        #expect(seconds(detector, 2, 4) > 1.5)
        #expect(seconds(detector, 5.5, 10) == 0)
    }

    @Test func picksTheEchoBackUpAfterTheCallPauses() {
        var call = noise(12, 0.1, seed: 15)
        fill(&call, from: 4, to: 5)
        let detector = run(mix(delayed(call, ms: 120, gain: 0.3), noise(12, 0.001, seed: 16)), call)
        #expect(seconds(detector, 6.5, 11) > 4)
    }

    @Test func stopsDecidingOnceAnalysisIsTooSlow() {
        let system = noise(10, 0.1, seed: 13)
        let detector = run(delayed(system, ms: 120, gain: 0.3), system, slowAnalysisMs: -1)
        #expect(detector.stats.disabled)
        #expect(detector.spans(0, 10 * rate).isEmpty)
    }

    @Test func carriesAnOngoingEchoOverTheUnanalyzedTail() {
        let system = noise(6.1, 0.1, seed: 14)
        let detector = run(delayed(system, ms: 120, gain: 0.3), system)
        let before = detector.analyzedThrough
        detector.finish()
        #expect(detector.analyzedThrough > before)
        let covered = seconds(detector, Double(before) / Double(rate), Double(detector.analyzedThrough) / Double(rate))
        #expect(abs(covered - Double(detector.analyzedThrough - before) / Double(rate)) < 0.001)
    }

    @Test func doesNothingUntilBothStreamsArePresent() {
        let detector = EchoDetector()
        detector.push(.mic, noise(3, 0.1, seed: 8), at: 0)
        #expect(detector.analyzedThrough == Int.min)
    }

    @Test func silenceSpansZeroesOnlyTheCoveredSamples() {
        var samples = [Float](repeating: 1, count: 10)
        silenceSpans(&samples, start: 100, spans: [EchoSpan(start: 98, end: 102), EchoSpan(start: 108, end: 120)])
        #expect(samples == [0, 0, 1, 1, 1, 1, 1, 1, 0, 0])
    }
}

private final class GateHarness {
    let detector: EchoDetector
    let gate: EchoGate
    var sent: [Double] = []

    init() {
        var config = EchoDetectorConfig()
        config.slowAnalysisMs = .infinity
        detector = EchoDetector(config)
        gate = EchoGate(detector: detector, sampleRate: rate)
    }

    func hold(_ start: Double, _ end: Double) {
        gate.hold(HeldChunk(
            start: Int(start * Double(rate)), end: Int(end * Double(rate)), samples: noise(end - start, 0.1, seed: 1),
            send: { [unowned self] _ in sent.append(start) }
        ))
    }

    func feedSilence(_ source: TranscriptSource, _ from: Double, _ to: Double) {
        for at in stride(from: Int((from * Double(rate)).rounded()), to: Int((to * Double(rate)).rounded()), by: echoFrame) {
            detector.push(source, [Float](repeating: 0, count: echoFrame), at: at)
        }
    }
}

struct EchoGateTests {
    @Test func holdsAChunkUntilTheDetectorHasDecidedPastIt() {
        let h = GateHarness()
        h.hold(0, 1)
        h.feedSilence(.system, 0, 3)
        h.feedSilence(.mic, 0, 3)
        h.gate.releaseDecided(systemLive: true)
        #expect(h.sent.isEmpty)
        let decided = 1 + echoHoldMs / 1000 + 0.4
        h.feedSilence(.system, 3, decided)
        h.feedSilence(.mic, 3, decided)
        h.gate.releaseDecided(systemLive: true)
        #expect(h.sent == [0])
    }

    @Test func sendsRightAwayWithoutCallAudio() {
        let h = GateHarness()
        h.hold(0, 1)
        h.gate.releaseDecided(systemLive: false)
        #expect(h.sent == [0])
    }

    @Test func stopsWaitingOnAStalledCallStream() {
        let h = GateHarness()
        h.hold(0, 1)
        h.feedSilence(.system, 0, 1)
        h.feedSilence(.mic, 0, 1 + echoMaxHoldMs / 1000)
        h.gate.releaseDecided(systemLive: true)
        #expect(h.sent == [0])
    }

    @Test func dropsAChunkThatIsAllEchoAndKeepsTheUserSpeakingAfterTheCall() {
        let h = GateHarness()
        var call = noise(15, 0.1, seed: 2)
        fill(&call, from: 8)
        var reply = noise(15, 0.1, seed: 3)
        fill(&reply, from: 0, to: 9)
        let mic = mix(delayed(call, ms: 120, gain: 0.3), reply)
        for ((at, systemFrame), (_, micFrame)) in zip(frames(call, size: echoFrame), frames(mic, size: echoFrame)) {
            h.detector.push(.system, systemFrame, at: at)
            h.detector.push(.mic, micFrame, at: at)
        }
        for (start, end) in [(3.0, 7.0), (9.5, 11.0)] {
            let from = Int(start * Double(rate))
            let to = Int(end * Double(rate))
            h.gate.hold(HeldChunk(start: from, end: to, samples: Array(mic[from..<to]), send: { [unowned h] _ in h.sent.append(start) }))
        }
        h.gate.releaseDecided(systemLive: true)
        #expect(h.sent == [9.5])
    }

    @Test func sendsEverythingInOrderOnFlush() {
        let h = GateHarness()
        h.hold(0, 1)
        h.hold(1, 2)
        h.gate.flush()
        #expect(h.sent == [0, 1])
    }
}
