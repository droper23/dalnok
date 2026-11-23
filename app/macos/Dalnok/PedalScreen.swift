// Warm Analog: the readout window of a stomp box, so a pedal shows as much as a Graphite faceplate without losing its
// charm. Inspired by how modern pedals carry information (gain-reduction LED ladders on studio compressor pedals, small
// backlit dot-matrix and OLED screens over direct knobs on multi-effects units); the drawing is Dalnok's own.
// A recessed, backlit window in the pedal's LED colour with a faint dot-matrix grid shows:
//   - the control being turned, by name and value (for a few seconds after it moves);
//   - otherwise a live picture suited to the plug-in: a 12-segment gain-reduction ladder (dynamics), the frequency
//     response (EQs and filters) or the output trace (everything else), with a one-line reading.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class PedalScreen: NSView {
    enum Mode: Equatable { case ladder, curve, scope }
    var mode: Mode = .scope { didSet { if mode != oldValue { needsDisplay = true } } }
    var glow: NSColor = .systemOrange { didSet { needsDisplay = true } }
    /// Dark when the pedal is bypassed or not loaded.
    var lit = true { didSet { if lit != oldValue { needsDisplay = true } } }
    /// Gain reduction in dB (ladder), shown 0…24 dB.
    var reduction: Double = 0 { didSet { if abs(reduction - oldValue) > 0.05 { needsDisplay = true } } }
    /// Response in dB at log-spaced points 20 Hz…20 kHz (curve), ±18 dB.
    var curve: [Double] = [] { didSet { needsDisplay = true } }
    /// Output samples (scope), −1…1.
    var trace: [Float] = [] { didSet { needsDisplay = true } }
    /// The idle reading (bottom line), e.g. "−4.2 dB GR" or "−12 dBFS".
    var reading = "" { didSet { if reading != oldValue { needsDisplay = true } } }
    private var touched: (name: String, value: String, at: TimeInterval)?

    static let height: CGFloat = 32

    /// A control moved: show its name and value for a while.
    func showValue(_ name: String, _ value: String) {
        touched = (name, value, ProcessInfo.processInfo.systemUptime)
        needsDisplay = true
    }
    var showingValue: Bool { touched.map { ProcessInfo.processInfo.systemUptime - $0.at < 2.5 } ?? false }
    /// The text a reader sees now (tests and VoiceOver).
    var text: String { showingValue ? "\(touched!.name) \(touched!.value)" : reading }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        setAccessibilityValue(text)
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        // Bezel: a black recess with a light lower lip, as a window cut into the enclosure.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.addPath(CGPath(roundedRect: outer.offsetBy(dx: 0, dy: 0.8), cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        let glass = outer.insetBy(dx: 2, dy: 2)
        let back = glow.blended(withFraction: 0.86, of: .black) ?? .black
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: glass, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)); ctx.clip()
        ctx.setFillColor((lit ? back : NSColor(white: 0.06, alpha: 1)).cgColor); ctx.fill(glass)
        // Dot-matrix grid.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        var y = glass.minY + 1
        while y < glass.maxY { ctx.fill(CGRect(x: glass.minX, y: y, width: glass.width, height: 0.5)); y += 2 }
        if lit { drawContent(ctx, glass) }
        // Glass highlight.
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: glass.minY), end: CGPoint(x: 0, y: glass.midY), options: [])
        ctx.restoreGState()
    }

    private func drawContent(_ ctx: CGContext, _ r: CGRect) {
        let ink = glow.blended(withFraction: 0.25, of: .white) ?? glow
        let font = NSFont(name: "Menlo-Bold", size: 7.5) ?? .monospacedSystemFont(ofSize: 7.5, weight: .bold)
        let shadow = NSShadow(); shadow.shadowColor = glow; shadow.shadowBlurRadius = 3
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink, .shadow: shadow]
        if showingValue, let t = touched {
            // Two lines: the control's name, then its value large.
            let name = t.name.uppercased() as NSString
            name.draw(in: CGRect(x: r.minX + 4, y: r.minY + 2, width: r.width - 8, height: 10), withAttributes: attrs)
            let big: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Menlo-Bold", size: 11) ?? font, .foregroundColor: ink, .shadow: shadow]
            let v = t.value as NSString, vs = v.size(withAttributes: big)
            v.draw(at: CGPoint(x: r.maxX - 4 - vs.width, y: r.maxY - vs.height - 1), withAttributes: big)
            return
        }
        let plot = CGRect(x: r.minX + 4, y: r.minY + 3, width: r.width - 8, height: r.height - 15)
        ctx.setShadow(offset: .zero, blur: 3, color: glow.cgColor)
        switch mode {
        case .ladder:
            let n = 12, gap: CGFloat = 1.5, w = (plot.width - gap * CGFloat(n - 1)) / CGFloat(n)
            let lit = Int((min(24, max(0, reduction)) / 24 * Double(n)).rounded()) // 1 segment = 2 dB
            for i in 0..<n {
                let on = i < lit
                ctx.setFillColor((on ? ink : glow.withAlphaComponent(0.16)).cgColor)
                ctx.fill(CGRect(x: plot.minX + CGFloat(i) * (w + gap), y: plot.minY + 1, width: w, height: plot.height - 2))
            }
        case .curve:
            ctx.setStrokeColor(glow.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: plot.minX, y: plot.midY)); ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.midY)); ctx.strokePath()
            guard curve.count > 1 else { break }
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1.2)
            for (i, db) in curve.enumerated() {
                let p = CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(curve.count - 1),
                                y: plot.midY - plot.height / 2 * CGFloat(max(-18, min(18, db)) / 18))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        case .scope:
            ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1)
            guard trace.count > 1 else {
                ctx.move(to: CGPoint(x: plot.minX, y: plot.midY)); ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.midY)); ctx.strokePath()
                break
            }
            for (i, s) in trace.enumerated() {
                let p = CGPoint(x: plot.minX + plot.width * CGFloat(i) / CGFloat(trace.count - 1), y: plot.midY - plot.height / 2 * CGFloat(max(-1, min(1, s))))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        let line = reading.uppercased() as NSString
        let ls = line.size(withAttributes: attrs)
        line.draw(at: CGPoint(x: r.maxX - 4 - ls.width, y: r.maxY - ls.height), withAttributes: attrs)
    }
}
