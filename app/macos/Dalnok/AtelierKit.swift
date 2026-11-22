// Atelier: drawing primitives for the sketchbook theme ("06 - Design/Atelier.md").
// Everything is drawn by hand in ink on sketchbook paper (or white gel pen on a black sketchbook): lines wobble a
// little and taper with the pen's pressure, boxes overshoot their corners, circles are one looped stroke, shading is
// cross-hatching, fills are ink washes, levels are scribbled in. One red pen for what must be seen.
// Every mark is deterministic: its wobble comes from a seed (the geometry, or a stable id such as a clip's), so the
// drawing never shimmers between redraws and a clip keeps its own hand as it scrolls.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// A hand-drawn border for a layer-backed view (buttons, the clock): it follows the view's size and keeps its hand.
final class SketchBorderLayer: CAShapeLayer {
    var seed = 0
    var overshoot: CGFloat = 2
    override var bounds: CGRect { didSet { if bounds.size != oldValue.size { rebuild() } } }
    func rebuild() {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5), s = seed, o = overshoot
        guard r.width > 2, r.height > 2 else { path = nil; return }
        path = Atelier.boxPath(r, seed: s, overshoot: o)
    }
    /// Puts one on `host` (replacing any earlier one) and returns it.
    @MainActor @discardableResult
    static func attach(to host: CALayer, color: NSColor, width: CGFloat = 0.9, seed: Int, overshoot: CGFloat = 2, dashed: Bool = false) -> SketchBorderLayer {
        host.sublayers?.filter { $0 is SketchBorderLayer }.forEach { $0.removeFromSuperlayer() }
        host.borderWidth = 0
        let l = SketchBorderLayer()
        l.seed = seed; l.overshoot = overshoot
        l.fillColor = nil; l.strokeColor = color.cgColor; l.lineWidth = width; l.lineCap = .round; l.lineJoin = .round
        if dashed { l.lineDashPattern = [3, 2.5] }
        l.frame = host.bounds
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        l.rebuild()
        host.addSublayer(l)
        return l
    }
}

/// The sketchbook's paper texture laid over a window (Atelier): a pattern layer, so it costs nothing per redraw.
@MainActor
final class PaperGrainView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        if let tile = Atelier.grainTile() {
            let image = NSImage(cgImage: tile, size: NSSize(width: CGFloat(tile.width) / 2, height: CGFloat(tile.height) / 2))
            layer?.backgroundColor = NSColor(patternImage: image).cgColor
        }
        layer?.opacity = 0.9
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
enum Atelier {
    static var ink: NSColor { Theme.text }
    static var vermilion: NSColor { Theme.accent }
    /// Pen weights (points): hairline, fine, medium, heavy.
    static let hair: CGFloat = 0.6, fine: CGFloat = 0.9, medium: CGFloat = 1.4, heavy: CGFloat = 2.2

    // MARK: The hand (deterministic jitter)

    /// 0…1 from an integer, stable across runs (a 64-bit mix).
    nonisolated static func hash(_ x: Int) -> Double {
        var z = UInt64(bitPattern: Int64(x)) &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
    /// Smooth -1…1 noise along `t` (one wiggle per unit), different for every seed.
    nonisolated static func noise(_ t: Double, seed: Int) -> Double {
        let i = Int(floor(t)), f = t - floor(t)
        let a = hash(seed &* 31 &+ i) * 2 - 1, b = hash(seed &* 31 &+ i &+ 1) * 2 - 1
        let s = (1 - cos(f * .pi)) / 2
        return a + (b - a) * s
    }
    /// A seed from geometry (rounded, so a mark redrawn in place keeps its shape).
    nonisolated static func seed(_ a: CGPoint, _ b: CGPoint = .zero) -> Int {
        let v = [a.x, a.y, b.x, b.y].map { Int(($0 / 2).rounded()) }
        return v.reduce(17) { $0 &* 486_187_739 &+ $1 }
    }

    /// The points of a hand-drawn line from `a` to `b`: a gentle wobble across it (a slow drift plus a faint tremor)
    /// that grows with length, and an overshoot past both ends.
    nonisolated static func handPoints(_ a: CGPoint, _ b: CGPoint, seed s: Int, wobble: CGFloat = 1, overshoot: CGFloat = 0) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y, len = max(0.001, hypot(dx, dy))
        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
        let start = CGPoint(x: a.x - ux * overshoot * CGFloat(0.4 + hash(s) * 0.8), y: a.y - uy * overshoot * CGFloat(0.4 + hash(s) * 0.8))
        let total = len + overshoot * CGFloat(0.8 + hash(s &+ 7) * 0.8)
        let amp = wobble * min(1.6, 0.35 + len * 0.004)
        let steps = max(2, min(80, Int(total / 6)))
        var out: [CGPoint] = []
        out.reserveCapacity(steps + 1)
        for k in 0...steps {
            let t = CGFloat(k) / CGFloat(steps), d = total * t
            // Ends stay closer to where the pen was put down and lifted.
            let env = CGFloat(sin(Double(t) * .pi)) * 0.7 + 0.3
            let off = amp * env * CGFloat(noise(Double(d) / 70, seed: s) * 0.85 + noise(Double(d) / 9, seed: s &+ 99) * 0.15)
            out.append(CGPoint(x: start.x + ux * d + nx * off, y: start.y + uy * d + ny * off))
        }
        return out
    }

    /// Strokes a pen line along `pts`: heavier pens become a filled outline whose width follows the pressure (a little
    /// thicker in the middle, thinner where the pen lands and lifts).
    static func pen(_ ctx: CGContext, _ pts: [CGPoint], weight: CGFloat, color: NSColor, seed s: Int) {
        guard pts.count > 1 else { return }
        ctx.saveGState()
        if weight < 1.0 {
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addLines(between: pts); ctx.strokePath()
        } else {
            var left: [CGPoint] = [], right: [CGPoint] = []
            for (k, p) in pts.enumerated() {
                let q = pts[min(pts.count - 1, k + 1)], o = pts[max(0, k - 1)]
                let dx = q.x - o.x, dy = q.y - o.y, l = max(0.001, hypot(dx, dy))
                let t = Double(k) / Double(pts.count - 1)
                let pressure = (0.55 + 0.45 * sin(t * .pi)) * (0.85 + 0.3 * hash(s &+ k / 4))
                let w = weight * CGFloat(pressure) / 2
                left.append(CGPoint(x: p.x - dy / l * w, y: p.y + dx / l * w))
                right.append(CGPoint(x: p.x + dy / l * w, y: p.y - dx / l * w))
            }
            ctx.setFillColor(color.cgColor)
            ctx.addLines(between: left + right.reversed()); ctx.closePath(); ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Paths for layer-drawn controls (chips, knob faces): the same hand as the drawn marks, as one stroke path.
    nonisolated static func boxPath(_ r: CGRect, seed s: Int, overshoot: CGFloat = 2) -> CGPath {
        let p = CGMutablePath()
        let c = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        for k in 0..<4 { p.addLines(between: handPoints(c[k], c[(k + 1) % 4], seed: s &+ 11 &* (k + 1), wobble: 0.8, overshoot: overshoot)) }
        return p
    }
    nonisolated static func loopPath(_ r: CGRect, seed s: Int) -> CGPath {
        let c = CGPoint(x: r.midX, y: r.midY), rx = r.width / 2, ry = r.height / 2
        let a0 = hash(s) * 2 * .pi, sweep = 2 * Double.pi + 0.35 + hash(s &+ 1) * 0.25
        let n = max(16, Int(max(rx, ry) * 1.6))
        let p = CGMutablePath()
        p.addLines(between: (0...n).map { k in
            let t = Double(k) / Double(n), a = a0 + sweep * t, wob = 1 + (0.035 + 0.5 / max(4, max(Double(rx), Double(ry)))) * noise(t * 3, seed: s) + 0.02 * t
            return CGPoint(x: c.x + CGFloat(cos(a) * wob) * rx, y: c.y + CGFloat(sin(a) * wob) * ry)
        })
        return p
    }

    // MARK: Marks

    /// A ruled line from `a` to `b`, drawn by hand. `seed` keeps a line's hand when its geometry changes (scrolling).
    static func rule(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, weight: CGFloat, color: NSColor = Theme.text, dash: [CGFloat] = [], seed: Int? = nil) {
        let s = seed ?? Self.seed(a, b)
        let pts = handPoints(a, b, seed: s, wobble: weight < 1 ? 0.8 : 1)
        if dash.isEmpty { return pen(ctx, pts, weight: weight, color: color, seed: s) }
        ctx.saveGState() // dotted and dashed rules stay light: a quick pen
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight); ctx.setLineCap(.round)
        ctx.setLineDash(phase: CGFloat(hash(s) * 4), lengths: dash)
        ctx.addLines(between: pts); ctx.strokePath()
        ctx.restoreGState()
    }

    /// A box drawn as four pen strokes that overshoot their corners, as a quick sketch does.
    static func box(_ ctx: CGContext, _ r: CGRect, weight: CGFloat = fine, color: NSColor = Theme.text, seed: Int? = nil, overshoot: CGFloat = 2.5) {
        let s = seed ?? Self.seed(r.origin, CGPoint(x: r.maxX, y: r.maxY))
        let j = { (k: Int) in CGFloat(hash(s &+ k) - 0.5) * 1.2 } // corners land a little off
        let c = [CGPoint(x: r.minX + j(1), y: r.minY + j(2)), CGPoint(x: r.maxX + j(3), y: r.minY + j(4)),
                 CGPoint(x: r.maxX + j(5), y: r.maxY + j(6)), CGPoint(x: r.minX + j(7), y: r.maxY + j(8))]
        let os = min(overshoot, min(r.width, r.height) * 0.2)
        for k in 0..<4 {
            pen(ctx, handPoints(c[k], c[(k + 1) % 4], seed: s &+ 11 &* (k + 1), overshoot: os), weight: weight, color: color, seed: s &+ k)
        }
    }

    /// A circle or ellipse drawn in one looped stroke that runs a little past where it began.
    static func loop(_ ctx: CGContext, _ r: CGRect, weight: CGFloat = fine, color: NSColor = Theme.text, seed: Int? = nil) {
        let s = seed ?? Self.seed(r.origin, CGPoint(x: r.maxX, y: r.maxY))
        let c = CGPoint(x: r.midX, y: r.midY), rx = r.width / 2, ry = r.height / 2
        let a0 = hash(s) * 2 * .pi, sweep = 2 * Double.pi + 0.35 + hash(s &+ 1) * 0.25
        let n = max(16, Int(max(rx, ry) * 1.6))
        var pts: [CGPoint] = []
        for k in 0...n {
            let t = Double(k) / Double(n), a = a0 + sweep * t
            let wob = 1 + (0.035 + 0.5 / max(4, max(Double(rx), Double(ry)))) * noise(t * 3, seed: s) + 0.02 * t // the loop drifts outward as it closes
            pts.append(CGPoint(x: c.x + CGFloat(cos(a) * wob) * rx, y: c.y + CGFloat(sin(a) * wob) * ry))
        }
        pen(ctx, pts, weight: weight, color: color, seed: s)
    }

    /// The outline of a hand-washed area: the rectangle's edges, gently uneven.
    nonisolated static func washPath(_ r: CGRect, seed s: Int) -> CGPath {
        let p = CGMutablePath()
        let c = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        var pts: [CGPoint] = []
        for k in 0..<4 { pts += handPoints(c[k], c[(k + 1) % 4], seed: s &+ 5 &* (k + 1), wobble: 0.9).dropLast() }
        p.addLines(between: pts); p.closeSubpath()
        return p
    }
    /// An ink wash: dilute ink brushed over an area, a little darker where it pooled at the edge.
    static func wash(_ ctx: CGContext, _ r: CGRect, color: NSColor, alpha: CGFloat = 0.18, seed: Int? = nil) {
        let s = seed ?? Self.seed(r.origin, CGPoint(x: r.maxX, y: r.maxY))
        let path = washPath(r, seed: s)
        ctx.saveGState()
        ctx.addPath(path); ctx.setFillColor(color.withAlphaComponent(alpha).cgColor); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(color.withAlphaComponent(min(1, alpha * 1.4)).cgColor); ctx.setLineWidth(2.2); ctx.strokePath()
        ctx.restoreGState()
    }

    /// Crop marks become sketched corner ticks: Atelier's selection, two quick strokes at each corner.
    static func cropMarks(_ ctx: CGContext, _ r: CGRect, length: CGFloat = 7, gap: CGFloat = 3, color: NSColor = Theme.text, weight: CGFloat = 1, seed: Int? = nil) {
        let s = seed ?? Self.seed(r.origin)
        for (i, (x, sx)) in ([(r.minX, -1.0), (r.maxX, 1.0)] as [(CGFloat, CGFloat)]).enumerated() {
            for (j, (y, sy)) in ([(r.minY, -1.0), (r.maxY, 1.0)] as [(CGFloat, CGFloat)]).enumerated() {
                let k = s &+ i * 2 + j
                rule(ctx, CGPoint(x: x + sx * gap, y: y), CGPoint(x: x + sx * (gap + length), y: y), weight: weight, color: color, seed: k)
                rule(ctx, CGPoint(x: x, y: y + sy * gap), CGPoint(x: x, y: y + sy * (gap + length)), weight: weight, color: color, seed: k &+ 50)
            }
        }
    }

    /// Hatching by hand (45°, a little uneven): "not in use": muted, offline, bypassed. `cross` adds the other
    /// direction, for shade.
    static func hatch(_ ctx: CGContext, _ rect: CGRect, spacing: CGFloat = 5, color: NSColor = Theme.ink(0.16), weight: CGFloat = 0.6, cross: Bool = false, seed: Int? = nil) {
        guard rect.width > 0, rect.height > 0 else { return }
        let s = seed ?? Self.seed(rect.origin)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight); ctx.setLineCap(.round)
        for dir in cross ? [1.0, -1.0] : [1.0] {
            var x = rect.minX - rect.height, k = 0
            while x < rect.maxX + rect.height {
                let jx = CGFloat(hash(s &+ k &* 3 &+ (dir > 0 ? 0 : 7_777)) - 0.5) * spacing * 0.35
                let a = CGPoint(x: x + jx, y: dir > 0 ? rect.maxY : rect.minY)
                let b = CGPoint(x: x + jx + rect.height, y: dir > 0 ? rect.minY : rect.maxY)
                ctx.addLines(between: handPoints(a, b, seed: s &+ k, wobble: 0.6))
                x += spacing; k += 1
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A scribbled fill: the pen going back and forth across `rect` (levels, filled marks).
    static func scribble(_ ctx: CGContext, _ rect: CGRect, color: NSColor, spacing: CGFloat = 2.2, weight: CGFloat = 0.8, vertical: Bool = true, seed: Int = 3) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }
        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: -0.5, dy: -0.5))
        var pts: [CGPoint] = []
        var k = 0
        if vertical { // strokes across, climbing
            var y = rect.minY
            while y <= rect.maxY + spacing {
                let j = CGFloat(hash(seed &+ k) - 0.5) * 0.8
                pts.append(CGPoint(x: k % 2 == 0 ? rect.minX - 0.5 : rect.maxX + 0.5, y: y + j))
                y += spacing; k += 1
            }
        } else {
            var x = rect.minX
            while x <= rect.maxX + spacing {
                let j = CGFloat(hash(seed &+ k) - 0.5) * 0.8
                pts.append(CGPoint(x: x + j, y: k % 2 == 0 ? rect.minY - 0.5 : rect.maxY + 0.5))
                x += spacing; k += 1
            }
        }
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight); ctx.setLineJoin(.round)
        ctx.addLines(between: pts); ctx.strokePath()
        ctx.restoreGState()
    }

    /// Paper grain: fibres and specks over a surface, from a tile made once per version (light or dark).
    private static var grainTiles: [Bool: CGImage] = [:]
    static func grainTile() -> CGImage? {
        let light = Theme.isLight
        if grainTiles[light] == nil { grainTiles[light] = makeGrain(light: light) }
        return grainTiles[light]
    }
    static func grain(_ ctx: CGContext, _ rect: CGRect, strength: CGFloat = 1) {
        guard let tile = grainTile() else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setAlpha(strength)
        ctx.draw(tile, in: CGRect(x: 0, y: 0, width: CGFloat(tile.width) / 2, height: CGFloat(tile.height) / 2), byTiling: true)
        ctx.restoreGState()
    }
    private static func makeGrain(light: Bool) -> CGImage? {
        let size = 384
        guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let speck = light ? CGColor(red: 0.30, green: 0.24, blue: 0.16, alpha: 1) : CGColor(red: 0.95, green: 0.92, blue: 0.85, alpha: 1)
        for k in 0..<5_200 { // tooth of the paper
            let x = hash(k * 2) * Double(size), y = hash(k * 2 + 1) * Double(size), a = 0.035 + hash(k * 5) * (light ? 0.06 : 0.05)
            c.setFillColor(speck.copy(alpha: CGFloat(a))!)
            let d = 1 + hash(k * 7) * 1.6
            c.fillEllipse(in: CGRect(x: x, y: y, width: d, height: d))
        }
        c.setLineCap(.round)
        for k in 0..<70 { // fibres
            let x = hash(9_000 + k) * Double(size), y = hash(9_500 + k) * Double(size)
            let a = hash(9_900 + k) * .pi, l = 6 + hash(9_700 + k) * 16
            c.setStrokeColor(speck.copy(alpha: light ? 0.07 : 0.06)!); c.setLineWidth(0.8)
            c.move(to: CGPoint(x: x, y: y))
            c.addQuadCurve(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l),
                           control: CGPoint(x: x + cos(a + 0.5) * l / 2, y: y + sin(a + 0.5) * l / 2))
            c.strokePath()
        }
        return c.makeImage()
    }

    /// A graduated scale, ticked by hand (meters, faders): ticks every `minor`, labelled every `major`.
    static func scale(_ ctx: CGContext, x: CGFloat, marks: [(y: CGFloat, label: String?, major: Bool)], left: Bool, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.textDim]
        for m in marks {
            let w: CGFloat = m.major ? 5 : 2.5
            rule(ctx, CGPoint(x: x, y: m.y), CGPoint(x: left ? x - w : x + w, y: m.y), weight: m.major ? fine : hair, color: Theme.ink(m.major ? 0.6 : 0.35))
            if let l = m.label as NSString? {
                let s = l.size(withAttributes: attrs)
                l.draw(at: CGPoint(x: left ? x - w - 2 - s.width : x + w + 2, y: m.y - s.height / 2), withAttributes: attrs)
            }
        }
    }

    /// A knob sketched in pen: a looped circle, quick ticks around it, the value hatched in the control's ink and a
    /// firm pointer stroke from a blot of ink at the hub.
    static func knob(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, value: CGFloat, from start: CGFloat = 0, color: NSColor, active: Bool) {
        let a0 = CGFloat.pi * 1.25, sweep = CGFloat.pi * 1.5
        func angle(_ v: CGFloat) -> CGFloat { a0 - sweep * v }
        let s = seed(c)
        ctx.saveGState()
        for i in stride(from: 0, through: 10, by: 2) { // fewer, quicker ticks than a printed dial
            let a = angle(CGFloat(i) / 10), long = i == 0 || i == 10
            let p0 = CGPoint(x: c.x + cos(a) * (r - (long ? 3 : 1.8)), y: c.y + sin(a) * (r - (long ? 3 : 1.8)))
            let p1 = CGPoint(x: c.x + cos(a) * (r + 0.5), y: c.y + sin(a) * (r + 0.5))
            rule(ctx, p0, p1, weight: long ? fine : hair, color: Theme.ink(long ? 0.6 : 0.38), seed: s &+ i)
        }
        let inner = r - 4.5
        let (lo, hi) = (min(start, value), max(start, value))
        if hi - lo > 0.002 { // the value: a hatched sweep inside the rim
            let wedge = CGMutablePath()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: inner + 1, startAngle: angle(lo), endAngle: angle(hi), clockwise: true)
            wedge.closeSubpath()
            ctx.saveGState(); ctx.addPath(wedge); ctx.clip()
            hatch(ctx, CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), spacing: 2.4, color: color.withAlphaComponent(active ? 0.9 : 0.65), weight: 0.7, seed: s)
            ctx.restoreGState()
        }
        loop(ctx, CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner), weight: active ? medium : fine,
             color: Theme.ink(active ? 0.95 : 0.7), seed: s)
        let tip = CGPoint(x: c.x + cos(angle(value)) * (inner + 1.5), y: c.y + sin(angle(value)) * (inner + 1.5))
        pen(ctx, handPoints(c, tip, seed: s &+ 3, wobble: 0.4), weight: heavy * 0.8, color: Theme.text, seed: s)
        ctx.setFillColor(Theme.text.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 1.8, y: c.y - 1.6, width: 3.6, height: 3.3))
        ctx.restoreGState()
    }

    /// A meter shaded in: a sketched column, the level hatched with the pen, cross-hatched red above -3 dB, and a short
    /// firm stroke for the peak. Positions 0…1.
    static func meter(_ ctx: CGContext, _ rect: CGRect, level: CGFloat, peak: CGFloat, clipped: Bool) {
        let vertical = rect.height > rect.width
        let s = seed(rect.origin)
        ctx.saveGState()
        let lit = vertical ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * level)
                           : CGRect(x: rect.minX, y: rect.minY, width: rect.width * level, height: rect.height)
        let hot: CGFloat = 0.9 // about -3 dB on the shared meter law
        let cool = vertical ? CGRect(x: lit.minX, y: lit.minY, width: lit.width, height: min(lit.height, rect.height * hot))
                            : CGRect(x: lit.minX, y: lit.minY, width: min(lit.width, rect.width * hot), height: lit.height)
        hatch(ctx, cool, spacing: 1.9, color: Theme.ink(0.8), weight: 0.75, seed: s) // shaded in with the pen
        if level > hot {
            let over = vertical ? CGRect(x: rect.minX, y: rect.minY + rect.height * hot, width: rect.width, height: rect.height * (level - hot))
                                : CGRect(x: rect.minX + rect.width * hot, y: rect.minY, width: rect.width * (level - hot), height: rect.height)
            hatch(ctx, over, spacing: 1.5, color: vermilion, weight: 0.9, cross: true, seed: s &+ 1)
        }
        box(ctx, rect, weight: hair, color: Theme.ink(0.55), seed: s, overshoot: 1.2)
        if peak > 0.01 {
            let a = vertical ? CGPoint(x: rect.minX - 1.5, y: rect.minY + rect.height * peak) : CGPoint(x: rect.minX + rect.width * peak, y: rect.minY - 1.5)
            let b = vertical ? CGPoint(x: rect.maxX + 1.5, y: a.y) : CGPoint(x: a.x, y: rect.maxY + 1.5)
            rule(ctx, a, b, weight: medium, color: clipped ? vermilion : Theme.text, seed: s &+ 9)
        }
        ctx.restoreGState()
    }

    // MARK: Hardware, sketched (plug-ins)

    /// A piece of studio hardware sketched in pen (y up): the front panel as a box, its top and right side receding in
    /// oblique projection, the side hatched in shade, rack ears with screws. Returns the front panel, where the
    /// controls go. `seed` keeps each unit's own hand; bypassed units are crossed through with hatching.
    @discardableResult
    static func hardware(_ ctx: CGContext, _ rect: CGRect, accent: NSColor, dimmed: Bool, seed s: Int) -> CGRect {
        let d: CGFloat = 6 // depth of the receding faces
        let front = CGRect(x: rect.minX + 1.5, y: rect.minY + 1.5, width: rect.width - 3 - d, height: rect.height - 3 - d)
        ctx.saveGState()
        // The panel itself: paper, a little brighter than the page, with a wash of the track's ink.
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fill(front)
        wash(ctx, front.insetBy(dx: 2, dy: 2), color: accent, alpha: dimmed ? 0.025 : 0.06, seed: s)
        // Top and side faces.
        let tl = CGPoint(x: front.minX, y: front.maxY), tr = CGPoint(x: front.maxX, y: front.maxY), br = CGPoint(x: front.maxX, y: front.minY)
        let top = CGMutablePath()
        top.addLines(between: [tl, CGPoint(x: tl.x + d, y: tl.y + d), CGPoint(x: tr.x + d, y: tr.y + d), tr]); top.closeSubpath()
        let side = CGMutablePath()
        side.addLines(between: [tr, CGPoint(x: tr.x + d, y: tr.y + d), CGPoint(x: br.x + d, y: br.y + d), br]); side.closeSubpath()
        ctx.addPath(top); ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillPath()
        ctx.addPath(side); ctx.setFillColor(Theme.panel.cgColor); ctx.fillPath()
        ctx.saveGState(); ctx.addPath(side); ctx.clip()
        hatch(ctx, side.boundingBox, spacing: 2.6, color: Theme.ink(0.35), weight: 0.6, seed: s &+ 2)
        ctx.restoreGState()
        for (a, b) in [(tl, CGPoint(x: tl.x + d, y: tl.y + d)), (CGPoint(x: tl.x + d, y: tl.y + d), CGPoint(x: tr.x + d, y: tr.y + d)),
                       (tr, CGPoint(x: tr.x + d, y: tr.y + d)), (CGPoint(x: tr.x + d, y: tr.y + d), CGPoint(x: br.x + d, y: br.y + d)),
                       (br, CGPoint(x: br.x + d, y: br.y + d))] {
            rule(ctx, a, b, weight: hair, color: Theme.ink(0.6), seed: s &+ Int(a.x + b.y))
        }
        box(ctx, front, weight: medium, color: Theme.ink(dimmed ? 0.55 : 0.9), seed: s, overshoot: 3)
        // Rack ears: a short ruled strip down each end with two screws (a circle and a slot).
        for (k, x) in [front.minX + 9, front.maxX - 9].enumerated() {
            rule(ctx, CGPoint(x: x, y: front.minY + 3), CGPoint(x: x, y: front.maxY - 3), weight: hair, color: Theme.ink(0.3), seed: s &+ 20 &+ k)
            for (m, y) in [front.maxY - 10, front.minY + 10].enumerated() {
                let c = CGPoint(x: (k == 0 ? front.minX : front.maxX) + (k == 0 ? 4.5 : -4.5), y: y)
                loop(ctx, CGRect(x: c.x - 2.4, y: c.y - 2.4, width: 4.8, height: 4.8), weight: 0.7, color: Theme.ink(0.6), seed: s &+ 30 &+ k * 2 &+ m)
                let ang = hash(s &+ 40 &+ k * 2 &+ m) * .pi
                rule(ctx, CGPoint(x: c.x - CGFloat(cos(ang)) * 1.8, y: c.y - CGFloat(sin(ang)) * 1.8),
                     CGPoint(x: c.x + CGFloat(cos(ang)) * 1.8, y: c.y + CGFloat(sin(ang)) * 1.8), weight: 0.6, color: Theme.ink(0.6), seed: s &+ 50 &+ k)
            }
        }
        // The track's ink as a stripe along the bottom edge, drawn with a broad pen.
        pen(ctx, handPoints(CGPoint(x: front.minX + 14, y: front.minY + 3), CGPoint(x: front.maxX - 14, y: front.minY + 3), seed: s &+ 60, wobble: 0.5),
            weight: 2.6, color: accent.withAlphaComponent(dimmed ? 0.35 : 0.85), seed: s &+ 60)
        if dimmed { hatch(ctx, front.insetBy(dx: 2, dy: 2), spacing: 6, color: Theme.ink(0.14), weight: 0.7, cross: true, seed: s &+ 70) }
        ctx.restoreGState()
        return front
    }

    /// A screen window on sketched hardware: a recessed box with its bezel shaded by hatching.
    static func screen(_ ctx: CGContext, _ r: CGRect, seed s: Int) {
        ctx.saveGState()
        let bezel = r.insetBy(dx: -3, dy: -3)
        let ring = CGMutablePath(); ring.addRect(bezel); ring.addRect(r)
        ctx.addPath(ring); ctx.clip(using: .evenOdd)
        hatch(ctx, bezel, spacing: 2.2, color: Theme.ink(0.3), weight: 0.55, seed: s)
        ctx.restoreGState()
        box(ctx, bezel, weight: fine, color: Theme.ink(0.75), seed: s &+ 1, overshoot: 2)
        box(ctx, r, weight: hair, color: Theme.ink(0.6), seed: s &+ 2, overshoot: 1)
    }

    /// A check box drawn by hand: a small sketched square, and when on, a quick tick that runs out of it.
    static func checkbox(_ ctx: CGContext, _ r: CGRect, on: Bool, enabled: Bool = true, flipped: Bool = false) {
        let s = seed(r.origin)
        box(ctx, r, weight: fine, color: Theme.ink(enabled ? 0.8 : 0.35), seed: s, overshoot: 1.5)
        guard on else { return }
        let y = { (f: CGFloat) in flipped ? r.minY + r.height * (1 - f) : r.minY + r.height * f }
        let a = CGPoint(x: r.minX + r.width * 0.15, y: y(0.5)), m = CGPoint(x: r.minX + r.width * 0.42, y: y(0.18)),
            b = CGPoint(x: r.maxX + r.width * 0.25, y: y(1.15))
        pen(ctx, handPoints(a, m, seed: s &+ 1, wobble: 0.3) + handPoints(m, b, seed: s &+ 2, wobble: 0.5), weight: 1.8,
            color: enabled ? Theme.text : Theme.textFaint, seed: s)
    }
}
