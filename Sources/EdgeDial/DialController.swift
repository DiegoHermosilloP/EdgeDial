import AppKit
import CoreGraphics

/// Glues the gesture engine to the actual system controls, the overlay, the
/// pointer lock and the haptics.
final class DialController: GestureEngineDelegate {
    private let engine: GestureEngine
    private let hud = HUD()
    private let volumeSound = VolumeFeedbackSound()
    private let brightness = BrightnessControl()
    private let volume = VolumeControl()
    private let noop = NoopControl()

    private var device: MultitouchDevice?
    private var healthTimer: Timer?
    /// When a frame last arrived, on a clock we control.
    private var lastFrameAt: Double = ProcessInfo.processInfo.systemUptime
    private var lastRecoveryAt: Double = 0
    /// Grows when a rebuild does not bring frames back, so a Mac driven by an
    /// external mouse does not rebuild the device every few seconds forever.
    private var recoveryBackoff: Double = 5

    /// Level of the dial currently being dragged, kept locally so a slide feels
    /// continuous even where the underlying control quantises what it stores.
    private var workingValue: Double = 0
    /// Set only once a dial has armed *and* its level was read successfully.
    /// Without it, a failed read would leave slides writing a stale value.
    private var armedAction: DialAction?
    private var didHitLimit = false
    /// Which sixteenth the volume was on when a tick last played.
    private var lastVolumeStep: Int?
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
            try buildDevice()
            self.startupError = nil
        } catch {
            startupError = error.localizedDescription
            return
        }

        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.engine.checkForStall()
            self?.checkStreamHealth()
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
        healthTimer?.invalidate()
        healthTimer = nil
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
        engine.cancel()
        unfreezeCursor()
        // Do not rebuild immediately: on wake the trackpad is often not ready
        // yet, and a rebuild that lands too early fails silently and is never
        // retried — which is exactly how the dials used to go dead after a
        // lid-close. Clear the backoff and let the health check settle it.
        recoveryBackoff = 5
        lastRecoveryAt = 0
        lastFrameAt = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkStreamHealth(force: true)
        }
    }

    @objc private func handleSleep() {
        engine.cancel()
        unfreezeCursor()
    }

    // MARK: - Keeping the stream alive

    private func buildDevice() throws {
        device?.stop()
        device = nil

        let device = try MultitouchDevice()
        device.onFrame = { [weak self] frame in
            // Frames arrive on the multitouch thread; all state lives on main.
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastFrameAt = ProcessInfo.processInfo.systemUptime
                self.engine.handle(frame: frame)
            }
        }
        device.start()
        self.device = device
        lastFrameAt = ProcessInfo.processInfo.systemUptime
    }

    private func checkStreamHealth(force: Bool = false) {
        guard let device, startupError == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime

        // The pointer only moves on a laptop because a finger is on the glass,
        // so recent pointer activity means frames ought to be arriving.
        let pointerIdle = min(
            CGEventSource.secondsSinceLastEventType(
                .hidSystemState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(
                .hidSystemState, eventType: .scrollWheel))

        let verdict = StreamHealth.assess(
            deviceReportsRunning: device.isStreamLive,
            secondsSinceLastFrame: now - lastFrameAt,
            secondsSincePointerInput: pointerIdle)

        guard force || verdict != .healthy else {
            recoveryBackoff = 5
            return
        }
        guard force || now - lastRecoveryAt >= recoveryBackoff else { return }
        if verdict == .healthy, !force { return }

        lastRecoveryAt = now
        do {
            // A fresh device, not a restart of the old handle: after a sleep the
            // old one can be past saving, and starting it again reports success
            // while delivering nothing.
            try buildDevice()
        } catch {
            startupError = error.localizedDescription
        }
        // If the rebuild does not bring frames back, try less often.
        recoveryBackoff = min(recoveryBackoff * 2, 120)
    }

    // MARK: - Dial wiring

    private func action(for side: DialSide) -> DialAction {
        side == .left ? config.leftAction : config.rightAction
    }

    private func control(for action: DialAction) -> LevelControl {
        switch action {
        case .brightness: return brightness
        case .volume: return volume
        case .none: return noop
        }
    }

    /// What each control reports it can actually do on this machine.
    func availability() -> (brightness: Bool, volume: Bool) {
        (brightness.isAvailable, volume.isAvailable)
    }

    /// Whether the volume tick can play at all: the clip has to exist and
    /// macOS's own feedback setting has to be on.
    var volumeSoundAvailable: Bool {
        volumeSound.isAvailable && VolumeFeedbackSound.systemFeedbackEnabled
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
        lastVolumeStep = action == .volume ? VolumeStep.index(for: current) : nil
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

        // One tick per step crossed, like holding a volume key down. Gated on
        // the system setting too, so turning feedback off in Sound settings
        // silences EdgeDial as well.
        if action == .volume, config.volumeFeedbackSound,
           VolumeFeedbackSound.systemFeedbackEnabled {
            let step = VolumeStep.index(for: workingValue)
            if step != lastVolumeStep {
                lastVolumeStep = step
                volumeSound.play()
            }
        }

        if config.showHUD {
            hud.show(action: action, value: workingValue, segments: config.hudSegments)
        }
    }

    func gestureEngine(_ engine: GestureEngine, didEnd side: DialSide) {
        armedAction = nil
        lastVolumeStep = nil
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
