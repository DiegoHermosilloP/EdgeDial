import AppKit
import CoreGraphics

/// Glues the gesture engine to the actual system controls, the overlay, the
/// pointer lock and the haptics.
final class DialController: GestureEngineDelegate {
    private let engine: GestureEngine
    private let hud = HUD()
    private let brightness = BrightnessControl()
    private let volume = VolumeControl()
    private let keyboardBacklight = KeyboardBacklightControl()
    private let nightShift = NightShiftControl()
    private let noop = NoopControl()

    private var device: MultitouchDevice?
    private var stallTimer: Timer?

    /// Level of the dial currently being dragged, kept locally so a slide feels
    /// continuous even where the underlying control quantises what it stores.
    private var workingValue: Double = 0
    /// Set only once a dial has armed *and* its level was read successfully.
    /// Without it, a failed read would leave slides writing a stale value.
    private var armedAction: DialAction?
    private var didHitLimit = false
    private var cursorFrozen = false

    private(set) var config: Config
    private(set) var startupError: String?

    var isTrackpadConnected: Bool { device?.isRunning == true }

    init(config: Config) {
        self.config = config.sanitized
        self.engine = GestureEngine(config: self.config)
        self.engine.delegate = self
    }

    // MARK: - Lifecycle

    func start() {
        guard MultitouchDevice.verifyLayout() else {
            startupError = "Unexpected trackpad data layout on this macOS version."
            return
        }
        do {
            let device = try MultitouchDevice()
            device.onFrame = { [weak self] frame in
                // Frames arrive on the multitouch thread; all state lives on main.
                DispatchQueue.main.async { self?.engine.handle(frame: frame) }
            }
            device.start()
            self.device = device
            self.startupError = nil
        } catch {
            startupError = error.localizedDescription
            return
        }

        stallTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.engine.checkForStall()
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(
            self, selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
    }

    func stop() {
        engine.cancel()
        unfreezeCursor()
        stallTimer?.invalidate()
        stallTimer = nil
        device?.stop()
        device = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Always runs, including on an unclean exit, so the pointer can never be
    /// left detached from the trackpad.
    func emergencyRelease() {
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    func apply(config newConfig: Config) {
        config = newConfig.sanitized
        engine.config = config
        engine.cancel()
    }

    @objc private func handleWake() {
        // The multitouch stream can come back dead after a sleep.
        engine.cancel()
        unfreezeCursor()
        device?.restart()
    }

    @objc private func handleSleep() {
        engine.cancel()
        unfreezeCursor()
    }

    // MARK: - Dial wiring

    private func action(for side: DialSide) -> DialAction {
        side == .left ? config.leftAction : config.rightAction
    }

    private func control(for action: DialAction) -> LevelControl {
        switch action {
        case .brightness: return brightness
        case .volume: return volume
        case .keyboardBacklight: return keyboardBacklight
        case .nightShift: return nightShift
        case .none: return noop
        }
    }

    /// Whether this machine can actually drive the given action.
    func isAvailable(_ action: DialAction) -> Bool {
        action == .none || control(for: action).isAvailable
    }

    func gestureEngine(_ engine: GestureEngine, didArm side: DialSide) {
        let action = action(for: side)
        let control = control(for: action)
        guard let current = control.read() else {
            armedAction = nil
            return
        }

        armedAction = action
        workingValue = current
        didHitLimit = false

        if config.freezeCursor { freezeCursor() }
        if config.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if config.showHUD {
            hud.show(action: action, value: workingValue, segments: config.hudSegments)
        }
    }

    func gestureEngine(_ engine: GestureEngine, didSlide side: DialSide, by delta: Double) {
        let action = action(for: side)
        guard armedAction == action else { return }
        let control = control(for: action)

        let raw = workingValue + delta
        workingValue = min(max(raw, 0), 1)

        // One tick when a slide runs into either end, not one per frame.
        let atLimit = raw <= 0 || raw >= 1
        if atLimit, !didHitLimit, config.hapticFeedback {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        didHitLimit = atLimit

        control.write(workingValue)
        if config.showHUD {
            hud.show(action: action, value: workingValue, segments: config.hudSegments)
        }
    }

    func gestureEngine(_ engine: GestureEngine, didEnd side: DialSide) {
        armedAction = nil
        unfreezeCursor()
        hud.scheduleHide()
    }

    // MARK: - Pointer lock

    /// Detaching the pointer from the device keeps the cursor still during a
    /// slide. This is a plain CoreGraphics call, so it needs no permissions —
    /// unlike swallowing the movement events, which would need Accessibility.
    private func freezeCursor() {
        guard !cursorFrozen else { return }
        CGAssociateMouseAndMouseCursorPosition(0)
        cursorFrozen = true
    }

    private func unfreezeCursor() {
        guard cursorFrozen else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        cursorFrozen = false
    }
}
