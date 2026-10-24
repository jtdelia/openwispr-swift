/// Must exceed the detector's hangover, since a restore can un-mark up to that much earlier audio.
public let echoHoldMs = 3000.0
/// A stalled call stream must not hold the user's speech forever.
public let echoMaxHoldMs = 2 * echoHoldMs

/// A mic chunk positioned on the detector's session sample clock.
public struct HeldChunk {
    public var start: Int
    public var end: Int
    public var samples: [Float]
    /// Called with the samples, echo silenced, when the chunk should be transcribed.
    public var send: ([Float]) -> Void

    public init(start: Int, end: Int, samples: [Float], send: @escaping ([Float]) -> Void) {
        self.start = start
        self.end = end
        self.samples = samples
        self.send = send
    }
}

/// Holds mic chunks until the echo detector has decided on them, then sends what isn't echo, in order.
public final class EchoGate {
    private let detector: EchoDetector
    private let sampleRate: Int
    private let holdSamples: Int
    private let maxHoldSamples: Int
    private var held: [HeldChunk] = []

    public init(detector: EchoDetector, sampleRate: Int) {
        self.detector = detector
        self.sampleRate = sampleRate
        holdSamples = msToSamples(echoHoldMs, sampleRate: sampleRate)
        maxHoldSamples = msToSamples(echoMaxHoldMs, sampleRate: sampleRate)
    }

    public func hold(_ chunk: HeldChunk) {
        held.append(chunk)
    }

    /// Sends every held chunk the detector has decided on; without call audio there is nothing to wait for.
    public func releaseDecided(systemLive: Bool) {
        while let first = held.first {
            let decided = detector.analyzedThrough >= first.end + holdSamples
            let overdue = detector.receivedThrough(.mic) >= first.end + maxHoldSamples
            if systemLive && !decided && !overdue { return }
            release(held.removeFirst())
        }
    }

    /// Sends everything still held, e.g. when recording stops.
    public func flush() {
        detector.finish()
        let chunks = held
        held = []
        for chunk in chunks { release(chunk) }
    }

    private func release(_ chunk: HeldChunk) {
        var samples = chunk.samples
        let spans = detector.spans(chunk.start, chunk.end)
        if !spans.isEmpty {
            silenceSpans(&samples, start: chunk.start, spans: spans)
            if speechMs(samples, sampleRate: sampleRate) < minSpeechMs { return }
        }
        chunk.send(samples)
    }
}
