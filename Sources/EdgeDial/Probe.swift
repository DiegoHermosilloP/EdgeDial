import AppKit
import Foundation

/// `EdgeDial --probe` prints what the app can see and do on this machine.
/// Useful when a macOS update changes something underneath it.
/// `EdgeDial --test-controls` exercises every control for real: reads it,
/// writes a couple of values, then puts the original back. The only way to know
/// a private framework still does what it used to is to drive it.
func runControlTest() {
    print("EdgeDial control test")
    print(String(repeating: "-", count: 56))

    let controls: [(String, LevelControl)] = [
        ("Screen brightness", BrightnessControl()),
        ("Volume", VolumeControl()),
        ("Keyboard backlight", KeyboardBacklightControl()),
        ("Night Shift warmth", NightShiftControl()),
    ]

    for (name, control) in controls {
        guard control.isAvailable, let original = control.read() else {
            print("\(name): unavailable on this Mac")
            continue
        }
        print(String(format: "%@: starts at %.2f", name, original))

        var results: [String] = []
        for target in [0.25, 0.75] {
            control.write(target)
            Thread.sleep(forTimeInterval: 0.35)
            let readBack = control.read() ?? -1
            let ok = abs(readBack - target) < 0.08
            results.append(String(format: "wrote %.2f read %.2f %@", target, readBack, ok ? "OK" : "MISMATCH"))
        }

        control.write(original)
        Thread.sleep(forTimeInterval: 0.35)
        let restored = control.read() ?? -1
        print("   " + results.joined(separator: " | "))
        print(String(format: "   restored to %.2f %@", restored,
                     abs(restored - original) < 0.08 ? "OK" : "WARN"))
    }
    print(String(repeating: "-", count: 56))
    print("Done. Anything marked MISMATCH means that control is not responding.")
}

func runProbe() {
    print("EdgeDial probe")
    print(String(repeating: "-", count: 56))

    let layoutSize = MemoryLayout<MTTouch>.size
    print("MTTouch struct size: \(layoutSize) bytes (expected 96) " +
          (layoutSize == 96 ? "OK" : "MISMATCH"))

    let brightness = BrightnessControl()
    let volume = VolumeControl()
    print("Brightness readable: \(brightness.isAvailable ? "yes" : "no")" +
          (brightness.read().map { ", now \(String(format: "%.2f", $0))" } ?? ""))
    print("Volume readable: \(volume.isAvailable ? "yes" : "no")" +
          (volume.read().map { ", now \(String(format: "%.2f", $0))" } ?? ""))

    let device: MultitouchDevice
    do {
        device = try MultitouchDevice()
    } catch {
        print("Multitouch: FAILED — \(error.localizedDescription)")
        exit(1)
    }
    print("Multitouch device: created")
    print("")
    print("Move and rest fingers on the trackpad for 10 seconds…")
    print("(x: 0 = left edge, 1 = right edge   y: 0 = near you, 1 = far from you)")
    print("")

    var frames = 0
    var maxFingers = 0
    var minX = Double.infinity, maxX = -Double.infinity
    var minY = Double.infinity, maxY = -Double.infinity
    var states = Set<Int32>()
    var lastPrint = 0.0
    let lock = NSLock()

    device.onFrame = { frame in
        lock.lock()
        defer { lock.unlock() }
        frames += 1
        maxFingers = max(maxFingers, frame.touches.count)
        for touch in frame.touches {
            states.insert(touch.state)
            let x = Double(touch.normalized.position.x)
            let y = Double(touch.normalized.position.y)
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let first = frame.touches.first, now - lastPrint > 0.25 {
            lastPrint = now
            print(String(
                format: "  finger %d  x=%.3f  y=%.3f  size=%.2f  state=%d  fingers=%d",
                first.identifier,
                Double(first.normalized.position.x),
                Double(first.normalized.position.y),
                Double(first.size),
                first.state,
                frame.touches.count))
        }
    }
    device.start()

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: deadline)
    }
    device.stop()

    print("")
    print(String(repeating: "-", count: 56))
    print("Frames received: \(frames)")
    if frames == 0 {
        print("RESULT: no trackpad data arrived. Multitouch reads are blocked or unsupported.")
        exit(2)
    }
    print("Most fingers at once: \(maxFingers)")
    print("Touch states seen: \(states.sorted())")
    print(String(format: "x range: %.3f … %.3f", minX, maxX))
    print(String(format: "y range: %.3f … %.3f", minY, maxY))
    print("RESULT: trackpad data is readable.")
}
