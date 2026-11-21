// Warm Analog drawing kit: hardware surfaces for the analog theme. Controls keep their positions,
// labels and colors in every theme; only their rendering changes (see "06 - Design/Warm Analog.md").
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import QuartzCore

@MainActor
enum Analog {

    // MARK: Surfaces

    /// Renders a texture once into a 2× bitmap and returns it as a pattern color. (An NSImage with a drawing handler
    /// can be redrawn every time the pattern is used, which made Warm Analog windows several seconds slower to draw.)
    static func bakedPattern(width: Int, height: Int, _ draw: @escaping (NSRect) -> Bool) -> NSColor {
        let size = NSSize(width: width, height: height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return Theme.panel }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        _ = draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return NSColor(patternImage: image)
    }

    /// A seamless faceplate texture (fine grain plus faint horizontal brushing), as a pattern color.
    static let faceplate: NSColor = {
        let size = 128
        return bakedPattern(width: size, height: size) { rect in
            Theme.panel.setFill(); rect.fill()
            var seed: UInt32 = 0x1234_5678
            func rnd() -> CGFloat { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return CGFloat(seed % 1000) / 1000 }
            for y in 0..<size { // brushing
                NSColor(white: rnd() > 0.5 ? 1 : 0, alpha: 0.012 + rnd() * 0.012).setFill()
                NSRect(x: 0, y: CGFloat(y), width: CGFloat(size), height: 1).fill()
            }
            for _ in 0..<900 { // grain
                NSColor(white: rnd() > 0.5 ? 1 : 0, alpha: 0.035).setFill()
                NSRect(x: rnd() * CGFloat(size), y: rnd() * CGFloat(size), width: 1, height: 1).fill()
            }
            return true
        }
    }()

    /// Walnut end cheeks (console side panels): vertical grain with darker streaks, as a pattern color.
    static let walnut: NSColor = {
        let w = 16, h = 256
        return bakedPattern(width: w, height: h) { rect in
            Theme.hex(0x4A2E1C).setFill(); rect.fill()
            var seed: UInt32 = 0x9E37_79B9
            func rnd() -> CGFloat { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return CGFloat(seed % 1000) / 1000 }
            for x in 0..<w { // long grain lines that wander slightly
                let dark = rnd() > 0.6
                NSColor(red: dark ? 0.16 : 0.42, green: dark ? 0.09 : 0.26, blue: dark ? 0.05 : 0.15, alpha: 0.25 + rnd() * 0.3).setFill()
                var y: CGFloat = 0
                while y < CGFloat(h) {
                    let len = 20 + rnd() * 60
                    NSRect(x: CGFloat(x) + (rnd() > 0.85 ? 0.5 : 0), y: y, width: 1, height: len).fill()
                    y += len + rnd() * 6
                }
            }
            return true
        }
    }()
    static let cheekWidth: CGFloat = 12

    /// A slotted screw head, as on a rack ear or faceplate corner.
    static func screw(_ ctx: CGContext, at c: CGPoint, radius r: CGFloat = 3.5, angle: CGFloat = 0.6) {
        ctx.saveGState()
        let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.addEllipse(in: rect)
        ctx.clip()
        let colors = [NSColor(white: 0.62, alpha: 1).cgColor, NSColor(white: 0.28, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        }
        ctx.setStrokeColor(NSColor(white: 0.1, alpha: 0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: c.x - cos(angle) * r, y: c.y - sin(angle) * r))
        ctx.addLine(to: CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokeEllipse(in: rect.insetBy(dx: -0.25, dy: -0.25))
    }

    /// Engraved label text: dark letters with a light lower edge, as if cut into the panel.
    static func engraved(_ text: String, font: NSFont, color: NSColor = Theme.textDim) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 1, alpha: 0.10)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 0
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .shadow: shadow])
    }

    // MARK: LEDs

    /// A round LED lens: dark tinted glass when off; bright core, hot-spot and halo when lit.
    static func led(_ ctx: CGContext, in rect: CGRect, color: NSColor, lit: Bool, glow: Bool = true) {
        let c = color.usingColorSpace(.sRGB) ?? color
        ctx.saveGState()
        if lit && glow {
            ctx.setShadow(offset: .zero, blur: rect.width * 1.1, color: c.withAlphaComponent(0.85).cgColor)
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: rect)
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        let center = CGPoint(x: rect.midX - rect.width * 0.12, y: rect.midY - rect.height * 0.15)
        let inner = lit ? NSColor(srgbRed: min(1, c.redComponent * 0.5 + 0.55), green: min(1, c.greenComponent * 0.5 + 0.55),
                                  blue: min(1, c.blueComponent * 0.5 + 0.55), alpha: 1) : c.blended(withFraction: 0.72, of: .black) ?? c
        let outer = lit ? c : (c.blended(withFraction: 0.86, of: .black) ?? c)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [inner.cgColor, outer.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: CGPoint(x: rect.midX, y: rect.midY),
                                   endRadius: rect.width * 0.62, options: [.drawsAfterEndLocation])
        }
        // Specular hot-spot on the lens.
        ctx.setFillColor(NSColor(white: 1, alpha: lit ? 0.55 : 0.18).cgColor)
        ctx.fillEllipse(in: CGRect(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.16,
                                   width: rect.width * 0.32, height: rect.height * 0.24))
        ctx.restoreGState()
        // Bezel.
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.65).cgColor)
        ctx.setLineWidth(0.75)
        ctx.strokeEllipse(in: rect)
    }

    // MARK: Knobs

    /// A knurled metal cap with a white pointer line; `angle` in radians (flipped view: −π/2 is up).
    static func knobCap(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, angle: CGFloat, hover: Bool, pointer: Bool = true) {
        ctx.saveGState()
        // Drop shadow under the cap.
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3, color: NSColor(white: 0, alpha: 0.6).cgColor)
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
        // Knurled skirt: fine radial ridges.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(white: 0.32, alpha: 1).cgColor)
        ctx.setLineWidth(0.6)
        for i in 0..<36 {
            let a = CGFloat(i) / 36 * 2 * .pi
            ctx.move(to: CGPoint(x: c.x + cos(a) * r * 0.78, y: c.y + sin(a) * r * 0.78))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * r * 0.98, y: c.y + sin(a) * r * 0.98))
        }
        ctx.strokePath()
        ctx.restoreGState()
        // Brushed aluminium top.
        let top = CGRect(x: c.x - r * 0.74, y: c.y - r * 0.74, width: r * 1.48, height: r * 1.48)
        ctx.saveGState()
        ctx.addEllipse(in: top)
        ctx.clip()
        let light = NSColor(white: hover ? 0.80 : 0.72, alpha: 1), dark = NSColor(white: hover ? 0.46 : 0.40, alpha: 1)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [light.cgColor, dark.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: top.minX, y: top.minY), end: CGPoint(x: top.maxX, y: top.maxY), options: [])
        }
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor) // concentric machining rings
        ctx.setLineWidth(0.5)
        for k in stride(from: 0.2, through: 0.9, by: 0.18) {
            ctx.strokeEllipse(in: top.insetBy(dx: top.width * CGFloat(k) / 2, dy: top.height * CGFloat(k) / 2))
        }
        ctx.restoreGState()
        guard pointer else { return }
        ctx.setStrokeColor(NSColor(white: 0.08, alpha: 1).cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: c.x + cos(angle) * r * 0.22, y: c.y + sin(angle) * r * 0.22))
        ctx.addLine(to: CGPoint(x: c.x + cos(angle) * r * 0.70, y: c.y + sin(angle) * r * 0.70))
        ctx.strokePath()
    }

    // MARK: Patch cables

    /// A patch cable between two jacks, sagging under its own weight, with plug barrels at both ends.
    static func cablePath(from a: CGPoint, to b: CGPoint, sag: CGFloat = 26) -> CGPath {
        let p = CGMutablePath()
        p.move(to: a)
        let dx = b.x - a.x
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx * 0.25, y: max(a.y, b.y) + sag),
                   control2: CGPoint(x: b.x - dx * 0.25, y: max(a.y, b.y) + sag))
        return p
    }

    static let cableColors: [NSColor] = [Theme.hex(0xC8463B), Theme.hex(0xE0A43A), Theme.hex(0x3F7FBF), Theme.hex(0x4E9A5A), Theme.hex(0x9A5BB0)]

    /// A jack socket (hex nut with a dark hole), as on a patch bay.
    static func jack(_ ctx: CGContext, at c: CGPoint, radius r: CGFloat = 5) {
        let hex = CGMutablePath()
        for i in 0..<6 {
            let a = CGFloat(i) / 6 * 2 * .pi + .pi / 6
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            i == 0 ? hex.move(to: p) : hex.addLine(to: p)
        }
        hex.closeSubpath()
        ctx.addPath(hex)
        ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.addPath(hex)
        ctx.setStrokeColor(NSColor(white: 0.15, alpha: 1).cgColor)
        ctx.setLineWidth(0.6)
        ctx.strokePath()
        ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45, width: r * 0.9, height: r * 0.9))
    }
}

/// Warm Analog master: a needle meter on a backlit paper dial. VU-style ballistics (about 300 ms to settle,
/// a little overshoot) driven by the master level, 0 VU at -18 dBFS; a peak lamp holds for a second after the
/// signal comes within 1 dB of full scale. The LED ladder beside it stays the exact peak meter.
@MainActor
final class NeedleMeter: NSView {
    private var angle: Double = -1, velocity: Double = 0 // -1 = left stop, 1 = right stop
    private var last = CACurrentMediaTime(), peakUntil: Double = 0
    override var isFlipped: Bool { true }

    /// Feed linear peak levels (left, right) about 60 times a second.
    func push(_ l: Float, _ r: Float) {
        let now = CACurrentMediaTime(), dt = min(0.05, now - last)
        last = now
        let level = max(l, r)
        if level > 0.891 { peakUntil = now + 1 } // within 1 dB of full scale
        let vu = level > 0 ? 20 * log10(Double(level)) + 18 : -60 // 0 VU = -18 dBFS
        let target = Self.position(forVU: vu)
        if Motion.reduced { angle += (target - angle) * min(1, dt / 0.3 * 3) }
        else { // mass-spring: settles in about 300 ms with a slight overshoot, like a real movement
            let k = 140.0, damping = 17.0
            velocity += (k * (target - angle) - damping * velocity) * dt
            angle += velocity * dt
        }
        angle = min(1.08, max(-1.05, angle))
        needsDisplay = true
    }
    /// Scale position (-1 … 1) for a VU value: -20 at the left stop, 0 at about two thirds, +3 at the right stop.
    static func position(forVU vu: Double) -> Double {
        let v = min(3.5, max(-21, vu))
        let p = pow(10, v / 20), lo = pow(10, -20.0 / 20), hi = pow(10, 3.0 / 20)
        return (p - lo) / (hi - lo) * 2 - 1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 2, dy: 2)
        // Bezel and backlit paper.
        ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        let face = r.insetBy(dx: 3, dy: 3)
        let paper = NSGradient(starting: NSColor(calibratedRed: 0.98, green: 0.90, blue: 0.70, alpha: 1),
                               ending: NSColor(calibratedRed: 0.86, green: 0.70, blue: 0.45, alpha: 1))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: face, xRadius: 2, yRadius: 2).addClip()
        paper?.draw(in: face, angle: 90)
        // Scale arc around a pivot below the face.
        let pivot = CGPoint(x: face.midX, y: face.maxY + face.height * 0.55)
        let radius = face.height * 1.25, spread = 0.72 // radians each side
        func point(_ pos: Double, _ rad: CGFloat) -> CGPoint {
            let a = Double.pi / 2 + pos * spread
            return CGPoint(x: pivot.x - CGFloat(cos(a)) * rad, y: pivot.y - CGFloat(sin(a)) * rad)
        }
        let ink = NSColor(white: 0.12, alpha: 1), red = NSColor(calibratedRed: 0.75, green: 0.12, blue: 0.08, alpha: 1)
        for vu in [-20.0, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3] {
            let pos = Self.position(forVU: vu)
            ctx.setStrokeColor((vu > 0 ? red : ink).cgColor)
            ctx.setLineWidth(vu == 0 ? 1.4 : 1)
            ctx.move(to: point(pos, radius)); ctx.addLine(to: point(pos, radius - (vu == 0 || vu == -20 || vu == 3 ? 7 : 4))); ctx.strokePath()
        }
        ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(2.5)
        ctx.addArc(center: pivot, radius: radius + 1.5, startAngle: CGFloat(Double.pi * 1.5 + Self.position(forVU: 0) * spread),
                   endAngle: CGFloat(Double.pi * 1.5 + spread), clockwise: false)
        ctx.strokePath()
        let legend: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7, weight: .bold), .foregroundColor: ink]
        ("VU" as NSString).draw(at: CGPoint(x: face.midX - 5, y: face.maxY - 13), withAttributes: legend)
        // Needle.
        ctx.setStrokeColor(NSColor(white: 0.08, alpha: 1).cgColor); ctx.setLineWidth(1.2)
        ctx.move(to: point(angle, radius + 2)); ctx.addLine(to: point(angle, radius * 0.45)); ctx.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        // Peak lamp.
        let lit = CACurrentMediaTime() < peakUntil
        Analog.led(ctx, in: CGRect(x: face.maxX - 9, y: face.minY + 3, width: 6, height: 6), color: Theme.recordOn, lit: lit)
    }
}

/// Tape transport physics shared by the small reels beside the counter and the tape machine window.
/// Units are the small reels' points (hub 5, full pack 15); angles are scale-free, so any drawing size turns at the
/// same, physically right rate. ω = v / r, integrated exactly: a spiral pack of thickness h gives dθ = 2π·dr / h, so
/// each reel turns by 2π·Δr / h as tape moves (the take-up pack grows, the supply pack shrinks; both turn the same
/// way). Driven by tape position, not elapsed time, so dropped frames never desynchronise the reels.
struct ReelModel {
    static let hub: CGFloat = 5, full: CGFloat = 15
    /// Linear tape speed in points per second of audio: 15 ips on a 10.5-inch reel scaled to these 15 pt packs
    /// (a full reel turns about 0.5 rev/s, an empty hub about 1.4 rev/s, like the real machine).
    static let speed: CGFloat = 43
    /// Tape thickness that makes the whole project fit on one reel: π(full² − hub²) = h · speed · length.
    static func thickness(length: Double, speed: CGFloat = speed) -> CGFloat {
        .pi * (full * full - hub * hub) / (speed * CGFloat(max(1, length)))
    }
    /// Seconds of sound in the project (the end of its last clip): exactly that much tape is on the reels. Past it
    /// the reels keep turning at tape speed but no more tape transfers.
    var length: Double = 120
    /// The playhead at the last advance (to turn the reels past the end of the tape).
    private var lastTarget: Double = 0
    /// Tape speed multiplier (1 = 15 ips; 0.5 = 7½ ips; 2 = 30 ips). Faster tape: the same music uses more tape.
    var speedFactor: CGFloat = 1
    /// Seconds of tape on the take-up reel (eases toward the playhead after a jump: a fast wind).
    private(set) var shown: Double = 0
    private(set) var angles: (CGFloat, CGFloat) = (0, 0)
    var fraction: CGFloat { CGFloat(max(0, min(1, shown / max(1, length)))) }
    /// Pack radii (supply, take-up). Tape area is conserved: r² goes linearly from hub² to full² across the reel.
    var radii: (CGFloat, CGFloat) {
        let hub = Self.hub, full = Self.full, f = fraction
        return (sqrt(hub * hub + (full * full - hub * hub) * (1 - f)), sqrt(hub * hub + (full * full - hub * hub) * f))
    }
    /// Moves the tape to `seconds`; jumps of more than a second wind there at `windRate` per second. Returns whether
    /// anything moved.
    mutating func advance(to seconds: Double, dt: Double, reduced: Bool, windRate: Double = 9) -> Bool {
        let playhead = max(0, seconds)
        defer { lastTarget = playhead }
        // Past the end of the sound: the reels spin on, the packs stay as they are.
        let beyond = max(0, playhead - length) - max(0, lastTarget - length)
        var spun = false
        if beyond > 0, beyond < 1, !reduced {
            let r = radii, v = Self.speed * speedFactor * CGFloat(beyond)
            angles = (angles.0 + v / r.0, angles.1 + v / r.1)
            spun = true
        }
        let target = min(playhead, length)
        var next = target
        if abs(target - shown) > 1, !reduced { next = shown + (target - shown) * min(1, dt * windRate) }
        guard abs(next - shown) > 1e-4 else { return spun }
        if reduced { shown = next; return true } // the packs show where you are; the reels don't turn
        let before = radii
        shown = next
        let after = radii
        let h = Self.thickness(length: length, speed: Self.speed * speedFactor)
        angles = (angles.0 + 2 * .pi * (before.0 - after.0) / h, angles.1 + 2 * .pi * (after.1 - before.1) / h)
        return true
    }
}

/// Warm Analog: two tape reels beside the position display. The tape moves with the playhead (each reel turns at
/// the speed its pack radius needs), the packs trade size across the project, and a jump winds fast to the new
/// spot. With Reduce Motion the reels never turn; the packs still show where you are.
@MainActor
final class TapeReels: NSView {
    private var model = ReelModel()
    private var last = CACurrentMediaTime()
    /// Project length in seconds (sets how full each reel is).
    var length: Double { get { model.length } set { model.length = newValue; needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 104, height: 42) }

    var tapeFraction: CGFloat { model.fraction } // for tests
    var reelAngles: (CGFloat, CGFloat) { model.angles } // for tests
    static let hub = ReelModel.hub, full = ReelModel.full, speed = ReelModel.speed
    static func thickness(length: Double) -> CGFloat { ReelModel.thickness(length: length) }
    private var radii: (CGFloat, CGFloat) { model.radii }
    private var angles: (CGFloat, CGFloat) { model.angles }

    func update(seconds: Double) {
        let now = CACurrentMediaTime(), dt = min(0.1, now - last)
        last = now
        if model.advance(to: seconds, dt: dt, reduced: Motion.reduced) { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The same NAB reels as the Tape Machine, scaled to the bar: the tape runs from the bottom of one pack, over
        // a head, to the other.
        let R = min(bounds.height / 2 - 1, bounds.width / 4 - 2), k = R / ReelModel.full
        let (rl, rr) = radii
        let cy = bounds.midY, left = CGPoint(x: R + 1, y: cy), right = CGPoint(x: bounds.width - R - 1, y: cy)
        ctx.setStrokeColor(Theme.hex(0x7A5236).cgColor); ctx.setLineWidth(1.4)
        let head = CGPoint(x: bounds.midX, y: bounds.height - 3)
        ctx.move(to: CGPoint(x: left.x + rl * k * 0.2, y: cy + rl * k)); ctx.addLine(to: head)
        ctx.addLine(to: CGPoint(x: right.x - rr * k * 0.2, y: cy + rr * k)); ctx.strokePath()
        ctx.setFillColor(NSColor(white: 0.62, alpha: 1).cgColor)
        ctx.fill(CGRect(x: head.x - 5, y: head.y - 2, width: 10, height: 3))
        TapeArt.reel(ctx, at: left, radius: R, hub: ReelModel.hub * k, pack: rl * k, angle: angles.0)
        TapeArt.reel(ctx, at: right, radius: R, hub: ReelModel.hub * k, pack: rr * k, angle: angles.1)
    }
}
