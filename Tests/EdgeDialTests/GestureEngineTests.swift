import XCTest

@testable import EdgeDial

/// The state machine decides whether a finger near the edge is a deliberate
/// dial or just the tail end of a cursor move, so it is worth pinning down.
final class GestureEngineTests: XCTestCase {
    private var engine: GestureEngine!
    private var recorder: Recorder!
    private var clock: Double = 0

    private final class Recorder: GestureEngineDelegate {
        enum Event: Equatable {
            case armed(String)
            case slid(String, Double)
            case ended(String)
        }
        var events: [Event] = []

        func gestureEngine(_ engine: GestureEngine, didArm side: DialSide) {
            events.append(.armed(side == .left ? "left" : "right"))
        }
        func gestureEngine(_ engine: GestureEngine, didSlide side: DialSide, by delta: Double) {
            events.append(.slid(side == .left ? "left" : "right", delta))
        }
        func gestureEngine(_ engine: GestureEngine, didEnd side: DialSide) {
            events.append(.ended(side == .left ? "left" : "right"))
        }

        var arms: [Event] { events.filter { if case .armed = $0 { return true }; return false } }
        var slides: [Double] {
            events.compactMap { if case .slid(_, let d) = $0 { return d }; return nil }
        }
    }

    override func setUp() {
        super.setUp()
        var config = Config()
        config.dwellMilliseconds = 300
        config.dwellJitter = 0.035
        config.sensitivity = 1.0
        config.leftZoneWidth = 0.18
        config.rightZoneWidth = 0.18
        recorder = Recorder()
        engine = GestureEngine(config: config)
        engine.delegate = recorder
        clock = 0
    }

    // MARK: - Helpers

    private func touch(x: Float, y: Float, id: Int32 = 1, size: Float = 0.5) -> MTTouch {
        MTTouch(
            frame: 0, timestamp: clock, identifier: id, state: 4, fingerID: id, handID: 1,
            normalized: MTReadout(
                position: MTPoint(x: x, y: y), velocity: MTPoint(x: 0, y: 0)),
            size: size, pressure: 0, angle: 0, majorAxis: 0, minorAxis: 0,
            absolute: MTReadout(
                position: MTPoint(x: 0, y: 0), velocity: MTPoint(x: 0, y: 0)),
            reserved0: 0, reserved1: 0, density: 0)
    }

    /// Advances the clock and feeds one frame.
    private func send(_ touches: [MTTouch], after seconds: Double = 0.016) {
        clock += seconds
        engine.handle(frame: TouchFrame(touches: touches, timestamp: clock))
    }

    private func liftOff() {
        send([])
    }

    /// Holds a finger still at a point for long enough to arm.
    private func dwell(x: Float, y: Float) {
        for _ in 0..<25 { send([touch(x: x, y: y)], after: 0.02) }
    }

    // MARK: - Arming

    func testRestingInLeftZoneArmsAfterDwell() {
        dwell(x: 0.05, y: 0.5)
        XCTAssertEqual(recorder.arms, [.armed("left")])
    }

    func testRestingInRightZoneArmsAfterDwell() {
        dwell(x: 0.95, y: 0.5)
        XCTAssertEqual(recorder.arms, [.armed("right")])
    }

    func testDoesNotArmBeforeDwellElapses() {
        // 200ms of stillness is under the 300ms threshold.
        for _ in 0..<10 { send([touch(x: 0.05, y: 0.5)], after: 0.02) }
        XCTAssertTrue(recorder.arms.isEmpty)
    }

    func testCentreOfTrackpadNeverArms() {
        dwell(x: 0.5, y: 0.5)
        XCTAssertTrue(recorder.arms.isEmpty)
    }

    func testArmsOnlyOnceWhileHeld() {
        dwell(x: 0.05, y: 0.5)
        dwell(x: 0.05, y: 0.5)
        XCTAssertEqual(recorder.arms.count, 1)
    }

    // MARK: - Rejection rules

    func testCursorMoveEndingInZoneDoesNotArm() {
        // The whole point of the design: a finger that lands mid-pad and then
        // travels into the edge strip is a cursor move, not a dial.
        send([touch(x: 0.5, y: 0.5)])
        for step in 1...20 {
            send([touch(x: 0.5 - Float(step) * 0.023, y: 0.5)], after: 0.02)
        }
        dwell(x: 0.05, y: 0.5)
        XCTAssertTrue(recorder.arms.isEmpty, "a swipe into the edge must not arm a dial")
    }

    func testWanderingDuringDwellCancels() {
        for _ in 0..<5 { send([touch(x: 0.05, y: 0.5)], after: 0.02) }
        // Drift well past the jitter radius before the dwell completes.
        send([touch(x: 0.05, y: 0.62)], after: 0.02)
        dwell(x: 0.05, y: 0.62)
        XCTAssertTrue(recorder.arms.isEmpty)
    }

    func testRejectionClearsOnlyAfterLiftOff() {
        dwell(x: 0.5, y: 0.5)
        XCTAssertTrue(recorder.arms.isEmpty)
        liftOff()
        dwell(x: 0.05, y: 0.5)
        XCTAssertEqual(recorder.arms, [.armed("left")])
    }

    func testSecondFingerCancelsAnActiveDial() {
        dwell(x: 0.05, y: 0.5)
        XCTAssertEqual(recorder.arms.count, 1)
        send([touch(x: 0.05, y: 0.5, id: 1), touch(x: 0.4, y: 0.5, id: 2)])
        XCTAssertEqual(recorder.events.last, .ended("left"))
    }

    func testTinyContactsAreIgnored() {
        for _ in 0..<25 { send([touch(x: 0.05, y: 0.5, size: 0.01)], after: 0.02) }
        XCTAssertTrue(recorder.arms.isEmpty)
    }

    func testDisabledEngineNeverArms() {
        engine.config.enabled = false
        dwell(x: 0.05, y: 0.5)
        XCTAssertTrue(recorder.arms.isEmpty)
    }

    func testZoneMappedToNothingDoesNotArm() {
        engine.config.leftAction = .none
        dwell(x: 0.05, y: 0.5)
        XCTAssertTrue(recorder.arms.isEmpty)
    }

    // MARK: - Sliding

    func testSlidingUpProducesPositiveDelta() {
        dwell(x: 0.05, y: 0.3)
        send([touch(x: 0.05, y: 0.5)])
        XCTAssertEqual(recorder.slides.reduce(0, +), 0.2, accuracy: 0.0001)
    }

    func testSlidingDownProducesNegativeDelta() {
        dwell(x: 0.05, y: 0.5)
        send([touch(x: 0.05, y: 0.3)])
        XCTAssertEqual(recorder.slides.reduce(0, +), -0.2, accuracy: 0.0001)
    }

    func testInvertFlipsDirection() {
        engine.config.invertDirection = true
        dwell(x: 0.05, y: 0.3)
        send([touch(x: 0.05, y: 0.5)])
        XCTAssertEqual(recorder.slides.reduce(0, +), -0.2, accuracy: 0.0001)
    }

    func testSensitivityScalesTravel() {
        engine.config.sensitivity = 2.0
        dwell(x: 0.05, y: 0.3)
        send([touch(x: 0.05, y: 0.5)])
        XCTAssertEqual(recorder.slides.reduce(0, +), 0.4, accuracy: 0.0001)
    }

    func testFullTravelAccumulatesAcrossManyFrames() {
        // Sixty small steps should sum to the same total as one big jump.
        dwell(x: 0.05, y: 0.2)
        for step in 1...60 {
            send([touch(x: 0.05, y: 0.2 + Float(step) * 0.01)], after: 0.008)
        }
        XCTAssertEqual(recorder.slides.reduce(0, +), 0.6, accuracy: 0.001)
    }

    func testHorizontalDriftWhileActiveDoesNotEndTheDial() {
        dwell(x: 0.05, y: 0.5)
        // Leaving the strip sideways is fine once the dial is running.
        send([touch(x: 0.40, y: 0.6)])
        XCTAssertFalse(recorder.events.contains(.ended("left")))
        XCTAssertEqual(recorder.slides.reduce(0, +), 0.1, accuracy: 0.0001)
    }

    // MARK: - Ending

    func testLiftOffEndsTheDial() {
        dwell(x: 0.05, y: 0.5)
        liftOff()
        XCTAssertEqual(recorder.events.last, .ended("left"))
    }

    func testNoEndEventWhenNothingWasArmed() {
        dwell(x: 0.5, y: 0.5)
        liftOff()
        XCTAssertFalse(recorder.events.contains(.ended("left")))
        XCTAssertFalse(recorder.events.contains(.ended("right")))
    }

    // MARK: - Config hygiene

    func testSanitizeClampsHandEditedValues() {
        var config = Config()
        config.leftZoneWidth = 9
        config.sensitivity = -4
        config.requiredFingerCount = 99
        config.dwellMilliseconds = -10
        let clean = config.sanitized
        XCTAssertEqual(clean.leftZoneWidth, 0.45)
        XCTAssertEqual(clean.sensitivity, 0.1)
        XCTAssertEqual(clean.requiredFingerCount, 5)
        XCTAssertEqual(clean.dwellMilliseconds, 0)
    }

    func testTouchStructMatchesFrameworkLayout() {
        XCTAssertTrue(MultitouchDevice.verifyLayout(), "MTTouch must stay 96 bytes")
    }
}

/// The hold-delay submenu has to stay honest about what is currently in effect,
/// including values that only the settings file can produce.
final class HoldDelayMenuTests: XCTestCase {
    func testPresetValueIsPresentExactlyOnce() {
        let options = AppDelegate.holdDelayOptions(current: 300)
        XCTAssertEqual(options.filter { $0.value == 300 }.count, 1)
        XCTAssertEqual(options.count, 7, "a preset value must not add a Custom row")
    }

    func testHandEditedValueGetsItsOwnRow() {
        let options = AppDelegate.holdDelayOptions(current: 275)
        XCTAssertEqual(options.count, 8)
        let custom = options.first { $0.value == 275 }
        XCTAssertNotNil(custom)
        XCTAssertTrue(custom?.label.contains("Custom") == true)
    }

    func testOptionsStaySortedWithACustomValue() {
        let values = AppDelegate.holdDelayOptions(current: 275).map(\.value)
        XCTAssertEqual(values, values.sorted())
    }

    func testEveryPresetSurvivesConfigSanitising() {
        // A preset the sanitiser would clamp would check a row that is not
        // what actually took effect.
        for preset in AppDelegate.holdDelayOptions(current: 300) {
            var config = Config()
            config.dwellMilliseconds = preset.value
            XCTAssertEqual(
                config.sanitized.dwellMilliseconds, preset.value,
                "preset \(preset.label) is outside the allowed range")
        }
    }
}

/// A settings file outlives the build that wrote it, so decoding has to cope
/// with keys that did not exist yet and keys that no longer do.
final class ConfigCompatibilityTests: XCTestCase {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    func testFileFromAnOlderBuildKeepsItsSettings() throws {
        // No volumeFeedbackSound key: this is what upgrading looks like.
        let config = try decode(#"""
            {"dwellMilliseconds": 500, "leftAction": "volume", "sensitivity": 3.0}
        """#)
        XCTAssertEqual(config.dwellMilliseconds, 500, "a tuned value must survive")
        XCTAssertEqual(config.leftAction, .volume)
        XCTAssertEqual(config.sensitivity, 3.0)
        XCTAssertTrue(config.volumeFeedbackSound, "a new key falls back to its default")
    }

    func testEmptyObjectYieldsDefaults() throws {
        let config = try decode("{}")
        XCTAssertEqual(config.dwellMilliseconds, Config().dwellMilliseconds)
        XCTAssertEqual(config.leftAction, .brightness)
        XCTAssertEqual(config.rightAction, .volume)
    }

    func testUnknownKeysAreIgnored() throws {
        // A key from a build that was later reverted must not break the file.
        let config = try decode(#"{"enabled": false, "keyboardBacklightStep": 7}"#)
        XCTAssertFalse(config.enabled)
    }

    func testAWronglyTypedValueFallsBackInsteadOfWipingTheFile() throws {
        let config = try decode(#"{"dwellMilliseconds": "fast", "sensitivity": 2.5}"#)
        XCTAssertEqual(config.dwellMilliseconds, Config().dwellMilliseconds)
        XCTAssertEqual(config.sensitivity, 2.5, "other keys must still be read")
    }

    func testRoundTripSurvivesEncoding() throws {
        var original = Config()
        original.dwellMilliseconds = 400
        original.volumeFeedbackSound = false
        original.hudSegments = 0
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(restored.dwellMilliseconds, 400)
        XCTAssertFalse(restored.volumeFeedbackSound)
        XCTAssertEqual(restored.hudSegments, 0)
    }

    func testIndicatorDefaultsToAContinuousBar() {
        XCTAssertEqual(Config().hudSegments, 0)
    }
}

/// The tick has to fire once per step, matching what the volume keys do.
final class VolumeStepTests: XCTestCase {
    func testMatchesTheSixteenStepsMacOSUses() {
        XCTAssertEqual(VolumeStep.count, 16)
        XCTAssertEqual(VolumeStep.index(for: 0), 0)
        XCTAssertEqual(VolumeStep.index(for: 1), 16)
    }

    func testAFullSweepCrossesEveryStepExactlyOnce() {
        var ticks = 0
        var previous = VolumeStep.index(for: 0)
        // 400 frames is roughly a slow slide at 120 Hz.
        for frame in 1...400 {
            let step = VolumeStep.index(for: Double(frame) / 400)
            if step != previous { ticks += 1; previous = step }
        }
        XCTAssertEqual(ticks, 16, "a 0→1 slide should tick once per step")
    }

    func testSmallMovementsWithinAStepDoNotTick() {
        let start = VolumeStep.index(for: 0.50)
        XCTAssertEqual(VolumeStep.index(for: 0.51), start)
        XCTAssertEqual(VolumeStep.index(for: 0.52), start)
    }

    func testValuesOutsideRangeAreClamped() {
        XCTAssertEqual(VolumeStep.index(for: -5), 0)
        XCTAssertEqual(VolumeStep.index(for: 5), 16)
    }
}
