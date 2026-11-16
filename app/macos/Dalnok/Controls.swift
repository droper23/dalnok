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

// MARK: - Rotary knob

/// Flat rotary knob (Valhalla-style minimalism: solid face, bold pointer, no
/// skeuomorphic gradients). On hover, drag or keyboard focus the face shrinks
/// to reveal a glowing value ring underneath, like the halo LEDs on a Scarlett
/// 4th-gen gain knob. Layer-based so the reveal animates smoothly.
/// Vertical drag; ⇧ for fine; ⌥-click or double-click resets; scroll; arrows.
@MainActor
class RotaryKnob: NSControl {
    /// Normalized value: −1…1 when `bipolar`, else 0…1.
    var value: Double = 0 { didSet { layoutLayers(); setAccessibilityValue(format(value)) } }
    var bipolar = true
    var defaultValue: Double = 0
    var tint: NSColor = Theme.accent { didSet { haloValue.strokeColor = tint.cgColor; haloValue.shadowColor = tint.cgColor } }
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var onBegin: (() -> Void)?
    var onChange: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var tracking = false
    private var hovering = false
    private var dragStart: (y: CGFloat, value: Double)?

    private let haloTrack = CAShapeLayer()
    private let haloValue = CAShapeLayer()
    private let face = CAShapeLayer()
    private let pointer = CAShapeLayer()
    static let revealScale: CGFloat = 0.68

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [haloTrack, haloValue] {
            l.fillColor = nil
            l.lineWidth = 3
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        haloTrack.strokeColor = Theme.hex(0xFFFFFF, 0.08).cgColor
        haloValue.strokeColor = tint.cgColor
        haloValue.shadowColor = tint.cgColor
        haloValue.shadowRadius = 4
        haloValue.shadowOpacity = 0.9
        haloValue.shadowOffset = .zero
        face.fillColor = Theme.hex(0x3A3E46).cgColor
        face.strokeColor = Theme.hex(0x000000, 0.35).cgColor
        face.lineWidth = 1
        pointer.strokeColor = Theme.hex(0xF2F3F5).cgColor
        pointer.lineWidth = 2
        pointer.lineCap = .round
        face.addSublayer(pointer)
        layer?.addSublayer(face)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        setRevealed(false, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 30) }

    // Angles in the flipped view: −90° points up; the sweep is ±135° around it.
    private func angle(_ v: Double) -> CGFloat {
        let n = bipolar ? v : v * 2 - 1
        return (-90 + CGFloat(n) * 135) * .pi / 180
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        let r = min(bounds.width, bounds.height) / 2
        guard r > 4 else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ringR = r - 2.5
        let track = CGMutablePath()
        track.addArc(center: c, radius: ringR, startAngle: angle(bipolar ? -1 : 0), endAngle: angle(1), clockwise: false)
        haloTrack.path = track
        let from = bipolar ? min(0, value) : 0, to = bipolar ? max(0, value) : value
        let arc = CGMutablePath()
        if abs(to - from) > 0.004 {
            arc.addArc(center: c, radius: ringR, startAngle: angle(from), endAngle: angle(to), clockwise: false)
        } else {
            // A lit dot at the center position, so "centered" is visible too.
            arc.addArc(center: c, radius: ringR, startAngle: angle(from) - 0.04, endAngle: angle(from) + 0.04, clockwise: false)
        }
        haloValue.path = arc
        // Face covers the ring at rest (scale 1); scales around its center.
        face.bounds = bounds
        face.position = c
        let faceR = r - 0.5
        face.path = CGPath(ellipseIn: CGRect(x: c.x - faceR, y: c.y - faceR, width: faceR * 2, height: faceR * 2), transform: nil)
        let a = angle(value)
        let ptr = CGMutablePath()
        ptr.move(to: CGPoint(x: c.x + cos(a) * faceR * 0.28, y: c.y + sin(a) * faceR * 0.28))
        ptr.addLine(to: CGPoint(x: c.x + cos(a) * faceR * 0.78, y: c.y + sin(a) * faceR * 0.78))
        pointer.path = ptr
        CATransaction.commit()
    }

    private func setRevealed(_ on: Bool, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        face.setAffineTransform(on ? CGAffineTransform(scaleX: Self.revealScale, y: Self.revealScale) : .identity)
        haloValue.opacity = on ? 1 : 0
        haloTrack.opacity = on ? 1 : 0
        face.fillColor = (on ? Theme.hex(0x44484F) : Theme.hex(0x3A3E46)).cgColor
        CATransaction.commit()
    }

    private func updateReveal() { setRevealed(hovering || tracking || window?.firstResponder === self, animated: true) }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateReveal() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateReveal() }

    private func set(_ v: Double) {
        var x = min(1, max(bipolar ? -1 : 0, v))
        if abs(x - defaultValue) < 0.02 { x = defaultValue } // detent
        value = x
        onChange?(x)
        ValueBubble.show(format(x), above: self, at: bounds.midX)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onBegin?()
        if event.modifierFlags.contains(.option) || event.clickCount == 2 {
            set(defaultValue); onEnd?(); ValueBubble.hide(); return
        }
        tracking = true
        updateReveal()
        dragStart = (event.locationInWindow.y, value)
        ValueBubble.show(format(value), above: self, at: bounds.midX)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let range = bipolar ? 2.0 : 1.0
        let perPoint = (event.modifierFlags.contains(.shift) ? 0.001 : 0.006) * range
        set(s.value + Double(event.locationInWindow.y - s.y) * perPoint)
    }
    override func mouseUp(with event: NSEvent) {
        tracking = false
        dragStart = nil
        hovering = bounds.contains(convert(event.locationInWindow, from: nil))
        updateReveal()
        ValueBubble.hide()
        onEnd?()
    }
    override func scrollWheel(with event: NSEvent) {
        let d = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 30)
        guard d != 0 else { return }
        onBegin?(); set(value + d * (bipolar ? 1 : 0.5)); onEnd?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { ValueBubble.hide() }
    }
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .rightArrow?, .upArrow?: nudge(0.05)
        case .leftArrow?, .downArrow?: nudge(-0.05)
        default: super.keyDown(with: event)
        }
    }
    private func nudge(_ d: Double) { onBegin?(); set(value + d); onEnd?(); ValueBubble.hide() }
    override func accessibilityPerformIncrement() -> Bool { nudge(0.1); return true }
    override func accessibilityPerformDecrement() -> Bool { nudge(-0.1); return true }
    override func becomeFirstResponder() -> Bool { DispatchQueue.main.async { self.updateReveal() }; return true }
    override func resignFirstResponder() -> Bool { DispatchQueue.main.async { self.updateReveal() }; return true }
    /// For screenshots/tests: show the revealed state without a mouse.
    func previewReveal(_ on: Bool) { hovering = on; updateReveal() }
}

/// Pan: a bipolar knob reading L/C/R.
@MainActor
final class PanKnob: RotaryKnob {
    var pan: Float {
        get { Float(value) }
        set { value = Double(newValue) }
    }
    var onPanChange: ((Float) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bipolar = true
        format = PanKnob.format
        onChange = { [weak self] v in self?.onPanChange?(Float(v)) }
        setAccessibilityValue(format(value))
    }
    required init?(coder: NSCoder) { fatalError() }

    static func format(_ p: Double) -> String {
        let v = Int((abs(p) * 100).rounded())
        return v == 0 ? "C" : (p < 0 ? "L\(v)" : "R\(v)")
    }
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
