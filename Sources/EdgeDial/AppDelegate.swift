import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DialController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DialController(config: Config.load())
        controller.start()

        statusItem = NSStatusItem.edgeDialItem()
        statusItem.menu = buildMenu()
        updateStatusAppearance()

        if let error = controller.startupError {
            let alert = NSAlert()
            alert.messageText = "EdgeDial could not read the trackpad"
            alert.informativeText = """
                \(error)

                EdgeDial relies on Apple's multitouch interface for raw finger \
                positions. The app will stay running so you can quit it from the \
                menu bar.
                """
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        controller.emergencyRelease()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = controller.config.enabled ? .on : .off
        toggle.tag = Tag.enabled.rawValue
        menu.addItem(toggle)

        menu.addItem(.separator())
        menu.addItem(actionSubmenu(title: "Left Edge", side: .left))
        menu.addItem(actionSubmenu(title: "Right Edge", side: .right))
        menu.addItem(holdDelaySubmenu())

        menu.addItem(.separator())

        let invert = NSMenuItem(
            title: "Slide Up Decreases", action: #selector(toggleInvert), keyEquivalent: "")
        invert.target = self
        invert.state = controller.config.invertDirection ? .on : .off
        invert.tag = Tag.invert.rawValue
        menu.addItem(invert)

        let hud = NSMenuItem(title: "Show Indicator", action: #selector(toggleHUD), keyEquivalent: "")
        hud.target = self
        hud.state = controller.config.showHUD ? .on : .off
        hud.tag = Tag.hud.rawValue
        menu.addItem(hud)

        let haptic = NSMenuItem(
            title: "Haptic Feedback", action: #selector(toggleHaptics), keyEquivalent: "")
        haptic.target = self
        haptic.state = controller.config.hapticFeedback ? .on : .off
        haptic.tag = Tag.haptics.rawValue
        menu.addItem(haptic)

        let freeze = NSMenuItem(
            title: "Hold Pointer Still", action: #selector(toggleFreeze), keyEquivalent: "")
        freeze.target = self
        freeze.state = controller.config.freezeCursor ? .on : .off
        freeze.tag = Tag.freeze.rawValue
        menu.addItem(freeze)

        menu.addItem(.separator())

        let login = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.tag = Tag.login.rawValue
        menu.addItem(login)

        let edit = NSMenuItem(
            title: "Edit Settings File…", action: #selector(editConfig), keyEquivalent: "")
        edit.target = self
        // An alternate pairs with the item above only when both carry the same
        // key equivalent; NSMenuItem defaults this mask to Command, which would
        // leave the pair mismatched.
        edit.keyEquivalentModifierMask = []
        menu.addItem(edit)

        // Option-click for the Finder, for anyone who wants their own editor.
        let revealInFinder = NSMenuItem(
            title: "Reveal Settings in Finder", action: #selector(revealConfig), keyEquivalent: "")
        revealInFinder.target = self
        revealInFinder.isAlternate = true
        revealInFinder.keyEquivalentModifierMask = [.option]
        menu.addItem(revealInFinder)

        let reload = NSMenuItem(
            title: "Reload Settings", action: #selector(reloadConfig), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit EdgeDial", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    /// Preset dwell times. The gesture is the one setting people actually need
    /// to tune — too short and dials arm by accident, too long and the gesture
    /// feels unresponsive — so it belongs in the menu rather than in a file.
    private static let holdDelayPresets: [(label: String, value: Double)] = [
        ("150 ms — Hair trigger", 150),
        ("200 ms — Fast", 200),
        ("250 ms", 250),
        ("300 ms — Default", 300),
        ("400 ms", 400),
        ("500 ms — Relaxed", 500),
        ("700 ms — Deliberate", 700),
    ]

    /// The rows to show for a given current value. A value typed into the
    /// settings file by hand is not in the preset list, so it is folded in and
    /// labelled, rather than leaving the submenu with nothing checked.
    static func holdDelayOptions(current: Double) -> [(label: String, value: Double)] {
        var presets = holdDelayPresets
        if !presets.contains(where: { abs($0.value - current) < 0.5 }) {
            presets.append(("\(Int(current.rounded())) ms — Custom", current))
            presets.sort { $0.value < $1.value }
        }
        return presets
    }

    private func holdDelaySubmenu() -> NSMenuItem {
        let current = controller.config.dwellMilliseconds
        let parent = NSMenuItem(
            title: "Hold Delay: \(Int(current.rounded())) ms", action: nil, keyEquivalent: "")
        parent.tag = Tag.holdDelay.rawValue

        let submenu = NSMenu()
        for preset in AppDelegate.holdDelayOptions(current: current) {
            let item = NSMenuItem(
                title: preset.label, action: #selector(pickHoldDelay(_:)), keyEquivalent: "")
            item.target = self
            item.state = abs(preset.value - current) < 0.5 ? .on : .off
            item.representedObject = preset.value
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func actionSubmenu(title: String, side: DialSide) -> NSMenuItem {
        let current = side == .left ? controller.config.leftAction : controller.config.rightAction
        let parent = NSMenuItem(title: "\(title): \(current.displayName)", action: nil, keyEquivalent: "")
        parent.tag = (side == .left ? Tag.leftAction : Tag.rightAction).rawValue

        let submenu = NSMenu()
        for action in DialAction.allCases {
            let item = NSMenuItem(
                title: action.displayName, action: #selector(pickAction(_:)), keyEquivalent: "")
            item.target = self
            item.state = action == current ? .on : .off
            item.representedObject = [
                "side": side == .left ? "left" : "right",
                "action": action.rawValue,
            ]
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private enum Tag: Int {
        case enabled = 1, invert, hud, haptics, freeze, login
        case leftAction, rightAction, holdDelay, status
    }

    private func statusLine() -> String {
        if let error = controller.startupError { return "Trackpad unavailable — \(error)" }
        let available = controller.availability()
        var parts: [String] = []
        if !available.brightness { parts.append("brightness unavailable") }
        if !available.volume { parts.append("volume unavailable") }
        return parts.isEmpty ? "Ready" : parts.joined(separator: ", ").capitalizedFirst
    }

    private func refreshMenu() {
        statusItem.menu = buildMenu()
        updateStatusAppearance()
    }

    private func updateStatusAppearance() {
        let enabled = controller.config.enabled && controller.startupError == nil
        statusItem.button?.appearsDisabled = !enabled
        statusItem.button?.toolTip = enabled
            ? "EdgeDial — rest a finger on a trackpad edge, then slide"
            : "EdgeDial — off"
    }

    // MARK: - Actions

    private func mutate(_ change: (inout Config) -> Void) {
        var config = controller.config
        change(&config)
        controller.apply(config: config)
        try? config.save()
        refreshMenu()
    }

    @objc private func toggleEnabled() { mutate { $0.enabled.toggle() } }
    @objc private func toggleInvert() { mutate { $0.invertDirection.toggle() } }
    @objc private func toggleHUD() { mutate { $0.showHUD.toggle() } }
    @objc private func toggleHaptics() { mutate { $0.hapticFeedback.toggle() } }
    @objc private func toggleFreeze() { mutate { $0.freezeCursor.toggle() } }

    @objc private func pickAction(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let side = info["side"],
              let raw = info["action"],
              let action = DialAction(rawValue: raw) else { return }
        mutate { config in
            if side == "left" { config.leftAction = action } else { config.rightAction = action }
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshMenu()
    }

    @objc private func pickHoldDelay(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        mutate { $0.dwellMilliseconds = value }
    }

    /// Ensures the file exists before anything is asked to open it.
    private func ensureConfigFileExists() -> URL {
        let url = Config.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? controller.config.save()
        }
        return url
    }

    @objc private func editConfig() {
        let url = ensureConfigFileExists()

        // Handing a .json to LaunchServices gives whatever happens to claim the
        // type: Xcode on a developer's Mac, but it could as easily be Excel,
        // Chrome or Notes, and on a Mac with no handler at all the user just
        // gets an error. TextEdit ships with every macOS install, so ask for it
        // by name and keep the Finder as a backstop.
        let candidates = [
            "/System/Applications/TextEdit.app",
            "/Applications/TextEdit.app",
        ].map { URL(fileURLWithPath: $0) }

        guard let editor = candidates.first(
            where: { FileManager.default.fileExists(atPath: $0.path) }
        ) else {
            revealConfig()
            return
        }

        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: options) {
            [weak self] _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.revealConfig() }
        }
    }

    @objc private func revealConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([ensureConfigFileExists()])
    }

    @objc private func reloadConfig() {
        controller.apply(config: Config.load())
        refreshMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension NSStatusItem {
    static func edgeDialItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        item.button?.image = NSImage(
            systemSymbolName: "slider.vertical.3", accessibilityDescription: "EdgeDial")?
            .withSymbolConfiguration(config)
        return item
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
