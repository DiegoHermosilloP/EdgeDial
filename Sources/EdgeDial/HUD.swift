import AppKit

/// A borderless, non-activating overlay that shows the level while a dial runs.
///
/// It deliberately does not look like a pixel copy of Apple's HUD: it sits
/// lower, it is a pill rather than a square, and it reads as "something else is
/// driving this", which is useful feedback when a dial arms unintentionally.
final class HUD {
    private enum Metrics {
        static let size = CGSize(width: 248, height: 62)
        static let bottomInset: CGFloat = 148
        static let cornerRadius: CGFloat = 31
        static let visibleDuration: TimeInterval = 0.85
        static let fadeDuration: TimeInterval = 0.22
    }

    private let panel: NSPanel
    private let iconView = NSImageView()
    private let barView = BarView()
    private var hideTimer: Timer?

    init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Metrics.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none

        let blur = NSVisualEffectView(frame: CGRect(origin: .zero, size: Metrics.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Metrics.cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        barView.translatesAutoresizingMaskIntoConstraints = false

        blur.addSubview(iconView)
        blur.addSubview(barView)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 22),
            iconView.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            barView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 18),
            barView.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -22),
            barView.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            barView.heightAnchor.constraint(equalToConstant: 10),
        ])

        panel.contentView = blur
    }

    /// Shows or updates the overlay. Safe to call on every frame of a slide.
    func show(action: DialAction, value: Double, segments: Int) {
        iconView.image = HUD.symbol(for: action, value: value)
        barView.segments = segments
        barView.value = min(max(value, 0), 1)

        reposition()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }

        hideTimer?.invalidate()
        hideTimer = nil
    }

    /// Starts the auto-hide countdown. Called when the finger lifts.
    func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(
            withTimeInterval: Metrics.visibleDuration, repeats: false
        ) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Metrics.fadeDuration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func reposition() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let frame = screen?.frame else { return }
        let origin = CGPoint(
            x: frame.midX - Metrics.size.width / 2,
            y: frame.minY + Metrics.bottomInset)
        panel.setFrame(CGRect(origin: origin, size: Metrics.size), display: false)
    }

    private static func symbol(for action: DialAction, value: Double) -> NSImage? {
        let name: String
        switch action {
        case .brightness:
            name = value < 0.34 ? "sun.min.fill" : (value < 0.67 ? "sun.max.fill" : "sun.max.fill")
        case .volume:
            if value <= 0.001 {
                name = "speaker.slash.fill"
            } else if value < 0.34 {
                name = "speaker.wave.1.fill"
            } else if value < 0.67 {
                name = "speaker.wave.2.fill"
            } else {
                name = "speaker.wave.3.fill"
            }
        case .none:
            name = "questionmark"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: action.displayName)?
            .withSymbolConfiguration(config)
    }
}

/// Level bar. Segmented like the system HUD when `segments > 0`, otherwise a
/// continuous fill.
private final class BarView: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var segments: Int = 16 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        guard value > 0 else { return }
        NSColor.labelColor.setFill()

        if segments <= 0 {
            let width = max(bounds.height, bounds.width * CGFloat(value))
            let fill = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
            return
        }

        let gap: CGFloat = 2
        let segmentWidth = (bounds.width - gap * CGFloat(segments - 1)) / CGFloat(segments)
        let lit = Int((Double(segments) * value).rounded(.up))
        for index in 0..<min(lit, segments) {
            let x = CGFloat(index) * (segmentWidth + gap)
            let rect = CGRect(x: x, y: 0, width: segmentWidth, height: bounds.height)
            let segmentRadius = min(radius, segmentWidth / 2)
            NSBezierPath(roundedRect: rect, xRadius: segmentRadius, yRadius: segmentRadius).fill()
        }
    }
}
