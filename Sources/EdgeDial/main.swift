import AppKit

if CommandLine.arguments.contains("--probe") {
    runProbe()
    exit(0)
}

// Restore the pointer even if the app is killed mid-gesture.
for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
    signal(signalNumber) { _ in
        CGAssociateMouseAndMouseCursorPosition(1)
        exit(0)
    }
}
atexit { CGAssociateMouseAndMouseCursorPosition(1) }

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
