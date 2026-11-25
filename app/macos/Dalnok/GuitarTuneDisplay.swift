// Actual monophonic pitch telemetry for Guitar Tune; never synthesizes a signal or an animated reading.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class GuitarTuneDisplay: NSView {
    struct Reading {
        var hz: Double = 0, cents: Double = 0, confidence: Double = 0, reference: Double = 440
        /// Bend Tolerance in cents (0: every note is corrected).
        var tolerance: Double = 0
        var bypassed = false
        var tracking: Bool { !bypassed && hz.isFinite && hz > 0 && confidence >= 50 }
        static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        static func name(_ midi: Int) -> String { "\(names[(midi % 12 + 12) % 12])\(Int(floor(Double(midi) / 12)) - 1)" }
        private var position: Double { 69 + 12 * log2(hz / max(1, reference)) }
        var note: String { tracking ? Self.name(Int(position.rounded())) : "—" }
        /// The scale note it's corrected toward (the error is measured from it).
        var target: String { tracking ? Self.name(Int((position - cents / 100).rounded())) : "—" }
        var inTune: Bool { tracking && abs(cents) <= 3 }
        /// Further from the target than the tolerance: played as a bend, left alone.
        var bending: Bool { tracking && tolerance > 0 && abs(cents) > tolerance }
        var status: String {
            if bypassed { return "BYPASSED" }
            guard tracking else { return "AWAITING SINGLE NOTE" }
            if inTune { return "✓ IN TUNE" }
            let c = String(format: "%+.1f cents", cents).replacingOccurrences(of: "-", with: "−")
            return bending ? "\(c) · BEND, LEFT ALONE" : c
        }
    }
    private(set) var reading = Reading()
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // preserve the device's selection/menu gestures
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel("Guitar Tune input pitch and target error")
        toolTip = "The note played, the scale note it's tuned toward and how far off it is (±50 cents shown). The shaded band is the Bend Tolerance: notes outside it are left alone. Confidence measures pitch detection, not correction quality."
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: Reading) {
        reading = value
        setAccessibilityValue(value.tracking ? "\(value.note), target \(value.target), \(value.status), \(Int(value.confidence)) percent confidence" : value.status)
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 3, dy: 3), compact = r.height < 90
        ctx.setFillColor(Theme.lcd.cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.fillPath()
        ctx.setStrokeColor(Theme.controlHi.cgColor); ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7, cornerHeight: 7, transform: nil)); ctx.strokePath()
        func text(_ s: String, _ rect: CGRect, _ size: CGFloat, _ color: NSColor, bold: Bool = false) {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (s as NSString).draw(in: rect, withAttributes: [.font: bold ? Theme.ui(size, .semibold) : Theme.mono(size), .foregroundColor: color, .paragraphStyle: paragraph])
        }
        let accent = reading.inTune ? Theme.accentText : Theme.text
        let heading = reading.tracking && reading.note != reading.target ? "\(reading.note) → \(reading.target)" : reading.note
        if compact {
            text(reading.tracking ? "\(heading)  \(reading.status)" : reading.status,
                 CGRect(x: r.minX + 3, y: r.minY + 5, width: r.width - 6, height: 18), 10, accent, bold: true)
        } else {
            text("PLAYED → TARGET", CGRect(x: r.minX, y: r.minY + 8, width: r.width, height: 14), 8, Theme.textDim)
            text(heading, CGRect(x: r.minX, y: r.minY + 23, width: r.width, height: 40), heading.count > 4 ? 24 : 30, accent, bold: true)
            text(reading.status, CGRect(x: r.minX, y: r.minY + 64, width: r.width, height: 15), 10, reading.inTune ? Theme.accentText : Theme.text, bold: reading.inTune)
        }
        // A ±50 cent scale (a scale note is never further than that): the tolerance band shaded, the needle on top.
        let y = compact ? r.maxY - 4 : r.minY + 93
        let left = r.minX + 17, width = max(1, r.width - 34), span = 50.0
        func x(_ cents: Double) -> CGFloat { left + width * CGFloat((max(-span, min(span, cents)) + span) / (2 * span)) }
        if reading.tolerance > 0, reading.tolerance < span {
            ctx.setFillColor(Theme.accentText.withAlphaComponent(0.14).cgColor)
            ctx.fill(CGRect(x: x(-reading.tolerance), y: y - (compact ? 3 : 8), width: x(reading.tolerance) - x(-reading.tolerance), height: compact ? 6 : 11))
        }
        ctx.setStrokeColor(Theme.textFaint.cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: left, y: y)); ctx.addLine(to: CGPoint(x: left + width, y: y)); ctx.strokePath()
        for tick in -5...5 {
            let tx = x(Double(tick) * 10)
            ctx.move(to: CGPoint(x: tx, y: y - (compact ? 2 : tick == 0 ? 7 : 3)))
            ctx.addLine(to: CGPoint(x: tx, y: y + 3)); ctx.strokePath()
        }
        if reading.tracking {
            let nx = x(reading.cents)
            ctx.setFillColor((reading.inTune ? Theme.accentText : reading.bending ? Theme.textDim : Theme.text).cgColor)
            if reading.inTune { // a different shape as well as colour: a dot on the centre line
                ctx.fillEllipse(in: CGRect(x: nx - 4, y: y - (compact ? 4 : 11), width: 8, height: 8))
            } else {
                ctx.move(to: CGPoint(x: nx, y: y - 2)); ctx.addLine(to: CGPoint(x: nx - 4, y: y - (compact ? 4 : 10)))
                ctx.addLine(to: CGPoint(x: nx + 4, y: y - (compact ? 4 : 10))); ctx.closePath(); ctx.fillPath()
            }
        }
        if !compact {
            text("−50            0            +50", CGRect(x: left - 10, y: y + 7, width: width + 20, height: 13), 8, Theme.textDim)
            if r.height >= 137 {
                let detail = reading.tracking ? String(format: "%.1f Hz  ·  %.0f%% confidence", reading.hz, reading.confidence) : "MONOPHONIC GUITAR"
                text(detail, CGRect(x: r.minX + 3, y: r.maxY - 20, width: r.width - 6, height: 14), 8, Theme.textDim)
            }
        }
    }
}
