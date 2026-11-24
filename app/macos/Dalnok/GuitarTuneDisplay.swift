// Actual monophonic pitch telemetry for Guitar Tune; never synthesizes a signal or an animated reading.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class GuitarTuneDisplay: NSView {
    struct Reading {
        var hz: Double = 0, cents: Double = 0, confidence: Double = 0, reference: Double = 440
        var bypassed = false
        var tracking: Bool { !bypassed && hz.isFinite && hz > 0 && confidence >= 50 }
        var note: String {
            guard tracking else { return "—" }
            let midi = Int((69 + 12 * log2(hz / max(1, reference))).rounded())
            let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
            return "\(names[(midi % 12 + 12) % 12])\(Int(floor(Double(midi) / 12)) - 1)"
        }
        var status: String {
            if bypassed { return "BYPASSED" }
            return tracking ? String(format: "%+.1f cents", cents).replacingOccurrences(of: "-", with: "−") : "AWAITING SINGLE NOTE"
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
        toolTip = "Input note and cents from the selected scale target. Confidence measures pitch detection, not correction quality."
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(_ value: Reading) {
        reading = value
        setAccessibilityValue(value.tracking ? "\(value.note), \(value.status), \(Int(value.confidence)) percent confidence" : value.status)
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
        let accent = reading.tracking && abs(reading.cents) <= 3 ? Theme.accentText : Theme.text
        if compact {
            text(reading.tracking ? "\(reading.note)  \(reading.status)" : reading.status,
                 CGRect(x: r.minX + 3, y: r.minY + 5, width: r.width - 6, height: 18), 10, accent, bold: true)
        } else {
            text("INPUT PITCH / TARGET ERROR", CGRect(x: r.minX, y: r.minY + 8, width: r.width, height: 14), 8, Theme.textDim)
            text(reading.note, CGRect(x: r.minX, y: r.minY + 23, width: r.width, height: 40), 30, accent, bold: true)
            text(reading.status, CGRect(x: r.minX, y: r.minY + 64, width: r.width, height: 15), 10, Theme.text)
        }
        let y = compact ? r.maxY - 4 : r.minY + 93
        let left = r.minX + 17, width = max(1, r.width - 34)
        ctx.setStrokeColor(Theme.textFaint.cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: left, y: y)); ctx.addLine(to: CGPoint(x: left + width, y: y)); ctx.strokePath()
        for tick in -4...4 {
            let x = left + width * CGFloat(tick + 4) / 8
            ctx.move(to: CGPoint(x: x, y: y - (compact ? 2 : tick == 0 ? 7 : 3)))
            ctx.addLine(to: CGPoint(x: x, y: y + 3)); ctx.strokePath()
        }
        if reading.tracking {
            let x = left + width * CGFloat((max(-100, min(100, reading.cents)) + 100) / 200)
            ctx.setFillColor(Theme.accentText.cgColor)
            ctx.move(to: CGPoint(x: x, y: y - 2)); ctx.addLine(to: CGPoint(x: x - 4, y: y - (compact ? 4 : 10)))
            ctx.addLine(to: CGPoint(x: x + 4, y: y - (compact ? 4 : 10))); ctx.closePath(); ctx.fillPath()
        }
        if !compact {
            text("−100           0           +100", CGRect(x: left - 10, y: y + 7, width: width + 20, height: 13), 8, Theme.textDim)
            if r.height >= 137 {
                let detail = reading.tracking ? String(format: "%.1f Hz  ·  %.0f%% confidence", reading.hz, reading.confidence) : "MONOPHONIC GUITAR"
                text(detail, CGRect(x: r.minX + 3, y: r.maxY - 20, width: r.width - 6, height: 14), 8, Theme.textDim)
            }
        }
    }
}
