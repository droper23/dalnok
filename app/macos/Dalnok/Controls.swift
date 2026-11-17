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
    private(set) var meterDb: Float = -120
    var showsMeter = false
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
        face.fillColor = Theme.controlHi.cgColor
        face.strokeColor = Theme.hex(0x000000, 0.35).cgColor
        face.lineWidth = 1
        pointer.strokeColor = Theme.hex(0xF2F3F5).cgColor
        pointer.lineWidth = 2
        pointer.lineCap = .round
        face.addSublayer(pointer)
        layer?.addSublayer(face)
        if Analog.on {
            // Discrete LED dots instead of a continuous ring (dash of zero length + round caps).
            for l in [haloTrack, haloValue] { l.lineWidth = 2.6; l.lineDashPattern = [0, 4.6] }
            haloTrack.strokeColor = Theme.hex(0xFFFFFF, 0.10).cgColor
            pointer.strokeColor = NSColor(white: 0.08, alpha: 1).cgColor
            face.fillColor = nil
            face.strokeColor = nil
            face.contentsGravity = .center
            face.contentsScale = 2
        }
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
        let showingLevel = showsMeter && meterDb > -60 && !hovering && !tracking
        let displayed = showingLevel ? Double(max(0, min(1, (meterDb + 60) / 60))) : value
        let from = bipolar ? min(0, displayed) : 0, to = bipolar ? max(0, displayed) : displayed
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
        if Analog.on { face.contents = Self.capImage(diameter: faceR * 2, hover: hovering || tracking) }
        let a = angle(value)
        let ptr = CGMutablePath()
        ptr.move(to: CGPoint(x: c.x + cos(a) * faceR * 0.28, y: c.y + sin(a) * faceR * 0.28))
        ptr.addLine(to: CGPoint(x: c.x + cos(a) * faceR * 0.78, y: c.y + sin(a) * faceR * 0.78))
        pointer.path = ptr
        CATransaction.commit()
    }

    /// Knurled aluminium cap (Warm Analog), rendered once per size and hover state.
    private static var caps: [String: CGImage] = [:]
    static func capImage(diameter d: CGFloat, hover: Bool) -> CGImage? {
        let key = "\(Int(d * 2))-\(hover)"
        if let image = caps[key] { return image }
        let px = Int(ceil(d * 2)) + 4
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        Analog.knobCap(ctx, center: CGPoint(x: CGFloat(px) / 4, y: CGFloat(px) / 4), radius: d / 2, angle: 0, hover: hover, pointer: false)
        let image = ctx.makeImage()
        caps[key] = image
        return image
    }

    private func setRevealed(_ on: Bool, animated: Bool) {
        if Analog.on {
            // Hardware: the cap never shrinks; its LED ring is always there, brighter while touched.
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            CATransaction.setAnimationDuration(Motion.standard)
            face.setAffineTransform(CGAffineTransform(scaleX: 0.66, y: 0.66))
            haloTrack.opacity = 1
            haloValue.opacity = on ? 1 : 0.8
            haloValue.shadowRadius = on ? 5 : 3
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        face.setAffineTransform(on ? CGAffineTransform(scaleX: Self.revealScale, y: Self.revealScale) : .identity)
        haloValue.opacity = on ? 1 : 0
        haloTrack.opacity = on ? 1 : 0
        face.fillColor = (on ? Theme.knobHover : Theme.controlHi).cgColor
        CATransaction.commit()
    }

    private func updateReveal() {
        let meterVisible = showsMeter && meterDb > -60 && !hovering && !tracking
        let interacting = hovering || tracking || (window?.firstResponder === self && !meterVisible)
        let color = meterVisible ? (meterDb >= 0 ? Theme.hex(0xE0574F) : meterDb >= -6 ? Theme.hex(0xE3A857) : Theme.hex(0x5FB39B)) : tint
        haloValue.strokeColor = color.cgColor
        haloValue.shadowColor = color.cgColor
        layoutLayers()
        setRevealed(interacting || meterVisible, animated: !meterVisible)
    }

    /// When playback stops, every ring falls to empty over the same time (each at its own rate) instead
    /// of at the meter's fixed dB/s, so all rings go dark together.
    static let meterReleaseSeconds: Double = 0.8
    private(set) var release: (startDb: Float, start: CFTimeInterval)?
    private var lastInputDb: Float = -120

    func transportChanged(playing: Bool) {
        release = !playing && showsMeter && meterDb > -60 ? (meterDb, CACurrentMediaTime()) : nil
    }

    func updateMeter(_ db: Float, now: CFTimeInterval = CACurrentMediaTime()) {
        defer { lastInputDb = db }
        if let r = release {
            let t = (now - r.start) / Self.meterReleaseSeconds
            // After the fall, a rising input is new signal (e.g. monitoring); a still-falling one is the old tail.
            if t >= 1 && (db <= -60 || db > lastInputDb) {
                release = nil
            } else {
                let curve = r.startDb - (r.startDb + 60) * Float(min(1, t))
                meterDb = t >= 1 ? -120 : curve
                updateReveal()
                return
            }
        }
        meterDb = db
        updateReveal()
    }

    // MARK: Animated external changes (undo, redo, scripts, automation)

    private var glideTimer: Timer?
    private var peekUntil = Date.distantPast
    /// Moves to `target` over a short ease-out glide and briefly reveals the ring, so a value that
    /// changes without the user touching the knob is visible. Instant while dragging or with Reduce Motion.
    func glide(to target: Double) {
        guard abs(target - value) > 1e-6 else { return }
        glideTimer?.invalidate()
        guard !tracking, !Motion.reduced, window != nil else { value = target; return }
        let start = value, began = Date(), duration = Motion.gentle
        peek()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let timer = self.glideTimer else { return }
                let p = min(1, Date().timeIntervalSince(began) / duration)
                let eased = 1 - pow(1 - p, 3)
                self.value = start + (target - start) * eased
                if p >= 1 { timer.invalidate(); self.glideTimer = nil }
            }
        }
        glideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    /// Shows the lit ring for a moment, then returns to the resting state.
    func peek(for seconds: Double = 0.7) {
        guard !Motion.reduced else { return }
        peekUntil = Date().addingTimeInterval(seconds)
        setRevealed(true, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, Date() >= self.peekUntil else { return }
            self.updateReveal()
        }
    }

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

/// Gain uses the same audio taper and unity detent as the original fader.
@MainActor
final class GainKnob: RotaryKnob {
    var db: Float {
        get { FaderControl.db(for: value) }
        set { value = FaderControl.position(for: newValue) }
    }
    func glide(toDb db: Float) { glide(to: FaderControl.position(for: db)) }
    var onGainChange: ((Float) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bipolar = false
        showsMeter = true
        defaultValue = FaderControl.position(for: 0)
        value = defaultValue
        format = { FaderControl.format(FaderControl.db(for: $0)) }
        onChange = { [weak self] v in self?.onGainChange?(FaderControl.db(for: v)) }
        setAccessibilityValue(format(value))
        toolTip = "Gain (dB)"
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Pan: a bipolar knob reading L/C/R.
@MainActor
final class PanKnob: RotaryKnob {
    var pan: Float {
        get { Float(value) }
        set { value = Double(newValue) }
    }
    func glide(toPan p: Float) { glide(to: Double(p)) }
    var onPanChange: ((Float) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        bipolar = true
        toolTip = "Pan (left/right)"
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
    var isOn = false {
        didSet {
            setAccessibilityValue(isOn ? "on" : "off")
            guard isOn != oldValue else { return }
            applyState(animated: true)
            if isOn { Motion.bounce(face, scale: 1.12, duration: 0.2) }
        }
    }
    /// Breathing glow (an armed track while recording).
    var pulsing = false {
        didSet {
            guard pulsing != oldValue else { return }
            let target = Analog.on ? led : glow // analog: the LED itself blinks softly
            if pulsing { Motion.pulse(target, from: Analog.on ? 1 : 0.9, to: Analog.on ? 0.35 : 0.2, period: 1.1) } else { Motion.stopPulse(target) }
            applyState(animated: true)
        }
    }
    var onToggle: ((Bool) -> Void)?
    private var pressed = false { didSet { applyState(animated: true) } }
    private var hovering = false { didSet { applyState(animated: true) } }
    private let face = CALayer(), glow = CALayer(), label = CATextLayer()
    /// Warm Analog: the state lives in an LED lens on a dark cap (the letter stays engraved on the cap).
    private let led = CALayer()
    private static var ledImages: [String: (on: CGImage, off: CGImage)] = [:]
    private static func ledImages(for color: NSColor) -> (on: CGImage, off: CGImage) {
        let key = color.description
        if let cached = ledImages[key] { return cached }
        func render(_ lit: Bool) -> CGImage {
            let size = 16
            let ctx = CGContext(data: nil, width: size * 2, height: size * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.scaleBy(x: 2, y: 2)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            Analog.led(ctx, in: CGRect(x: 4, y: 4.5, width: 7.5, height: 7.5), color: color, lit: lit)
            NSGraphicsContext.restoreGraphicsState()
            return ctx.makeImage()!
        }
        let images = (render(true), render(false))
        ledImages[key] = images
        return images
    }

    init(_ letter: String, on: NSColor, onText: NSColor, help: String) {
        self.letter = letter
        self.onColor = on
        self.onText = onText
        super.init(frame: .zero)
        toolTip = help
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(help)
        wantsLayer = true
        // Glow sits behind the face: a soft halo in the chip's on-color, like a lit console button.
        glow.cornerRadius = 5
        glow.shadowColor = on.cgColor
        glow.shadowRadius = 5
        glow.shadowOffset = .zero
        glow.shadowOpacity = 0
        glow.backgroundColor = on.withAlphaComponent(0.001).cgColor
        face.cornerRadius = 4
        face.borderWidth = 1
        label.string = letter
        label.font = Theme.ui(10, .bold)
        label.fontSize = 10
        label.alignmentMode = .center
        label.contentsScale = 2
        layer?.addSublayer(glow)
        layer?.addSublayer(face)
        face.addSublayer(label)
        if Analog.on {
            face.addSublayer(led)
            glow.isHidden = true
            label.alignmentMode = .right
        }
        layer?.masksToBounds = false
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        applyState(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: Analog.on ? 28 : 22, height: 18) }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.bounds = bounds
        face.position = CGPoint(x: bounds.midX, y: bounds.midY)
        glow.frame = bounds
        label.frame = Analog.on ? CGRect(x: 0, y: (bounds.height - 13) / 2, width: bounds.width - 5, height: 13)
                                : CGRect(x: 0, y: (bounds.height - 13) / 2, width: bounds.width, height: 13)
        led.frame = CGRect(x: -1, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    private func applyState(animated: Bool) {
        if Analog.on {
            let images = Self.ledImages(for: onColor)
            let body = { [self] in
                // Dark machined cap; the LED carries the state, so the cap never changes color.
                face.backgroundColor = (pressed ? NSColor(white: 0.10, alpha: 1) : hovering ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.15, alpha: 1)).cgColor
                face.borderColor = NSColor(white: 0, alpha: 0.8).cgColor
                face.shadowColor = NSColor.black.cgColor
                face.shadowOpacity = pressed ? 0.1 : 0.6
                face.shadowRadius = 1
                face.shadowOffset = CGSize(width: 0, height: pressed ? -0.5 : -1.5)
                label.foregroundColor = (isOn ? Theme.text : Theme.textDim).cgColor
                led.contents = isOn ? images.on : images.off
                face.transform = pressed ? CATransform3DMakeTranslation(0, 1, 0) : CATransform3DIdentity
            }
            if animated { Motion.layers(Motion.quick, body) } else { CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit() }
            return
        }
        let body = { [self] in
            face.backgroundColor = (isOn ? onColor : (pressed ? Theme.controlHi : (hovering ? Theme.knobHover : Theme.control))).cgColor
            face.borderColor = (isOn ? NSColor.clear : Theme.hairline).cgColor
            label.foregroundColor = (isOn ? onText : (hovering ? Theme.text : Theme.textDim)).cgColor
            glow.shadowOpacity = isOn ? (pulsing ? 0.9 : 0.45) : 0
            face.transform = pressed ? CATransform3DMakeScale(0.9, 0.9, 1) : CATransform3DIdentity
        }
        if animated { Motion.layers(Motion.quick, body) } else { CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit() }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { isOn.toggle(); onToggle?(isOn) }
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
    override func mouseEntered(with event: NSEvent) { Motion.layers(Motion.quick) { layer?.backgroundColor = Theme.hex(0xFFFFFF, 0.07).cgColor } }
    override func mouseExited(with event: NSEvent) { Motion.layers(Motion.standard) { layer?.backgroundColor = NSColor.clear.cgColor } }
    override func mouseDown(with event: NSEvent) {
        Motion.centerAnchor(layer)
        Motion.layers(Motion.quick) { layer?.transform = CATransform3DMakeScale(0.9, 0.9, 1) }
        super.mouseDown(with: event) // runs the tracking loop and the action
        Motion.layers(Motion.standard) { layer?.transform = CATransform3DIdentity }
    }
}
