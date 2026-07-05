import AppKit

// Draws the DMG window background: warm paper, halftone corner, an arrow from
// the app icon position to the Applications position, and install hints.
// Usage: swift make_dmg_background.swift <output.png>
// Sized for a 660×440 pt Finder window, rendered @2x with 144 dpi metadata.

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg_bg.png"
let W = 660.0, H = 440.0, S = 2.0

let ink    = NSColor(calibratedRed: 26/255,  green: 22/255,  blue: 20/255,  alpha: 1)
let paper  = NSColor(calibratedRed: 247/255, green: 243/255, blue: 236/255, alpha: 1)
let accent = NSColor(calibratedRed: 255/255, green: 77/255,  blue: 46/255,  alpha: 1)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W*S), pixelsHigh: Int(H*S),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let gctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
gctx.cgContext.scaleBy(x: S, y: S)

// Convert top-left y to bottom-left y
func Y(_ t: Double) -> Double { H - t }

paper.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

// Halftone dots, top-right corner, fading out
for row in 0..<10 {
    for col in 0..<16 {
        let x = W - 20 - Double(col) * 14
        let y = Y(20 + Double(row) * 14)
        let fade = 1.0 - (Double(col) / 16 + Double(row) / 10) / 2
        guard fade > 0.05 else { continue }
        ink.withAlphaComponent(0.12 * fade).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)).fill()
    }
}

// Title
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, centerX: Double, topY: Double) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let sz = s.size()
    s.draw(at: NSPoint(x: centerX - Double(sz.width) / 2, y: Y(topY) - Double(sz.height)))
}

draw("Install Bonk", size: 26, weight: .bold, color: ink, centerX: W / 2, topY: 46)
draw("drag the fist into Applications", size: 14, weight: .medium,
     color: ink.withAlphaComponent(0.55), centerX: W / 2, topY: 80)

// Arrow between the two icon positions (icons centered at x=165 and x=495, y≈205)
let yArrow = Y(205.0)
let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 250, y: yArrow))
arrow.curve(to: NSPoint(x: 408, y: yArrow),
            controlPoint1: NSPoint(x: 300, y: yArrow + 26),
            controlPoint2: NSPoint(x: 360, y: yArrow + 26))
accent.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.move(to: NSPoint(x: 394, y: yArrow + 16))
head.line(to: NSPoint(x: 412, y: yArrow + 1))
head.line(to: NSPoint(x: 392, y: yArrow - 8))
accent.setStroke()
head.stroke()

// First-launch note at the bottom
draw("first launch: right-click Bonk → Open  ·  100% local, no network",
     size: 12, weight: .regular, color: ink.withAlphaComponent(0.45),
     centerX: W / 2, topY: 408)

NSGraphicsContext.restoreGraphicsState()

rep.size = NSSize(width: W, height: H)   // 144 dpi so Finder renders it @2x
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("dmg background written to \(out)")
