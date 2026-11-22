// Renders the iWalk app icon (1024x1024 PNG) with CoreGraphics.
// Usage: swift ios/Tools/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          // Opaque: iOS app icons must not have an alpha channel.
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }

// CoreGraphics' origin is bottom-left; flip so y grows downward like a design canvas.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// 1. Background: Indian Ocean teal (top-left) to coastal green (bottom-right).
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x0A5C78), rgb(0x0E8A7E), rgb(0x3DB86B)] as CFArray,
                    locations: [0, 0.5, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])

// 2. Faint topographic contour lines around a hill in the upper right.
ctx.setLineWidth(6)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.09))
for i in 0..<7 {
    let r = 120.0 + Double(i) * 95
    let path = CGMutablePath()
    let cx = 760.0, cy = 300.0
    for step in 0...120 {
        let t = Double(step) / 120 * 2 * .pi
        let wobble = 1 + 0.07 * sin(3 * t + Double(i)) + 0.04 * cos(5 * t)
        let p = CGPoint(x: cx + r * 1.15 * wobble * cos(t), y: cy + r * 0.85 * wobble * sin(t))
        step == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    ctx.addPath(path)
    ctx.strokePath()
}

// Everything below is scaled toward the centre so it stays inside the Watch's circular mask.
ctx.translateBy(x: size / 2, y: size / 2)
ctx.scaleBy(x: 0.88, y: 0.88)
ctx.translateBy(x: -size / 2, y: -size / 2)

// 3. The route: a winding S-curve from bottom-left to the top-right destination.
let start = CGPoint(x: 268, y: 790)
let mid = CGPoint(x: 512, y: 560)
let end = CGPoint(x: 742, y: 262)
let walked = CGMutablePath()
walked.move(to: start)
walked.addCurve(to: mid, control1: CGPoint(x: 470, y: 820), control2: CGPoint(x: 300, y: 600))
let route = CGMutablePath()
route.addPath(walked)
route.addCurve(to: end, control1: CGPoint(x: 720, y: 520), control2: CGPoint(x: 560, y: 300))

ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Soft shadow under the whole route.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0x00303A, 0.35))
ctx.setLineWidth(74)
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.addPath(route)
ctx.strokePath()
ctx.restoreGState()

// Walked part in warm orange along the first half of the route (the recorded track).
ctx.setLineWidth(42)
ctx.setStrokeColor(rgb(0xFF8A3D))
ctx.addPath(walked)
ctx.strokePath()

// 4. Start marker: white ring with a green centre.
func disc(_ c: CGPoint, _ r: Double, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}
disc(start, 66, rgb(0xFFFFFF))
disc(start, 40, rgb(0x2FA866))

// 5. Destination marker: map pin in orange with a white dot.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(0x00303A, 0.35))
let pin = CGMutablePath()
let headR = 92.0
let head = CGPoint(x: end.x, y: end.y - 70)
pin.addArc(center: head, radius: headR, startAngle: .pi * 0.80, endAngle: .pi * 0.20, clockwise: false)
pin.addLine(to: CGPoint(x: end.x, y: end.y + 62))
pin.closeSubpath()
ctx.addPath(pin)
ctx.setFillColor(rgb(0xFF8A3D))
ctx.fillPath()
ctx.restoreGState()
disc(head, 38, rgb(0xFFFFFF))

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
