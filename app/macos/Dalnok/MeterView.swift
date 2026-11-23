// Stereo peak meter with ballistics (instant attack, 24 dB/s fall) and a
// 1.5 s peak hold. Scale: -60 … +6 dBFS; red at or above 0 dBFS.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class MeterView: NSView {
    private(set) var levelDb: (Float, Float) = (-120, -120)
    private var holdDb: (Float, Float) = (-120, -120)
    private var holdTime: (Double, Double) = (0, 0)
    private(set) var clipped = false
    private var last = CACurrentMediaTime()
    var vertical = false
    /// Atelier's master in the control bar (audit B4): an engraved arc with a needle instead of two columns.
    var needle = false { didSet { if needle != oldValue { needsDisplay = true } } }

    static let floorDb: Float = -60, ceilDb: Float = 6

    /// Feed linear peaks since the last frame.
    func push(_ l: Float, _ r: Float) {
        let now = CACurrentMediaTime()
        let dt = Float(now - last)
        last = now
        func db(_ x: Float) -> Float { x > 0 ? 20 * log10(x) : -120 }
        func step(_ cur: Float, _ peak: Float) -> Float { max(peak, cur - 24 * dt) }
        let before = (levelDb, holdDb, clipped)
        levelDb = (step(levelDb.0, db(l)), step(levelDb.1, db(r)))
        if levelDb.0 >= holdDb.0 || now - holdTime.0 > 1.5 { holdDb.0 = levelDb.0; holdTime.0 = now }
        if levelDb.1 >= holdDb.1 || now - holdTime.1 > 1.5 { holdDb.1 = levelDb.1; holdTime.1 = now }
        if l >= 1 || r >= 1 { clipped = true }
        // Silence and a settled meter draw nothing new (the review: 60 redraws a second of an unchanged meter).
        func shown(_ d: Float) -> Float { max(Self.floorDb - 1, d) }
        if shown(before.0.0) != shown(levelDb.0) || shown(before.0.1) != shown(levelDb.1) || shown(before.1.0) != shown(holdDb.0)
            || shown(before.1.1) != shown(holdDb.1) || before.2 != clipped { needsDisplay = true }
    }

    func resetClip() { clipped = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) { resetClip() }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - Self.floorDb) / (Self.ceilDb - Self.floorDb))))
    }

    private func color(_ db: Float) -> NSColor {
        Self.ramp(db)
    }
    /// Each look's meter colours, quiet to loud (the audit: one ramp per look, its own): Graphite phosphor teal to
    /// amber to coral; Warm Analog LED green, amber, red; Prism along the spectrum, cyan through violet to pink;
    /// Atelier its inks.
    static func ramp(_ db: Float) -> NSColor {
        let (low, mid, hot, over): (UInt32, UInt32, UInt32, UInt32) = switch Theme.activeStyle {
        case .graphite: (0x4FD1B5, 0x8FD9A0, 0xF2B35A, 0xF0645A)
        case .warmAnalog: (0x7BD86B, 0xC8D45A, 0xFFB347, 0xF0523C)
        case .prism: Theme.isLight ? (0x2BA8D9, 0x6F6CE0, 0xD9489C, 0xE0384F) : (0x6FE3FF, 0xA99BFF, 0xFF7AC6, 0xFF5470)
        case .atelier: (0x5FB39B, 0xB9C46A, 0xE3A857, 0xE0574F)
        }
        return Theme.hex(db >= 0 ? over : db >= -6 ? hot : db >= -18 ? mid : low)
    }

    /// An arc indicator as on an engraved instrument: a graduated arc (−60 to +6 dB, the louder channel), a lozenge
    /// needle from a pivot at the foot, the held peak as a gold tick on the arc, and the clip as a filled stop at +6.
    private func drawNeedle(_ ctx: CGContext) {
        let pivot = CGPoint(x: bounds.midX, y: bounds.minY + 3)
        let r = min(bounds.width / 2 - 6, bounds.height - 8)
        func angle(_ db: Float) -> CGFloat { (140 - 100 * fraction(db)) * .pi / 180 }
        func at(_ a: CGFloat, _ rr: CGFloat) -> CGPoint { CGPoint(x: pivot.x + cos(a) * rr, y: pivot.y + sin(a) * rr) }
        let arc = CGMutablePath()
        arc.addArc(center: pivot, radius: r, startAngle: angle(Self.floorDb), endAngle: angle(Self.ceilDb), clockwise: true)
        ctx.addPath(arc); ctx.setStrokeColor(Theme.ink(0.7).cgColor); ctx.setLineWidth(Atelier.fine); ctx.strokePath()
        // The loud end (0 to +6 dB) doubled with a hatched band, as a printed scale marks its red zone.
        let hot = CGMutablePath()
        hot.addArc(center: pivot, radius: r - 2, startAngle: angle(0), endAngle: angle(Self.ceilDb), clockwise: true)
        ctx.addPath(hot); ctx.setStrokeColor(Theme.ink(0.55).cgColor); ctx.setLineWidth(2.5); ctx.strokePath()
        for db: Float in [-60, -40, -30, -20, -12, -6, -3, 0, 3, 6] {
            let major = [-40, -20, -6, 0].contains(db)
            Atelier.rule(ctx, at(angle(db), r), at(angle(db), r + (major ? 4.5 : 2.5)), weight: Atelier.hair, color: Theme.ink(0.75))
        }
        for (db, label) in [(Float(-20), "20"), (0, "0")] {
            let p = at(angle(db), r - 10) // inside the arc, clear of the bar's edge
            Atelier.note(ctx, label, at: CGPoint(x: p.x, y: p.y - 4), size: 7.5, color: Theme.textDim, flipped: false, align: .center, roman: true)
        }
        let hold = max(holdDb.0, holdDb.1)
        if hold > Self.floorDb { Atelier.rule(ctx, at(angle(hold), r - 4), at(angle(hold), r + 1), weight: Atelier.medium, color: Atelier.gold) }
        if clipped { ctx.setFillColor(Atelier.vermilion.cgColor); let c = at(angle(Self.ceilDb), r); ctx.fillEllipse(in: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)) }
        // The needle: a slim lozenge from the pivot, its counterweight a small turned boss.
        let a = angle(max(levelDb.0, levelDb.1)), tip = at(a, r - 1), side = CGPoint(x: -sin(a) * 1.3, y: cos(a) * 1.3)
        let mid = at(a, r * 0.18)
        let lozenge = CGMutablePath()
        lozenge.addLines(between: [pivot, CGPoint(x: mid.x + side.x, y: mid.y + side.y), tip, CGPoint(x: mid.x - side.x, y: mid.y - side.y)]); lozenge.closeSubpath()
        ctx.addPath(lozenge); ctx.setFillColor(Theme.text.cgColor); ctx.fillPath()
        let boss = CGRect(x: pivot.x - 3, y: pivot.y - 3, width: 6, height: 6)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: boss)
        Atelier.loop(ctx, boss, weight: Atelier.fine, color: Theme.text)
    }

    /// Warm Analog: a ladder of LED segments (lit up to the level, peak segment held, unlit segments dim).
    private func drawLadder(_ ctx: CGContext) {
        ctx.setFillColor(NSColor(white: 0.04, alpha: 1).cgColor)
        ctx.fill(bounds)
        let gap: CGFloat = 1, pitch: CGFloat = vertical ? 3.5 : 4
        let length = vertical ? bounds.height : bounds.width
        let count = max(4, Int(length / pitch))
        let bars = [(levelDb.0, holdDb.0), (levelDb.1, holdDb.1)]
        for (i, (lv, hold)) in bars.enumerated() {
            let level = fraction(lv), peak = fraction(hold)
            for k in 0..<count {
                let at = (CGFloat(k) + 0.5) / CGFloat(count)
                let db = Self.floorDb + Float(at) * (Self.ceilDb - Self.floorDb) // segment position on the dB scale
                let lit = at <= level || (abs(at - peak) < 0.5 / CGFloat(count) && hold > -60)
                let base = clipped && k == count - 1 ? Theme.hex(0xE0574F) : color(db)
                ctx.setFillColor((lit ? base : base.withAlphaComponent(0.13)).cgColor)
                let r: CGRect
                if vertical {
                    let w = (bounds.width - gap) / 2
                    r = CGRect(x: CGFloat(i) * (w + gap), y: CGFloat(k) * pitch, width: w, height: pitch - 1)
                } else {
                    let h = (bounds.height - gap) / 2
                    r = CGRect(x: CGFloat(k) * pitch, y: CGFloat(i) * (h + gap), width: pitch - 1, height: h)
                }
                ctx.fill(r)
                if lit { // a little bloom on lit segments
                    ctx.setFillColor(base.withAlphaComponent(0.25).cgColor)
                    ctx.fill(r.insetBy(dx: -0.5, dy: -0.5))
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if Theme.look.ledLadderMeters { return drawLadder(ctx) }
        if needle { return drawNeedle(ctx) }
        if Theme.look.meters == .lightPipe || Theme.look.meters == .graduated {
            // Two pipes (Prism) or two drawn columns (Atelier), side by side or stacked.
            let gap: CGFloat = vertical ? 2 : 1.5
            for (i, (lv, hold)) in [(levelDb.0, holdDb.0), (levelDb.1, holdDb.1)].enumerated() {
                let r = vertical ? CGRect(x: CGFloat(i) * ((bounds.width + gap) / 2), y: 0, width: (bounds.width - gap) / 2, height: bounds.height)
                                 : CGRect(x: 0, y: CGFloat(i) * ((bounds.height + gap) / 2), width: bounds.width, height: (bounds.height - gap) / 2)
                let peak = hold > -60 ? fraction(hold) : 0
                if Theme.look.meters == .lightPipe { Prism.lightPipe(ctx, r, level: fraction(lv), peak: peak, clipped: clipped) }
                else { Atelier.meter(ctx, r, level: fraction(lv), peak: peak, clipped: clipped) }
            }
            // 0 dBFS mark.
            ctx.setFillColor(Theme.ink(0.5).cgColor)
            if vertical { ctx.fill(CGRect(x: 0, y: bounds.height * fraction(0), width: bounds.width, height: 0.5)) }
            else { ctx.fill(CGRect(x: bounds.width * fraction(0), y: 0, width: 0.5, height: bounds.height)) }
            return
        }
        ctx.setFillColor(Theme.window.cgColor)
        ctx.fill(bounds)
        let gap: CGFloat = 1
        let bars = [(levelDb.0, holdDb.0), (levelDb.1, holdDb.1)]
        for (i, (lv, hold)) in bars.enumerated() {
            let r: CGRect
            if vertical {
                let w = (bounds.width - gap) / 2
                r = CGRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
                let h = r.height * fraction(lv)
                ctx.setFillColor(color(lv).cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: h))
                ctx.setFillColor(color(hold).withAlphaComponent(0.9).cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.minY + r.height * fraction(hold) - 2, width: r.width, height: 2))
            } else {
                let h = (bounds.height - gap) / 2
                r = CGRect(x: 0, y: CGFloat(i) * (h + gap), width: bounds.width, height: h)
                ctx.setFillColor(color(lv).cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width * fraction(lv), height: r.height))
                ctx.setFillColor(color(hold).withAlphaComponent(0.9).cgColor)
                ctx.fill(CGRect(x: r.minX + r.width * fraction(hold) - 1, y: r.minY, width: 1, height: r.height))
            }
        }
        // 0 dBFS tick
        ctx.setFillColor(Theme.text.withAlphaComponent(0.35).cgColor)
        if vertical { ctx.fill(CGRect(x: 0, y: bounds.height * fraction(0), width: bounds.width, height: 0.5)) }
        else { ctx.fill(CGRect(x: bounds.width * fraction(0), y: 0, width: 0.5, height: bounds.height)) }
        if clipped {
            ctx.setFillColor(Theme.hex(0xE0574F).cgColor)
            if vertical { ctx.fill(CGRect(x: 0, y: bounds.height - 3, width: bounds.width, height: 3)) }
            else { ctx.fill(CGRect(x: bounds.width - 3, y: 0, width: 3, height: bounds.height)) }
        }
    }
}
