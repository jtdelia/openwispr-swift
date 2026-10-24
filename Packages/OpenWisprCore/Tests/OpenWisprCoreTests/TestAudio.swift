@testable import OpenWisprCore

let rate = 16_000

/// Mulberry32 white noise; a plain LCG's low bits correlate with shifted copies of themselves.
func noise(_ seconds: Double, _ amplitude: Float, seed: UInt32) -> [Float] {
    var state = seed
    return (0..<Int((seconds * Double(rate)).rounded())).map { _ in
        state &+= 0x6D2B_79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Float((Double(t ^ (t >> 14)) / 4_294_967_296) * 2 - 1) * amplitude
    }
}

func delayed(_ source: [Float], ms: Double, gain: Float) -> [Float] {
    let shift = Int((ms / 1000 * Double(rate)).rounded())
    var out = [Float](repeating: 0, count: source.count)
    for i in shift..<source.count { out[i] = source[i - shift] * gain }
    return out
}

func mix(_ parts: [Float]...) -> [Float] {
    var out = [Float](repeating: 0, count: parts[0].count)
    for part in parts {
        for i in out.indices { out[i] += part[i] }
    }
    return out
}

func fill(_ samples: inout [Float], from: Double, to: Double? = nil) {
    let start = Int((from * Double(rate)).rounded())
    let end = to.map { Int(($0 * Double(rate)).rounded()) } ?? samples.count
    for i in start..<min(end, samples.count) { samples[i] = 0 }
}

func frames(_ samples: [Float], size: Int) -> [(at: Int, frame: [Float])] {
    stride(from: 0, to: samples.count, by: size).map { ($0, Array(samples[$0..<min(samples.count, $0 + size)])) }
}
