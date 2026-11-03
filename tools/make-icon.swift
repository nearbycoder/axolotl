// Renders the Axolotl icon family from one vector description.
// Usage: swift tools/make-icon.swift <output-dir>
//
// Outputs app icons (iOS full-bleed, macOS plate), the in-app glyph, web icons, and SVGs.
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// MARK: Geometry (1024 × 1024, y down)

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }

func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
    let a = lerp(p0, p1, t), b = lerp(p1, p2, t), c = lerp(p2, p3, t)
    return lerp(lerp(a, b, t), lerp(b, c, t), t)
}

/// A stroke along a cubic Bézier whose width tapers from `w0` to `w1`, with a round tip.
func taperedFrond(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, w0: CGFloat, w1: CGFloat) -> CGPath {
    let n = 80
    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0...n {
        let t = CGFloat(i) / CGFloat(n)
        let p = cubic(p0, p1, p2, p3, t)
        let q = cubic(p0, p1, p2, p3, min(1, t + 0.001))
        let r = cubic(p0, p1, p2, p3, max(0, t - 0.001))
        var dx = q.x - r.x, dy = q.y - r.y
        let len = max(0.0001, hypot(dx, dy)); dx /= len; dy /= len
        // Ease the taper so the frond stays full most of its length.
        let w = (w0 + (w1 - w0) * pow(t, 1.6)) / 2
        left.append(CGPoint(x: p.x - dy * w, y: p.y + dx * w))
        right.append(CGPoint(x: p.x + dy * w, y: p.y - dx * w))
    }
    let path = CGMutablePath()
    path.move(to: left[0])
    for p in left.dropFirst() { path.addLine(to: p) }
    // Round tip.
    let tip = p3, end = left.last!
    let a0 = atan2(end.y - tip.y, end.x - tip.x)
    path.addArc(center: tip, radius: w1 / 2, startAngle: a0, endAngle: a0 + .pi, clockwise: true)
    for p in right.reversed() { path.addLine(to: p) }
    path.closeSubpath()
    return path
}

func superellipse(center c: CGPoint, rx: CGFloat, ry: CGFloat, n: CGFloat, squashBottom: CGFloat = 0) -> CGPath {
    let path = CGMutablePath()
    let steps = 360
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        var x = pow(abs(ct), 2 / n) * rx * (ct < 0 ? -1 : 1)
        var y = pow(abs(st), 2 / n) * ry * (st < 0 ? -1 : 1)
        // Gently narrow the lower half for a softer jaw.
        if y > 0 { x *= 1 - squashBottom * (y / ry) * (y / ry) }
        y += 0
        let p = CGPoint(x: c.x + x, y: c.y + y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

struct Glyph {
    var body: [CGPath] = []
    var cutouts: [CGPath] = []
}

/// The axolotl mark: a broad head with three swept gill fronds per side.
/// Adds feather-like filaments along the upper edge of a frond.
func feathered(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, w0: CGFloat, w1: CGFloat, into g: inout Glyph) {
    g.body.append(taperedFrond(p0, p1, p2, p3, w0: w0, w1: w1))
    for (i, t) in [0.3, 0.5, 0.7].enumerated() {
        let t = CGFloat(t)
        let p = cubic(p0, p1, p2, p3, t)
        let q = cubic(p0, p1, p2, p3, t + 0.01)
        var dx = q.x - p.x, dy = q.y - p.y
        let len = hypot(dx, dy); dx /= len; dy /= len
        var nx = -dy, ny = dx
        if ny > 0 { nx = -nx; ny = -ny }
        let fx = dx * 0.55 + nx * 0.85, fy = dy * 0.55 + ny * 0.85
        let fl = hypot(fx, fy)
        let length = (56 - CGFloat(i) * 10)
        let start = CGPoint(x: p.x - dx * 6, y: p.y - dy * 6)
        let end = CGPoint(x: p.x + fx / fl * length, y: p.y + fy / fl * length)
        let mid = CGPoint(x: (start.x + end.x) / 2 + dx * 6, y: (start.y + end.y) / 2 + dy * 6)
        g.body.append(taperedFrond(start, mid, mid, end, w0: 20 - CGFloat(i) * 2, w1: 8))
    }
}

func axolotl() -> Glyph {
    var g = Glyph()
    let cx: CGFloat = 512, cy: CGFloat = 612
    for side: CGFloat in [-1, 1] {
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: cx + side * x, y: y) }
        // Three gently arcing fronds per side, rooted behind the head.
        feathered(P(118, 520), P(140, 430), P(186, 352), P(250, 292), w0: 46, w1: 18, into: &g)
        feathered(P(160, 556), P(220, 490), P(290, 450), P(360, 430), w0: 46, w1: 18, into: &g)
        feathered(P(188, 612), P(262, 592), P(330, 576), P(398, 572), w0: 44, w1: 17, into: &g)
    }
    g.body.append(superellipse(center: CGPoint(x: cx, y: cy), rx: 232, ry: 152, n: 2.6, squashBottom: 0.12))
    for side: CGFloat in [-1, 1] {
        let r: CGFloat = 18
        g.cutouts.append(CGPath(ellipseIn: CGRect(x: cx + side * 128 - r, y: cy - 34 - r, width: 2 * r, height: 2 * r), transform: nil))
    }
    return g
}

func squircle(_ rect: CGRect) -> CGPath {
    // Continuous-corner rounded square, close to Apple's icon shape.
    let path = CGMutablePath()
    let n: CGFloat = 5
    let c = CGPoint(x: rect.midX, y: rect.midY), a = rect.width / 2
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let ct = cos(t), st = sin(t)
        let p = CGPoint(x: c.x + pow(abs(ct), 2 / n) * a * (ct < 0 ? -1 : 1), y: c.y + pow(abs(st), 2 / n) * a * (st < 0 ? -1 : 1))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

// MARK: Drawing

func drawBackground(_ ctx: CGContext, in rect: CGRect) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    if style == "dark" {
        let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x3A2140), rgb(0x24152A), rgb(0x150C19)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xF25C88, 0.38), rgb(0xF25C88, 0)] as CFArray, locations: [0, 1])!
        let c = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.56)
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: rect.width * 0.52, options: [])
    } else {
        let grad = CGGradient(colorsSpace: cs, colors: [rgb(0xFF8FA8), rgb(0xEF5F84), rgb(0xC2386A)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY), end: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.maxY), options: [])
    }
    // Soft top light.
    let light = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, style == "dark" ? 0.10 : 0.26), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(light, startCenter: CGPoint(x: rect.midX, y: rect.minY), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.minY), endRadius: rect.width * 0.8, options: [])
}

let style = ProcessInfo.processInfo.environment["STYLE"] ?? "dark"  // "pink" renders the alternate light variant

func drawGlyph(_ ctx: CGContext, color: CGColor?, shadow: Bool) {
    let g = axolotl()
    ctx.saveGState()
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: 16), blur: 40, color: style == "dark" ? rgb(0x000000, 0.45) : rgb(0x6A1035, 0.35)) }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    // Fill each piece on its own so overlapping fronds never cancel out.
    ctx.setFillColor(rgb(0xFFFFFF))
    for p in g.body { ctx.addPath(p); ctx.fillPath() }
    ctx.setBlendMode(.sourceIn)
    if let color {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    } else {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors = style == "dark" ? [rgb(0xFFC2D0), rgb(0xFF7A9C), rgb(0xE5487A)] : [rgb(0xFFFFFF), rgb(0xFFFFFF), rgb(0xFFEAF0)]
        let grad = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 250), end: CGPoint(x: 512, y: 780), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.setBlendMode(.destinationOut)
    for c in g.cutouts { ctx.addPath(c); ctx.fillPath() }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

enum Variant { case ios, mac, glyphOnly(UInt32) }

func render(size: Int, _ variant: Variant) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    let full = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    switch variant {
    case .ios:
        drawBackground(ctx, in: full)
        drawGlyph(ctx, color: nil, shadow: true)
    case .mac:
        let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = squircle(plate)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 22, color: rgb(0x000000, 0.32))
        ctx.addPath(shape); ctx.setFillColor(rgb(0x24152A)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        drawBackground(ctx, in: plate)
        // Scale the glyph into the plate.
        ctx.translateBy(x: 100, y: 100)
        ctx.scaleBy(x: 824 / 1024, y: 824 / 1024)
        drawGlyph(ctx, color: nil, shadow: true)
        ctx.restoreGState()
        // Hairline inner edge for definition on light backgrounds.
        ctx.addPath(shape)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.18)); ctx.setLineWidth(2); ctx.strokePath()
    case .glyphOnly(let hex):
        ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: 1.3, y: 1.3); ctx.translateBy(x: -512, y: -520)
        drawGlyph(ctx, color: rgb(hex), shadow: false)
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: SVG

func svgPath(_ path: CGPath) -> String {
    var d = ""
    path.applyWithBlock { el in
        let e = el.pointee
        func f(_ p: CGPoint) -> String { String(format: "%.1f %.1f", p.x, p.y) }
        switch e.type {
        case .moveToPoint: d += "M\(f(e.points[0]))"
        case .addLineToPoint: d += "L\(f(e.points[0]))"
        case .addQuadCurveToPoint: d += "Q\(f(e.points[0])) \(f(e.points[1]))"
        case .addCurveToPoint: d += "C\(f(e.points[0])) \(f(e.points[1])) \(f(e.points[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svg(withPlate: Bool) -> String {
    let g = axolotl()
    let cut = g.cutouts.map(svgPath).joined()
    let mask = """
    <mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><rect width="1024" height="1024" fill="#fff"/><path d="\(cut)" fill="#000"/></mask>
    """
    if withPlate {
        let pieces = g.body.map { "<path d=\"\(svgPath($0))\"/>" }.joined()
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><defs>
        <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3A2140"/><stop offset=".55" stop-color="#24152A"/><stop offset="1" stop-color="#150C19"/></linearGradient>
        <radialGradient id="glow" cx=".5" cy=".56" r=".52"><stop offset="0" stop-color="#F25C88" stop-opacity=".38"/><stop offset="1" stop-color="#F25C88" stop-opacity="0"/></radialGradient>
        <linearGradient id="fg" x1="0" y1="250" x2="0" y2="780" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#FFC2D0"/><stop offset=".55" stop-color="#FF7A9C"/><stop offset="1" stop-color="#E5487A"/></linearGradient>
        \(mask)</defs>
        <rect width="1024" height="1024" rx="230" fill="url(#bg)"/><rect width="1024" height="1024" rx="230" fill="url(#glow)"/>
        <g fill="url(#fg)" mask="url(#cut)">\(pieces)</g></svg>
        """
    }
    let pieces = g.body.map { "<path d=\"\(svgPath($0))\"/>" }.joined()
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="120 240 784 560"><defs>\(mask)</defs><g fill="currentColor" mask="url(#cut)">\(pieces)</g></svg>
    """
}

try render(size: 1024, .ios).write(to: out.appendingPathComponent("icon-ios-1024.png"))
for s in [16, 32, 64, 128, 256, 512, 1024] { try render(size: s, .mac).write(to: out.appendingPathComponent("icon-mac-\(s).png")) }
try render(size: 512, .ios).write(to: out.appendingPathComponent("glyph-512.png"))
try render(size: 180, .ios).write(to: out.appendingPathComponent("apple-touch-icon.png"))
try render(size: 64, .mac).write(to: out.appendingPathComponent("favicon-64.png"))
try svg(withPlate: true).write(to: out.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)
try svg(withPlate: false).write(to: out.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)
print("wrote icons to \(out.path)")
