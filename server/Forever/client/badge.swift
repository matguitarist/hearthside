// The copy's icon: the game's own, with a "FOREVER" banner across its lower part, so Hearthside's
// copy stands apart from Battle.net's app (and from Pandaria's client) in the Dock, Finder and the
// Local Network list. `swift badge.swift <in.png> <out.png>`, at the input's size.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let bitmap = source.representations.first as? NSBitmapImageRep ?? NSBitmapImageRep(data: source.tiffRepresentation!)
else { fatalError("usage: badge.swift <in.png> <out.png>") }
let size = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
bitmap.draw(in: CGRect(origin: .zero, size: size))

// A band across the lower third: deep teal with a gold edge, the word in gold capitals.
let band = CGRect(x: size.width * 0.06, y: size.height * 0.10, width: size.width * 0.88, height: size.height * 0.22)
let shape = NSBezierPath(roundedRect: band, xRadius: band.height * 0.22, yRadius: band.height * 0.22)
NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.36, alpha: 0.96).setFill()
shape.fill()
NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.32, alpha: 1).setStroke()
shape.lineWidth = max(1, size.width * 0.012)
shape.stroke()

let font = NSFont.systemFont(ofSize: band.height * 0.56, weight: .heavy)
let text = NSAttributedString(string: "FOREVER", attributes: [
    .font: font,
    .foregroundColor: NSColor(calibratedRed: 1, green: 0.86, blue: 0.45, alpha: 1),
    .kern: band.height * 0.04,
])
let bounds = text.size()
text.draw(at: CGPoint(x: band.midX - bounds.width / 2, y: band.midY - bounds.height / 2))
NSGraphicsContext.restoreGraphicsState()

try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
