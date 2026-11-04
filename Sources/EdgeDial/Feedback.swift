import AppKit

/// macOS moves the volume in sixteenths, and the volume keys play one tick per
/// step. Matching that number keeps a slide feeling like holding the key down
/// rather than like a continuous sweep.
enum VolumeStep {
    static let count = 16

    /// Which of the sixteen steps a 0...1 level falls on.
    static func index(for value: Double) -> Int {
        let clamped = min(max(value, 0), 1)
        return Int((clamped * Double(count)).rounded())
    }
}

/// Plays the system volume tick, the one the volume keys make.
///
/// Deliberately `NSSound` rather than `AudioServicesPlaySystemSound`: NSSound
/// goes out through the default output device, so the tick is heard *at* the
/// level just set. That is the entire point of the sound — it is how you judge
/// the new volume without looking.
final class VolumeFeedbackSound {
    /// Newest first. The CoreAudio component holds the sound the media keys
    /// use; BezelServices is where it lived on older systems.
    private static let candidatePaths = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Media Keys.aif",
        "/System/Library/Components/CoreAudio.component/Contents/Resources/SystemSounds/system/Media Keys.aif",
        "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
    ]

    private let sound: NSSound?
    private var lastPlayed: Double = 0

    /// Sliding can cross steps far faster than a key repeat ever would, and
    /// restarting the clip every few milliseconds just sounds like a rattle.
    private let minimumInterval: Double = 0.045

    init() {
        let path = VolumeFeedbackSound.candidatePaths.first {
            FileManager.default.fileExists(atPath: $0)
        }
        // byReference: the file is read from disk rather than copied into the
        // app, so it always matches whatever the current macOS ships.
        sound = path.flatMap { NSSound(contentsOfFile: $0, byReference: true) }
    }

    var isAvailable: Bool { sound != nil }

    /// Whether macOS's own "Play feedback when volume is changed" is on.
    /// Read fresh so toggling it in System Settings takes effect immediately.
    static var systemFeedbackEnabled: Bool {
        guard let value = UserDefaults.standard.object(
            forKey: "com.apple.sound.beep.feedback") else { return true }
        if let number = value as? NSNumber { return number.boolValue }
        return true
    }

    func play() {
        guard let sound else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPlayed >= minimumInterval else { return }
        lastPlayed = now
        // Restart rather than overlap, which is what holding the key down does.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
