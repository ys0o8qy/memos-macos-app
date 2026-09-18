import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        NSColor(calibratedRed: 0.18, green: 0.38, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 208, yRadius: 208).fill()
        NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.90, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 270, y: 212, width: 484, height: 600), xRadius: 44, yRadius: 44).fill()
        NSColor(calibratedRed: 0.18, green: 0.38, blue: 0.30, alpha: 1).setStroke()
        for (y, width) in [(654.0, 292.0), (538.0, 292.0), (422.0, 178.0)] {
            let path = NSBezierPath()
            path.lineWidth = 30; path.lineCapStyle = .round
            path.move(to: NSPoint(x: 366, y: y)); path.line(to: NSPoint(x: 366 + width, y: y)); path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
