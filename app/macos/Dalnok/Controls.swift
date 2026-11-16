// Custom mixer controls: fader, pan knob, toggle chips. Drawn to match the
// canvas (one visual language), with pro interaction details and full
// VoiceOver/keyboard support.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

// MARK: - Value bubble (shared)

@MainActor
final class ValueBubble {
    private static let label: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = Theme.mono(11, .medium)
        l.textColor = Theme.text
        l.alignment = .center
        l.wantsLayer = true
        l.layer?.backgroundColor = Theme.hex(0x0B0C0E, 0.92).cgColor
        l.layer?.cornerRadius = 4
        l.layer?.borderWidth = 1
        l.layer?.borderColor = Theme.hairline.cgColor
        return l
    }()

    static func show(_ text: String, above view: NSView, at x: CGFloat) {
        guard let root = view.window?.contentView else { return }
        let l = label
        if l.superview !== root { root.addSubview(l, positioned: .above, relativeTo: nil) }
        l.stringValue = text
        l.sizeToFit()
        let w = l.frame.width + 12, h: CGFloat = 18
        let p = view.convert(CGPoint(x: x, y: view.isFlipped ? 0 : view.bounds.height), to: root)
        l.frame = CGRect(x: p.x - w / 2, y: p.y + (root.isFlipped ? -h - 4 : 4), width: w, height: h)
        l.isHidden = false
    }

    static func hide() { label.isHidden = true }
}

// MARK: - Fader

/// Horizontal volume fader with an audio taper (position ∝ amplitude^¼),
/// unity at ~84%, +6 dB max. ⌥-click or double-click resets to 0 dB; ⇧-drag is fine.
@MainActor
final class FaderControl: NSControl {
    static let maxDb: Float = 6
    var db: Float = 0 { didSet { needsDisplay = true; setAccessibilityValue(Self.format(db)) } }
    var tint: NSColor = Theme.textDim { didSet { needsDisplay = true } }
    var onBegin: (() -> Void)?
    var onChange: ((Float) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var tracking = false
    private var dragStart: (x: CGFloat, pos: Double)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityValue(Self.format(db))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 18) }

    static func format(_ db: Float) -> String { db <= -95 ? "−∞ dB" : String(format: "%@%.1f dB", db >= 0 ? "+" : "−", abs(db)) }

    static func position(for db: Float) -> Double {
        guard db > -95 else { return 0 }
        let amp = pow(10, Double(db) / 20), maxAmp = pow(10, Double(maxDb) / 20)
        return pow(amp, 0.25) / pow(maxAmp, 0.25)
    }
    static func db(for position: Double) -> Float {
        let p = min(1, max(0, position))
        guard p > 0.001 else { return -.infinity }
        let amp = pow(p * pow(pow(10, Double(maxDb) / 20), 0.25), 4)
        var d = Float(20 * log10(amp))
        if abs(d) < 0.25 { d = 0 } // gentle detent at unity
        return max(-95, d) <= -95 ? -.infinity : d
    }

    private var grooveRect: CGRect { CGRect(x: 6, y: bounds.midY - 2, width: bounds.width - 12, height: 4) }
    private func x(for pos: Double) -> CGFloat { grooveRect.minX + CGFloat(pos) * grooveRect.width }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let g = grooveRect, pos = Self.position(for: db), capX = x(for: pos)
        // Groove with inner shadow feel.
        ctx.setFillColor(Theme.hex(0x0A0B0D).cgColor)
        ctx.addPath(CGPath(roundedRect: g, cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.fillPath()
        // Level fill.
        ctx.setFillColor(tint.withAlphaComponent(0.55).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: g.minX, y: g.minY, width: max(0, capX - g.minX), height: g.height),
                           cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.fillPath()
        // Unity tick.
        let u = x(for: Self.position(for: 0))
        ctx.setFillColor(Theme.textFaint.cgColor)
        ctx.fill(CGRect(x: u - 0.5, y: g.maxY + 2, width: 1, height: 3))
        // Cap: small machined block with a center line.
        let cap = CGRect(x: capX - 5, y: bounds.midY - 7, width: 10, height: 14)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setFillColor((tracking ? Theme.hex(0xF2F3F5) : Theme.hex(0xC9CCD2)).cgColor)
        ctx.addPath(CGPath(roundedRect: cap, cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setFillColor(Theme.hex(0x2A2D33).cgColor)
        ctx.fill(CGRect(x: capX - 0.5, y: cap.minY + 3, width: 1, height: cap.height - 6))
        if window?.firstResponder === self {
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(1)
            ctx.stroke(cap.insetBy(dx: -1.5, dy: -1.5))
        }
    }

    private func set(_ value: Float) {
        db = value
        onChange?(value)
        ValueBubble.show(Self.format(value), above: self, at: x(for: Self.position(for: value)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) || event.clickCount == 2 {
            onBegin?(); set(0); onEnd?(); ValueBubble.hide()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        tracking = true
        onBegin?()
        // Clicking the groove jumps; grabbing the cap keeps relative position.
        let pos = Self.position(for: db)
        if abs(p.x - x(for: pos)) > 8 { set(Self.db(for: Double((p.x - grooveRect.minX) / grooveRect.width))) }
        dragStart = (p.x, Self.position(for: db))
        ValueBubble.show(Self.format(db), above: self, at: x(for: Self.position(for: db)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let scale = event.modifierFlags.contains(.shift) ? 0.15 : 1.0
        set(Self.db(for: s.pos + Double((p.x - s.x) / grooveRect.width) * scale))
    }

    override func mouseUp(with event: NSEvent) {
        tracking = false
        dragStart = nil
        needsDisplay = true
        ValueBubble.hide()
        onEnd?()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 120 : event.scrollingDeltaY / 20
        guard delta != 0 else { return }
        onBegin?()
        set(Self.db(for: Self.position(for: db) + Double(delta) * 0.05))
        onEnd?()
        NSObject.cancelPreviousPerformRequests(withTarget: ValueBubble.self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ValueBubble.hide() }
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .rightArrow?, .upArrow?: step(+0.5)
        case .leftArrow?, .downArrow?: step(-0.5)
        default: super.keyDown(with: event)
        }
    }
    private func step(_ d: Float) {
        onBegin?()
        let base = db.isFinite ? db : -60
        set(min(Self.maxDb, base + d)); onEnd?(); ValueBubble.hide()
    }
    override func accessibilityPerformIncrement() -> Bool { step(+1); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-1); return true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

// MARK: - Pan knob

/// Rotary pan (270° sweep). Vertical drag; ⇧ for fine; ⌥-click or double-click centers.
@MainActor
final class PanKnob: NSControl {
    var pan: Float = 0 { didSet { needsDisplay = true; setAccessibilityValue(Self.format(pan)) } }
    var tint: NSColor = Theme.text { didSet { needsDisplay = true } }
    var onBegin: (() -> Void)?
    var onChange: ((Float) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var tracking = false
    private var dragStart: (y: CGFloat, pan: Float)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityValue(Self.format(pan))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 26, height: 26) }

    static func format(_ p: Float) -> String {
        let v = Int((abs(p) * 100).rounded())
        return v == 0 ? "C" : (p < 0 ? "L\(v)" : "R\(v)")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = min(bounds.width, bounds.height) / 2 - 2.5
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        // Angles (flipped view: y down). 0 at top, ±135°.
        func angle(_ p: Float) -> CGFloat { (-90 + CGFloat(p) * 135) * .pi / 180 }
        // Track arc.
        ctx.setLineWidth(2.5); ctx.setLineCap(.round)
        ctx.setStrokeColor(Theme.hex(0x0A0B0D).cgColor)
        ctx.addArc(center: c, radius: r, startAngle: angle(-1), endAngle: angle(1), clockwise: false); ctx.strokePath()
        // Value arc from center.
        if abs(pan) > 0.005 {
            ctx.setStrokeColor(tint.withAlphaComponent(0.85).cgColor)
            ctx.addArc(center: c, radius: r, startAngle: angle(min(0, pan)), endAngle: angle(max(0, pan)), clockwise: false)
            ctx.strokePath()
        }
        // Body.
        let body = CGRect(x: c.x - r + 3, y: c.y - r + 3, width: (r - 3) * 2, height: (r - 3) * 2)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setFillColor((tracking ? Theme.controlHi : Theme.control).cgColor)
        ctx.fillEllipse(in: body)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // Pointer.
        let a = angle(pan)
        ctx.setStrokeColor(Theme.text.cgColor); ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: c.x + cos(a) * (r - 8), y: c.y + sin(a) * (r - 8)))
        ctx.addLine(to: CGPoint(x: c.x + cos(a) * (r - 3.5), y: c.y + sin(a) * (r - 3.5)))
        ctx.strokePath()
        if window?.firstResponder === self {
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(1)
            ctx.strokeEllipse(in: bounds.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func set(_ p: Float) {
        var v = min(1, max(-1, p))
        if abs(v) < 0.02 { v = 0 } // center detent
        pan = v
        onChange?(v)
        ValueBubble.show(Self.format(v), above: self, at: bounds.midX)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onBegin?()
        if event.modifierFlags.contains(.option) || event.clickCount == 2 {
            set(0); onEnd?(); ValueBubble.hide(); return
        }
        tracking = true
        dragStart = (event.locationInWindow.y, pan)
        ValueBubble.show(Self.format(pan), above: self, at: bounds.midX)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let scale: Float = event.modifierFlags.contains(.shift) ? 0.002 : 0.012
        set(s.pan + Float(event.locationInWindow.y - s.y) * scale)
    }
    override func mouseUp(with event: NSEvent) {
        tracking = false; dragStart = nil; needsDisplay = true
        ValueBubble.hide(); onEnd?()
    }
    override func scrollWheel(with event: NSEvent) {
        let d = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 30)
        guard d != 0 else { return }
        onBegin?(); set(pan + d); onEnd?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ValueBubble.hide() }
    }
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .rightArrow?, .upArrow?: nudge(0.05)
        case .leftArrow?, .downArrow?: nudge(-0.05)
        default: super.keyDown(with: event)
        }
    }
    private func nudge(_ d: Float) { onBegin?(); set(pan + d); onEnd?(); ValueBubble.hide() }
    override func accessibilityPerformIncrement() -> Bool { nudge(0.1); return true }
    override func accessibilityPerformDecrement() -> Bool { nudge(-0.1); return true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

// MARK: - Toggle chip (Mute / Solo / later Record)

@MainActor
final class ToggleChip: NSControl {
    let letter: String
    let onColor: NSColor
    let onText: NSColor
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn ? "on" : "off") } }
    var onToggle: ((Bool) -> Void)?
    private var pressed = false

    init(_ letter: String, on: NSColor, onText: NSColor, help: String) {
        self.letter = letter
        self.onColor = on
        self.onText = onText
        super.init(frame: .zero)
        toolTip = help
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(help)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 18) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.setFillColor((isOn ? onColor : (pressed ? Theme.controlHi : Theme.control)).cgColor)
        ctx.fillPath()
        if !isOn {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.setStrokeColor(Theme.hairline.cgColor); ctx.setLineWidth(1); ctx.strokePath()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(10, .bold), .foregroundColor: isOn ? onText : Theme.textDim]
        let s = letter as NSString, size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { isOn.toggle(); onToggle?(isOn) }
        needsDisplay = true
    }
    override func accessibilityPerformPress() -> Bool { isOn.toggle(); onToggle?(isOn); return true }
}

// MARK: - Icon button (transport, toolbar)

@MainActor
final class IconButton: NSButton {
    init(_ symbol: String, help: String, size: CGFloat = 13, weight: NSFont.Weight = .semibold) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?.withSymbolConfiguration(cfg)
        contentTintColor = Theme.text
        toolTip = help
        setAccessibilityLabel(help)
        wantsLayer = true
        layer?.cornerRadius = 6
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setSymbol(_ name: String, tint: NSColor = Theme.text) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?.withSymbolConfiguration(cfg)
        contentTintColor = tint
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Theme.hex(0xFFFFFF, 0.07).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}
