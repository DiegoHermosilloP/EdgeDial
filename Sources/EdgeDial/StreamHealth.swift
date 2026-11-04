import Foundation

/// Decides when the trackpad stream has died and needs rebuilding.
///
/// The hard part is that "no touch frames" is the normal state — nobody is
/// touching the trackpad most of the time — so silence alone proves nothing.
/// The tell is silence *while the pointer is being driven*: on a laptop the
/// pointer only moves because a finger is on the glass, so frames must be
/// arriving. If they are not, the stream is gone.
enum StreamHealth {
    /// No frames for this long, with the pointer active, means a dead stream.
    static let silenceThreshold: Double = 5

    /// How recently the pointer must have moved for its silence to count.
    static let pointerActivityWindow: Double = 1.5

    enum Verdict: Equatable {
        case healthy
        /// The framework itself reports the device stopped.
        case deviceStopped
        /// The device claims to run but no frames arrive while the pointer moves.
        case silentlyDead
    }

    static func assess(
        deviceReportsRunning: Bool,
        secondsSinceLastFrame: Double,
        secondsSincePointerInput: Double
    ) -> Verdict {
        if !deviceReportsRunning { return .deviceStopped }
        if secondsSincePointerInput <= pointerActivityWindow,
           secondsSinceLastFrame > silenceThreshold {
            return .silentlyDead
        }
        return .healthy
    }
}
