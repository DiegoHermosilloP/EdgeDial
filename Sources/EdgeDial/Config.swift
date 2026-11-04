import Foundation

enum DialAction: String, Codable, CaseIterable {
    case brightness
    case volume
    case none

    var displayName: String {
        switch self {
        case .brightness: return "Brightness"
        case .volume: return "Volume"
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

    /// Play the system volume tick as the volume dial crosses each step, the
    /// way the volume keys do. Also gated on macOS's own "Play feedback when
    /// volume is changed" setting.
    var volumeFeedbackSound = true

    /// Show EdgeDial's own on-screen indicator.
    var showHUD = true

    /// Steps the HUD bar is divided into. 0 draws a continuous bar.
    var hudSegments = 0

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("EdgeDial/config.json")
    }

    init() {}

    // MARK: - Decoding
    //
    // Swift's synthesised decoder throws on a missing key even when the
    // property has a default value, so a settings file written by an older
    // build would fail to decode the moment a new key is added — and every
    // setting the user had tuned would silently revert. Decoding each key
    // independently means old files keep working and unknown keys are ignored.

    private enum CodingKeys: String, CodingKey {
        case enabled
        case leftAction, rightAction
        case leftZoneWidth, rightZoneWidth
        case dwellMilliseconds, dwellJitter
        case sensitivity, invertDirection
        case requiredFingerCount, minimumTouchSize
        case freezeCursor, hapticFeedback, volumeFeedbackSound
        case showHUD, hudSegments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()

        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? `default`
        }

        enabled = value(.enabled, fallback.enabled)
        leftAction = value(.leftAction, fallback.leftAction)
        rightAction = value(.rightAction, fallback.rightAction)
        leftZoneWidth = value(.leftZoneWidth, fallback.leftZoneWidth)
        rightZoneWidth = value(.rightZoneWidth, fallback.rightZoneWidth)
        dwellMilliseconds = value(.dwellMilliseconds, fallback.dwellMilliseconds)
        dwellJitter = value(.dwellJitter, fallback.dwellJitter)
        sensitivity = value(.sensitivity, fallback.sensitivity)
        invertDirection = value(.invertDirection, fallback.invertDirection)
        requiredFingerCount = value(.requiredFingerCount, fallback.requiredFingerCount)
        minimumTouchSize = value(.minimumTouchSize, fallback.minimumTouchSize)
        freezeCursor = value(.freezeCursor, fallback.freezeCursor)
        hapticFeedback = value(.hapticFeedback, fallback.hapticFeedback)
        volumeFeedbackSound = value(.volumeFeedbackSound, fallback.volumeFeedbackSound)
        showHUD = value(.showHUD, fallback.showHUD)
        hudSegments = value(.hudSegments, fallback.hudSegments)
    }

    // MARK: - Storage

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
