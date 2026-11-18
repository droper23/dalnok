// Graphite faceplate displays: the instrument panel each kind of plug-in gets beside its controls.
// Dynamics get a backlit moving-coil gain-reduction meter; EQs and filters a response screen (the exact curve for
// Dalnok's own EQs, a curve measured from the signal for hosted ones, over a live spectrum); everything else a
// phosphor oscilloscope. They read the engine's per-plug-in meters and display tap (live playback only).
// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import AppKit

@MainActor
enum FaceplateDisplay {
    enum Kind: Equatable { case gainReduction, response, scope }

    static func kind(name: String, path: String, instrument: Bool) -> Kind {
        if instrument { return .scope }
        let parts = path.split(separator: ":")
        let format = parts.count == 3 && parts.allSatisfy({ $0.count == 4 }) ? "AU" : path.hasSuffix(".clap") ? "CLAP" : "VST3"
        let c = PluginTaxonomy.classify(name: name, kind: "effect", format: format, path: path, categories: []).category
        switch c {
        case "Compression", "Limiting", "Gate / Expander": return .gainReduction
        case "EQ", "Filtering": return .response
        default: return .scope
        }
    }

    /// Display size for a unit whose controls take `rows` rows.
    static func size(_ kind: Kind, rows: Int) -> NSSize {
        switch kind {
        case .gainReduction: NSSize(width: 150, height: rows > 1 ? 112 : 96)
        case .response: NSSize(width: rows > 1 ? 236 : 200, height: rows > 1 ? 140 : 96)
        case .scope: NSSize(width: rows > 1 ? 168 : 150, height: rows > 1 ? 120 : 96)
        }
    }

    // MARK: Shared drawing

    /// A recessed bezel around a display window: dark machined frame, inner shadow, and the window's rect.
    static func bezel(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat = 5) -> CGRect {
        let outer = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.addPath(outer); ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(outer); ctx.clip()
        let colors = [NSColor(white: 0.20, alpha: 1).cgColor, NSColor(white: 0.10, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(outer); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        return rect.insetBy(dx: 4, dy: 4)
    }

    /// Glass over a window: a soft diagonal glare and an inner shadow at the top edge.
    static func glass(_ ctx: CGContext, _ window: CGRect, radius: CGFloat) {
        let path = CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let glare = [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glare, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: window.minX, y: window.minY), end: CGPoint(x: window.minX + window.width * 0.45, y: window.midY),
                                   options: [])
        }
        let inner = [NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: inner, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: window.minY), end: CGPoint(x: 0, y: window.minY + 6), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1); ctx.strokePath()
    }

    static func text(_ s: String, at rect: CGRect, font: NSFont, color: NSColor, align: NSTextAlignment = .center) {
        let para = NSMutableParagraphStyle(); para.alignment = align
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }
}

// MARK: Signal analysis

/// Power spectra of the tap's input and output (Hann window, 4096 points), averaged over time. From them come the
/// output spectrum and, where the input has energy, the measured magnitude response of the plug-in.
@MainActor
final class SpectrumAnalyzer {
    static let n = 4096
    nonisolated(unsafe) private let setup: vDSP_DFT_Setup?
    private let window: [Float]
    private(set) var inPower: [Float], outPower: [Float]
    private(set) var frames = 0

    init() {
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.n), .FORWARD)
        var w = [Float](repeating: 0, count: Self.n)
        vDSP_hann_window(&w, vDSP_Length(Self.n), Int32(vDSP_HANN_NORM))
        window = w
        inPower = [Float](repeating: 0, count: Self.n / 2)
        outPower = inPower
    }
    deinit { if let setup { vDSP_DFT_DestroySetup(setup) } }

    private func power(_ x: [Float]) -> [Float] {
        guard let setup, x.count == Self.n else { return [Float](repeating: 0, count: Self.n / 2) }
        var windowed = [Float](repeating: 0, count: Self.n)
        vDSP_vmul(x, 1, window, 1, &windowed, 1, vDSP_Length(Self.n))
        let half = Self.n / 2
        var re = [Float](repeating: 0, count: half), im = re, outRe = re, outIm = re
        for i in 0..<half { re[i] = windowed[2 * i]; im[i] = windowed[2 * i + 1] }
        vDSP_DFT_Execute(setup, re, im, &outRe, &outIm)
        var p = [Float](repeating: 0, count: half)
        for i in 0..<half { p[i] = outRe[i] * outRe[i] + outIm[i] * outIm[i] }
        p[0] = 0 // DC and Nyquist share bin 0 in the packed format
        return p
    }

    /// Adds the latest block; `fast` follows changes quickly (spectrum), the response averages slower.
    func push(input: [Float], output: [Float]) {
        let pi = power(input), po = power(output)
        let a: Float = frames == 0 ? 1 : 0.25
        for i in 0..<pi.count {
            inPower[i] += (pi[i] - inPower[i]) * a
            outPower[i] += (po[i] - outPower[i]) * a
        }
        frames += 1
    }

    /// Output level (dB, relative) at `hz`, smoothed over a third of an octave.
    func outputDb(at hz: Double, rate: Double) -> Float { band(outPower, hz, rate, 1.0 / 3).map { 10 * log10($0 + 1e-20) } ?? -200 }
    /// Measured response (dB) at `hz`: output over input power in a sixth of an octave; nil where the input is too quiet.
    func responseDb(at hz: Double, rate: Double, floor: Float) -> Float? {
        guard let i = band(inPower, hz, rate, 1.0 / 6), let o = band(outPower, hz, rate, 1.0 / 6), i > floor else { return nil }
        return 10 * log10((o + 1e-20) / i)
    }
    /// Loudest input band power, for choosing a validity floor.
    var inputPeak: Float { inPower.max() ?? 0 }

    private func band(_ p: [Float], _ hz: Double, _ rate: Double, _ octaves: Double) -> Float? {
        let binHz = rate / Double(Self.n)
        let lo = max(1, Int(hz * pow(2, -octaves / 2) / binHz)), hi = min(p.count - 1, max(lo, Int(hz * pow(2, octaves / 2) / binHz)))
        guard lo <= hi else { return nil }
        var sum: Float = 0
        for i in lo...hi { sum += p[i] }
        return sum / Float(hi - lo + 1)
    }
}

// MARK: Gain-reduction meter

/// A backlit moving-coil gain-reduction meter. The needle rests at 0 and swings left as the plug-in reduces gain.
/// The reading is the plug-in's own gain-reduction output when it reports one, else the level change through it
/// (output over input) measured relative to its make-up gain.
@MainActor
final class GainReductionMeter: NSView {
    private var needle: Double = 0, velocity: Double = 0 // needle position: 0 = rest (0 dB), 1 = full scale (20 dB)
    private var target: Double = 0
    private var last = CACurrentMediaTime()
    private var makeup: Double = 0, makeupSeen = false
    private(set) var reductionDb: Double = 0
    static let scale: [Double] = [0, 1, 2, 3, 5, 7, 10, 15, 20]

    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Gain reduction")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Needle travel for a reduction in dB (wider near 0, like a printed GR scale).
    static func position(_ db: Double) -> Double { pow(max(0, min(20, db)) / 20, 0.6) }

    /// Feeds one frame: either the plug-in's reported reduction (dB, positive), or input/output RMS (linear).
    func update(reported: Double?, inRms: Float, outRms: Float) {
        if let r = reported {
            reductionDb = abs(r)
        } else if inRms > 0.003 && outRms > 0 {
            // Level change through the plug-in; its make-up gain is the highest change seen recently (when it isn't reducing).
            let change = 20 * log10(Double(outRms / inRms))
            if !makeupSeen || change > makeup { makeup = change; makeupSeen = true } else { makeup -= 0.02 } // slowly forgets
            reductionDb = max(0, makeup - change)
        } else {
            reductionDb = 0
        }
        target = Self.position(reductionDb)
        setAccessibilityValue(String(format: "%.1f dB", reductionDb))
        step()
    }

    /// Needle ballistics: a damped spring (about 300 ms to settle, a touch of overshoot), like a real movement.
    private func step() {
        let now = CACurrentMediaTime(), dt = min(0.05, now - last)
        last = now
        guard !Motion.reduced else { needle = target; needsDisplay = true; return }
        let k = 160.0, c = 2 * sqrt(k) * 0.72
        for _ in 0..<4 {
            let h = dt / 4
            velocity += (k * (target - needle) - c * velocity) * h
            needle += velocity * h
        }
        needle = max(-0.02, min(1.03, needle))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let window = FaceplateDisplay.bezel(ctx, bounds)
        let r: CGFloat = 3
        let face = CGPath(roundedRect: window, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.saveGState()
        ctx.addPath(face); ctx.clip()
        // Backlit face: warm cream, brightest low in the middle where the lamp sits.
        ctx.setFillColor(NSColor(srgbRed: 0.86, green: 0.80, blue: 0.64, alpha: 1).cgColor); ctx.fill(window)
        let lamp = [NSColor(srgbRed: 1, green: 0.96, blue: 0.82, alpha: 0.95).cgColor, NSColor(srgbRed: 0.80, green: 0.72, blue: 0.54, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: lamp, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: window.midX, y: window.maxY), startRadius: 0,
                                   endCenter: CGPoint(x: window.midX, y: window.maxY), endRadius: window.width * 0.75, options: [])
        }
        // Scale: an arc around a pivot below the window.
        let pivot = CGPoint(x: window.midX, y: window.maxY + window.height * 0.62)
        let radius = window.height * 1.22
        let span = 0.47 // radians each side of vertical
        func angle(_ pos: Double) -> CGFloat { CGFloat(span - 2 * span * pos) } // 0 dB on the right
        func pt(_ a: CGFloat, _ rr: CGFloat) -> CGPoint { CGPoint(x: pivot.x + rr * sin(a), y: pivot.y - rr * cos(a)) }
        let ink = NSColor(white: 0.10, alpha: 0.92)
        ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1)
        ctx.addArc(center: pivot, radius: radius, startAngle: -.pi / 2 - CGFloat(span), endAngle: -.pi / 2 + CGFloat(span), clockwise: false)
        ctx.strokePath()
        // Heavy-reduction band in red (10 dB and beyond).
        ctx.setStrokeColor(NSColor(srgbRed: 0.72, green: 0.12, blue: 0.10, alpha: 0.9).cgColor); ctx.setLineWidth(3)
        let a10 = angle(Self.position(10)), a20 = angle(1)
        ctx.addArc(center: pivot, radius: radius + 2, startAngle: -.pi / 2 + a20, endAngle: -.pi / 2 + a10, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(ink.cgColor)
        let font = NSFont.systemFont(ofSize: 7.5, weight: .semibold)
        for db in Self.scale {
            let a = angle(Self.position(db))
            ctx.setLineWidth(db == 0 ? 1.4 : 1)
            ctx.move(to: pt(a, radius)); ctx.addLine(to: pt(a, radius + (db == 0 || db == 10 || db == 20 ? 6 : 4))); ctx.strokePath()
            let p = pt(a, radius + 11)
            FaceplateDisplay.text(db == 0 ? "0" : String(format: "%.0f", db), at: CGRect(x: p.x - 9, y: p.y - 5, width: 18, height: 10), font: font,
                                  color: db >= 10 ? NSColor(srgbRed: 0.62, green: 0.10, blue: 0.08, alpha: 1) : ink)
        }
        for i in 0..<20 where !Self.scale.contains(Double(i)) {
            let a = angle(Self.position(Double(i)))
            ctx.setLineWidth(0.6)
            ctx.move(to: pt(a, radius)); ctx.addLine(to: pt(a, radius + 2.5)); ctx.strokePath()
        }
        FaceplateDisplay.text("GAIN REDUCTION", at: CGRect(x: window.minX, y: window.maxY - window.height * 0.47, width: window.width, height: 10),
                              font: NSFont.systemFont(ofSize: 6.5, weight: .bold), color: ink.withAlphaComponent(0.8))
        FaceplateDisplay.text("dB", at: CGRect(x: window.minX, y: window.maxY - window.height * 0.47 + 9, width: window.width, height: 10),
                              font: NSFont.systemFont(ofSize: 7, weight: .regular), color: ink.withAlphaComponent(0.7))
        // Needle with its shadow on the face, then the pivot cover.
        let a = angle(needle)
        let tip = pt(a, radius + 7), base = pt(a, window.height * 0.62)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(1.6)
        ctx.move(to: CGPoint(x: base.x + 2.5, y: base.y + 2)); ctx.addLine(to: CGPoint(x: tip.x + 2.5, y: tip.y + 2)); ctx.strokePath()
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 0.06, alpha: 1).cgColor); ctx.setLineWidth(1.1); ctx.setLineCap(.round)
        ctx.move(to: base); ctx.addLine(to: tip); ctx.strokePath()
        ctx.setLineCap(.butt)
        // The movement's housing: a dark dome over the pivot, lit from above.
        let dome = CGRect(x: window.midX - window.width * 0.26, y: window.maxY - window.height * 0.17, width: window.width * 0.52, height: window.height * 0.5)
        let domePath = CGPath(ellipseIn: dome, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(domePath); ctx.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(domePath); ctx.clip()
        let sheen = [NSColor(white: 0.30, alpha: 1).cgColor, NSColor(white: 0.08, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheen, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: dome.minY), end: CGPoint(x: 0, y: dome.minY + dome.height * 0.35), options: [])
        }
        ctx.restoreGState()
        ctx.restoreGState()
        FaceplateDisplay.glass(ctx, window, radius: r)
        // Pivot screw on the cover.
        Faceplate.screw(ctx, CGPoint(x: window.midX, y: window.maxY - window.height * 0.08))
    }
}

// MARK: Response screen

/// An EQ screen: log-frequency grid, the live output spectrum, and the response curve with a soft glow.
@MainActor
final class ResponseScreen: NSView {
    var curve: [Double]? { didSet { needsDisplay = true } }       // dB at `ResponseScreen.frequencies`
    var measured = false { didSet { needsDisplay = true } }
    /// Band handles drawn on the curve (Dalnok's own EQs): frequency and number.
    var markers: [(hz: Double, label: String)] = [] { didSet { needsDisplay = true } }
    var spectrum: [Float]? { didSet { needsDisplay = true } }      // dB at the same frequencies (relative)
    var tint: NSColor = Theme.accent
    static let range: Double = 18 // ±dB
    static let frequencies: [Double] = (0..<160).map { 20 * pow(1000, Double($0) / 159) }

    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Frequency response")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let window = FaceplateDisplay.bezel(ctx, bounds)
        let r: CGFloat = 3
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.clip()
        let bg = [NSColor(srgbRed: 0.035, green: 0.055, blue: 0.07, alpha: 1).cgColor, NSColor(srgbRed: 0.055, green: 0.085, blue: 0.10, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: window.minY), end: CGPoint(x: 0, y: window.maxY), options: [])
        }
        let plot = window.insetBy(dx: 2, dy: 3)
        func x(_ hz: Double) -> CGFloat { plot.minX + plot.width * CGFloat(log10(hz / 20) / 3) }
        func y(_ db: Double) -> CGFloat { plot.midY - plot.height / 2 * CGFloat(max(-1.05, min(1.05, db / Self.range))) }
        // Grid.
        let grid = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.70, alpha: 1)
        for hz in [30.0, 40, 50, 60, 70, 80, 90, 200, 300, 400, 500, 600, 700, 800, 900, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000] {
            ctx.setStrokeColor(grid.withAlphaComponent(0.07).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: x(hz), y: plot.minY)); ctx.addLine(to: CGPoint(x: x(hz), y: plot.maxY)); ctx.strokePath()
        }
        for hz in [100.0, 1000, 10000] {
            ctx.setStrokeColor(grid.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.6)
            ctx.move(to: CGPoint(x: x(hz), y: plot.minY)); ctx.addLine(to: CGPoint(x: x(hz), y: plot.maxY)); ctx.strokePath()
        }
        for db in stride(from: -12.0, through: 12, by: 6) {
            ctx.setStrokeColor(grid.withAlphaComponent(db == 0 ? 0.26 : 0.09).cgColor); ctx.setLineWidth(db == 0 ? 0.7 : 0.5)
            ctx.move(to: CGPoint(x: plot.minX, y: y(db))); ctx.addLine(to: CGPoint(x: plot.maxX, y: y(db))); ctx.strokePath()
        }
        let small = Theme.mono(6.5)
        for (hz, t) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
            FaceplateDisplay.text(t, at: CGRect(x: x(hz) + 2, y: plot.maxY - 9, width: 24, height: 9), font: small, color: grid.withAlphaComponent(0.55), align: .left)
        }
        for db in [12.0, -12] {
            FaceplateDisplay.text(String(format: "%+.0f", db), at: CGRect(x: plot.minX + 1, y: y(db) - 9, width: 22, height: 9), font: small,
                                  color: grid.withAlphaComponent(0.45), align: .left)
        }
        // Spectrum (output), a soft filled mountain behind the curve.
        if let raw = spectrum, raw.count == Self.frequencies.count, let top = raw.max(), top > -150 {
            // Low bands span few FFT bins: smooth across neighbouring points so the outline reads as a spectrum, not steps.
            let s = raw.indices.map { i -> Float in
                let lo = max(0, i - 3), hi = min(raw.count - 1, i + 3)
                return raw[lo...hi].reduce(0, +) / Float(hi - lo + 1)
            }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            var prev: CGPoint?
            for (i, hz) in Self.frequencies.enumerated() {
                let level = Double(max(0, min(1, (s[i] - top + 60) / 60))) // top 60 dB of the spectrum
                let p = CGPoint(x: x(hz), y: plot.maxY - plot.height * 0.85 * CGFloat(level))
                if let q = prev { path.addQuadCurve(to: CGPoint(x: (q.x + p.x) / 2, y: (q.y + p.y) / 2), control: q) } else { path.addLine(to: p) }
                prev = p
            }
            if let q = prev { path.addLine(to: q) }
            path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)); path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let fill = [NSColor(srgbRed: 0.40, green: 0.70, blue: 0.85, alpha: 0.30).cgColor, NSColor(srgbRed: 0.40, green: 0.70, blue: 0.85, alpha: 0.03).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: fill, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: plot.minY), end: CGPoint(x: 0, y: plot.maxY), options: [])
            }
            ctx.restoreGState()
        }
        // Response curve: filled to 0 dB, then the line with a glow.
        if let c = curve, c.count == Self.frequencies.count {
            let line = CGMutablePath()
            for (i, hz) in Self.frequencies.enumerated() {
                let p = CGPoint(x: x(hz), y: y(c[i]))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            let area = line.mutableCopy()!
            area.addLine(to: CGPoint(x: plot.maxX, y: y(0))); area.addLine(to: CGPoint(x: plot.minX, y: y(0))); area.closeSubpath()
            ctx.addPath(area); ctx.setFillColor(tint.withAlphaComponent(0.14).cgColor); ctx.fillPath()
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: tint.withAlphaComponent(0.9).cgColor)
            ctx.addPath(line); ctx.setStrokeColor(tint.cgColor); ctx.setLineWidth(1.7); ctx.setLineJoin(.round)
            if measured { ctx.setLineDash(phase: 0, lengths: [4, 2]) }
            ctx.strokePath()
            ctx.restoreGState()
        }
        if let c = curve, c.count == Self.frequencies.count {
            for m in markers where m.hz >= 20 && m.hz <= 20_000 {
                let pos = log10(m.hz / 20) / 3 * Double(c.count - 1)
                let i = min(c.count - 2, Int(pos)), t = pos - Double(i)
                let center = CGPoint(x: x(m.hz), y: y(c[i] + (c[i + 1] - c[i]) * t))
                let dot = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 4, color: tint.withAlphaComponent(0.8).cgColor)
                ctx.setFillColor(NSColor(srgbRed: 0.05, green: 0.08, blue: 0.10, alpha: 0.95).cgColor); ctx.fillEllipse(in: dot)
                ctx.restoreGState()
                ctx.setStrokeColor(tint.cgColor); ctx.setLineWidth(1.2); ctx.strokeEllipse(in: dot)
                FaceplateDisplay.text(m.label, at: CGRect(x: dot.minX, y: dot.minY + 1, width: dot.width, height: 9),
                                      font: NSFont.systemFont(ofSize: 6.5, weight: .bold), color: tint)
            }
        }
        if measured {
            FaceplateDisplay.text("MEASURED", at: CGRect(x: plot.maxX - 52, y: plot.minY + 1, width: 50, height: 9), font: small,
                                  color: grid.withAlphaComponent(0.55), align: .right)
        }
        ctx.restoreGState()
        FaceplateDisplay.glass(ctx, window, radius: r)
    }
}

// MARK: Oscilloscope

/// A phosphor oscilloscope: the plug-in's output, triggered on a rising zero crossing, with a little persistence.
@MainActor
final class ScopeScreen: NSView {
    private var traces: [[Float]] = [] // newest last
    override var isFlipped: Bool { true }
    static let phosphor = NSColor(srgbRed: 0.50, green: 1.0, blue: 0.70, alpha: 1)

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Oscilloscope")
    }
    required init?(coder: NSCoder) { fatalError() }

    var traceCount: Int { traces.count }

    /// Adds the latest output block (about 20 ms shown).
    func push(_ samples: [Float]) {
        let span = min(samples.count / 2, 960)
        guard span > 16 else { return }
        var start = samples.count - span - 1
        // Trigger: the latest rising zero crossing that still leaves a full sweep after it.
        var i = samples.count - span - 1
        while i > 1 { if samples[i - 1] <= 0 && samples[i] > 0 { start = i; break }; i -= 1 }
        traces.append(Array(samples[start..<min(samples.count, start + span)]))
        if traces.count > 4 { traces.removeFirst() }
        needsDisplay = true
    }
    func clear() { if !traces.isEmpty { traces = []; needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let window = FaceplateDisplay.bezel(ctx, bounds)
        let r: CGFloat = 3
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.clip()
        let bg = [NSColor(srgbRed: 0.03, green: 0.07, blue: 0.05, alpha: 1).cgColor, NSColor(srgbRed: 0.015, green: 0.035, blue: 0.025, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: window.midX, y: window.midY), startRadius: 0,
                                   endCenter: CGPoint(x: window.midX, y: window.midY), endRadius: window.width * 0.7, options: [.drawsAfterEndLocation])
        }
        // Graticule: 8 × 6 divisions with minor ticks on the centre lines.
        let p = Self.phosphor
        ctx.setStrokeColor(p.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(0.5)
        for i in 1..<8 { let x = window.minX + window.width * CGFloat(i) / 8; ctx.move(to: CGPoint(x: x, y: window.minY)); ctx.addLine(to: CGPoint(x: x, y: window.maxY)) }
        for i in 1..<6 { let y = window.minY + window.height * CGFloat(i) / 6; ctx.move(to: CGPoint(x: window.minX, y: y)); ctx.addLine(to: CGPoint(x: window.maxX, y: y)) }
        ctx.strokePath()
        ctx.setStrokeColor(p.withAlphaComponent(0.22).cgColor)
        for i in 0..<40 {
            let x = window.minX + window.width * CGFloat(i) / 40
            ctx.move(to: CGPoint(x: x, y: window.midY - 1.5)); ctx.addLine(to: CGPoint(x: x, y: window.midY + 1.5))
        }
        ctx.strokePath()
        // Traces, oldest faintest; the newest glows.
        for (k, t) in traces.enumerated() {
            let age = traces.count - 1 - k
            let path = CGMutablePath()
            for (i, v) in t.enumerated() {
                let pt = CGPoint(x: window.minX + window.width * CGFloat(i) / CGFloat(max(1, t.count - 1)),
                                 y: window.midY - window.height * 0.45 * CGFloat(max(-1, min(1, v))))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.saveGState()
            if age == 0 { ctx.setShadow(offset: .zero, blur: 5, color: p.withAlphaComponent(0.9).cgColor) }
            ctx.addPath(path); ctx.setStrokeColor(p.withAlphaComponent(age == 0 ? 0.95 : 0.35 / CGFloat(age)).cgColor)
            ctx.setLineWidth(age == 0 ? 1.3 : 1); ctx.setLineJoin(.round); ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
        FaceplateDisplay.glass(ctx, window, radius: r)
    }
}
