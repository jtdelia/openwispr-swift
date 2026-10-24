import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the Mac plays, except this app's own sounds, through a Core Audio process tap
/// on a private aggregate device. The first use asks for "System Audio Recording Only" permission.
final class SystemAudioTap: @unchecked Sendable {
    private static let unavailable = "System audio is unavailable. Allow it in System Settings → Privacy & Security → Screen & System Audio Recording."

    private let queue = DispatchQueue(label: "openwispr.system-audio", qos: .userInitiated)
    private var tapId = AudioObjectID(kAudioObjectUnknown)
    private var aggregateId = AudioObjectID(kAudioObjectUnknown)
    private var procId: AudioDeviceIOProcID?

    func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "OpenWispr meeting audio"

        guard AudioHardwareCreateProcessTap(description, &tapId) == noErr else { throw CaptureError.systemAudio(Self.unavailable) }

        guard let outputUid = defaultOutputUid() else {
            stop()
            throw CaptureError.systemAudio("No audio output device is available to listen to.")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenWispr Meeting Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateId) == noErr else {
            stop()
            throw CaptureError.systemAudio(Self.unavailable)
        }

        guard var streamDescription = tapFormat(), let format = AVAudioFormat(streamDescription: &streamDescription) else {
            stop()
            throw CaptureError.systemAudio(Self.unavailable)
        }
        let resampler = try Resampler(from: format)
        let status = AudioDeviceCreateIOProcIDWithBlock(&procId, aggregateId, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            onSamples(resampler.convert(buffer))
        }
        guard status == noErr, AudioDeviceStart(aggregateId, procId) == noErr else {
            stop()
            throw CaptureError.systemAudio(Self.unavailable)
        }
    }

    func stop() {
        if aggregateId != kAudioObjectUnknown {
            if let procId {
                AudioDeviceStop(aggregateId, procId)
                AudioDeviceDestroyIOProcID(aggregateId, procId)
            }
            AudioHardwareDestroyAggregateDevice(aggregateId)
        }
        if tapId != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapId) }
        procId = nil
        aggregateId = AudioObjectID(kAudioObjectUnknown)
        tapId = AudioObjectID(kAudioObjectUnknown)
    }

    private func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func defaultOutputUid() -> String? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return AudioDevices.stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private func tapFormat() -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapId, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}
