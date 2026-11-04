import Foundation

enum DialSide {
    case left
    case right
}

protocol GestureEngineDelegate: AnyObject {
    /// A dial just armed: the finger has rested in an edge strip long enough.
    func gestureEngine(_ engine: GestureEngine, didArm side: DialSide)
    /// The finger moved while armed. `delta` is a signed change in 0...1 units.
    func gestureEngine(_ engine: GestureEngine, didSlide side: DialSide, by delta: Double)
    /// The gesture ended, either by lifting off or by being cancelled.
    func gestureEngine(_ engine: GestureEngine, didEnd side: DialSide)
}

/// Turns a stream of raw trackpad frames into arm / slide / end events.
///
/// The state machine exists to separate "resting a finger near the edge on
/// purpose" from the far more common "moving the cursor from near the edge".
/// A gesture only arms if the finger stays inside a jitter radius for the whole
/// dwell; the moment it wanders, the touch is rejected and cannot re-arm until
/// every finger has left the trackpad. That last rule is what stops a dial from
/// snapping on halfway through an ordinary swipe.
final class GestureEngine {
    private enum State {
        case idle
        case dwelling(signature: [Int32], side: DialSide, origin: MTPoint, since: Double)
        case active(signature: [Int32], side: DialSide, lastY: Float)
        /// This set of fingers has disqualified itself; wait for liftoff.
        case rejected
    }

    weak var delegate: GestureEngineDelegate?
    var config: Config

    private var state: State = .idle
    /// Monotonic wall clock, used only for stall detection. Dwell timing uses the
    /// device's own frame timestamps so the two clocks never have to agree.
    private var lastFrameWallClock: Double = 0

    init(config: Config) {
        self.config = config
    }

    /// Call on the main thread, once per frame of trackpad data.
    func handle(frame: TouchFrame) {
        lastFrameWallClock = ProcessInfo.processInfo.systemUptime

        let touches = frame.touches.filter { Double($0.size) >= config.minimumTouchSize }

        guard config.enabled else {
            cancel()
            return
        }

        // Every finger gone: clean slate.
        if touches.isEmpty {
            cancel()
            return
        }

        guard touches.count == config.requiredFingerCount else {
            // Wrong number of fingers. If a dial was running, end it; either way
            // this contact group cannot arm until liftoff.
            cancelKeepingRejection()
            return
        }

        let signature = touches.map(\.identifier).sorted()
        let point = centroid(of: touches)

        switch state {
        case .rejected:
            return

        case .idle:
            guard let side = zone(containing: point) else {
                state = .rejected
                return
            }
            state = .dwelling(
                signature: signature, side: side, origin: point, since: frame.timestamp)

        case .dwelling(let armedSignature, let side, let origin, let since):
            guard armedSignature == signature else {
                state = .rejected
                return
            }
            if distance(point, origin) > config.dwellJitter {
                // The finger is on its way somewhere: this is a cursor move.
                state = .rejected
                return
            }
            if (frame.timestamp - since) * 1000 >= config.dwellMilliseconds {
                state = .active(signature: signature, side: side, lastY: point.y)
                delegate?.gestureEngine(self, didArm: side)
            }

        case .active(let armedSignature, let side, let lastY):
            guard armedSignature == signature else {
                delegate?.gestureEngine(self, didEnd: side)
                state = .rejected
                return
            }
            let dy = Double(point.y - lastY)
            state = .active(signature: signature, side: side, lastY: point.y)
            if dy != 0 {
                let sign = config.invertDirection ? -1.0 : 1.0
                delegate?.gestureEngine(self, didSlide: side, by: dy * config.sensitivity * sign)
            }
        }
    }

    /// Ends any running gesture and returns to idle. Used on disable, sleep and quit.
    func cancel() {
        if case .active(_, let side, _) = state {
            delegate?.gestureEngine(self, didEnd: side)
        }
        state = .idle
    }

    /// Like `cancel()` but keeps the current contact group disqualified.
    private func cancelKeepingRejection() {
        if case .active(_, let side, _) = state {
            delegate?.gestureEngine(self, didEnd: side)
        }
        state = .rejected
    }

    /// Ends a gesture that stopped receiving frames, e.g. across a sleep/wake.
    func checkForStall() {
        guard case .active = state else { return }
        if ProcessInfo.processInfo.systemUptime - lastFrameWallClock > 1.0 { cancel() }
    }

    var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    // MARK: - Geometry

    private func zone(containing point: MTPoint) -> DialSide? {
        let x = Double(point.x)
        if x <= config.leftZoneWidth, config.leftAction != .none { return .left }
        if x >= 1 - config.rightZoneWidth, config.rightAction != .none { return .right }
        return nil
    }

    private func centroid(of touches: [MTTouch]) -> MTPoint {
        guard touches.count > 1 else { return touches[0].normalized.position }
        var sumX: Float = 0
        var sumY: Float = 0
        for touch in touches {
            sumX += touch.normalized.position.x
            sumY += touch.normalized.position.y
        }
        let count = Float(touches.count)
        return MTPoint(x: sumX / count, y: sumY / count)
    }

    private func distance(_ a: MTPoint, _ b: MTPoint) -> Double {
        let dx = Double(a.x - b.x)
        let dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
