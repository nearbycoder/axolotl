// Renders the Axolotl app icon. Usage: swift tools/make-icon.swift <output-dir>
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws the artwork into a 1024×1024 space (y down). `inset` shrinks it into a macOS-style plate.
func draw(_ ctx: CGContext, mac: Bool) {
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    var plate = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    if mac {
        plate = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.setFillColor(color(0x0F766E))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.clip()
    }
    // Background gradient.
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x2DD4BF), color(0x0F766E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: plate.minX, y: plate.minY), end: CGPoint(x: plate.maxX, y: plate.maxY), options: [])

    // Work in a unit space scaled to the plate.
    ctx.saveGState()
    ctx.translateBy(x: plate.minX, y: plate.minY)
    ctx.scaleBy(x: plate.width / 1024, y: plate.height / 1024)

    // Bubbles.
    for (x, y, r, a) in [(820.0, 230.0, 26.0, 0.35), (870.0, 320.0, 14.0, 0.3), (190.0, 250.0, 18.0, 0.25)] {
        ctx.setFillColor(color(0xFFFFFF, a))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    // Gills: three feathery stalks per side.
    func gill(from base: CGPoint, angle: CGFloat, length: CGFloat, mirrored: Bool) {
        let dir = CGPoint(x: cos(angle) * (mirrored ? -1 : 1), y: sin(angle))
        let tip = CGPoint(x: base.x + dir.x * length, y: base.y + dir.y * length)
        ctx.setStrokeColor(color(0xE8638B))
        ctx.setLineWidth(52)
        ctx.setLineCap(.round)
        ctx.move(to: base)
        ctx.addLine(to: tip)
        ctx.strokePath()
        // Fronds along the stalk.
        let normal = CGPoint(x: -dir.y, y: dir.x)
        for i in 1...4 {
            let t = CGFloat(i) / 4.6 + 0.08
            let p = CGPoint(x: base.x + dir.x * length * t, y: base.y + dir.y * length * t)
            for side in [-1.0, 1.0] {
                let c = CGPoint(x: p.x + normal.x * 34 * side, y: p.y + normal.y * 34 * side)
                ctx.setFillColor(color(0xF472B6))
                ctx.fillEllipse(in: CGRect(x: c.x - 20, y: c.y - 20, width: 40, height: 40))
            }
        }
        ctx.setFillColor(color(0xF9A8D4))
        ctx.fillEllipse(in: CGRect(x: tip.x - 26, y: tip.y - 26, width: 52, height: 52))
    }
    let deg = CGFloat.pi / 180
    for mirrored in [false, true] {
        let bx: CGFloat = mirrored ? 1024 - 300 : 300
        gill(from: CGPoint(x: bx, y: 500), angle: 215 * deg, length: 200, mirrored: mirrored)
        gill(from: CGPoint(x: bx - (mirrored ? -10 : 10), y: 560), angle: 185 * deg, length: 215, mirrored: mirrored)
        gill(from: CGPoint(x: bx, y: 620), angle: 155 * deg, length: 190, mirrored: mirrored)
    }

    // Head.
    let head = CGRect(x: 512 - 290, y: 600 - 215, width: 580, height: 430)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x064E3B, 0.35))
    ctx.setFillColor(color(0xFBCFE8))
    ctx.fillEllipse(in: head)
    ctx.restoreGState()
    // Soft lower shading.
    ctx.saveGState()
    ctx.addEllipse(in: head)
    ctx.clip()
    ctx.setFillColor(color(0xF9A8D4, 0.55))
    ctx.fillEllipse(in: CGRect(x: head.minX - 40, y: head.midY + 90, width: head.width + 80, height: head.height))
    ctx.restoreGState()

    // Cheeks.
    ctx.setFillColor(color(0xF472B6, 0.55))
    ctx.fillEllipse(in: CGRect(x: 330 - 46, y: 680 - 26, width: 92, height: 52))
    ctx.fillEllipse(in: CGRect(x: 694 - 46, y: 680 - 26, width: 92, height: 52))

    // Eyes.
    for x in [402.0, 622.0] {
        ctx.setFillColor(color(0x1F2937))
        ctx.fillEllipse(in: CGRect(x: x - 38, y: 590 - 38, width: 76, height: 76))
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillEllipse(in: CGRect(x: x - 22, y: 590 - 26, width: 24, height: 24))
        ctx.fillEllipse(in: CGRect(x: x + 8, y: 590 + 8, width: 10, height: 10))
    }

    // Smile.
    ctx.setStrokeColor(color(0x1F2937))
    ctx.setLineWidth(14)
    ctx.setLineCap(.round)
    ctx.addArc(center: CGPoint(x: 512, y: 640), radius: 64, startAngle: 25 * deg, endAngle: 155 * deg, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}

func render(size: Int, mac: Bool) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.interpolationQuality = .high
    draw(ctx, mac: mac)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

try render(size: 1024, mac: false).write(to: out.appendingPathComponent("icon-ios-1024.png"))
for s in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: s, mac: true).write(to: out.appendingPathComponent("icon-mac-\(s).png"))
}
try render(size: 512, mac: false).write(to: out.appendingPathComponent("glyph-512.png"))
try render(size: 180, mac: false).write(to: out.appendingPathComponent("apple-touch-icon.png"))
try render(size: 64, mac: true).write(to: out.appendingPathComponent("favicon-64.png"))
print("wrote icons to \(out.path)")
