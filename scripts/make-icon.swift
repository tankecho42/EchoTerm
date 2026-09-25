import AppKit
import CoreGraphics

// A code-native mark, rendered separately at each required macOS icon size.
// Usage: swift scripts/make-icon.swift /path/EchoTerm.iconset [preview-directory]
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: make-icon.swift <iconset-directory> [preview-directory]\n", stderr)
    exit(1)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func drawMark(pixels: Int) {
    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 192, yRadius: 192)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha: 0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -9 * CGFloat(pixels) / 1024)
    shadow.shadowBlurRadius = 15 * CGFloat(pixels) / 1024
    shadow.set()
    color(0x191E25).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: color(0x171C23), ending: color(0x2B313A))!.draw(in: tile, angle: 90)
    color(0xFFFFFF, alpha: 0.1).setStroke()
    tile.lineWidth = 1.5; tile.stroke()

    // A large, low-contrast paw is part of the upper-right background.
    // Clip it to the tile and draw the terminal prompt above it.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let background = NSAffineTransform()
    background.translateX(by: 340, yBy: 348)
    background.scale(by: 4.2)
    background.translateX(by: -690, yBy: -318)
    background.concat()
    color(0xB8C8C1, alpha: 0.11).setFill()
    for (x, y, w, h): (CGFloat, CGFloat, CGFloat, CGFloat) in [
        (690, 386, 25, 33), (721, 412, 27, 37), (755, 421, 28, 38),
        (790, 409, 27, 36), (821, 382, 24, 32)
    ] {
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: w, height: h)).fill()
    }
    let palm = NSBezierPath()
    palm.move(to: NSPoint(x: 713, y: 348))
    palm.curve(to: NSPoint(x: 735, y: 384), controlPoint1: NSPoint(x: 715, y: 366), controlPoint2: NSPoint(x: 724, y: 374))
    palm.curve(to: NSPoint(x: 798, y: 384), controlPoint1: NSPoint(x: 753, y: 405), controlPoint2: NSPoint(x: 779, y: 405))
    palm.curve(to: NSPoint(x: 821, y: 348), controlPoint1: NSPoint(x: 810, y: 374), controlPoint2: NSPoint(x: 820, y: 365))
    palm.curve(to: NSPoint(x: 795, y: 326), controlPoint1: NSPoint(x: 825, y: 326), controlPoint2: NSPoint(x: 808, y: 318))
    palm.curve(to: NSPoint(x: 739, y: 326), controlPoint1: NSPoint(x: 775, y: 338), controlPoint2: NSPoint(x: 758, y: 338))
    palm.curve(to: NSPoint(x: 713, y: 348), controlPoint1: NSPoint(x: 724, y: 317), controlPoint2: NSPoint(x: 709, y: 328))
    palm.close(); palm.fill()
    NSGraphicsContext.restoreGraphicsState()

    color(0xE9EEEC).setStroke()
    let prompt = NSBezierPath()
    prompt.lineWidth = pixels <= 32 ? 64 : 57
    prompt.lineCapStyle = .round; prompt.lineJoinStyle = .round
    prompt.move(to: NSPoint(x: 238, y: 615))
    prompt.line(to: NSPoint(x: 390, y: 488))
    prompt.line(to: NSPoint(x: 238, y: 361))
    prompt.stroke()
    let cursor = NSBezierPath()
    cursor.lineWidth = prompt.lineWidth; cursor.lineCapStyle = .round
    cursor.move(to: NSPoint(x: 461, y: 360)); cursor.line(to: NSPoint(x: 591, y: 360)); cursor.stroke()


}

func bitmap(size: Int, drawing: (CGContext) -> Void) -> NSBitmapImageRep {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    drawing(context)
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: context.makeImage()!)
}
func icon(_ pixels: Int) -> NSBitmapImageRep {
    bitmap(size: pixels) { context in
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawMark(pixels: pixels)
    }
}
func write(_ bitmap: NSBitmapImageRep, to path: URL) throws {
    try bitmap.representation(using: .png, properties: [:])!.write(to: path)
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try write(icon(size * scale), to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
if CommandLine.arguments.count >= 3 {
    let previews = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
    try write(icon(1024), to: previews.appendingPathComponent("EchoTerm.png"))
    try write(icon(256), to: previews.appendingPathComponent("EchoTerm-preview.png"))
    let contact = bitmap(size: 640) { context in
        for (y, hex): (CGFloat, UInt32) in [(0, 0xEEF0F2), (320, 0x11151A)] {
            color(hex).setFill(); NSBezierPath(rect: NSRect(x: 0, y: y, width: 640, height: 320)).fill()
            var x: CGFloat = 20
            for pixels in [256, 128, 64, 32, 16] {
                let glyph = icon(pixels).cgImage!
                context.draw(glyph, in: CGRect(x: x, y: y + (320 - CGFloat(pixels)) / 2, width: CGFloat(pixels), height: CGFloat(pixels)))
                x += CGFloat(pixels) + 20
            }
        }
    }
    try write(contact, to: previews.appendingPathComponent("EchoTerm-sizes.png"))
}
