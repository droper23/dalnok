// Each Guitar Studio module's main screen: a picture of what the module is doing, drawn in orange and blue light from
// its own settings and lit by its measured level. With no signal the picture rests; nothing pretends to be audio.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
enum SpaceScreen {
    struct State {
        var module: String
        /// Knob positions (normalized), by knob index.
        var knobs: [Double]
        /// The module's measured output level, 0 (silent, −60 dB or less) to 1 (0 dBFS); and its input's.
        var level: CGFloat
        var input: CGFloat
        var on: Bool
        var time: Double
        func k(_ i: Int, _ fallback: Double = 0.5) -> CGFloat { CGFloat(i < knobs.count ? knobs[i] : fallback) }
    }

    static func draw(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(s.on ? 1 : 0.35)
        // A faint grid, as on a scope.
        ctx.setStrokeColor(Space.hex(0xffffff, 0.035).cgColor); ctx.setLineWidth(1)
        var x = r.minX + 12
        while x < r.maxX { ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY)); x += 18 }
        var y = r.midY.truncatingRemainder(dividingBy: 18)
        while y < r.maxY { if y > r.minY { ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y)) }; y += 18 }
        ctx.strokePath()
        switch s.module {
        case "Noise Gate": gate(ctx, r, s)
        case "Compressor": compressor(ctx, r, s)
        case "Boost", "Overdrive", "Distortion", "Fuzz": drive(ctx, r, s)
        case "Amp Clean", "Amp Crunch", "Amp Lead": amp(ctx, r, s)
        case "Cabinet": cabinet(ctx, r, s)
        case "EQ": eq(ctx, r, s)
        case "Wah": wah(ctx, r, s)
        case "Chorus", "Flanger", "Phaser", "Vibrato": modulation(ctx, r, s)
        case "Tremolo": tremolo(ctx, r, s)
        case "Delay": delay(ctx, r, s)
        case "Reverb": reverb(ctx, r, s)
        case "Spring": spring(ctx, r, s)
        default: break
        }
    }

    /// A wave across the screen: `shape` maps a phase (radians) to −1…1.
    private static func wave(_ r: CGRect, amplitude: CGFloat, cycles: CGFloat, phase: CGFloat, yOffset: CGFloat = 0, _ shape: (CGFloat) -> CGFloat) -> CGPath {
        let p = CGMutablePath()
        let n = 120
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let pt = CGPoint(x: r.minX + 10 + t * (r.width - 20), y: r.midY + yOffset - amplitude * shape(t * cycles * 2 * .pi + phase))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
    private static func live(_ s: State) -> CGFloat { s.on ? s.level : 0 }

    private static func gate(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let threshold = s.k(0) // where the gate opens, on the screen's scale
        let open = s.input > threshold * 0.9
        let ty = r.height * 0.42 * (0.15 + 0.85 * threshold)
        for sign in [CGFloat(-1), 1] {
            let line = CGMutablePath(); line.move(to: CGPoint(x: r.minX + 10, y: r.midY + sign * ty)); line.addLine(to: CGPoint(x: r.maxX - 10, y: r.midY + sign * ty))
            ctx.saveGState(); ctx.setLineDash(phase: 0, lengths: [3, 4]); Space.glowStroke(ctx, line, Space.blue.withAlphaComponent(0.6), width: 1, bloom: 0.4); ctx.restoreGState()
        }
        let amp = open ? r.height * 0.42 * live(s) : 0.6
        Space.glowStroke(ctx, wave(r, amplitude: amp, cycles: 5, phase: CGFloat(s.time * 3)) { sin($0) }, open ? Space.orange : Space.blue, width: 1.6)
    }

    private static func compressor(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let c = CGPoint(x: r.midX, y: r.midY), maxR = r.height * 0.42
        let ratio = s.k(1), thr = 1 - s.k(0)
        let ringR = maxR * (0.3 + 0.7 * thr)
        Space.glowStroke(ctx, CGPath(ellipseIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: 2 * ringR, height: 2 * ringR), transform: nil),
                         Space.blue.withAlphaComponent(0.7), width: 1.2, bloom: 0.5)
        // The signal as a sphere: above the ring it is squeezed (flatter as the ratio rises).
        let raw = maxR * (0.12 + 0.88 * live(s))
        let over = max(0, raw - ringR)
        let rr = min(raw, ringR) + over * (1 - ratio * 0.85)
        ctx.saveGState(); ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: 1 + ratio * 0.35 * (over > 0 ? 1 : 0), y: 1)
        Space.glowDot(ctx, .zero, rr * 0.55, Space.orange, intensity: 0.35 + 0.65 * live(s))
        ctx.restoreGState()
    }

    private static func drive(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let drive = s.k(0), fuzz = s.module == "Fuzz", hard = s.module == "Distortion" || fuzz
        let a = r.height * 0.36 * (0.15 + 0.85 * live(s))
        let gain = 1 + drive * (s.module == "Boost" ? 2 : 9)
        let clean = wave(r, amplitude: a, cycles: 2.5, phase: CGFloat(s.time * 2)) { sin($0) }
        ctx.saveGState(); ctx.setLineDash(phase: 0, lengths: [2, 4]); Space.glowStroke(ctx, clean, Space.blue.withAlphaComponent(0.5), width: 1, bloom: 0.3); ctx.restoreGState()
        let driven = wave(r, amplitude: a, cycles: 2.5, phase: CGFloat(s.time * 2)) { p in
            let x = sin(p) * gain
            if fuzz { return x > 0 ? min(1, x) : max(-0.6, x) } // asymmetric, squared off
            return hard ? max(-1, min(1, x)) : tanh(x) / tanh(gain)
        }
        Space.glowStroke(ctx, driven, Space.orange, width: 1.8, bloom: 0.6 + drive)
    }

    private static func amp(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        // A star: the core is the gain, its corona the signal; bass, middle and treble are three blue orbits.
        let c = CGPoint(x: r.midX, y: r.midY), lit = live(s), gain = s.k(0)
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        for k in 0..<24 {
            let ang = CGFloat(k) / 24 * 2 * .pi + CGFloat(s.time * 0.15)
            let len = r.height * (0.16 + 0.22 * gain + 0.18 * lit * (0.6 + 0.4 * sin(CGFloat(k) * 2.3 + CGFloat(s.time * 4))))
            let ray = CGMutablePath(); ray.move(to: CGPoint(x: c.x + cos(ang) * r.height * 0.12, y: c.y + sin(ang) * r.height * 0.12))
            ray.addLine(to: CGPoint(x: c.x + cos(ang) * len, y: c.y + sin(ang) * len))
            ctx.addPath(ray); ctx.setStrokeColor(Space.orange.withAlphaComponent(0.25 + 0.35 * lit).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        }
        ctx.restoreGState()
        Space.glowDot(ctx, c, r.height * (0.07 + 0.05 * gain), Space.amber, intensity: 0.5 + 0.5 * lit)
        for (i, k) in [1, 2, 3].enumerated() {
            let rx = r.width * (0.22 + 0.08 * CGFloat(i)), ry = r.height * (0.16 + 0.05 * CGFloat(i)) * (0.6 + 0.8 * s.k(k))
            let orbit = CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
            Space.glowStroke(ctx, orbit, Space.blue.withAlphaComponent(0.35 + 0.4 * s.k(k)), width: 1, bloom: 0.4)
            let ang = CGFloat(s.time * (0.4 + 0.3 * Double(i))) + CGFloat(i) * 2
            Space.glowDot(ctx, CGPoint(x: c.x + cos(ang) * rx, y: c.y + sin(ang) * ry), 2, Space.ice, intensity: 0.8)
        }
    }

    private static func cabinet(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let size = Int((s.k(0) * 2).rounded()), lit = live(s)
        let n = [1, 2, 4][size]
        let cols = n == 1 ? 1 : 2, rows = n == 4 ? 2 : 1
        let cell = CGSize(width: r.width * 0.5 / CGFloat(cols), height: r.height * 0.84 / CGFloat(rows))
        let rad = min(cell.width, cell.height) * 0.42
        let origin = CGPoint(x: r.midX - cell.width * CGFloat(cols) / 2, y: r.midY - cell.height * CGFloat(rows) / 2)
        var first = CGPoint.zero
        for i in 0..<n {
            let c = CGPoint(x: origin.x + cell.width * (CGFloat(i % cols) + 0.5), y: origin.y + cell.height * (CGFloat(i / cols) + 0.5))
            if i == 0 { first = c }
            for k in 0..<4 {
                let pulse = 1 + 0.06 * lit * sin(CGFloat(s.time * 9) + CGFloat(k))
                let rr = rad * (0.25 + 0.25 * CGFloat(k)) * pulse
                Space.glowStroke(ctx, CGPath(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr), transform: nil),
                                 (k == 0 ? Space.orange : Space.blue).withAlphaComponent(0.35 + 0.4 * lit), width: 1, bloom: 0.4)
            }
        }
        // The mic: across the first cone (Mic), smaller further away (Distance).
        let mic = CGPoint(x: first.x + rad * s.k(1), y: first.y)
        Space.glowDot(ctx, mic, 2 + 3 * (1 - s.k(2)), Space.ice, intensity: 1)
    }

    private static func eq(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        // An approximate response from the six controls: cuts at the ends, shelves, and a bell at Frequency.
        let lowCut = s.k(0, 0), bass = s.k(1) * 2 - 1, mid = s.k(2) * 2 - 1, freq = s.k(3), treble = s.k(4) * 2 - 1, highCut = s.k(5, 1)
        let p = CGMutablePath(), fill = CGMutablePath()
        let n = 120, scale = r.height * 0.32
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            var g = bass / (1 + exp((t - 0.25) * 18)) + treble / (1 + exp(-(t - 0.75) * 18)) + mid * exp(-pow((t - (0.2 + 0.6 * freq)) * 6, 2))
            g -= 1.6 * max(0, (lowCut * 0.35 - t) / 0.12) + 1.6 * max(0, (t - (0.65 + 0.35 * highCut)) / 0.12)
            let pt = CGPoint(x: r.minX + 10 + t * (r.width - 20), y: r.midY - max(-1.4, min(1.2, g)) * scale)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            i == 0 ? fill.move(to: CGPoint(x: pt.x, y: r.maxY)) : ()
            fill.addLine(to: pt)
        }
        fill.addLine(to: CGPoint(x: r.maxX - 10, y: r.maxY)); fill.closeSubpath()
        ctx.saveGState(); ctx.addPath(fill); ctx.clip()
        ctx.drawLinearGradient(Space.gradient([Space.blue.withAlphaComponent(0.25 + 0.2 * live(s)), .clear]), start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
        ctx.restoreGState()
        Space.glowStroke(ctx, p, Space.orange, width: 1.6)
        Space.glowDot(ctx, CGPoint(x: r.minX + 10 + (0.2 + 0.6 * freq) * (r.width - 20), y: r.midY - mid * scale), 2.6, Space.ice)
    }

    private static func wah(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let auto = s.k(1, 0), rate = s.k(2, 0), res = s.k(3)
        let pos = min(1, max(0, s.k(0) + auto * 0.4 * CGFloat(sin(s.time * Double(0.5 + 6 * rate) * 2 * .pi))))
        let p = CGMutablePath(), n = 120
        let centre = 0.15 + 0.7 * pos, width = 0.03 + 0.12 * (1 - res)
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let g = exp(-pow((t - centre) / width, 2))
            let pt = CGPoint(x: r.minX + 10 + t * (r.width - 20), y: r.maxY - 10 - (0.12 + 0.75 * g * (0.4 + 0.6 * max(0.25, live(s)))) * (r.height - 20))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        Space.glowStroke(ctx, p, Space.orange, width: 1.8, bloom: 0.5 + res)
        let marker = CGMutablePath(); let x = r.minX + 10 + centre * (r.width - 20)
        marker.move(to: CGPoint(x: x, y: r.maxY - 8)); marker.addLine(to: CGPoint(x: x, y: r.maxY - 2))
        Space.glowStroke(ctx, marker, Space.ice, width: 2)
    }

    private static func modulation(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let rate = Double(s.k(0)), depth = s.k(1), lit = live(s)
        let speed = 0.3 + 3 * rate, a = r.height * 0.28 * (0.3 + 0.7 * max(0.35, lit))
        let voices = s.module == "Vibrato" ? 1 : s.module == "Phaser" ? 3 : 2
        for v in 0..<voices {
            let shift = CGFloat(v) * 0.9 * depth * CGFloat(sin(s.time * speed * 2 * .pi + Double(v)))
            let path = wave(r, amplitude: a, cycles: s.module == "Flanger" ? 4 : 2.5, phase: CGFloat(s.time * 1.5) + shift) { sin($0) }
            Space.glowStroke(ctx, path, (v == 0 ? Space.orange : Space.blue).withAlphaComponent(v == 0 ? 1 : 0.75), width: v == 0 ? 1.7 : 1.3, bloom: 0.5)
        }
        if s.module == "Vibrato" { // the pitch sway, as a moving dot
            let x = r.midX + CGFloat(sin(s.time * speed * 2 * .pi)) * depth * r.width * 0.3
            Space.glowDot(ctx, CGPoint(x: x, y: r.maxY - 12), 2.5, Space.ice)
        }
    }

    private static func tremolo(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let rate = Double(s.k(0)), depth = s.k(1), shape = s.k(2, 0)
        let bars = 28, w = (r.width - 20) / CGFloat(bars)
        ctx.saveGState(); ctx.setBlendMode(.screen)
        for i in 0..<bars {
            let ph = Double(i) / Double(bars) * 4 * .pi - s.time * (1 + 8 * rate)
            var lfo = CGFloat(0.5 + 0.5 * sin(ph))
            lfo = lfo * (1 - shape) + (lfo > 0.5 ? 1 : 0) * shape
            let g = 1 - depth * lfo
            let h = (r.height - 24) * g * (0.25 + 0.75 * max(0.3, live(s)))
            let bar = CGRect(x: r.minX + 10 + CGFloat(i) * w + 1, y: r.midY - h / 2, width: w - 2, height: h)
            ctx.setFillColor((g > 0.6 ? Space.orange : Space.blue).withAlphaComponent(0.25 + 0.6 * g).cgColor)
            ctx.addPath(Space.rounded(bar, 1)); ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func delay(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let time = s.k(0), feedback = s.k(1), pong = s.k(4, 0), lit = live(s)
        let spacing = (r.width - 40) * (0.08 + 0.22 * time)
        let travel = CGFloat((s.time * 0.5).truncatingRemainder(dividingBy: 1)) * spacing
        var x = r.minX + 20 + travel, k = 0, a: CGFloat = 1
        while x < r.maxX - 12, a > 0.04 {
            let y = r.midY + (k % 2 == 0 ? -1 : 1) * pong * r.height * 0.22 * (k == 0 ? 0 : 1)
            let rad = (4 + 9 * lit) * (0.5 + 0.5 * a)
            Space.glowDot(ctx, CGPoint(x: x, y: y), rad * 0.5, k == 0 ? Space.orange : Space.blue, intensity: a * (0.4 + 0.6 * max(0.3, lit)))
            x += spacing; k += 1; a *= 0.25 + 0.7 * feedback
        }
    }

    private static func reverb(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let decay = s.k(0), size = s.k(1), tone = s.k(3), lit = live(s)
        let c = CGPoint(x: r.midX, y: r.midY)
        var seed: UInt32 = 11
        ctx.saveGState(); ctx.setBlendMode(.screen)
        for i in 0..<140 {
            seed = seed &* 1664525 &+ 1013904223; let ang = CGFloat(seed % 6283) / 1000
            seed = seed &* 1664525 &+ 1013904223; let dist = CGFloat(seed % 1000) / 1000
            let drift = CGFloat((s.time * 0.05 * Double(1 + i % 3)).truncatingRemainder(dividingBy: 1))
            let d = pow((dist + drift * 0.3).truncatingRemainder(dividingBy: 1), 0.7) * r.height * (0.2 + 0.75 * size) * (0.6 + 0.6 * decay)
            let p = CGPoint(x: c.x + cos(ang) * d * 1.5, y: c.y + sin(ang) * d * 0.8)
            let fade = 1 - d / (r.height * 1.1)
            let color = dist < tone ? Space.orange : Space.blue
            ctx.setFillColor(color.withAlphaComponent(max(0, fade) * (0.25 + 0.6 * max(0.25, lit))).cgColor)
            let sz = 1 + 1.6 * (1 - dist)
            ctx.fillEllipse(in: CGRect(x: p.x - sz / 2, y: p.y - sz / 2, width: sz, height: sz))
        }
        ctx.restoreGState()
        Space.glowDot(ctx, c, 3 + 4 * lit, Space.amber, intensity: 0.4 + 0.6 * lit)
    }

    private static func spring(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let drip = s.k(2), lit = live(s)
        for line in 0..<3 {
            let y0 = r.minY + r.height * (0.3 + 0.2 * CGFloat(line))
            let p = CGMutablePath()
            let n = 160
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                let wob = sin(t * 18 - CGFloat(s.time * (6 + 6 * Double(drip))) + CGFloat(line)) * lit * 5 * sin(t * .pi)
                let coil = sin(t * 140) * 3.5
                let pt = CGPoint(x: r.minX + 14 + t * (r.width - 28), y: y0 + coil + wob)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            Space.glowStroke(ctx, p, (line == 1 ? Space.orange : Space.blue).withAlphaComponent(0.85), width: 0.9, bloom: 0.4)
        }
    }
}
