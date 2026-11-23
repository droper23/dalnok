// Atelier's toolbar and place glyphs, engraved (audit A9; the owner: plate-style iconography wherever there is room).
// Each glyph is outlined at the kit's rule weight and shaded with parallel hatching instead of a solid fill, so it
// reads as part of the same plate as the dials and figures. Template images: the button's tint colours them.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
enum AtelierGlyphs {
    private static var cache: [String: NSImage] = [:]

    /// The engraved glyph for an SF Symbol name, or nil when Atelier has none (the caller keeps the symbol).
    static func image(_ symbol: String, size: CGFloat = 18) -> NSImage? {
        guard Theme.activeStyle == .atelier, draws(symbol) else { return nil }
        let key = "\(symbol)-\(size)"
        if let i = cache[key] { return i }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: rect.width / 18, y: rect.height / 18) // drawn on an 18-point grid, y up
            draw(symbol, ctx)
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    private static let known: Set<String> = [
        "play.fill", "pause.fill", "circle.fill", "backward.end.fill", "repeat", "metronome.fill", "123.rectangle", "magnifyingglass",
        "plus.rectangle.on.rectangle", "point.topleft.down.to.point.bottomright.curvepath", "rectangle.3.group", "square.grid.3x2",
        "slider.vertical.3", "sidebar.left", "sidebar.right", "plus", "puzzlepiece.extension", "star", "star.fill", "clock", "folder",
    ]
    static func draws(_ symbol: String) -> Bool { known.contains(symbol) }

    // MARK: Pen

    private static let line: CGFloat = 1.1, hair: CGFloat = 0.55
    private static func stroke(_ ctx: CGContext, _ p: CGPath, _ w: CGFloat = line) {
        ctx.addPath(p); ctx.setLineWidth(w); ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.setStrokeColor(NSColor.black.cgColor); ctx.strokePath()
    }
    /// Parallel engraving inside `p` (45°, or `angle`), the way the plates shade a surface.
    private static func hatch(_ ctx: CGContext, _ p: CGPath, spacing: CGFloat = 1.6, angle: CGFloat = .pi / 4, alpha: CGFloat = 0.85) {
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        let b = p.boundingBox.insetBy(dx: -2, dy: -2), d = hypot(b.width, b.height)
        let c = CGPoint(x: b.midX, y: b.midY), dir = CGPoint(x: cos(angle), y: sin(angle)), n = CGPoint(x: -dir.y, y: dir.x)
        var t = -d / 2
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(alpha).cgColor); ctx.setLineWidth(hair)
        while t <= d / 2 {
            let o = CGPoint(x: c.x + n.x * t, y: c.y + n.y * t)
            ctx.move(to: CGPoint(x: o.x - dir.x * d, y: o.y - dir.y * d)); ctx.addLine(to: CGPoint(x: o.x + dir.x * d, y: o.y + dir.y * d))
            t += spacing
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
    private static func poly(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p }
    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath { CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil) }
    private static func arrow(_ ctx: CGContext, at p: CGPoint, angle a: CGFloat, size s: CGFloat = 3.4) {
        let back = CGPoint(x: p.x - cos(a) * s, y: p.y - sin(a) * s), n = CGPoint(x: -sin(a) * s * 0.45, y: cos(a) * s * 0.45)
        ctx.addPath(poly([p, CGPoint(x: back.x + n.x, y: back.y + n.y), CGPoint(x: back.x - n.x, y: back.y - n.y)]))
        ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    }
    /// A small solid in the shared oblique: a front rectangle with top and right faces receding up and right.
    private static func block(_ ctx: CGContext, _ r: CGRect, depth d: CGFloat = 1.8, shade: Bool = true) {
        let top = poly([CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + d, y: r.maxY + d), CGPoint(x: r.maxX + d, y: r.maxY + d), CGPoint(x: r.maxX, y: r.maxY)])
        let side = poly([CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX + d, y: r.minY + d), CGPoint(x: r.maxX + d, y: r.maxY + d), CGPoint(x: r.maxX, y: r.maxY)])
        if shade { hatch(ctx, side, spacing: 1.0) }
        stroke(ctx, top, hair); stroke(ctx, side, hair); stroke(ctx, CGPath(rect: r, transform: nil), 0.9)
    }

    // MARK: Glyphs

    private static func draw(_ s: String, _ ctx: CGContext) {
        switch s {
        case "play.fill":
            let p = poly([CGPoint(x: 5, y: 3.5), CGPoint(x: 15, y: 9), CGPoint(x: 5, y: 14.5)])
            hatch(ctx, p, spacing: 1.3); stroke(ctx, p)
        case "pause.fill":
            for x in [4.5, 10.5] as [CGFloat] { let r = rect(x, 3.5, 3.4, 11); hatch(ctx, r, spacing: 1.2); stroke(ctx, r) }
        case "circle.fill": // record: a turned button, densely engraved (the tint makes it the one red)
            let r = CGRect(x: 3.5, y: 3.5, width: 11, height: 11)
            let c = CGPath(ellipseIn: r, transform: nil)
            hatch(ctx, c, spacing: 1.0); hatch(ctx, c, spacing: 1.4, angle: -.pi / 4, alpha: 0.6); stroke(ctx, c)
        case "backward.end.fill":
            let bar = rect(3.5, 4, 2.2, 10); hatch(ctx, bar, spacing: 1); stroke(ctx, bar, 0.9)
            let p = poly([CGPoint(x: 14.5, y: 4), CGPoint(x: 7, y: 9), CGPoint(x: 14.5, y: 14)])
            hatch(ctx, p, spacing: 1.3); stroke(ctx, p)
        case "repeat": // the cycle: an ellipse in perspective with two arrows round it
            let e = CGMutablePath()
            e.addArc(center: CGPoint(x: 9, y: 9), radius: 6, startAngle: 0.35, endAngle: .pi - 0.35, clockwise: false)
            stroke(ctx, e)
            let f = CGMutablePath()
            f.addArc(center: CGPoint(x: 9, y: 9), radius: 6, startAngle: .pi + 0.35, endAngle: 2 * .pi - 0.35, clockwise: false)
            stroke(ctx, f)
            arrow(ctx, at: CGPoint(x: 9 + 6 * cos(.pi - 0.35), y: 9 + 6 * sin(.pi - 0.35)), angle: .pi + 1.3)
            arrow(ctx, at: CGPoint(x: 9 + 6 * cos(-0.35), y: 9 + 6 * sin(-0.35)), angle: 1.3 - .pi + .pi)
        case "metronome.fill": // a pyramid case, its front hatched, a pendulum with its weight
            let body = poly([CGPoint(x: 3.5, y: 2.5), CGPoint(x: 14.5, y: 2.5), CGPoint(x: 11, y: 15.5), CGPoint(x: 7, y: 15.5)])
            let side = poly([CGPoint(x: 9, y: 2.5), CGPoint(x: 14.5, y: 2.5), CGPoint(x: 11, y: 15.5), CGPoint(x: 9.6, y: 15.5)])
            hatch(ctx, side, spacing: 1.1); stroke(ctx, body)
            let rod = CGMutablePath(); rod.move(to: CGPoint(x: 9, y: 4.5)); rod.addLine(to: CGPoint(x: 12.8, y: 13.5)); stroke(ctx, rod, 0.9)
            let w = rect(10.6, 9.4, 2.2, 1.8); ctx.addPath(w); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
            let base = CGMutablePath(); base.move(to: CGPoint(x: 2.5, y: 2.5)); base.addLine(to: CGPoint(x: 15.5, y: 2.5)); stroke(ctx, base, 1.3)
        case "123.rectangle": // count-in: a ruled card with three numerals
            let r = CGRect(x: 2, y: 4, width: 13, height: 10)
            block(ctx, r, depth: 1.5)
            let f = Theme.title(7, .semibold)
            NSGraphicsContext.saveGraphicsState()
            ("123" as NSString).draw(at: CGPoint(x: 3.7, y: 5.2), withAttributes: [.font: f, .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
        case "magnifyingglass":
            let lens = CGPath(ellipseIn: CGRect(x: 2.5, y: 6, width: 9.5, height: 9.5), transform: nil)
            stroke(ctx, lens)
            let glint = CGMutablePath(); glint.addArc(center: CGPoint(x: 7.25, y: 10.75), radius: 3.2, startAngle: 1.9, endAngle: 2.9, clockwise: false); stroke(ctx, glint, hair)
            let handle = poly([CGPoint(x: 10.6, y: 6.8), CGPoint(x: 15.8, y: 1.6), CGPoint(x: 16.9, y: 2.7), CGPoint(x: 11.7, y: 7.9)])
            hatch(ctx, handle, spacing: 0.9); stroke(ctx, handle, 0.9)
        case "plus.rectangle.on.rectangle": // import: two plates, one behind the other, and a plus
            block(ctx, CGRect(x: 5.5, y: 6.5, width: 10, height: 8), depth: 0, shade: false)
            let front = CGRect(x: 2, y: 2.5, width: 10, height: 8)
            ctx.setFillColor(NSColor.clear.cgColor)
            ctx.saveGState(); ctx.setBlendMode(.clear); ctx.fill(front.insetBy(dx: -0.6, dy: -0.6)); ctx.restoreGState()
            stroke(ctx, CGPath(rect: front, transform: nil), 0.9)
            let p = CGMutablePath(); p.move(to: CGPoint(x: 7, y: 4.3)); p.addLine(to: CGPoint(x: 7, y: 8.7)); p.move(to: CGPoint(x: 4.8, y: 6.5)); p.addLine(to: CGPoint(x: 9.2, y: 6.5))
            stroke(ctx, p)
        case "point.topleft.down.to.point.bottomright.curvepath": // automation: a curve through two lettered nodes
            let c = CGMutablePath(); c.move(to: CGPoint(x: 3.5, y: 14)); c.addCurve(to: CGPoint(x: 14.5, y: 4), control1: CGPoint(x: 9, y: 14), control2: CGPoint(x: 9, y: 4))
            stroke(ctx, c)
            for p in [CGPoint(x: 3.5, y: 14), CGPoint(x: 14.5, y: 4)] {
                let n = CGRect(x: p.x - 1.9, y: p.y - 1.9, width: 3.8, height: 3.8)
                ctx.saveGState(); ctx.setBlendMode(.clear); ctx.fillEllipse(in: n); ctx.restoreGState()
                stroke(ctx, CGPath(ellipseIn: n, transform: nil), 0.9)
            }
            let base = CGMutablePath(); base.move(to: CGPoint(x: 2, y: 1.8)); base.addLine(to: CGPoint(x: 16, y: 1.8)); stroke(ctx, base, hair)
        case "rectangle.3.group", "square.grid.3x2": // the launcher: a grid of slots, two of them engraved (filled)
            for (i, (x, y)) in [(2.0, 10.0), (7.0, 10.0), (12.0, 10.0), (2.0, 4.0), (7.0, 4.0), (12.0, 4.0)].enumerated() {
                let r = rect(CGFloat(x), CGFloat(y), 4, 4.2)
                if i == 1 || i == 3 { hatch(ctx, r, spacing: 1.0) }
                stroke(ctx, r, 0.9)
            }
        case "slider.vertical.3": // the mixer: three screwed rails with fader blocks at different heights
            for (x, y) in [(4.0, 11.0), (9.0, 6.0), (14.0, 9.0)] as [(CGFloat, CGFloat)] {
                let rail = CGMutablePath(); rail.move(to: CGPoint(x: x, y: 2)); rail.addLine(to: CGPoint(x: x, y: 16)); stroke(ctx, rail, hair)
                block(ctx, CGRect(x: x - 2.2, y: y - 1.6, width: 3.6, height: 3.2), depth: 1)
            }
        case "sidebar.left", "sidebar.right": // a plate with its side column ruled and hatched
            let r = CGRect(x: 2, y: 3, width: 14, height: 12)
            let col = s == "sidebar.left" ? CGRect(x: 2, y: 3, width: 4.5, height: 12) : CGRect(x: 11.5, y: 3, width: 4.5, height: 12)
            hatch(ctx, CGPath(rect: col, transform: nil), spacing: 1.2)
            stroke(ctx, CGPath(rect: r, transform: nil)); stroke(ctx, CGPath(rect: col, transform: nil), hair)
            stroke(ctx, CGPath(rect: r.insetBy(dx: -1.2, dy: -1.2), transform: nil), hair)
        case "plus":
            let p = CGMutablePath(); p.move(to: CGPoint(x: 9, y: 3.5)); p.addLine(to: CGPoint(x: 9, y: 14.5)); p.move(to: CGPoint(x: 3.5, y: 9)); p.addLine(to: CGPoint(x: 14.5, y: 9))
            stroke(ctx, p, 1.3)
        case "puzzlepiece.extension": // plug-ins: a plate with a jack socket and its plug, in section
            block(ctx, CGRect(x: 2.5, y: 4, width: 9, height: 9), depth: 1.6)
            let socket = CGPath(ellipseIn: CGRect(x: 5, y: 6.5, width: 4, height: 4), transform: nil); stroke(ctx, socket, 0.9)
            let plug = CGMutablePath(); plug.move(to: CGPoint(x: 9.5, y: 8.5)); plug.addLine(to: CGPoint(x: 16, y: 8.5)); stroke(ctx, plug, 1.2)
        case "star", "star.fill":
            var pts: [CGPoint] = []
            for i in 0..<10 { let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 5, r: CGFloat = i % 2 == 0 ? 7 : 2.9; pts.append(CGPoint(x: 9 + cos(a) * r, y: 8.6 + sin(a) * r)) }
            let p = poly(pts)
            if s == "star.fill" { hatch(ctx, p, spacing: 1.0) }
            stroke(ctx, p, 0.9)
        case "clock": // a dial: graduated ring and two hands
            let c = CGPoint(x: 9, y: 9)
            stroke(ctx, CGPath(ellipseIn: CGRect(x: 2.5, y: 2.5, width: 13, height: 13), transform: nil))
            for i in 0..<12 {
                let a = CGFloat(i) * .pi / 6, r0: CGFloat = i % 3 == 0 ? 4.4 : 5.2
                let t = CGMutablePath(); t.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0)); t.addLine(to: CGPoint(x: c.x + cos(a) * 6, y: c.y + sin(a) * 6)); stroke(ctx, t, hair)
            }
            let h = CGMutablePath(); h.move(to: c); h.addLine(to: CGPoint(x: 9, y: 13)); h.move(to: c); h.addLine(to: CGPoint(x: 12, y: 8)); stroke(ctx, h, 1)
        case "folder": // a portfolio: two boards in the oblique, the front one hatched on its edge
            let back = poly([CGPoint(x: 2.5, y: 4), CGPoint(x: 2.5, y: 14), CGPoint(x: 7, y: 14), CGPoint(x: 8.5, y: 12.5), CGPoint(x: 15.5, y: 12.5), CGPoint(x: 15.5, y: 4)])
            stroke(ctx, back, 0.9)
            let front = poly([CGPoint(x: 2.5, y: 4), CGPoint(x: 4, y: 10.5), CGPoint(x: 16.5, y: 10.5), CGPoint(x: 15.5, y: 4)])
            hatch(ctx, front, spacing: 1.6, alpha: 0.55); stroke(ctx, front, 0.9)
        default: break
        }
    }
}
