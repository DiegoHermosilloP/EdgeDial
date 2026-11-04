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

// MARK: - Keyboard backlight

/// Keyboard backlight through CoreBrightness. Same private-framework caveat as
/// `BrightnessControl`, and the same reason: the alternative is synthesising
/// the backlight keys, which would cost an Accessibility grant.
final class KeyboardBacklightControl: LevelControl {
    @objc private protocol KeyboardBrightnessClientProtocol {
        @objc(copyKeyboardBacklightIDs)
        func copyKeyboardBacklightIDs() -> NSArray?
        @objc(isKeyboardBuiltIn:)
        func isKeyboardBuiltIn(_ keyboardID: UInt64) -> Bool
        @objc(brightnessForKeyboard:)
        func brightness(forKeyboard keyboardID: UInt64) -> Float
        @objc(setBrightness:forKeyboard:)
        func setBrightness(_ value: Float, forKeyboard keyboardID: UInt64) -> Bool
    }

    private let client: KeyboardBrightnessClientProtocol?
    private let keyboardID: UInt64?

    init() {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let type = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
            client = nil
            keyboardID = nil
            return
        }
        let instance = type.init()
        let typed = unsafeBitCast(instance, to: KeyboardBrightnessClientProtocol.self)
        client = typed

        // A Mac with no backlit keyboard reports no IDs at all.
        let ids = (typed.copyKeyboardBacklightIDs() as? [NSNumber])?.map(\.uint64Value) ?? []
        keyboardID = ids.first(where: { typed.isKeyboardBuiltIn($0) }) ?? ids.first
    }

    var isAvailable: Bool { client != nil && keyboardID != nil }

    func read() -> Double? {
        guard let client, let keyboardID else { return nil }
        let value = client.brightness(forKeyboard: keyboardID)
        return value.isFinite && value >= 0 ? Double(value) : nil
    }

    func write(_ value: Double) {
        guard let client, let keyboardID else { return }
        _ = client.setBrightness(Float(min(max(value, 0), 1)), forKeyboard: keyboardID)
    }
}

// MARK: - Night Shift

/// Night Shift warmth. Strength alone is invisible while Night Shift is off, so
/// the dial switches it on as soon as you slide up from zero and off again when
/// you slide back down — otherwise the first half of the gesture would appear
/// to do nothing.
final class NightShiftControl: LevelControl {
    @objc private protocol BlueLightClientProtocol {
        @objc(setStrength:commit:)
        func setStrength(_ strength: Float, commit: Bool) -> Bool
        @objc(getStrength:)
        func getStrength(_ strength: UnsafeMutablePointer<Float>) -> Bool
        @objc(setEnabled:)
        func setEnabled(_ enabled: Bool) -> Bool
        @objc(getBlueLightStatus:)
        func getBlueLightStatus(_ status: UnsafeMutableRawPointer) -> Bool
    }

    /// Below this, treat the dial as off rather than imperceptibly warm.
    private static let onThreshold = 0.02

    private let client: BlueLightClientProtocol?
    private var isOn = false

    init() {
        _ = dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        guard let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
            client = nil
            return
        }
        client = unsafeBitCast(type.init(), to: BlueLightClientProtocol.self)
    }

    var isAvailable: Bool { client != nil && read() != nil }

    /// The status struct's layout is undocumented, so rather than declare it,
    /// hand over a generous zeroed buffer and read only `active`, which is the
    /// first byte and the one field whose position is not in doubt.
    private func isActive() -> Bool {
        guard let client else { return false }
        let size = 256
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        guard client.getBlueLightStatus(buffer) else { return false }
        return buffer.load(as: UInt8.self) != 0
    }

    func read() -> Double? {
        guard let client else { return nil }
        var strength: Float = 0
        guard client.getStrength(&strength) else { return nil }
        isOn = isActive()
        // Night Shift remembers a strength while switched off; reporting that
        // would start the dial somewhere the screen plainly is not.
        return isOn ? Double(strength) : 0
    }

    func write(_ value: Double) {
        guard let client else { return }
        let clamped = min(max(value, 0), 1)
        let shouldBeOn = clamped > NightShiftControl.onThreshold

        if shouldBeOn != isOn {
            _ = client.setEnabled(shouldBeOn)
            isOn = shouldBeOn
        }
        if shouldBeOn {
            _ = client.setStrength(Float(clamped), commit: true)
        }
    }
}
