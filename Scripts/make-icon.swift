// Renders build/AppIcon.iconset from scratch so the repo carries no binary
// assets. Draws straight into a bitmap rep: NSImage.lockFocus has no usable
// window server in a command-line context.
import AppKit

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let side = CGFloat(pixels)
    let plateRect = CGRect(x: 0, y: 0, width: side, height: side)
        .insetBy(dx: side * 0.07, dy: side * 0.07)

    // Rounded slab, standing in for the trackpad.
    let plate = NSBezierPath(
        roundedRect: plateRect, xRadius: side * 0.19, yRadius: side * 0.19)
    NSGradient(
        starting: NSColor(calibratedWhite: 0.30, alpha: 1),
        ending: NSColor(calibratedWhite: 0.09, alpha: 1)
    )?.draw(in: plate, angle: 270)

    NSColor(calibratedWhite: 1, alpha: 0.14).setStroke()
    plate.lineWidth = max(1, side * 0.006)
    plate.stroke()

    // Two lit edge strips: brightness left, volume right.
    let stripWidth = plateRect.width * 0.165
    let verticalInset = plateRect.height * 0.13
    for (index, color) in [NSColor.systemYellow, NSColor.systemTeal].enumerated() {
        let x = index == 0
            ? plateRect.minX + plateRect.width * 0.085
            : plateRect.maxX - plateRect.width * 0.085 - stripWidth
        let strip = CGRect(
            x: x, y: plateRect.minY + verticalInset,
            width: stripWidth, height: plateRect.height - verticalInset * 2)
        let path = NSBezierPath(
            roundedRect: strip, xRadius: stripWidth / 2, yRadius: stripWidth / 2)
        NSGradient(
            starting: color.withAlphaComponent(0.95),
            ending: color.withAlphaComponent(0.10)
        )?.draw(in: path, angle: 90)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// Exactly the names iconutil expects; anything else makes it fail.
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        guard let data = render(pixels: base * scale) else {
            FileHandle.standardError.write(Data("failed at \(base)@\(scale)x\n".utf8))
            exit(1)
        }
        let suffix = scale == 1 ? "" : "@2x"
        let name = "icon_\(base)x\(base)\(suffix).png"
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
print("iconset written")
