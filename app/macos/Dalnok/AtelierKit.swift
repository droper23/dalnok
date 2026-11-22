// Atelier: drawing primitives for the Codex theme ("06 - Design/Atelier.md").
// The studio as a plate from an old natural-philosophy book: every mark ruled and measured, like a copper engraving of
// a scientific instrument. Sepia ink on parchment (light), or cream engraving on dark umber with gold (dark, after the
// "Mathematics" plates). Shade is engraved in fine parallel lines; panels are plates framed by a heavy and a fine rule;
// titles sit in cartouches; figures are numbered ("Fig. 2") with parts lettered (A, B, a, f) and leader lines; light
// dashed construction circles show how a figure was set out with the compass. Mathematical, never sketchy.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A ruled frame for a layer-backed view (buttons, the clock, cards): it follows the view's size.
final class SketchBorderLayer: CAShapeLayer {
    var seed = 0
    var overshoot: CGFloat = 2
    override var bounds: CGRect { didSet { if bounds.size != oldValue.size { rebuild() } } }
    func rebuild() {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        guard r.width > 2, r.height > 2 else { path = nil; return }
        path = Atelier.boxPath(r, seed: seed, overshoot: overshoot)
    }
    /// Puts one on `host` (replacing any earlier one) and returns it.
    @MainActor @discardableResult
    static func attach(to host: CALayer, color: NSColor, width: CGFloat = 0.9, seed: Int, overshoot: CGFloat = 2, dashed: Bool = false) -> SketchBorderLayer {
        host.sublayers?.filter { $0 is SketchBorderLayer }.forEach { $0.removeFromSuperlayer() }
        host.borderWidth = 0
        let l = SketchBorderLayer()
        l.seed = seed; l.overshoot = overshoot
        l.fillColor = nil; l.strokeColor = color.cgColor; l.lineWidth = min(width, 0.9)
        if dashed { l.lineDashPattern = [3, 2.5] }
        l.frame = host.bounds
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        l.rebuild()
        host.addSublayer(l)
        return l
    }
}

/// The parchment laid over a window (Atelier): fibres, a faint mottle and (light) a little foxing, as one pattern layer.
@MainActor
final class PaperGrainView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if let tile = Atelier.grainTile() {
            let image = NSImage(cgImage: tile, size: NSSize(width: CGFloat(tile.width) / 2, height: CGFloat(tile.height) / 2))
            layer?.backgroundColor = NSColor(patternImage: image).cgColor
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum Atelier {
    static var ink: NSColor { Theme.text }
    /// The coloured ink of the codex: red ochre on parchment, terracotta on umber (playhead, record, the selected).
    static var vermilion: NSColor { Theme.accent }
    /// Gold: headings, cartouche rules and figure letters on the dark plate; ochre on parchment.
    static var gold: NSColor { Theme.cycle }
    /// Engraver's line weights (points): hairline, fine, medium, heavy.
    static let hair: CGFloat = 0.5, fine: CGFloat = 0.8, medium: CGFloat = 1.2, heavy: CGFloat = 1.8

    // MARK: Geometry (deterministic)

    nonisolated static func hash(_ x: Int) -> Double {
        var z = UInt64(bitPattern: Int64(x)) &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    nonisolated static func noise(_ t: Double, seed: Int) -> Double {
        let i = Int(floor(t)), f = t - floor(t)
        let a = hash(seed &* 31 &+ i) * 2 - 1, b = hash(seed &* 31 &+ i &+ 1) * 2 - 1
        return a + (b - a) * (1 - cos(f * .pi)) / 2
    }
    nonisolated static func seed(_ a: CGPoint, _ b: CGPoint = .zero) -> Int {
        [a.x, a.y, b.x, b.y].map { Int(($0 / 2).rounded()) }.reduce(17) { $0 &* 486_187_739 &+ $1 }
    }
    /// A ruled line as points. `overshoot` runs it past both ends, as construction lines run past a corner.
    nonisolated static func handPoints(_ a: CGPoint, _ b: CGPoint, seed s: Int = 0, wobble: CGFloat = 0, overshoot: CGFloat = 0) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y, len = max(0.001, hypot(dx, dy))
        let ux = dx / len * overshoot, uy = dy / len * overshoot
        return [CGPoint(x: a.x - ux, y: a.y - uy), CGPoint(x: b.x + ux, y: b.y + uy)]
    }
    /// An even engraved line through `pts`.
    static func pen(_ ctx: CGContext, _ pts: [CGPoint], weight: CGFloat, color: NSColor, seed s: Int = 0) {
        guard pts.count > 1 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight); ctx.setLineCap(.butt); ctx.setLineJoin(.miter)
        ctx.addLines(between: pts); ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Paths for layer-drawn controls

    nonisolated static func boxPath(_ r: CGRect, seed s: Int = 0, overshoot: CGFloat = 2) -> CGPath { CGPath(rect: r, transform: nil) }
    nonisolated static func loopPath(_ r: CGRect, seed s: Int = 0) -> CGPath { CGPath(ellipseIn: r, transform: nil) }
    nonisolated static func washPath(_ r: CGRect, seed s: Int = 0) -> CGPath { CGPath(rect: r, transform: nil) }

    // MARK: Marks

    /// A ruled line; `dash` for construction lines.
    static func rule(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, weight: CGFloat, color: NSColor = Theme.text, dash: [CGFloat] = [], seed: Int? = nil) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight); ctx.setLineCap(.butt)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.restoreGState()
    }

    /// A ruled frame; with `overshoot` above 2.5, hairline construction lines run past each corner (a draughtsman's set-out).
    static func box(_ ctx: CGContext, _ r: CGRect, weight: CGFloat = fine, color: NSColor = Theme.text, seed: Int? = nil, overshoot: CGFloat = 0) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight)
        ctx.stroke(r.insetBy(dx: weight / 2, dy: weight / 2))
        if overshoot > 2.5 {
            ctx.setLineWidth(hair); ctx.setStrokeColor(color.withAlphaComponent(color.alphaComponent * 0.45).cgColor)
            let o = min(overshoot, 5)
            for (x, sx) in [(r.minX, -1.0), (r.maxX, 1.0)] as [(CGFloat, CGFloat)] {
                for (y, sy) in [(r.minY, -1.0), (r.maxY, 1.0)] as [(CGFloat, CGFloat)] {
                    ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + sx * o, y: y))
                    ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: y + sy * o))
                }
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// A circle drawn with the compass.
    static func loop(_ ctx: CGContext, _ r: CGRect, weight: CGFloat = fine, color: NSColor = Theme.text, seed: Int? = nil) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight)
        ctx.strokeEllipse(in: r.insetBy(dx: weight / 2, dy: weight / 2))
        ctx.restoreGState()
    }

    /// A pale tint laid over an area (the plate's hand colouring).
    static func wash(_ ctx: CGContext, _ r: CGRect, color: NSColor, alpha: CGFloat = 0.14, seed: Int? = nil) {
        ctx.saveGState(); ctx.setFillColor(color.withAlphaComponent(alpha).cgColor); ctx.fill(r); ctx.restoreGState()
    }

    /// Selection: registration marks just outside the corners.
    static func cropMarks(_ ctx: CGContext, _ r: CGRect, length: CGFloat = 7, gap: CGFloat = 3, color: NSColor = Theme.text, weight: CGFloat = 1, seed: Int? = nil) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight)
        for (x, sx) in [(r.minX, -1.0), (r.maxX, 1.0)] as [(CGFloat, CGFloat)] {
            for (y, sy) in [(r.minY, -1.0), (r.maxY, 1.0)] as [(CGFloat, CGFloat)] {
                ctx.move(to: CGPoint(x: x + sx * gap, y: y)); ctx.addLine(to: CGPoint(x: x + sx * (gap + length), y: y))
                ctx.move(to: CGPoint(x: x, y: y + sy * gap)); ctx.addLine(to: CGPoint(x: x, y: y + sy * (gap + length)))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Engraved shading: even parallel lines at `angle` (45° by default); `cross` adds the perpendicular set.
    static func hatch(_ ctx: CGContext, _ rect: CGRect, spacing: CGFloat = 4, color: NSColor = Theme.ink(0.16), weight: CGFloat = 0.5,
                      cross: Bool = false, seed: Int? = nil, angle: CGFloat = .pi / 4) {
        guard rect.width > 0, rect.height > 0 else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight)
        let c = CGPoint(x: rect.midX, y: rect.midY), reach = hypot(rect.width, rect.height) / 2 + spacing
        for a in cross ? [angle, angle + .pi / 2] : [angle] {
            let dx = cos(a), dy = sin(a), nx = -dy, ny = dx
            var t = -reach
            while t <= reach {
                let p = CGPoint(x: c.x + nx * t, y: c.y + ny * t)
                ctx.move(to: CGPoint(x: p.x - dx * reach, y: p.y - dy * reach)); ctx.addLine(to: CGPoint(x: p.x + dx * reach, y: p.y + dy * reach))
                t += spacing
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Engraved fill: fine rules across `rect` (levels). `vertical`: the rules run horizontally, stacking upward.
    static func scribble(_ ctx: CGContext, _ rect: CGRect, color: NSColor, spacing: CGFloat = 1.6, weight: CGFloat = 0.6, vertical: Bool = true, seed: Int = 3) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        hatch(ctx, rect, spacing: spacing, color: color, weight: weight, angle: vertical ? 0 : .pi / 2)
    }

    // MARK: Parchment

    private static var grainTiles: [Bool: CGImage] = [:]
    static func grainTile() -> CGImage? {
        let light = Theme.isLight
        if grainTiles[light] == nil { grainTiles[light] = makeGrain(light: light) }
        return grainTiles[light]
    }
    static func grain(_ ctx: CGContext, _ rect: CGRect, strength: CGFloat = 1) {
        guard let tile = grainTile() else { return }
        ctx.saveGState(); ctx.clip(to: rect); ctx.setAlpha(strength)
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: CGFloat(tile.width) / 2, height: CGFloat(tile.height) / 2), byTiling: true)
        ctx.restoreGState()
    }
    private static func makeGrain(light: Bool) -> CGImage? {
        let size = 512
        guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sepia = light ? CGColor(red: 0.42, green: 0.30, blue: 0.16, alpha: 1) : CGColor(red: 0.90, green: 0.80, blue: 0.56, alpha: 1)
        let mottle = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [sepia.copy(alpha: light ? 0.04 : 0.025)!, sepia.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
        for k in 0..<22 { // broad soft blots, wrapped so the tile is seamless
            let x = hash(20_000 + k) * Double(size), y = hash(21_000 + k) * Double(size), r = 30 + hash(22_000 + k) * 90
            for ox in [-size, 0, size] { for oy in [-size, 0, size] {
                let p = CGPoint(x: x + Double(ox), y: y + Double(oy))
                c.drawRadialGradient(mottle, startCenter: p, startRadius: 0, endCenter: p, endRadius: r, options: [])
            } }
        }
        for k in 0..<4_200 { // tooth
            let x = hash(k * 2) * Double(size), y = hash(k * 2 + 1) * Double(size), a = 0.02 + hash(k * 5) * 0.035
            c.setFillColor(sepia.copy(alpha: CGFloat(a))!)
            let d = 0.8 + hash(k * 7) * 1.2
            c.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d))
        }
        c.setLineCap(.round)
        for k in 0..<120 { // laid fibres, mostly along the sheet
            let x = hash(9_000 + k) * Double(size), y = hash(9_500 + k) * Double(size)
            let a = (hash(9_900 + k) - 0.5) * 0.8, l = 8 + hash(9_700 + k) * 24
            c.setStrokeColor(sepia.copy(alpha: 0.05)!); c.setLineWidth(0.6)
            c.move(to: CGPoint(x: x, y: y))
            c.addQuadCurve(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l), control: CGPoint(x: x + cos(a + 0.3) * l / 2, y: y + sin(a + 0.3) * l / 2))
            c.strokePath()
        }
        for k in 0..<5 where light { // foxing
            let x = hash(30_000 + k) * Double(size), y = hash(31_000 + k) * Double(size), r = 2 + hash(32_000 + k) * 4
            c.setFillColor(CGColor(red: 0.55, green: 0.33, blue: 0.15, alpha: 0.06))
            c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r * 0.8))
        }
        return c.makeImage()
    }

    // MARK: Instruments

    /// A graduated scale (meters, faders), lettered in the serif.
    static func scale(_ ctx: CGContext, x: CGFloat, marks: [(y: CGFloat, label: String?, major: Bool)], left: Bool, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.title(font.pointSize, .regular), .foregroundColor: Theme.textDim]
        for m in marks {
            let w: CGFloat = m.major ? 5 : 2.5
            rule(ctx, CGPoint(x: x, y: m.y), CGPoint(x: left ? x - w : x + w, y: m.y), weight: m.major ? 0.6 : hair, color: Theme.ink(m.major ? 0.75 : 0.45))
            if let l = m.label as NSString? {
                let s = l.size(withAttributes: attrs)
                l.draw(at: CGPoint(x: left ? x - w - 2 - s.width : x + w + 2, y: m.y - s.height / 2), withAttributes: attrs)
            }
        }
    }

    /// An engraved dial: a ring of fine graduations (longer every fifth), a turned globe shaded by curved engraving on
    /// the side away from the light, the value as a hatched sector, and a slim lozenge needle from a turned hub.
    static func knob(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, value: CGFloat, from start: CGFloat = 0, color: NSColor, active: Bool) {
        let a0 = CGFloat.pi * 1.25, sweep = CGFloat.pi * 1.5
        func angle(_ v: CGFloat) -> CGFloat { a0 - sweep * v }
        ctx.saveGState()
        for i in 0...30 {
            let a = angle(CGFloat(i) / 30), long = i % 5 == 0
            let p0 = CGPoint(x: c.x + cos(a) * (r - (long ? 3 : 1.6)), y: c.y + sin(a) * (r - (long ? 3 : 1.6)))
            let p1 = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            rule(ctx, p0, p1, weight: long ? 0.6 : 0.35, color: Theme.ink(long ? 0.8 : 0.45))
        }
        let inner = r - 4.5
        let face = CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: face)
        ctx.saveGState(); ctx.addEllipse(in: face); ctx.clip()
        globeShade(ctx, face)
        ctx.restoreGState()
        let (lo, hi) = (min(start, value), max(start, value))
        if hi - lo > 0.002 {
            let wedge = CGMutablePath()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: inner, startAngle: angle(lo), endAngle: angle(hi), clockwise: true)
            wedge.closeSubpath()
            ctx.saveGState(); ctx.addPath(wedge); ctx.clip()
            hatch(ctx, face, spacing: 1.5, color: color.withAlphaComponent(active ? 0.9 : 0.65), weight: 0.45)
            ctx.restoreGState()
        }
        loop(ctx, face, weight: active ? medium : fine, color: Theme.ink(active ? 1 : 0.9))
        loop(ctx, face.insetBy(dx: 1.6, dy: 1.6), weight: hair, color: Theme.ink(0.35))
        needle(ctx, center: c, angle: angle(value), length: inner + 1)
        ctx.restoreGState()
    }
    /// Curved engraving lines across the lower right of a disc, as light from the upper left falls on a turned part.
    static func globeShade(_ ctx: CGContext, _ face: CGRect, flipped: Bool = false) {
        // The shadow side is a crescent: the disc less a lit disc moved toward the light; it is engraved in fine
        // diagonal lines.
        let lit = face.offsetBy(dx: -face.width * 0.22, dy: (flipped ? -1 : 1) * face.height * 0.22)
        ctx.saveGState()
        let crescent = CGMutablePath(); crescent.addEllipse(in: face); crescent.addEllipse(in: lit.insetBy(dx: -face.width * 0.05, dy: -face.height * 0.05))
        ctx.addPath(crescent); ctx.clip(using: .evenOdd)
        hatch(ctx, face, spacing: 1.3, color: Theme.ink(0.32), weight: 0.35, angle: -.pi / 4)
        ctx.restoreGState()
    }
    /// A slim lozenge needle with a turned hub.
    static func needle(_ ctx: CGContext, center c: CGPoint, angle a: CGFloat, length: CGFloat, color: NSColor = Theme.text) {
        let tip = CGPoint(x: c.x + cos(a) * length, y: c.y + sin(a) * length)
        let tail = CGPoint(x: c.x - cos(a) * length * 0.28, y: c.y - sin(a) * length * 0.28)
        let w: CGFloat = 1.3, n = CGPoint(x: -sin(a) * w, y: cos(a) * w)
        let p = CGMutablePath()
        p.addLines(between: [tail, CGPoint(x: c.x + n.x, y: c.y + n.y), tip, CGPoint(x: c.x - n.x, y: c.y - n.y)]); p.closeSubpath()
        ctx.saveGState()
        ctx.addPath(p); ctx.setFillColor(color.cgColor); ctx.fillPath()
        let hub = CGRect(x: c.x - 1.7, y: c.y - 1.7, width: 3.4, height: 3.4)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: hub)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(0.6); ctx.strokeEllipse(in: hub)
        ctx.restoreGState()
    }

    /// A ruled column: the level engraved in fine rules, red ochre above -3 dB, a short rule for the peak.
    static func meter(_ ctx: CGContext, _ rect: CGRect, level: CGFloat, peak: CGFloat, clipped: Bool) {
        let vertical = rect.height > rect.width
        ctx.saveGState()
        let lit = vertical ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * level)
                           : CGRect(x: rect.minX, y: rect.minY, width: rect.width * level, height: rect.height)
        let hot: CGFloat = 0.9
        let cool = vertical ? CGRect(x: lit.minX, y: lit.minY, width: lit.width, height: min(lit.height, rect.height * hot))
                            : CGRect(x: lit.minX, y: lit.minY, width: min(lit.width, rect.width * hot), height: lit.height)
        scribble(ctx, cool, color: Theme.ink(0.85), spacing: 1.3, weight: 0.55, vertical: vertical)
        if level > hot {
            let over = vertical ? CGRect(x: rect.minX, y: rect.minY + rect.height * hot, width: rect.width, height: rect.height * (level - hot))
                                : CGRect(x: rect.minX + rect.width * hot, y: rect.minY, width: rect.width * (level - hot), height: rect.height)
            scribble(ctx, over, color: vermilion, spacing: 1.1, weight: 0.7, vertical: vertical)
        }
        box(ctx, rect, weight: hair, color: Theme.ink(0.75))
        if peak > 0.01 {
            let a = vertical ? CGPoint(x: rect.minX - 1, y: rect.minY + rect.height * peak) : CGPoint(x: rect.minX + rect.width * peak, y: rect.minY - 1)
            let b = vertical ? CGPoint(x: rect.maxX + 1, y: a.y) : CGPoint(x: a.x, y: rect.maxY + 1)
            rule(ctx, a, b, weight: fine, color: clipped ? vermilion : Theme.text)
        }
        ctx.restoreGState()
    }

    // MARK: Plates (plug-ins)

    /// A plug-in as a plate of the book (y up): a leaf framed by a heavy and a fine rule with lozenges set into the inner
    /// corners, the track's ink as a fine rule under the head. Bypassed plates are engraved over. Returns the inner field.
    @discardableResult
    static func hardware(_ ctx: CGContext, _ rect: CGRect, accent: NSColor, dimmed: Bool, seed s: Int) -> CGRect {
        let outer = rect.insetBy(dx: 1.5, dy: 1.5)
        ctx.saveGState()
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fill(outer)
        let ink = Theme.ink(dimmed ? 0.5 : 0.9)
        box(ctx, outer, weight: medium, color: ink)
        let inner = outer.insetBy(dx: 3.5, dy: 3.5)
        box(ctx, inner, weight: hair, color: ink)
        for (x, y) in [(inner.minX, inner.minY), (inner.maxX, inner.minY), (inner.minX, inner.maxY), (inner.maxX, inner.maxY)] {
            ornament(ctx, CGPoint(x: x, y: y), size: 3.2, color: ink)
        }
        rule(ctx, CGPoint(x: inner.minX + 10, y: inner.maxY - 26), CGPoint(x: inner.maxX - 10, y: inner.maxY - 26), weight: hair, color: accent.withAlphaComponent(dimmed ? 0.35 : 0.85))
        if dimmed { hatch(ctx, inner.insetBy(dx: 1, dy: 1), spacing: 5, color: Theme.ink(0.09), weight: 0.45) }
        ctx.restoreGState()
        return inner
    }

    /// A small lozenge over a corner or a rule's centre.
    static func ornament(_ ctx: CGContext, _ c: CGPoint, size s: CGFloat, color: NSColor, filled: Bool = true) {
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: c.x, y: c.y - s), CGPoint(x: c.x + s, y: c.y), CGPoint(x: c.x, y: c.y + s), CGPoint(x: c.x - s, y: c.y)]); p.closeSubpath()
        ctx.saveGState()
        ctx.addPath(p); ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillPath()
        ctx.addPath(p); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(0.6); ctx.strokePath()
        if filled { ctx.setFillColor(color.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 0.8, y: c.y - 0.8, width: 1.6, height: 1.6)) }
        ctx.restoreGState()
    }

    /// A figure's frame: a neatline (two rules with a graduated band between, alternately filled like a map border).
    static func screen(_ ctx: CGContext, _ r: CGRect, seed s: Int = 0) {
        ctx.saveGState()
        box(ctx, r, weight: fine, color: Theme.ink(0.8))
        let b: CGFloat = 2, band = r.insetBy(dx: -b, dy: -b)
        box(ctx, band, weight: hair, color: Theme.ink(0.5))
        ctx.setFillColor(Theme.ink(0.32).cgColor)
        var x = r.minX, k = 0
        while x < r.maxX {
            if k % 2 == 0 { ctx.fill(CGRect(x: x, y: band.minY, width: min(6, r.maxX - x), height: b)); ctx.fill(CGRect(x: x, y: r.maxY, width: min(6, r.maxX - x), height: b)) }
            x += 6; k += 1
        }
        var y = r.minY; k = 0
        while y < r.maxY {
            if k % 2 == 1 { ctx.fill(CGRect(x: band.minX, y: y, width: b, height: min(6, r.maxY - y))); ctx.fill(CGRect(x: r.maxX, y: y, width: b, height: min(6, r.maxY - y))) }
            y += 6; k += 1
        }
        ctx.restoreGState()
    }

    /// A check box: a ruled square; when on, a saltire engraved in it.
    static func checkbox(_ ctx: CGContext, _ r: CGRect, on: Bool, enabled: Bool = true, flipped: Bool = false) {
        box(ctx, r, weight: fine, color: Theme.ink(enabled ? 0.85 : 0.35))
        guard on else { return }
        let i = r.insetBy(dx: 3, dy: 3), c = enabled ? Theme.text : Theme.textFaint
        rule(ctx, CGPoint(x: i.minX, y: i.minY), CGPoint(x: i.maxX, y: i.maxY), weight: 1.3, color: c)
        rule(ctx, CGPoint(x: i.minX, y: i.maxY), CGPoint(x: i.maxX, y: i.minY), weight: 1.3, color: c)
    }

    // MARK: Lettering and annotation

    /// A cartouche: a label in a frame with pointed ends and a fine inner frame ("02 · Dynamics"). Returns its frame.
    @discardableResult
    static func cartouche(_ ctx: CGContext, _ text: String, center c: CGPoint, font: NSFont, color: NSColor = Theme.text,
                          fill: NSColor = Theme.panelRaised, flipped: Bool = false) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let s = (text as NSString).size(withAttributes: attrs)
        let h = ceil(s.height + 6), w = ceil(s.width + h + 12)
        let r = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        func shape(_ r: CGRect) -> CGPath {
            let p = CGMutablePath(), k = r.height / 2
            p.addLines(between: [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.minX + k * 0.7, y: r.minY), CGPoint(x: r.maxX - k * 0.7, y: r.minY),
                                 CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX - k * 0.7, y: r.maxY), CGPoint(x: r.minX + k * 0.7, y: r.maxY)])
            p.closeSubpath(); return p
        }
        ctx.saveGState()
        ctx.addPath(shape(r)); ctx.setFillColor(fill.cgColor); ctx.fillPath()
        ctx.addPath(shape(r)); ctx.setStrokeColor(Theme.ink(0.85).cgColor); ctx.setLineWidth(fine); ctx.strokePath()
        ctx.addPath(shape(r.insetBy(dx: 3, dy: 2))); ctx.setStrokeColor(gold.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(hair); ctx.strokePath()
        ctx.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: flipped)
        (text as NSString).draw(at: CGPoint(x: c.x - s.width / 2, y: c.y - s.height / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return r
    }

    /// An ornamental rule: fine rules from `a` to `b` with a lozenge at the middle and an arrowhead at the end.
    static func ornamentRule(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, color: NSColor = Theme.ink(0.7), arrow: Bool = true) {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        rule(ctx, a, CGPoint(x: mid.x - 6, y: mid.y), weight: hair, color: color)
        rule(ctx, CGPoint(x: mid.x + 6, y: mid.y), b, weight: hair, color: color)
        ornament(ctx, mid, size: 3.5, color: color)
        if arrow { arrowhead(ctx, at: b, angle: atan2(b.y - a.y, b.x - a.x), color: color) }
    }

    /// A slim engraved arrowhead with its tip at `p`, pointing along `angle`.
    static func arrowhead(_ ctx: CGContext, at p: CGPoint, angle: CGFloat, color: NSColor, size: CGFloat = 6) {
        let back = CGPoint(x: p.x - cos(angle) * size, y: p.y - sin(angle) * size)
        let n = CGPoint(x: -sin(angle) * size * 0.32, y: cos(angle) * size * 0.32)
        let path = CGMutablePath()
        path.addLines(between: [p, CGPoint(x: back.x + n.x, y: back.y + n.y), CGPoint(x: back.x + cos(angle) * size * 0.25, y: back.y + sin(angle) * size * 0.25),
                                CGPoint(x: back.x - n.x, y: back.y - n.y)]); path.closeSubpath()
        ctx.saveGState(); ctx.addPath(path); ctx.setFillColor(color.cgColor); ctx.fillPath(); ctx.restoreGState()
    }

    /// Text in the annotation hand (italic serif). `p` is the text's top-left in a flipped context.
    static func note(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat = 8.5, color: NSColor = Theme.textDim,
                     flipped: Bool = true, align: NSTextAlignment = .left, roman: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: roman ? Theme.title(size, .regular) : Theme.note(size), .foregroundColor: color]
        let s = (text as NSString).size(withAttributes: attrs)
        let x = align == .center ? p.x - s.width / 2 : align == .right ? p.x - s.width : p.x
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: flipped)
        (text as NSString).draw(at: CGPoint(x: x, y: p.y), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A lettered callout, as on an engraved instrument: a fine leader from the part at `from` to a small serif letter.
    static func callout(_ ctx: CGContext, _ letter: String, from: CGPoint, to: CGPoint, flipped: Bool = true) {
        rule(ctx, from, to, weight: 0.4, color: Theme.ink(0.45))
        ctx.setFillColor(Theme.ink(0.6).cgColor); ctx.fillEllipse(in: CGRect(x: from.x - 0.9, y: from.y - 0.9, width: 1.8, height: 1.8))
        note(ctx, letter, at: CGPoint(x: to.x + (to.x >= from.x ? 1.5 : -1.5), y: to.y - 5.5), size: 8, color: gold,
             flipped: flipped, align: to.x >= from.x ? .left : .right)
    }

    /// Fig. 1, the diapason (y down): a tuning fork engraved in perspective with its sine beside it, lettered, with
    /// the frequency set out as an equation. Decorates the start page and empty plates.
    static func diapason(_ ctx: CGContext, _ r: CGRect, figure: String = "Fig. 1") {
        let ink = Theme.ink(0.8), faint = Theme.ink(0.3)
        let fx = r.minX + r.width * 0.22, top = r.minY + 8, bottom = r.maxY - 18
        let gap: CGFloat = 7, prong: CGFloat = 3.2
        let stemTop = top + (bottom - top) * 0.62
        for side in [-1.0, 1.0] as [CGFloat] { // prongs, each a long slim bar with an engraved shadow side
            let x = fx + side * gap
            let bar = CGRect(x: x - prong / 2, y: top, width: prong, height: stemTop - top)
            ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fill(bar)
            hatch(ctx, CGRect(x: bar.midX, y: bar.minY, width: prong / 2, height: bar.height), spacing: 1.1, color: faint, weight: 0.35, angle: .pi / 2)
            box(ctx, bar, weight: 0.6, color: ink)
        }
        let yoke = CGMutablePath() // the U where the prongs meet
        yoke.move(to: CGPoint(x: fx - gap - prong / 2, y: stemTop))
        yoke.addArc(center: CGPoint(x: fx, y: stemTop), radius: gap + prong / 2, startAngle: .pi, endAngle: 0, clockwise: true)
        yoke.addLine(to: CGPoint(x: fx + gap - prong / 2, y: stemTop))
        yoke.addArc(center: CGPoint(x: fx, y: stemTop), radius: gap - prong / 2, startAngle: 0, endAngle: .pi, clockwise: false)
        yoke.closeSubpath()
        ctx.addPath(yoke); ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillPath()
        ctx.addPath(yoke); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(0.6); ctx.strokePath()
        let stem = CGRect(x: fx - 1.6, y: stemTop + gap + prong / 2 - 1, width: 3.2, height: bottom - stemTop - gap - 6)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fill(stem); box(ctx, stem, weight: 0.6, color: ink)
        let knob = CGRect(x: fx - 4, y: stem.maxY - 1, width: 8, height: 6)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: knob)
        hatch(ctx, CGRect(x: knob.midX, y: knob.minY, width: knob.width / 2, height: knob.height), spacing: 1.1, color: faint, weight: 0.35, angle: .pi / 2)
        loop(ctx, knob, weight: 0.6, color: ink)
        for k in 1...3 { // vibration marks beside the prongs
            let o = CGFloat(k) * 3.5
            for side in [-1.0, 1.0] as [CGFloat] {
                let x = fx + side * (gap + prong / 2 + o)
                ctx.saveGState(); ctx.setStrokeColor(faint.cgColor); ctx.setLineWidth(0.4)
                ctx.addArc(center: CGPoint(x: fx, y: top + 14), radius: gap + o + 2, startAngle: side > 0 ? -0.5 : .pi + 0.5, endAngle: side > 0 ? 0.5 : .pi - 0.5, clockwise: side < 0)
                ctx.strokePath(); ctx.restoreGState()
                _ = x
            }
        }
        // The sine it sounds, beside it, with its period dimensioned.
        let sx = r.minX + r.width * 0.42, sw = r.width * 0.5, sy = top + 22, amp: CGFloat = 9
        var pts: [CGPoint] = []
        for i in 0...80 { let t = CGFloat(i) / 80; pts.append(CGPoint(x: sx + sw * t, y: sy - amp * sin(t * 4 * .pi))) }
        pen(ctx, pts, weight: 0.9, color: vermilion)
        rule(ctx, CGPoint(x: sx, y: sy), CGPoint(x: sx + sw + 4, y: sy), weight: 0.4, color: faint)
        arrowhead(ctx, at: CGPoint(x: sx + sw + 6, y: sy), angle: 0, color: faint, size: 4)
        let dimY = sy + amp + 7
        rule(ctx, CGPoint(x: sx, y: dimY), CGPoint(x: sx + sw / 2, y: dimY), weight: 0.4, color: Theme.ink(0.5))
        arrowhead(ctx, at: CGPoint(x: sx, y: dimY), angle: .pi, color: Theme.ink(0.5), size: 4)
        arrowhead(ctx, at: CGPoint(x: sx + sw / 2, y: dimY), angle: 0, color: Theme.ink(0.5), size: 4)
        note(ctx, "T", at: CGPoint(x: sx + sw / 4, y: dimY + 1), size: 8, color: Theme.textDim, align: .center)
        note(ctx, "f = 440 Hz", at: CGPoint(x: sx + sw * 0.1, y: sy - amp - 18), size: 10, color: Theme.text)
        note(ctx, "f = 1 / T", at: CGPoint(x: sx + sw * 0.1, y: dimY + 13), size: 8.5, color: Theme.textDim)
        callout(ctx, "a", from: CGPoint(x: fx + gap, y: top + 6), to: CGPoint(x: fx + gap + 12, y: top))
        callout(ctx, "b", from: CGPoint(x: fx, y: stem.midY), to: CGPoint(x: fx - 14, y: stem.midY - 4))
        note(ctx, figure, at: CGPoint(x: r.maxX - 4, y: r.maxY - 12), size: 9, color: Theme.textDim, align: .right)
    }

    /// A dashed construction circle (how a figure was set out with the compass).
    static func construction(_ ctx: CGContext, circle r: CGRect, color: NSColor = Theme.ink(0.18)) {
        ctx.saveGState(); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(0.4); ctx.setLineDash(phase: 0, lengths: [2, 2.5])
        ctx.strokeEllipse(in: r); ctx.restoreGState()
    }
}
