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

    static let floorDb: Float = -60, ceilDb: Float = 6

    /// Feed linear peaks since the last frame.
    func push(_ l: Float, _ r: Float) {
        let now = CACurrentMediaTime()
        let dt = Float(now - last)
        last = now
        func db(_ x: Float) -> Float { x > 0 ? 20 * log10(x) : -120 }
        func step(_ cur: Float, _ peak: Float) -> Float { max(peak, cur - 24 * dt) }
        levelDb = (step(levelDb.0, db(l)), step(levelDb.1, db(r)))
        if levelDb.0 >= holdDb.0 || now - holdTime.0 > 1.5 { holdDb.0 = levelDb.0; holdTime.0 = now }
        if levelDb.1 >= holdDb.1 || now - holdTime.1 > 1.5 { holdDb.1 = levelDb.1; holdTime.1 = now }
        if l >= 1 || r >= 1 { clipped = true }
        needsDisplay = true
    }

    func resetClip() { clipped = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) { resetClip() }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat(max(0, min(1, (db - Self.floorDb) / (Self.ceilDb - Self.floorDb))))
    }

    private func color(_ db: Float) -> NSColor {
        db >= 0 ? Theme.hex(0xE0574F) : db >= -6 ? Theme.hex(0xE3A857) : db >= -18 ? Theme.hex(0xB9C46A) : Theme.hex(0x5FB39B)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
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
                ctx.fill(CGRect(x: r.minX, y: r.minY + r.height * fraction(hold) - 1, width: r.width, height: 1))
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
