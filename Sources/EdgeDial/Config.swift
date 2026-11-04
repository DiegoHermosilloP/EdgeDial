import Foundation

enum DialAction: String, Codable, CaseIterable {
    case brightness
    case volume
    case keyboardBacklight
    case nightShift
    case none

    var displayName: String {
        switch self {
        case .brightness: return "Screen Brightness"
        case .volume: return "Volume"
        case .keyboardBacklight: return "Keyboard Backlight"
        case .nightShift: return "Night Shift Warmth"
        case .none: return "Nothing"
        }
    }
}

struct Config: Codable {
    /// Master switch. Mirrored by the menu bar toggle.
    var enabled = true

    /// What the left and right edge strips control.
    var leftAction: DialAction = .brightness
    var rightAction: DialAction = .volume

    /// Width of each edge strip as a fraction of trackpad width.
    var leftZoneWidth = 0.18
    var rightZoneWidth = 0.18

    /// How long a finger must rest still in a strip before the dial arms.
    var dwellMilliseconds = 300.0

    /// How far the finger may wander during the dwell, as a fraction of the
    /// trackpad diagonal, before it is treated as a cursor move instead.
    var dwellJitter = 0.035

    /// Value change produced by sliding the full height of the trackpad.
    /// 1.0 = exactly one full range per full-height swipe.
    var sensitivity = 1.5

    /// Slide up to decrease instead of increase.
    var invertDirection = false

    /// Ignore the gesture unless exactly this many fingers are down.
    var requiredFingerCount = 1

    /// Reject contacts smaller than this, which filters out stray brushes.
    var minimumTouchSize = 0.08

    /// Pin the pointer in place while a dial is active.
    var freezeCursor = true

    /// Haptic tick when a dial arms and at the ends of the range.
    var hapticFeedback = true

    /// Show EdgeDial's own on-screen indicator.
    var showHUD = true

    /// Steps the HUD bar is divided into. 0 draws a continuous bar.
    var hudSegments = 16

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EdgeDial/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data("EdgeDial: config.json is not valid, using defaults (\(error))\n".utf8))
            return Config()
        }
    }

    func save() throws {
        let url = Config.fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Clamps anything a hand-edited file could get wrong.
    var sanitized: Config {
        var copy = self
        copy.leftZoneWidth = min(max(leftZoneWidth, 0.02), 0.45)
        copy.rightZoneWidth = min(max(rightZoneWidth, 0.02), 0.45)
        copy.dwellMilliseconds = min(max(dwellMilliseconds, 0), 3000)
        copy.dwellJitter = min(max(dwellJitter, 0.002), 0.3)
        copy.sensitivity = min(max(sensitivity, 0.1), 10)
        copy.requiredFingerCount = min(max(requiredFingerCount, 1), 5)
        copy.minimumTouchSize = min(max(minimumTouchSize, 0), 2)
        copy.hudSegments = min(max(hudSegments, 0), 64)
        return copy
    }
}
