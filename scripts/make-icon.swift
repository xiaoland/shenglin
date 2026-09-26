import AppKit
import Foundation

let size = 1024
let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
let square = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968),
                          xRadius: 220, yRadius: 220)
NSGradient(starting: NSColor(red: 0.08, green: 0.20, blue: 0.35, alpha: 1),
           ending: NSColor(red: 0.02, green: 0.08, blue: 0.17, alpha: 1))!
    .draw(in: square, angle: -55)

NSColor(red: 0.15, green: 0.82, blue: 0.78, alpha: 0.12).setFill()
NSBezierPath(ovalIn: NSRect(x: 180, y: 180, width: 664, height: 664)).fill()

let bars: [(CGFloat, CGFloat)] = [(285, 210), (390, 420), (495, 580), (600, 360), (705, 190)]
for (x, height) in bars {
    let rect = NSRect(x: x, y: (1024 - height) / 2, width: 54, height: height)
    NSColor(red: 0.43, green: 0.95, blue: 0.88, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 27, yRadius: 27).fill()
}

NSGraphicsContext.restoreGraphicsState()
let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MacGUI/AppIcon.png"
try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
