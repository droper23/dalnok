// Atelier: drawing primitives for the composer's-workspace theme ("06 - Design/Atelier.md").
// Drawing rules: ink on ivory; hierarchy from line weight and type, not from fills; one vermilion for what must be
// seen (playhead, recording); hatching, crop marks and rules borrowed from technical drawing.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
enum Atelier {
    static var ink: NSColor { Theme.text }
    static var vermilion: NSColor { Theme.accent }
    /// Line weights (points) of the drawing: hairline, fine, medium, heavy.
    static let hair: CGFloat = 0.5, fine: CGFloat = 0.75, medium: CGFloat = 1.25, heavy: CGFloat = 2

    /// A rule from `a` to `b`.
    static func rule(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, weight: CGFloat, color: NSColor = Theme.text, dash: [CGFloat] = []) {
        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight); ctx.setLineCap(.butt)
        if !dash.isEmpty { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        ctx.restoreGState()
    }

    /// Crop (registration) marks just outside a rectangle's corners: Atelier's selection, as a printer marks the trim.
    static func cropMarks(_ ctx: CGContext, _ r: CGRect, length: CGFloat = 7, gap: CGFloat = 3, color: NSColor = Theme.text, weight: CGFloat = 1) {
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

    /// Section hatching (45°), the drafting convention for "not in use": muted, offline, bypassed.
    static func hatch(_ ctx: CGContext, _ rect: CGRect, spacing: CGFloat = 5, color: NSColor = Theme.ink(0.16), weight: CGFloat = 0.6) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(weight)
        var x = rect.minX - rect.height
        while x < rect.maxX { ctx.move(to: CGPoint(x: x, y: rect.maxY)); ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.minY)); x += spacing }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// A graduated scale (meters, faders): ticks every `minor`, labelled every `major`, along a vertical line at `x`.
    static func scale(_ ctx: CGContext, x: CGFloat, marks: [(y: CGFloat, label: String?, major: Bool)], left: Bool, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.textDim]
        for m in marks {
            let w: CGFloat = m.major ? 5 : 2.5
            rule(ctx, CGPoint(x: x, y: m.y), CGPoint(x: left ? x - w : x + w, y: m.y), weight: m.major ? fine : hair, color: Theme.ink(m.major ? 0.55 : 0.3))
            if let l = m.label as NSString? {
                let s = l.size(withAttributes: attrs)
                l.draw(at: CGPoint(x: left ? x - w - 2 - s.width : x + w + 2, y: m.y - s.height / 2), withAttributes: attrs)
            }
        }
    }

    /// A drafted knob: an outline circle with a printed arc of ticks, a filled ink sector for the value and a needle.
    static func knob(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, value: CGFloat, from start: CGFloat = 0, color: NSColor, active: Bool) {
        let a0 = CGFloat.pi * 1.25, sweep = CGFloat.pi * 1.5
        func angle(_ v: CGFloat) -> CGFloat { a0 - sweep * v }
        ctx.saveGState()
        // Printed ticks: 11 around the arc, ends and centre longer.
        for i in 0...10 {
            let a = angle(CGFloat(i) / 10), long = i == 0 || i == 5 || i == 10
            let p0 = CGPoint(x: c.x + cos(a) * (r - (long ? 3.5 : 2)), y: c.y + sin(a) * (r - (long ? 3.5 : 2)))
            let p1 = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            rule(ctx, p0, p1, weight: long ? fine : hair, color: Theme.ink(long ? 0.6 : 0.35))
        }
        let inner = r - 5
        // Value: a pale sector from the origin, in the control's ink.
        let (lo, hi) = (min(start, value), max(start, value))
        if hi - lo > 0.002 {
            ctx.move(to: c)
            ctx.addArc(center: c, radius: inner, startAngle: angle(lo), endAngle: angle(hi), clockwise: true)
            ctx.closePath()
            ctx.setFillColor(color.withAlphaComponent(active ? 0.32 : 0.2).cgColor); ctx.fillPath()
        }
        ctx.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner))
        ctx.setFillColor(Theme.panelRaised.withAlphaComponent(0.55).cgColor); ctx.fillPath()
        ctx.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner))
        ctx.setStrokeColor(Theme.ink(active ? 0.9 : 0.6).cgColor); ctx.setLineWidth(active ? medium : fine); ctx.strokePath()
        // Needle: a fine ink line from the hub to the rim.
        let tip = CGPoint(x: c.x + cos(angle(value)) * inner, y: c.y + sin(angle(value)) * inner)
        rule(ctx, c, tip, weight: medium, color: Theme.text)
        ctx.setFillColor(Theme.text.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
        ctx.restoreGState()
    }

    /// A graduated meter: a fine outline column with an ink fill; ticks every 6 dB, a vermilion over-zone above -3 dB
    /// and a hollow peak marker. Positions 0…1.
    static func meter(_ ctx: CGContext, _ rect: CGRect, level: CGFloat, peak: CGFloat, clipped: Bool) {
        let vertical = rect.height > rect.width
        ctx.saveGState()
        ctx.setFillColor(Theme.well.withAlphaComponent(0.55).cgColor); ctx.fill(rect)
        let lit = vertical ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * level)
                           : CGRect(x: rect.minX, y: rect.minY, width: rect.width * level, height: rect.height)
        ctx.setFillColor(Theme.ink(0.62).cgColor); ctx.fill(lit)
        let hot: CGFloat = 0.9 // about -3 dB on the shared meter law
        if level > hot {
            let over = vertical ? CGRect(x: rect.minX, y: rect.minY + rect.height * hot, width: rect.width, height: rect.height * (level - hot))
                                : CGRect(x: rect.minX + rect.width * hot, y: rect.minY, width: rect.width * (level - hot), height: rect.height)
            ctx.setFillColor(vermilion.cgColor); ctx.fill(over)
        }
        ctx.setStrokeColor(Theme.ink(0.5).cgColor); ctx.setLineWidth(hair); ctx.stroke(rect.insetBy(dx: hair / 2, dy: hair / 2))
        if peak > 0.01 {
            let p = vertical ? CGRect(x: rect.minX - 1, y: rect.minY + rect.height * peak - 0.75, width: rect.width + 2, height: 1.5)
                             : CGRect(x: rect.minX + rect.width * peak - 0.75, y: rect.minY - 1, width: 1.5, height: rect.height + 2)
            ctx.setFillColor((clipped ? vermilion : Theme.text).cgColor); ctx.fill(p)
        }
        ctx.restoreGState()
    }
}
