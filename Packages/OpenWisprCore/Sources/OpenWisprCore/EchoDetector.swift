import Accelerate
import Foundation

public struct EchoDetectorConfig: Sendable {
    public var sampleRate = 16_000
    /// Analysis runs at `sampleRate / decimation`.
    public var decimation = 2
    /// Analysis window in decimated samples (power of two).
    public var fftSize = 16_384
    public var cadenceMs = 320.0
    /// RMS below which a stream counts as silent.
    public var energyFloor: Float = 0.003
    /// Minimum normalized correlation peak for a window to count.
    public var scoreFloor = 0.03
    public var lagToleranceMs = 35.0
    /// How many counted windows the lock is judged over.
    public var lagWindow = 8
    public var lagStabilityMin = 5
    /// Our two capture clocks are only roughly aligned, so the mic may lead or trail by up to this much.
    public var maxAbsLagMs = 500.0
    public var attackUpdates = 3
    public var hangoverMs = 2000.0
    /// Locked updates required after a quiet freeze before the lock is trusted again.
    public var corroborations = 2
    public var slowAnalysisMs = 10.0
    public var slowAnalysisLimit = 5

    public init() {}
}

/// Must cover the longest mic chunk plus how long it can be held for a decision.
private let segmentRetentionMs = 60_000.0
private let lowpassTapCount = 31

public struct EchoSpan: Sendable, Equatable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct EchoStats: Sendable, Equatable {
    public var analyzed: Int
    public var correlated: Int
    public var suppressedMs: Double
    /// Mic delay behind the call at the most recent lock.
    public var lagMs: Double?
    public var disabled: Bool
}

/// When the call plays through speakers, the microphone hears it again a moment later. GCC-PHAT
/// cross-correlation finds that delay; once it stays stable, the echoed mic audio is marked so it isn't
/// transcribed a second time as the user.
///
/// All positions are session samples at `sampleRate`, shared by both streams, so the two captures
/// line up regardless of how their capture callbacks batch frames.
public final class EchoDetector {
    private struct Segment {
        var start: Int
        var end: Int
        var systemActive: Bool
        var suppressed: Bool
    }

    private let config: EchoDetectorConfig
    private let windowSamples: Int
    private let cadenceSamples: Int
    private let maxLagSamples: Int
    private let hangoverSamples: Int
    private let retentionSamples: Int
    private let mic: SampleRing
    private let system: SampleRing
    private let fft: Fft
    private let lowpass: [Double]
    private var micWindow: [Float]
    private var systemWindow: [Float]
    private var x: [Double]
    private var y: [Double]

    private var nextAnalysisEnd: Int?
    private var lastAnalysisEnd: Int?
    private var segments: [Segment] = []
    private var prunedSuppressed = 0
    private var recentLagsMs: [Double] = []
    private var lockedLagMs: Double?
    private var suppressing = false
    private var consecutiveLocked = 0
    private var corroborationsNeeded = 0
    /// Mic audio before this is from before a quiet freeze and is left out of new windows.
    private var freshFrom = Int.min
    private var belowSince: Int?
    private var quietStreak = 0
    private var slowStreak = 0
    private var disabled = false
    private var analyzed = 0
    private var correlated = 0

    public init(_ config: EchoDetectorConfig = EchoDetectorConfig()) {
        precondition(config.fftSize > 0 && config.fftSize & (config.fftSize - 1) == 0, "fftSize must be a power of two")
        self.config = config
        windowSamples = config.fftSize * config.decimation
        cadenceSamples = msToSamples(config.cadenceMs, sampleRate: config.sampleRate)
        maxLagSamples = msToSamples(config.maxAbsLagMs, sampleRate: config.sampleRate)
        hangoverSamples = msToSamples(config.hangoverMs, sampleRate: config.sampleRate)
        retentionSamples = msToSamples(segmentRetentionMs, sampleRate: config.sampleRate)
        let capacity = windowSamples + maxLagSamples + 4 * cadenceSamples + config.sampleRate
        mic = SampleRing(capacity: capacity)
        system = SampleRing(capacity: capacity)
        fft = Fft(size: config.fftSize)
        lowpass = lowpassTaps(count: lowpassTapCount, cutoff: 0.45 / Double(config.decimation))
        micWindow = [Float](repeating: 0, count: windowSamples)
        systemWindow = [Float](repeating: 0, count: windowSamples)
        x = [Double](repeating: 0, count: config.fftSize)
        y = [Double](repeating: 0, count: config.fftSize)
    }

    /// Session sample through which echo decisions are final, apart from walk-back and hangover trimming.
    public var analyzedThrough: Int { lastAnalysisEnd ?? Int.min }

    public var stats: EchoStats {
        let suppressed = segments.reduce(prunedSuppressed) { $0 + ($1.suppressed ? $1.end - $1.start : 0) }
        return EchoStats(
            analyzed: analyzed, correlated: correlated,
            suppressedMs: (Double(suppressed) / Double(config.sampleRate) * 1000).rounded(), lagMs: lockedLagMs, disabled: disabled
        )
    }

    /// Session sample just past the latest audio received from `source`.
    public func receivedThrough(_ source: TranscriptSource) -> Int {
        let ring = ring(source)
        return ring.isEmpty ? Int.min : ring.end
    }

    public func push(_ source: TranscriptSource, _ frame: [Float], at start: Int) {
        ring(source).write(frame, at: start)
        if mic.isEmpty || system.isEmpty { return }
        var next = nextAnalysisEnd ?? max(mic.start, system.start) + windowSamples
        let ready = min(mic.end, system.end)
        while next <= ready {
            analyze(next)
            next += cadenceSamples
        }
        nextAnalysisEnd = next
    }

    /// Carries the current decision over audio received since the last analysis, e.g. when recording stops.
    public func finish() {
        guard let last = lastAnalysisEnd else { return }
        let end = min(receivedThrough(.mic), receivedThrough(.system))
        guard end > last else { return }
        var segment = makeSegment(last, end)
        segment.suppressed = suppressing && segment.systemActive
        record(segment)
    }

    /// Merged echo spans overlapping `[from, to)`; gaps of up to one analysis step are filled.
    public func spans(_ from: Int, _ to: Int) -> [EchoSpan] {
        var out: [EchoSpan] = []
        for segment in segments where segment.suppressed && segment.end > from && segment.start < to {
            if let last = out.last, segment.start - last.end <= cadenceSamples {
                out[out.count - 1].end = max(last.end, segment.end)
            } else {
                out.append(EchoSpan(start: segment.start, end: segment.end))
            }
        }
        return out
    }

    private func ring(_ source: TranscriptSource) -> SampleRing {
        switch source {
        case .mic: mic
        case .system: system
        }
    }

    private func makeSegment(_ start: Int, _ end: Int) -> Segment {
        Segment(start: start, end: end, systemActive: system.rms(start - maxLagSamples, end) >= config.energyFloor, suppressed: false)
    }

    private func record(_ segment: Segment) {
        segments.append(segment)
        lastAnalysisEnd = segment.end
        var drop = 0
        while drop < segments.count, segments[drop].end < segment.end - retentionSamples {
            if segments[drop].suppressed { prunedSuppressed += segments[drop].end - segments[drop].start }
            drop += 1
        }
        if drop > 0 { segments.removeFirst(drop) }
    }

    private func analyze(_ end: Int) {
        let start = end - cadenceSamples
        var segment = makeSegment(start, end)
        if disabled {
            record(segment)
            return
        }
        if mic.rms(start, end) < config.energyFloor {
            quietStreak += 1
            // A short dip is analyzed normally; a longer quiet freezes the decision until the mic is busy again.
            if quietStreak >= 2 {
                consecutiveLocked = 0
                corroborationsNeeded = config.corroborations
                recentLagsMs = []
                freshFrom = end
                segment.suppressed = suppressing && segment.systemActive
                record(segment)
                return
            }
        } else {
            quietStreak = 0
        }

        analyzed += 1
        let windowStart = end - windowSamples
        mic.read(from: windowStart, into: &micWindow)
        system.read(from: windowStart, into: &systemWindow)
        if freshFrom > windowStart {
            for i in 0..<min(windowSamples, freshFrom - windowStart) { micWindow[i] = 0 }
        }
        var counted = false
        if rms(micWindow) >= config.energyFloor && rms(systemWindow) >= config.energyFloor {
            let began = ContinuousClock.now
            let (score, lagMs) = correlate()
            noteAnalysisTime(ContinuousClock.now - began)
            if score >= config.scoreFloor {
                counted = true
                correlated += 1
                recentLagsMs.append(lagMs)
                if recentLagsMs.count > config.lagWindow { recentLagsMs.removeFirst() }
            }
        }

        var locked = counted && isLocked()
        if locked && corroborationsNeeded > 0 {
            corroborationsNeeded -= 1
            locked = false
        }
        if locked {
            consecutiveLocked += 1
            belowSince = nil
            lockedLagMs = median(recentLagsMs)
            if !suppressing && consecutiveLocked >= config.attackUpdates {
                suppressing = true
                // The lock needs a few windows of evidence, so the echo began up to a window earlier.
                var i = segments.count - 1
                while i >= 0, segments[i].start >= windowStart {
                    if segments[i].systemActive { segments[i].suppressed = true }
                    i -= 1
                }
            }
        } else {
            consecutiveLocked = 0
            if suppressing {
                let since = belowSince ?? start
                belowSince = since
                if end - since >= hangoverSamples {
                    suppressing = false
                    var i = segments.count - 1
                    while i >= 0, segments[i].start >= since {
                        segments[i].suppressed = false
                        i -= 1
                    }
                    belowSince = nil
                }
            }
        }
        segment.suppressed = suppressing && segment.systemActive
        record(segment)
    }

    private func isLocked() -> Bool {
        let lags = recentLagsMs
        if lags.count < config.lagStabilityMin { return false }
        let center = median(lags)
        let within = lags.filter { abs($0 - center) <= config.lagToleranceMs }.count
        return within >= config.lagStabilityMin && abs(center) <= config.maxAbsLagMs
    }

    private func correlate() -> (score: Double, lagMs: Double) {
        decimate(micWindow, taps: lowpass, factor: config.decimation, into: &x)
        decimate(systemWindow, taps: lowpass, factor: config.decimation, into: &y)
        let (score, lag) = gccPhat(fft, x, y)
        return (score, Double(lag) / (Double(config.sampleRate) / Double(config.decimation)) * 1000)
    }

    private func noteAnalysisTime(_ elapsed: Duration) {
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        slowStreak = ms > config.slowAnalysisMs ? slowStreak + 1 : 0
        if slowStreak < config.slowAnalysisLimit { return }
        disabled = true
        suppressing = false
        print("openwispr: echo detector disabled: analysis took \(String(format: "%.1f", ms)) ms")
    }
}

/// Zeroes the samples of `samples` (starting at session sample `start`) covered by `spans`.
public func silenceSpans(_ samples: inout [Float], start: Int, spans: [EchoSpan]) {
    for span in spans {
        let from = max(0, span.start - start)
        let to = min(samples.count, span.end - start)
        if to > from { for i in from..<to { samples[i] = 0 } }
    }
}

/// Normalized cross-correlation peak and lag of `x` against `y`; a positive lag means `x` trails `y`.
public func gccPhat(_ fft: Fft, _ x: [Double], _ y: [Double]) -> (score: Double, lag: Int) {
    let n = fft.size
    var xr = x
    var xi = [Double](repeating: 0, count: n)
    var yr = y
    var yi = [Double](repeating: 0, count: n)
    fft.transform(&xr, &xi, inverse: false)
    fft.transform(&yr, &yi, inverse: false)
    // The cross spectrum X·conj(Y), whitened to unit magnitude.
    var re = vDSP.add(vDSP.multiply(xr, yr), vDSP.multiply(xi, yi))
    var im = vDSP.subtract(vDSP.multiply(xi, yr), vDSP.multiply(xr, yi))
    let magnitude = vDSP.add(1e-12, vDSP.hypot(re, im))
    re = vDSP.divide(re, magnitude)
    im = vDSP.divide(im, magnitude)
    fft.transform(&re, &im, inverse: true)
    let (index, score) = vDSP.indexOfMaximum(vDSP.hypot(re, im))
    let lag = Int(index)
    return (score, lag <= n / 2 ? lag : lag - n)
}

/// In-place complex FFT on Accelerate; the inverse is scaled by 1/n.
public final class Fft: @unchecked Sendable {
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetupD

    public init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        log2n = vDSP_Length(size.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { fatalError("Couldn't create an FFT of size \(size)") }
        self.setup = setup
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    public func transform(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        re.withUnsafeMutableBufferPointer { real in
            im.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPDoubleSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                vDSP_fft_zipD(setup, &split, 1, log2n, FFTDirection(inverse ? kFFTDirection_Inverse : kFFTDirection_Forward))
                if inverse {
                    var scale = 1 / Double(size)
                    vDSP_vsmulD(real.baseAddress!, 1, &scale, real.baseAddress!, 1, vDSP_Length(size))
                    vDSP_vsmulD(imaginary.baseAddress!, 1, &scale, imaginary.baseAddress!, 1, vDSP_Length(size))
                }
            }
        }
    }
}

/// Holds the latest samples of one stream, addressed by session sample.
private final class SampleRing {
    private var buffer: [Float]
    private let capacity: Int
    private(set) var start = 0
    private(set) var end = 0
    private(set) var isEmpty = true

    init(capacity: Int) {
        self.capacity = capacity
        buffer = [Float](repeating: 0, count: capacity)
    }

    func write(_ frame: [Float], at position: Int) {
        if isEmpty {
            start = position
            end = position
            isEmpty = false
        }
        // Gaps (a capture that started late or stalled) read back as silence.
        if end < position {
            for i in end..<min(position, end + capacity) { buffer[slot(i)] = 0 }
        }
        for (i, sample) in frame.enumerated() { buffer[slot(position + i)] = sample }
        end = max(end, position + frame.count)
    }

    func read(from: Int, into out: inout [Float]) {
        for i in 0..<out.count { out[i] = sample(at: from + i) }
    }

    func rms(_ from: Int, _ to: Int) -> Float {
        guard to > from else { return 0 }
        var sum: Float = 0
        for i in from..<to {
            let value = sample(at: i)
            sum += value * value
        }
        return (sum / Float(to - from)).squareRoot()
    }

    private func slot(_ index: Int) -> Int { ((index % capacity) + capacity) % capacity }

    private func sample(at index: Int) -> Float {
        if index < start || index >= end || index < end - capacity { return 0 }
        return buffer[slot(index)]
    }
}

/// Blackman-windowed sinc low-pass with unit DC gain; `cutoff` is in cycles per input sample.
private func lowpassTaps(count: Int, cutoff: Double) -> [Double] {
    let middle = Double(count - 1) / 2
    var taps = (0..<count).map { i -> Double in
        let t = Double(i) - middle
        let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
        let window = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(count - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(count - 1))
        return sinc * window
    }
    let sum = taps.reduce(0, +)
    for i in taps.indices { taps[i] /= sum }
    return taps
}

/// Low-pass filters and downsamples `input` by `factor` into `out`, removing the mean.
private func decimate(_ input: [Float], taps: [Double], factor: Int, into out: inout [Double]) {
    let middle = (taps.count - 1) >> 1
    // Zero padding on both sides stands in for samples past the window's edges.
    var padded = [Double](repeating: 0, count: (out.count - 1) * factor + taps.count)
    let copied = min(input.count, padded.count - middle)
    padded.withUnsafeMutableBufferPointer { buffer in
        input.withUnsafeBufferPointer { source in
            vDSP_vspdp(source.baseAddress!, 1, buffer.baseAddress! + middle, 1, vDSP_Length(copied))
        }
    }
    vDSP_desampD(padded, vDSP_Stride(factor), taps, &out, vDSP_Length(out.count), vDSP_Length(taps.count))
    let mean = vDSP.mean(out)
    vDSP.add(-mean, out, result: &out)
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let mid = sorted.count >> 1
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}
