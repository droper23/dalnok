// Each Guitar Studio module's main screen. Every family has its own display technology (meters, an amber CRT, valve glow,
// a blueprint, an analyser, a scope, a starfield) and every module its own picture, drawn from its settings and lit by
// its measured level, with a readout of its main setting. With no signal the picture rests; nothing pretends to be audio.
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
        /// The plug-in's text for the module's main setting (shown in the screen's corner).
        var readout = ""
        func k(_ i: Int, _ fallback: Double = 0.5) -> CGFloat { CGFloat(i < knobs.count ? knobs[i] : fallback) }
    }

    /// Which knob each module's readout shows, and its label.
    static func readout(for module: String) -> (knob: Int, label: String) {
        switch module {
        case "Noise Gate", "Compressor": (0, "THR")
        case "Boost", "Amp Clean", "Amp Crunch", "Amp Lead": (0, "GAIN")
        case "Overdrive", "Distortion": (0, "DRIVE")
        case "Fuzz": (0, "FUZZ")
        case "Cabinet": (0, "")
        case "EQ": (3, "FREQ")
        case "Wah": (0, "PEDAL")
        case "Chorus", "Flanger", "Phaser", "Tremolo", "Vibrato": (0, "RATE")
        case "Delay": (0, "")
        case "Reverb", "Spring": (0, "DECAY")
        default: (0, "")
        }
    }

    enum Look { case meter, crt, valve, blueprint, analyser, scope, cosmos }
    static func look(_ module: String) -> Look {
        switch module {
        case "Noise Gate", "Compressor", "Tremolo": .meter
        case "Boost", "Overdrive", "Distortion", "Fuzz", "Spring": .crt
        case "Amp Clean", "Amp Crunch", "Amp Lead": .valve
        case "Cabinet": .blueprint
        case "EQ", "Wah", "Flanger": .analyser
        case "Chorus", "Phaser", "Vibrato": .scope
        default: .cosmos
        }
    }
    static let amber = Space.hex(0xffae42), cyan = Space.hex(0x6fd3ff)

    static func draw(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let look = look(s.module)
        background(ctx, r.insetBy(dx: -6, dy: -6), look, s)
        ctx.saveGState()
        ctx.setAlpha(s.on ? 1 : 0.35)
        switch s.module {
        case "Noise Gate": gate(ctx, r, s)
        case "Compressor": compressor(ctx, r, s)
        case "Boost": boost(ctx, r, s)
        case "Overdrive": overdrive(ctx, r, s)
        case "Distortion": distortion(ctx, r, s)
        case "Fuzz": fuzz(ctx, r, s)
        case "Amp Clean": valves(ctx, r, s, count: 1)
        case "Amp Crunch": valves(ctx, r, s, count: 2)
        case "Amp Lead": valves(ctx, r, s, count: 3)
        case "Cabinet": cabinet(ctx, r, s)
        case "EQ": eq(ctx, r, s)
        case "Wah": wah(ctx, r, s)
        case "Chorus": chorus(ctx, r, s)
        case "Flanger": flanger(ctx, r, s)
        case "Phaser": phaser(ctx, r, s)
        case "Tremolo": tremolo(ctx, r, s)
        case "Vibrato": vibrato(ctx, r, s)
        case "Delay": delay(ctx, r, s)
        case "Reverb": reverb(ctx, r, s)
        case "Spring": spring(ctx, r, s)
        default: break
        }
        ctx.restoreGState()
        foreground(ctx, r.insetBy(dx: -6, dy: -6), look)
        if !s.readout.isEmpty {
            let label = readout(for: s.module).label
            let color: NSColor = look == .crt ? amber : look == .blueprint ? cyan : Space.hex(0xffffff, 0.8)
            Space.text((label.isEmpty ? "" : label + " ") + s.readout, CGRect(x: r.minX + 2, y: r.minY, width: r.width - 4, height: 12),
                       font: Space.mono(8.5), color: color.withAlphaComponent(s.on ? 0.85 : 0.35), align: .right)
        }
    }

    // MARK: Display technologies

    private static func background(_ ctx: CGContext, _ r: CGRect, _ look: Look, _ s: State) {
        switch look {
        case .meter:
            ctx.setFillColor(Space.hex(0x050506).cgColor); ctx.fill(r)
        case .crt:
            Space.radial(ctx, CGPoint(x: r.midX, y: r.midY), max(r.width, r.height) * 0.7, [Space.hex(0x2a1606), Space.hex(0x120903), Space.hex(0x050302)], [0, 0.6, 1])
        case .valve:
            Space.radial(ctx, CGPoint(x: r.midX, y: r.maxY), r.width * 0.8, [Space.hex(0x22130a), Space.hex(0x0b0806), Space.hex(0x060505)], [0, 0.6, 1])
        case .blueprint:
            ctx.setFillColor(Space.hex(0x0a1a35).cgColor); ctx.fill(r)
            ctx.setLineWidth(0.5)
            for (step, a) in [(CGFloat(8), CGFloat(0.08)), (40, 0.18)] {
                ctx.setStrokeColor(cyan.withAlphaComponent(a).cgColor)
                var x = r.minX; while x < r.maxX { ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY)); x += step }
                var y = r.minY; while y < r.maxY { ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y)); y += step }
                ctx.strokePath()
            }
        case .analyser:
            ctx.setFillColor(Space.hex(0x060708).cgColor); ctx.fill(r)
            let plot = r.insetBy(dx: 14, dy: 14)
            ctx.setStrokeColor(Space.hex(0xffffff, 0.07).cgColor); ctx.setLineWidth(0.6)
            for f in [0.0, 0.25, 0.5, 0.75, 1.0] as [CGFloat] {
                ctx.move(to: CGPoint(x: plot.minX, y: plot.minY + plot.height * f)); ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.minY + plot.height * f))
            }
            for f in [0.0, 0.33, 0.66, 1.0] as [CGFloat] {
                ctx.move(to: CGPoint(x: plot.minX + plot.width * f, y: plot.minY)); ctx.addLine(to: CGPoint(x: plot.minX + plot.width * f, y: plot.maxY))
            }
            ctx.strokePath()
            for (f, t) in [(0.0, "100"), (0.33, "1k"), (0.66, "5k"), (1.0, "10k")] as [(CGFloat, String)] {
                Space.text(t, CGRect(x: plot.minX + plot.width * f - 14, y: r.maxY - 12, width: 28, height: 10), font: Space.mono(6.5), color: Space.hex(0xffffff, 0.3))
            }
        case .scope:
            Space.radial(ctx, CGPoint(x: r.midX, y: r.midY), max(r.width, r.height) * 0.65, [Space.hex(0x0b1a36), Space.hex(0x060c1a), Space.hex(0x030509)], [0, 0.6, 1])
            ctx.setStrokeColor(Space.blue.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(0.6)
            let c = CGPoint(x: r.midX, y: r.midY)
            for k in 1...3 { let rr = r.height * 0.15 * CGFloat(k); ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)) }
            ctx.move(to: CGPoint(x: r.minX, y: c.y)); ctx.addLine(to: CGPoint(x: r.maxX, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: r.minY)); ctx.addLine(to: CGPoint(x: c.x, y: r.maxY)); ctx.strokePath()
        case .cosmos:
            ctx.setFillColor(Space.hex(0x030304).cgColor); ctx.fill(r)
            var seed: UInt32 = 23
            for _ in 0..<60 {
                seed = seed &* 1664525 &+ 1013904223; let x = r.minX + CGFloat(seed % 1000) / 1000 * r.width
                seed = seed &* 1664525 &+ 1013904223; let y = r.minY + CGFloat(seed % 1000) / 1000 * r.height
                seed = seed &* 1664525 &+ 1013904223; let a = 0.15 + CGFloat(seed % 100) / 200
                ctx.setFillColor(Space.hex(0xffffff, a).cgColor); ctx.fillEllipse(in: CGRect(x: x, y: y, width: 1.1, height: 1.1))
            }
        }
    }
    /// What lies over the picture: scanlines and a curved-glass vignette on the CRT.
    private static func foreground(_ ctx: CGContext, _ r: CGRect, _ look: Look) {
        guard look == .crt else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        var y = r.minY
        while y < r.maxY { ctx.fill(CGRect(x: r.minX, y: y, width: r.width, height: 1)); y += 3 }
        ctx.drawRadialGradient(Space.gradient([.clear, NSColor.black.withAlphaComponent(0.55)], [0.55, 1]), startCenter: CGPoint(x: r.midX, y: r.midY),
                               startRadius: 0, endCenter: CGPoint(x: r.midX, y: r.midY), endRadius: max(r.width, r.height) * 0.62, options: [])
    }

    // MARK: Helpers

    /// A wave across `r`: `shape` maps a phase (radians) to −1…1.
    private static func wave(_ r: CGRect, amplitude: CGFloat, cycles: CGFloat, phase: CGFloat, yOffset: CGFloat = 0, _ shape: (CGFloat) -> CGFloat) -> CGPath {
        let p = CGMutablePath()
        let n = 140
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let pt = CGPoint(x: r.minX + 10 + t * (r.width - 20), y: r.midY + yOffset - amplitude * shape(t * cycles * 2 * .pi + phase))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
    private static func live(_ s: State) -> CGFloat { s.on ? s.level : 0 }
    private static func phosphor(_ ctx: CGContext, _ p: CGPath, width: CGFloat = 1.6, bloom: CGFloat = 1) {
        Space.glowStroke(ctx, p, amber, width: width, bloom: 1.2 * bloom)
    }

    // MARK: Dynamics (meters)

    /// An LED ladder of the input level; segments past the threshold light orange, the gate's state in words.
    private static func gate(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let n = 24, threshold = s.k(0), open = s.input > threshold * 0.9 && s.on
        let bar = CGRect(x: r.minX + 10, y: r.midY - 14, width: r.width - 20, height: 28)
        let w = bar.width / CGFloat(n)
        for i in 0..<n {
            let f = CGFloat(i) / CGFloat(n - 1)
            let lit = f <= s.input && s.input > 0.01
            let seg = CGRect(x: bar.minX + CGFloat(i) * w + 1, y: bar.minY, width: w - 2, height: bar.height)
            let color = f >= threshold ? Space.orange : Space.blue
            ctx.setFillColor((lit ? color : color.withAlphaComponent(0.12)).cgColor)
            ctx.addPath(Space.rounded(seg, 1.5)); ctx.fillPath()
            if lit { Space.glowDot(ctx, CGPoint(x: seg.midX, y: seg.midY), 0.1, color, intensity: 0.5) }
        }
        let tx = bar.minX + bar.width * threshold
        let notch = CGMutablePath()
        notch.move(to: CGPoint(x: tx, y: bar.minY - 4)); notch.addLine(to: CGPoint(x: tx - 4, y: bar.minY - 11)); notch.addLine(to: CGPoint(x: tx + 4, y: bar.minY - 11)); notch.closeSubpath()
        ctx.addPath(notch); ctx.setFillColor(Space.hex(0xffffff, 0.85).cgColor); ctx.fillPath()
        Space.text(open ? "OPEN" : "CLOSED", CGRect(x: r.minX, y: bar.maxY + 10, width: r.width, height: 14), font: Space.font(10, .semibold),
                   color: open ? Space.orange : Space.hex(0xffffff, 0.4), kern: 3)
    }

    /// A VU-style needle showing the gain reduction the settings imply for the level going in.
    private static func compressor(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let c = CGPoint(x: r.midX, y: r.maxY + 10), radius = r.height * 0.95
        let span = CGFloat.pi * 0.28
        func angle(_ f: CGFloat) -> CGFloat { -.pi / 2 - span + 2 * span * f }
        let arc = CGMutablePath(); arc.addArc(center: c, radius: radius, startAngle: angle(0), endAngle: angle(1), clockwise: false)
        ctx.addPath(arc); ctx.setStrokeColor(Space.hex(0xffffff, 0.35).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        let red = CGMutablePath(); red.addArc(center: c, radius: radius, startAngle: angle(0.7), endAngle: angle(1), clockwise: false)
        ctx.addPath(red); ctx.setStrokeColor(Space.orange.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(2.5); ctx.strokePath()
        for k in 0...10 {
            let a = angle(CGFloat(k) / 10), l: CGFloat = k % 5 == 0 ? 9 : 5
            ctx.move(to: CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * (radius - l), y: c.y + sin(a) * (radius - l)))
        }
        ctx.setStrokeColor(Space.hex(0xffffff, 0.45).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        Space.text("GR", CGRect(x: r.minX + 8, y: r.maxY - 16, width: 40, height: 12), font: Space.mono(8), color: Space.hex(0xffffff, 0.5), align: .left)
        // Gain reduction: the part of the input above the threshold, less by the ratio.
        let over = max(0, live(s) - (1 - s.k(0)) * 0.8), gr = min(1, over * (0.3 + 1.6 * s.k(1)))
        let a = angle(1 - gr), needle = CGMutablePath()
        needle.move(to: CGPoint(x: c.x + cos(a) * radius * 0.35, y: c.y + sin(a) * radius * 0.35))
        needle.addLine(to: CGPoint(x: c.x + cos(a) * (radius + 4), y: c.y + sin(a) * (radius + 4)))
        Space.glowStroke(ctx, needle, Space.orange, width: 1.4, bloom: 0.6)
    }

    // MARK: Drives (amber CRT)

    /// Input (dim) and the boosted signal, larger by the gain.
    private static func boost(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let base = r.height * 0.14 * (0.4 + 0.6 * max(0.35, live(s))), gain = 1 + 2.2 * s.k(0)
        ctx.saveGState(); ctx.setLineDash(phase: 0, lengths: [2, 3])
        phosphor(ctx, wave(r, amplitude: base, cycles: 2, phase: CGFloat(s.time * 2)) { sin($0) }, width: 0.8, bloom: 0.3)
        ctx.restoreGState()
        phosphor(ctx, wave(r, amplitude: min(r.height * 0.42, base * gain), cycles: 2, phase: CGFloat(s.time * 2)) { sin($0) }, width: 1.8)
    }
    /// Soft clipping: the tops round over as Drive rises.
    private static func overdrive(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let g = 1 + 7 * s.k(0), a = r.height * 0.36 * (0.35 + 0.65 * max(0.35, live(s)))
        phosphor(ctx, wave(r, amplitude: a, cycles: 3, phase: CGFloat(s.time * 2)) { tanh(sin($0) * g) / tanh(g) }, width: 1.8, bloom: 0.8 + s.k(0))
    }
    /// The transfer curve (input across, output up) with the signal's operating point riding it.
    private static func distortion(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let side = r.height - 16, box = CGRect(x: r.midX - side / 2, y: r.midY - side / 2, width: side, height: side)
        ctx.setStrokeColor(amber.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.6)
        ctx.stroke(box)
        ctx.move(to: CGPoint(x: box.midX, y: box.minY)); ctx.addLine(to: CGPoint(x: box.midX, y: box.maxY))
        ctx.move(to: CGPoint(x: box.minX, y: box.midY)); ctx.addLine(to: CGPoint(x: box.maxX, y: box.midY)); ctx.strokePath()
        let g = 1 + 12 * s.k(0)
        func f(_ x: CGFloat) -> CGFloat { max(-1, min(1, x * g)) * 0.92 }
        let curve = CGMutablePath()
        for i in 0...80 {
            let x = CGFloat(i) / 40 - 1
            let p = CGPoint(x: box.midX + x * side / 2, y: box.midY - f(x) * side / 2)
            i == 0 ? curve.move(to: p) : curve.addLine(to: p)
        }
        phosphor(ctx, curve, width: 1.6)
        let x = CGFloat(sin(s.time * 3)) * max(0.15, live(s))
        Space.glowDot(ctx, CGPoint(x: box.midX + x * side / 2, y: box.midY - f(x) * side / 2), 2.6, amber)
    }
    /// A square, gated, dot-matrix wave: the fuzz's sputter.
    private static func fuzz(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let cols = 44, rows = 15
        let cw = (r.width - 16) / CGFloat(cols), ch = (r.height - 16) / CGFloat(rows)
        let bias = s.k(2) * 0.6, a = 0.35 + 0.65 * max(0.35, live(s))
        for c in 0..<cols {
            let ph = CGFloat(c) / CGFloat(cols) * 4 * .pi + CGFloat(s.time * 2)
            let v = sin(ph) + bias > 0 ? a : -a * (1 - bias)
            let row = Int(((1 - (v + 1) / 2) * CGFloat(rows - 1)).rounded())
            for rr in 0..<rows {
                let on = rr == row || (rr - row) * (rr - (rows / 2)) < 0 && abs(rr - rows / 2) <= abs(row - rows / 2) && false
                let p = CGRect(x: r.minX + 8 + CGFloat(c) * cw + 0.6, y: r.minY + 8 + CGFloat(rr) * ch + 0.6, width: cw - 1.2, height: ch - 1.2)
                ctx.setFillColor((on ? amber : amber.withAlphaComponent(0.07)).cgColor)
                ctx.fill(p)
            }
            // The vertical edges of the square wave.
            if c > 0 {
                let prev = sin(ph - 4 * .pi / CGFloat(cols)) + bias > 0
                if prev != (sin(ph) + bias > 0) {
                    for rr in min(row, rows - 1 - row)...max(row, rows - 1 - row) {
                        ctx.setFillColor(amber.cgColor)
                        ctx.fill(CGRect(x: r.minX + 8 + CGFloat(c) * cw + 0.6, y: r.minY + 8 + CGFloat(rr) * ch + 0.6, width: cw - 1.2, height: ch - 1.2))
                    }
                }
            }
        }
    }

    // MARK: Amps (valves)

    /// Glass valves whose filaments and plates glow with the gain and the signal; the tone stack as three bars.
    private static func valves(_ ctx: CGContext, _ r: CGRect, _ s: State, count: Int) {
        let lit = live(s), gain = s.k(0)
        let w = min(52, max(8, (r.width - 90 - CGFloat(count - 1) * 10) / CGFloat(count))), h = r.height - 10
        let x0 = r.minX + 14
        for i in 0..<count {
            let tube = CGRect(x: x0 + CGFloat(i) * (w + 10), y: r.minY + 6, width: w, height: h)
            let glass = CGMutablePath()
            glass.addRoundedRect(in: tube, cornerWidth: w / 2, cornerHeight: w / 2)
            let heat = 0.35 + 0.4 * gain + 0.35 * lit * CGFloat(0.85 + 0.15 * sin(s.time * 7 + Double(i)))
            ctx.saveGState(); ctx.addPath(glass); ctx.clip(); ctx.setBlendMode(.screen)
            Space.radial(ctx, CGPoint(x: tube.midX, y: tube.midY + h * 0.12), w * 1.1, [Space.orange.withAlphaComponent(0.5 * heat), Space.orange.withAlphaComponent(0.1 * heat), .clear])
            ctx.restoreGState()
            ctx.addPath(glass); ctx.setStrokeColor(Space.hex(0xffffff, 0.22).cgColor); ctx.setLineWidth(1); ctx.strokePath()
            // Plates, grid and filament.
            let plate = CGRect(x: tube.midX - w * 0.26, y: tube.minY + h * 0.28, width: w * 0.52, height: h * 0.42)
            ctx.setStrokeColor(Space.hex(0xbfc5cc, 0.55).cgColor); ctx.setLineWidth(1); ctx.stroke(plate)
            ctx.setStrokeColor(Space.hex(0xbfc5cc, 0.3).cgColor)
            var gy = plate.minY + 3; while gy < plate.maxY { ctx.move(to: CGPoint(x: plate.minX + 3, y: gy)); ctx.addLine(to: CGPoint(x: plate.maxX - 3, y: gy)); gy += 3 }
            ctx.strokePath()
            let fil = CGMutablePath(); fil.move(to: CGPoint(x: tube.midX, y: plate.minY + 2)); fil.addLine(to: CGPoint(x: tube.midX, y: plate.maxY - 2))
            Space.glowStroke(ctx, fil, Space.orange, width: 1.4, bloom: 0.6 + heat)
            ctx.setFillColor(Space.hex(0xbfc5cc, 0.5).cgColor) // pins
            for p in 0..<4 { ctx.fill(CGRect(x: tube.minX + w * (0.25 + 0.17 * CGFloat(p)), y: tube.maxY - 4, width: 1.5, height: 4)) }
        }
        // Bass, middle, treble.
        let bx = r.maxX - 62
        for (i, (k, name)) in [(1, "B"), (2, "M"), (3, "T")].enumerated() {
            let x = bx + CGFloat(i) * 18, top = r.minY + 16, height = r.height - 36
            ctx.setFillColor(Space.blue.withAlphaComponent(0.15).cgColor); ctx.fill(CGRect(x: x, y: top, width: 8, height: height))
            let v = s.k(k)
            ctx.setFillColor(Space.blue.cgColor); ctx.fill(CGRect(x: x, y: top + height * (1 - v), width: 8, height: height * v))
            Space.text(name, CGRect(x: x - 4, y: top + height + 4, width: 16, height: 10), font: Space.mono(7), color: Space.hex(0xffffff, 0.5))
        }
    }

    // MARK: Cabinet (blueprint)

    /// A drawing of the baffle: speaker outlines with centre marks, the mic with a dimension line to the cone's centre.
    private static func cabinet(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let size = Int((s.k(0) * 2).rounded()), n = [1, 2, 4][size]
        let cols = n == 1 ? 1 : 2, rows = n == 4 ? 2 : 1
        let baffleWidth = min(r.width - 24, r.height * 1.5)
        let baffle = CGRect(x: r.midX - baffleWidth / 2, y: r.minY + 6, width: baffleWidth, height: r.height - 12)
        ctx.setStrokeColor(cyan.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(1); ctx.stroke(baffle)
        let cell = CGSize(width: baffle.width / CGFloat(cols), height: baffle.height / CGFloat(rows))
        let rad = min(cell.width, cell.height) * 0.38
        var first = CGPoint.zero
        for i in 0..<n {
            let c = CGPoint(x: baffle.minX + cell.width * (CGFloat(i % cols) + 0.5), y: baffle.minY + cell.height * (CGFloat(i / cols) + 0.5))
            if i == 0 { first = c }
            let pulse = 1 + 0.05 * live(s) * CGFloat(sin(s.time * 10 + Double(i)))
            ctx.setStrokeColor(cyan.withAlphaComponent(0.8).cgColor)
            ctx.strokeEllipse(in: CGRect(x: c.x - rad * pulse, y: c.y - rad * pulse, width: 2 * rad * pulse, height: 2 * rad * pulse))
            ctx.setStrokeColor(cyan.withAlphaComponent(0.35).cgColor)
            ctx.strokeEllipse(in: CGRect(x: c.x - rad * 0.3, y: c.y - rad * 0.3, width: rad * 0.6, height: rad * 0.6))
            ctx.move(to: CGPoint(x: c.x - 4, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 4, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - 4)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 4)); ctx.strokePath()
        }
        let mic = CGPoint(x: first.x + rad * s.k(1), y: first.y + rad * 0.15)
        ctx.setStrokeColor(Space.orange.cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: first.x, y: first.y + rad + 6)); ctx.addLine(to: CGPoint(x: mic.x, y: first.y + rad + 6)); ctx.strokePath()
        Space.glowDot(ctx, mic, 2.5 + 2.5 * (1 - s.k(2)), Space.orange)
    }

    // MARK: Filter (analyser)

    private static func eq(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let plot = r.insetBy(dx: 8, dy: 8)
        let lowCut = s.k(0, 0), bass = s.k(1) * 2 - 1, mid = s.k(2) * 2 - 1, freq = s.k(3), treble = s.k(4) * 2 - 1, highCut = s.k(5, 1)
        let p = CGMutablePath(), fill = CGMutablePath(), n = 120, scale = plot.height * 0.32
        func gain(_ t: CGFloat) -> CGFloat {
            var g = bass / (1 + exp((t - 0.25) * 18)) + treble / (1 + exp(-(t - 0.75) * 18)) + mid * exp(-pow((t - (0.2 + 0.6 * freq)) * 6, 2))
            g -= 1.6 * max(0, (lowCut * 0.35 - t) / 0.12) + 1.6 * max(0, (t - (0.65 + 0.35 * highCut)) / 0.12)
            return max(-1.4, min(1.2, g))
        }
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let pt = CGPoint(x: plot.minX + t * plot.width, y: plot.midY - gain(t) * scale)
            if i == 0 { p.move(to: pt); fill.move(to: CGPoint(x: pt.x, y: plot.midY)) } else { p.addLine(to: pt) }
            fill.addLine(to: pt)
        }
        fill.addLine(to: CGPoint(x: plot.maxX, y: plot.midY)); fill.closeSubpath()
        ctx.saveGState(); ctx.addPath(fill); ctx.setFillColor(Space.orange.withAlphaComponent(0.12 + 0.1 * live(s)).cgColor); ctx.fillPath(); ctx.restoreGState()
        Space.glowStroke(ctx, p, Space.orange, width: 1.5)
        for (t, g) in [(0.12, bass), (0.2 + 0.6 * freq, mid), (0.88, treble)] as [(CGFloat, CGFloat)] {
            let c = CGPoint(x: plot.minX + t * plot.width, y: plot.midY - gain(t) * scale)
            _ = g
            ctx.setStrokeColor(Space.hex(0xffffff, 0.9).cgColor); ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8))
        }
    }

    /// Spectrum bars with the resonant peak where the pedal is; a small rocker shows its angle.
    private static func wah(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let plot = r.insetBy(dx: 10, dy: 10)
        let auto = s.k(1, 0), rate = s.k(2, 0), res = s.k(3)
        let pos = min(1, max(0, s.k(0) + auto * 0.4 * CGFloat(sin(s.time * Double(0.5 + 6 * rate) * 2 * .pi))))
        let bars = 30, w = plot.width / CGFloat(bars), centre = 0.1 + 0.8 * pos, width = 0.04 + 0.14 * (1 - res)
        for i in 0..<bars {
            let t = (CGFloat(i) + 0.5) / CGFloat(bars)
            let g = 0.12 + 0.85 * exp(-pow((t - centre) / width, 2)) * (0.45 + 0.55 * max(0.3, live(s)))
            let h = plot.height * g
            ctx.setFillColor((g > 0.5 ? Space.orange : Space.blue).withAlphaComponent(0.35 + 0.6 * g).cgColor)
            ctx.fill(CGRect(x: plot.minX + CGFloat(i) * w + 1, y: plot.maxY - h, width: w - 2, height: h))
        }
        let pivot = CGPoint(x: plot.minX + 16, y: plot.minY + 14), a = -0.5 + pos * 0.5
        let rocker = CGMutablePath()
        rocker.move(to: CGPoint(x: pivot.x - cos(a) * 12, y: pivot.y - sin(a) * 12)); rocker.addLine(to: CGPoint(x: pivot.x + cos(a) * 12, y: pivot.y + sin(a) * 12))
        Space.glowStroke(ctx, rocker, Space.ice, width: 2, bloom: 0.4)
    }

    /// Comb-filter teeth that sweep: the flanger's jet.
    private static func flanger(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let plot = r.insetBy(dx: 10, dy: 12)
        let sweep = CGFloat(0.5 + 0.5 * sin(s.time * (0.3 + 3 * Double(s.k(0))) * 2 * .pi)) * s.k(1)
        let spacing = 0.06 + 0.12 * (1 - s.k(2)) * (1 - 0.5 * sweep), depth = 0.4 + 0.5 * abs(s.k(3) - 0.5) * 2
        let p = CGMutablePath(), n = 200
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let g = 1 - depth * pow(0.5 + 0.5 * cos(2 * .pi * t / spacing), 6)
            let pt = CGPoint(x: plot.minX + t * plot.width, y: plot.maxY - plot.height * g * (0.5 + 0.5 * max(0.3, live(s))))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        Space.glowStroke(ctx, p, Space.blue, width: 1.4)
        let line = CGMutablePath(); line.move(to: CGPoint(x: plot.minX, y: plot.maxY)); line.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.addPath(line); ctx.setStrokeColor(Space.orange.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(1); ctx.strokePath()
    }

    // MARK: Modulation (scope)

    /// Two voices as translucent ribbons that drift against each other.
    private static func chorus(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let rate = Double(s.k(0)), depth = s.k(1)
        let a = r.height * 0.22 * (0.4 + 0.6 * max(0.35, live(s)))
        for v in 0..<3 {
            let shift = CGFloat(v) * 0.7 * depth * CGFloat(sin(s.time * (0.3 + 3 * rate) * 2 * .pi + Double(v) * 1.7))
            let top = wave(r, amplitude: a, cycles: 2, phase: CGFloat(s.time) + shift, yOffset: -4) { sin($0) }
            let bottom = wave(r, amplitude: a, cycles: 2, phase: CGFloat(s.time) + shift, yOffset: 4) { sin($0) }
            let ribbon = CGMutablePath(); ribbon.addPath(top)
            let pts = bottom.points.reversed()
            for p in pts { ribbon.addLine(to: p) }
            ribbon.closeSubpath()
            let color = [Space.orange, Space.blue, Space.ice][v]
            ctx.saveGState(); ctx.setBlendMode(.screen)
            ctx.addPath(ribbon); ctx.setFillColor(color.withAlphaComponent(0.28).cgColor); ctx.fillPath()
            ctx.restoreGState()
            Space.glowStroke(ctx, top, color.withAlphaComponent(0.8), width: 0.8, bloom: 0.3)
        }
    }
    /// A rose figure, one petal pair per stage, turning with the rate.
    private static func phaser(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let stages = [4, 6, 8, 12][min(3, Int((s.k(2) * 3).rounded()))]
        let c = CGPoint(x: r.midX, y: r.midY), rad = r.height * 0.42 * (0.6 + 0.4 * max(0.3, live(s)))
        let turn = CGFloat(s.time * (0.1 + 1.2 * Double(s.k(0))))
        let k = CGFloat(stages) / 2, p = CGMutablePath()
        for i in 0...360 {
            let t = CGFloat(i) / 360 * 2 * .pi
            let rr = rad * (0.35 + 0.65 * abs(cos(k * t)) * (0.5 + 0.5 * s.k(1)))
            let pt = CGPoint(x: c.x + cos(t + turn) * rr, y: c.y + sin(t + turn) * rr)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        Space.glowStroke(ctx, p, Space.orange, width: 1.2, bloom: 0.6)
        Space.glowDot(ctx, c, 2.5, Space.ice)
    }
    /// The pitch swaying like a pendulum, with its trail.
    private static func vibrato(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let pivot = CGPoint(x: r.midX, y: r.minY + 6), len = r.height - 22
        let speed = 0.5 + 4 * Double(s.k(0)), swing = 0.15 + 0.6 * s.k(1)
        let arc = CGMutablePath(); arc.addArc(center: pivot, radius: len, startAngle: .pi / 2 - swing, endAngle: .pi / 2 + swing, clockwise: false)
        ctx.saveGState(); ctx.setLineDash(phase: 0, lengths: [2, 3]); Space.glowStroke(ctx, arc, Space.blue, width: 1, bloom: 0.3); ctx.restoreGState()
        for k in 0..<8 {
            let t = s.time - Double(k) * 0.04
            let a = CGFloat.pi / 2 + swing * CGFloat(sin(t * speed * 2 * .pi))
            Space.glowDot(ctx, CGPoint(x: pivot.x + cos(a) * len, y: pivot.y + sin(a) * len), 3.2 - CGFloat(k) * 0.3, Space.orange,
                          intensity: (1 - CGFloat(k) / 8) * (0.5 + 0.5 * max(0.3, live(s))))
        }
        let a = CGFloat.pi / 2 + swing * CGFloat(sin(s.time * speed * 2 * .pi))
        ctx.move(to: pivot); ctx.addLine(to: CGPoint(x: pivot.x + cos(a) * len, y: pivot.y + sin(a) * len))
        ctx.setStrokeColor(Space.hex(0xffffff, 0.25).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
    }

    // MARK: Tremolo (meter)

    /// A ring of LEDs pulsing at the rate; depth sets how far they dim, shape how hard they switch.
    private static func tremolo(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let c = CGPoint(x: r.midX, y: r.midY), rad = r.height * 0.36, n = 24
        let rate = 1 + 8 * Double(s.k(0)), depth = s.k(1), shape = s.k(2, 0)
        var lfo = CGFloat(0.5 + 0.5 * sin(s.time * rate * 2 * .pi))
        lfo = lfo * (1 - shape) + (lfo > 0.5 ? 1 : 0) * shape
        let g = (1 - depth * lfo) * (0.4 + 0.6 * max(0.35, live(s)))
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            Space.glowDot(ctx, CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad), 2.4, i % 2 == 0 ? Space.orange : Space.amber, intensity: g)
        }
        Space.glowDot(ctx, c, 4 + 6 * g, Space.orange, intensity: g)
    }

    // MARK: Time (cosmos, CRT)

    /// Echoes on a timeline: each tap smaller by the feedback, spaced by the time, alternating sides when ping-ponged.
    private static func delay(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let time = s.k(0), feedback = s.k(1), pong = s.k(4, 0), lit = live(s)
        let base = r.maxY - 16
        ctx.move(to: CGPoint(x: r.minX + 8, y: base)); ctx.addLine(to: CGPoint(x: r.maxX - 8, y: base))
        ctx.setStrokeColor(Space.hex(0xffffff, 0.18).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
        let spacing = (r.width - 30) * (0.08 + 0.22 * time)
        var x = r.minX + 16, a: CGFloat = 1, k = 0
        while x < r.maxX - 10, a > 0.05 {
            let h = (r.height - 34) * a * (0.4 + 0.6 * max(0.3, lit))
            let side: CGFloat = k == 0 ? 0 : (k % 2 == 0 ? -1 : 1) * pong * 8
            let bar = CGMutablePath(); bar.move(to: CGPoint(x: x, y: base)); bar.addLine(to: CGPoint(x: x, y: base - h))
            Space.glowStroke(ctx, bar, k == 0 ? Space.orange : Space.blue, width: 1.6, bloom: 0.5)
            Space.glowDot(ctx, CGPoint(x: x, y: base - h + side), 2.4 * (0.6 + 0.4 * a), k == 0 ? Space.orange : Space.ice, intensity: a)
            x += spacing; a *= 0.2 + 0.75 * feedback; k += 1
        }
        let run = CGFloat((s.time * 0.6).truncatingRemainder(dividingBy: 1))
        Space.glowDot(ctx, CGPoint(x: r.minX + 16 + run * (r.width - 32), y: base), 1.6, Space.hex(0xffffff), intensity: 0.6)
    }
    /// A room in perspective (its size) filling with particles (the decay) coloured by the tone.
    private static func reverb(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let size = s.k(1), decay = s.k(0), tone = s.k(3), lit = live(s)
        let c = CGPoint(x: r.midX, y: r.midY)
        let back = CGSize(width: r.width * (0.18 + 0.2 * size), height: r.height * (0.2 + 0.2 * size))
        let inner = CGRect(x: c.x - back.width / 2, y: c.y - back.height / 2, width: back.width, height: back.height)
        let outer = r.insetBy(dx: 6, dy: 6)
        ctx.setStrokeColor(Space.blue.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.8)
        ctx.stroke(inner)
        for (a, b) in [(CGPoint(x: outer.minX, y: outer.minY), CGPoint(x: inner.minX, y: inner.minY)), (CGPoint(x: outer.maxX, y: outer.minY), CGPoint(x: inner.maxX, y: inner.minY)),
                       (CGPoint(x: outer.minX, y: outer.maxY), CGPoint(x: inner.minX, y: inner.maxY)), (CGPoint(x: outer.maxX, y: outer.maxY), CGPoint(x: inner.maxX, y: inner.maxY))] {
            ctx.move(to: a); ctx.addLine(to: b)
        }
        ctx.strokePath()
        var seed: UInt32 = 11
        ctx.saveGState(); ctx.setBlendMode(.screen)
        for i in 0..<120 {
            seed = seed &* 1664525 &+ 1013904223; let ang = CGFloat(seed % 6283) / 1000
            seed = seed &* 1664525 &+ 1013904223; let dist = CGFloat(seed % 1000) / 1000
            let drift = CGFloat((s.time * 0.05 * Double(1 + i % 3)).truncatingRemainder(dividingBy: 1))
            let d = pow((dist + drift * 0.3).truncatingRemainder(dividingBy: 1), 0.7) * r.height * (0.2 + 0.6 * decay)
            let p = CGPoint(x: c.x + cos(ang) * d * 1.6, y: c.y + sin(ang) * d * 0.8)
            ctx.setFillColor((dist < tone ? Space.orange : Space.ice).withAlphaComponent(max(0, 1 - d / r.height) * (0.25 + 0.6 * max(0.25, lit))).cgColor)
            let sz = 0.8 + 1.4 * (1 - dist)
            ctx.fillEllipse(in: CGRect(x: p.x - sz / 2, y: p.y - sz / 2, width: sz, height: sz))
        }
        ctx.restoreGState()
    }
    /// Three springs on the amber CRT, shaking with the signal; drip adds the ripple.
    private static func spring(_ ctx: CGContext, _ r: CGRect, _ s: State) {
        let drip = s.k(2), lit = live(s)
        for line in 0..<3 {
            let y0 = r.minY + r.height * (0.28 + 0.22 * CGFloat(line))
            let p = CGMutablePath(), n = 180
            for i in 0...n {
                let t = CGFloat(i) / CGFloat(n)
                let wob = sin(t * 18 - CGFloat(s.time * (6 + 6 * Double(drip))) + CGFloat(line)) * lit * 6 * sin(t * .pi)
                let pt = CGPoint(x: r.minX + 14 + t * (r.width - 28), y: y0 + sin(t * 150) * 3.5 + wob)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            phosphor(ctx, p, width: 0.9, bloom: 0.5)
        }
        for x in [r.minX + 8, r.maxX - 14] { ctx.setFillColor(amber.withAlphaComponent(0.5).cgColor); ctx.fill(CGRect(x: x, y: r.minY + 10, width: 6, height: r.height - 20)) }
    }
}

private extension CGPath {
    /// The path's points in order (lines only).
    var points: [CGPoint] {
        var out: [CGPoint] = []
        applyWithBlock { e in
            let t = e.pointee.type
            if t == .moveToPoint || t == .addLineToPoint { out.append(e.pointee.points[0]) }
        }
        return out
    }
}
