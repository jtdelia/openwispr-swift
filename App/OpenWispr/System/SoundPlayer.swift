import AVFoundation
import OpenWisprCore

/// Short synthesized cues so the app ships no audio assets.
@MainActor
final class SoundPlayer {
    private struct Tone {
        var frequency: Double
        var start: Double
        var duration: Double
        var gain: Double = 0.08
    }

    private static let sampleRate = 44_100.0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]

    init() {
        engine.attach(player)
        try? engine.connectNode(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ sound: Sound) {
        let buffer = buffers[sound] ?? render(Self.tones(sound))
        buffers[sound] = buffer
        do {
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            try player.playAudio()
        } catch {
            return
        }
    }

    private static func tones(_ sound: Sound) -> [Tone] {
        switch sound {
        case .start: [Tone(frequency: 660, start: 0, duration: 0.09), Tone(frequency: 880, start: 0.07, duration: 0.12)]
        case .stop: [Tone(frequency: 880, start: 0, duration: 0.09), Tone(frequency: 600, start: 0.07, duration: 0.12)]
        case .lock:
            [Tone(frequency: 880, start: 0, duration: 0.07), Tone(frequency: 880, start: 0.1, duration: 0.07), Tone(frequency: 1175, start: 0.2, duration: 0.12)]
        case .error: [Tone(frequency: 220, start: 0, duration: 0.25, gain: 0.1)]
        }
    }

    /// Sine tones with a 10 ms linear attack and an exponential decay to -80 dB, like the Web Audio original.
    private func render(_ tones: [Tone]) -> AVAudioPCMBuffer {
        let end = tones.map { $0.start + $0.duration + 0.02 }.max() ?? 0
        let frames = AVAudioFrameCount(end * Self.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) { samples[index] = 0 }
        for tone in tones {
            let first = Int(tone.start * Self.sampleRate)
            let count = Int((tone.duration + 0.02) * Self.sampleRate)
            for offset in 0..<count where first + offset < Int(frames) {
                let time = Double(offset) / Self.sampleRate
                let envelope: Double
                if time < 0.01 {
                    envelope = tone.gain * time / 0.01
                } else if time < tone.duration {
                    envelope = tone.gain * pow(0.0001 / tone.gain, (time - 0.01) / (tone.duration - 0.01))
                } else {
                    envelope = 0.0001 * (1 - (time - tone.duration) / 0.02)
                }
                samples[first + offset] += Float(envelope * sin(2 * .pi * tone.frequency * time))
            }
        }
        return buffer
    }
}
