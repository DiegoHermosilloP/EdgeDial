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

        let reveal = NSMenuItem(
            title: "Edit Settings File…", action: #selector(editConfig), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

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
        case enabled = 1, invert, hud, haptics, freeze, login, leftAction, rightAction, status
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

    @objc private func editConfig() {
        let url = Config.fileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? controller.config.save()
        }
        NSWorkspace.shared.open(url)
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
