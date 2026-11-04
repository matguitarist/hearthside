// Renders an SVG to a square PNG with AppKit's own SVG support (macOS 14+):
// `render <in.svg> <out.png> <pixels>`. Used by scripts/macos-app.sh for the app icon (globe.svg or ember.svg).
import AppKit

let args = CommandLine.arguments
let size = Int(args[3])!
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else { fatalError("unreadable \(args[1])") }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
