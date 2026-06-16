// Draws the Meeting Assistant app icon (mic + waveform on a blue→indigo
// squircle) at 1024×1024 and writes a PNG. Pure CoreGraphics so it renders
// crisply at any size. Usage: swift Scripts/make-icon.swift /tmp/icon.png
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon.png"
let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}
func col(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}
let cx: CGFloat = 512

// ── Squircle background ────────────────────────────────────────────────────
let margin: CGFloat = 96
let rect = CGRect(x: margin, y: margin, width: CGFloat(S) - 2*margin, height: CGFloat(S) - 2*margin)
let squircle = CGPath(roundedRect: rect, cornerWidth: 190, cornerHeight: 190, transform: nil)

// Soft drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: col(0, 0, 0, 0.28))
ctx.addPath(squircle); ctx.setFillColor(col(0, 0, 0, 1)); ctx.fillPath()
ctx.restoreGState()

// Blue → indigo diagonal gradient.
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: cs,
                    colors: [col(0.22, 0.47, 0.99), col(0.35, 0.17, 0.92)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
// Gentle top highlight for depth.
let hi = CGGradient(colorsSpace: cs,
                    colors: [col(1, 1, 1, 0.16), col(1, 1, 1, 0)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(hi, start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.midY + 60), options: [])
ctx.restoreGState()

let white = col(1, 1, 1, 1)

// ── Waveform (top) ─────────────────────────────────────────────────────────
let barW: CGFloat = 46
let gap: CGFloat = 38
let heights: [CGFloat] = [86, 168, 232, 168, 86]
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var bx = cx - totalW / 2
let waveCY: CGFloat = 742
ctx.setFillColor(white)
for h in heights {
    let r = CGRect(x: bx, y: waveCY - h/2, width: barW, height: h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW/2, cornerHeight: barW/2, transform: nil))
    bx += barW + gap
}
ctx.fillPath()

// ── Microphone (bottom) ────────────────────────────────────────────────────
// Head capsule.
let headW: CGFloat = 188
let headTop: CGFloat = 556
let headBottom: CGFloat = 300
let headRect = CGRect(x: cx - headW/2, y: headBottom, width: headW, height: headTop - headBottom)
ctx.setFillColor(white)
ctx.addPath(CGPath(roundedRect: headRect, cornerWidth: headW/2, cornerHeight: headW/2, transform: nil))
ctx.fillPath()

// Cradle (U arc hugging the lower head) + stem + base, stroked.
ctx.setStrokeColor(white)
ctx.setLineWidth(40)
ctx.setLineCap(.round)
let cradleCY: CGFloat = 392
let cradleR: CGFloat = 168
ctx.addArc(center: CGPoint(x: cx, y: cradleCY), radius: cradleR,
           startAngle: .pi * 200/180, endAngle: .pi * 340/180, clockwise: false)
ctx.strokePath()
// Stem.
let stemTop = cradleCY - cradleR
let stemBottom: CGFloat = 196
ctx.move(to: CGPoint(x: cx, y: stemTop))
ctx.addLine(to: CGPoint(x: cx, y: stemBottom))
ctx.strokePath()
// Base.
ctx.move(to: CGPoint(x: cx - 86, y: stemBottom))
ctx.addLine(to: CGPoint(x: cx + 86, y: stemBottom))
ctx.strokePath()

// ── Write PNG ──────────────────────────────────────────────────────────────
guard let img = ctx.makeImage() else { fatalError("no image") }
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("no dest")
}
CGImageDestinationAddImage(dest, img, nil)
if CGImageDestinationFinalize(dest) { print("wrote \(outPath)") } else { fatalError("write failed") }
