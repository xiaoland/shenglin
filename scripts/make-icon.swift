import AppKit
import Foundation

let size = 1024
let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
NSGraphicsContext.current?.imageInterpolation = .high

let bounds = NSRect(x: 28, y: 28, width: 968, height: 968)
let tile = NSBezierPath(roundedRect: bounds, xRadius: 220, yRadius: 220)
NSGradient(starting: NSColor(red: 0.035, green: 0.18, blue: 0.24, alpha: 1),
           ending: NSColor(red: 0.025, green: 0.09, blue: 0.17, alpha: 1))!
    .draw(in: tile, angle: -55)

// Two nearby endpoints joined by a single flowing audio path.
let path = NSBezierPath()
path.move(to: NSPoint(x: 296, y: 682))
path.curve(to: NSPoint(x: 728, y: 350),
           controlPoint1: NSPoint(x: 735, y: 790),
           controlPoint2: NSPoint(x: 250, y: 250))
path.lineWidth = 94
path.lineCapStyle = .round
path.lineJoinStyle = .round
NSColor(red: 0.34, green: 0.88, blue: 0.78, alpha: 1).setStroke()
path.stroke()

for (point, color) in [
    (NSPoint(x: 296, y: 682), NSColor(red: 0.93, green: 0.99, blue: 0.96, alpha: 1)),
    (NSPoint(x: 728, y: 350), NSColor(red: 0.93, green: 0.99, blue: 0.96, alpha: 1))
] {
    color.setFill()
    NSBezierPath(ovalIn: NSRect(x: point.x - 86, y: point.y - 86, width: 172, height: 172)).fill()
}

NSGraphicsContext.restoreGraphicsState()
let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MacGUI/AppIcon.png"
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
