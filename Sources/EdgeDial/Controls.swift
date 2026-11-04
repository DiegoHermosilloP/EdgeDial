import CoreAudio
import CoreGraphics
import Foundation

/// Something whose level EdgeDial can read and write in the 0...1 range.
protocol LevelControl {
    var isAvailable: Bool { get }
    func read() -> Double?
    func write(_ value: Double)
}

// MARK: - Brightness

/// Built-in display brightness via DisplayServices, which is what the
/// brightness keys themselves drive. Private, but it is the only route that
/// does not need Accessibility permission to synthesise key presses.
final class BrightnessControl: LevelControl {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private var getBrightness: GetFn?
    private var setBrightness: SetFn?

    init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ) else { return }
        if let raw = dlsym(handle, "DisplayServicesGetBrightness") {
            getBrightness = unsafeBitCast(raw, to: GetFn.self)
        }
        if let raw = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightness = unsafeBitCast(raw, to: SetFn.self)
        }
    }

    var isAvailable: Bool { getBrightness != nil && setBrightness != nil && displayID != nil }

    /// Resolved fresh each time: lid open/close and external displays change it.
    private var displayID: CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        if let builtIn = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) { return builtIn }
        return ids.first
    }

    func read() -> Double? {
        guard let getBrightness, let id = displayID else { return nil }
        var value: Float = 0
        guard getBrightness(id, &value) == 0 else { return nil }
        return Double(value)
    }

    func write(_ value: Double) {
        guard let setBrightness, let id = displayID else { return }
        _ = setBrightness(id, Float(min(max(value, 0), 1)))
    }
}

// MARK: - Volume

/// Default output device volume through CoreAudio. Public API, no permissions.
final class VolumeControl: LevelControl {
    private var device: AudioObjectID? {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Devices differ: some expose a main-element scalar, others only per-channel.
    private func volumeAddresses(for device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        var main = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(device, &main, &settable) == noErr, settable.boolValue {
                return [main]
            }
        }

        var stereoAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        _ = AudioObjectGetPropertyData(device, &stereoAddress, 0, nil, &size, &channels)

        return channels.map {
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: $0)
        }
    }

    var isAvailable: Bool {
        guard let device else { return false }
        return !volumeAddresses(for: device).isEmpty && read() != nil
    }

    func read() -> Double? {
        guard let device else { return nil }
        var total = 0.0
        var count = 0
        for var address in volumeAddresses(for: device) {
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                total += Double(value)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : nil
    }

    func write(_ value: Double) {
        guard let device else { return }
        let clamped = Float32(min(max(value, 0), 1))
        for var address in volumeAddresses(for: device) {
            var scalar = clamped
            let size = UInt32(MemoryLayout<Float32>.size)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &scalar)
        }
        // A device left muted stays silent however high the scalar goes, so a
        // deliberate volume-up should lift mute the way the volume keys do.
        setMuted(clamped <= 0.0001, on: device)
    }

    private func setMuted(_ muted: Bool, on device: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return }
        var value: UInt32 = muted ? 1 : 0
        _ = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}

final class NoopControl: LevelControl {
    var isAvailable: Bool { false }
    func read() -> Double? { nil }
    func write(_ value: Double) {}
}
