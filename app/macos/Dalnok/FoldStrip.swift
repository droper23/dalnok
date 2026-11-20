// A folded unit in the device chain (dalnok_plugin_set_folded): a narrow strip that keeps the unit's name, its
// on/off state and (Graphite) its output level in view, so a long chain fits the panel.
// Graphite: a slim rack blank with the name engraved upright, a power lamp and a level column.
// Warm Analog: the stomp box turned onto its side edge, as pedals are stood up at the back of a crowded board:
// the enclosure's edge in its own colour and finish, the name stencilled along it, the input jack and the LED.
// The on/off switch stays usable while folded: Graphite's power lamp and Warm Analog's footswitch at the top of the
// strip toggle bypass (the same undoable engine edit as the unfolded unit). Clicking anywhere else unfolds the unit;
// right-click gives the unit's menu.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

final class FoldStrip: NSView {
    static var width: CGFloat { Analog.on ? 44 : 34 }
    var name: String { didSet { needsDisplay = true; setAccessibilityLabel("\(name), folded") } }
    var engaged = true { didSet { if engaged != oldValue { needsDisplay = true; power.setAccessibilityValue(engaged ? "on" : "bypassed") } } }
    var loaded = true { didSet { needsDisplay = true; power.isEnabled = onToggle != nil && loaded } }
    /// Output level 0…1 (Graphite), smoothed by the caller's meter polling.
    var level: CGFloat = 0 { didSet { if abs(level - oldValue) > 0.004 { needsDisplay = true } } }
    var look: PedalLook?
    var onUnfold: (() -> Void)?
    var onToggle: (() -> Void)? { didSet { power.isEnabled = onToggle != nil && loaded } }
    var menuProvider: (() -> NSMenu?)?
    /// The on/off switch (transparent: the strip draws the lamp or footswitch under it).
    let power = NSButton(title: "", target: nil, action: nil)
    /// Where the on/off switch sits (strip coordinates, y up).
    var powerRect: CGRect {
        let r = bounds
        return Analog.on ? CGRect(x: r.midX - 16, y: r.maxY - 52, width: 32, height: 48) : CGRect(x: r.midX - 13, y: r.maxY - 38, width: 26, height: 26)
    }

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        power.isBordered = false
        power.isTransparent = true
        power.target = self
        power.action = #selector(powerPressed)
        power.setAccessibilityLabel("On/Off: \(name)")
        power.toolTip = "On/Off: bypass \(name) (undoable)"
        addSubview(power)
        toolTip = "\(name) (folded). Click to unfold."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(name), folded")
        setAccessibilityHelp("Unfolds the plug-in")
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func powerPressed() { onToggle?() }
    override func layout() {
        super.layout()
        power.frame = powerRect
    }
    override func accessibilityPerformPress() -> Bool { onUnfold?(); return true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p), !powerRect.contains(p) { onUnfold?() }
    }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if Analog.on, let look { drawPedalEdge(ctx, look) } else { drawRackBlank(ctx) }
    }

    /// The name set upright along the strip, reading bottom to top, truncated to fit.
    private func drawUpright(_ ctx: CGContext, text: String, attrs: [NSAttributedString.Key: Any], centerX: CGFloat, from y0: CGFloat, to y1: CGFloat) {
        var s = text
        var str = NSAttributedString(string: s, attributes: attrs)
        let room = max(0, y1 - y0)
        while str.size().width > room, s.count > 1 {
            s = String(s.dropLast(2)) + "…"
            str = NSAttributedString(string: s, attributes: attrs)
        }
        ctx.saveGState()
        ctx.translateBy(x: centerX + str.size().height / 2 - 2, y: y0 + (room - str.size().width) / 2)
        ctx.rotate(by: .pi / 2)
        NSGraphicsContext.saveGraphicsState()
        str.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private func drawRackBlank(_ ctx: CGContext) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        let top = Theme.hex(0x3A3D44), bottom = Theme.hex(0x26282D)
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
        ctx.resetClip()
        ctx.addPath(path)
        ctx.setStrokeColor(Theme.hairline.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        Faceplate.screw(ctx, CGPoint(x: r.midX, y: r.minY + 8))
        // Power key at the top: a recessed round key whose ring lights while the unit is on.
        let key = powerRect.insetBy(dx: 2, dy: 2)
        let lamp = key
        let lit = engaged && loaded
        ctx.setFillColor(Theme.hex(0x17191D).cgColor)
        ctx.fillEllipse(in: key)
        ctx.setStrokeColor((lit ? Theme.accent : Theme.hex(0x50545C)).cgColor)
        ctx.setLineWidth(1.6)
        if lit { ctx.setShadow(offset: .zero, blur: 6, color: Theme.accent.withAlphaComponent(0.8).cgColor) }
        let c = CGPoint(x: key.midX, y: key.midY), rad = key.width * 0.24
        ctx.addArc(center: c, radius: rad, startAngle: .pi * 0.62, endAngle: .pi * 0.38, clockwise: false) // ⏻
        ctx.move(to: CGPoint(x: c.x, y: c.y + rad * 0.15)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + rad * 1.25))
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // Level column at the bottom (12 segments).
        let column = CGRect(x: r.midX - 3, y: r.minY + 18, width: 6, height: 54)
        let segments = 12, seg = column.height / CGFloat(segments)
        for i in 0..<segments {
            let on = lit && CGFloat(i + 1) / CGFloat(segments) <= level + 0.001
            let hue: NSColor = i >= 10 ? Theme.hex(0xFF5A4A) : i >= 8 ? Theme.hex(0xFFC24A) : Theme.hex(0x55D17A)
            ctx.setFillColor((on ? hue : hue.withAlphaComponent(0.13)).cgColor)
            ctx.fill(CGRect(x: column.minX, y: column.minY + CGFloat(i) * seg + 0.5, width: column.width, height: seg - 1))
        }
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.7); shadow.shadowOffset = NSSize(width: 0, height: -1)
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(11, .semibold),
                                                    .foregroundColor: loaded ? (lit ? Faceplate.engraving : Theme.textFaint) : Theme.textFaint,
                                                    .shadow: shadow]
        drawUpright(ctx, text: name, attrs: attrs, centerX: r.midX, from: column.maxY + 8, to: lamp.minY - 8)
    }

    private func drawPedalEdge(_ ctx: CGContext, _ look: PedalLook) {
        // The enclosure's edge: a narrow box whose face catches the light along its top bevel.
        let r = bounds.insetBy(dx: 3, dy: 2)
        let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 2, height: -3), blur: 6, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(look.color.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // Bevel light on the left (the board's lamp), shade on the right where the face turns away.
        let light = look.color.blended(withFraction: 0.35, of: .white) ?? look.color
        let shade = look.color.blended(withFraction: 0.45, of: .black) ?? look.color
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [light.cgColor, look.color.cgColor, shade.cgColor] as CFArray,
                           locations: [0, 0.35, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: 0), end: CGPoint(x: r.maxX, y: 0), options: [])
        if look.finish == .hammertone || look.finish == .sparkle {
            var rng = PedalRandom(name)
            for _ in 0..<Int(r.width * r.height / 18) {
                let p = CGPoint(x: rng.range(r.minX, r.maxX), y: rng.range(r.minY, r.maxY))
                ctx.setFillColor(NSColor.white.withAlphaComponent(look.finish == .sparkle ? 0.35 : 0.08).cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x, y: p.y, width: 1.2, height: 1.2))
            }
        }
        ctx.restoreGState()
        // The LED, seen edge-on at the top, and the input jack low on the side.
        let lit = engaged && loaded
        let led = CGRect(x: r.midX - 3.5, y: r.maxY - 12, width: 7, height: 7)
        ctx.setFillColor((lit ? look.ledColor : (look.ledColor.blended(withFraction: 0.75, of: .black) ?? .black)).cgColor)
        if lit { ctx.setShadow(offset: .zero, blur: 8, color: look.ledColor.cgColor) }
        ctx.fillEllipse(in: led)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // The footswitch, still reachable on the folded pedal: a chrome cap seen from above.
        let cap = CGRect(x: r.midX - 11, y: led.minY - 30, width: 22, height: 22)
        let chrome = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                colors: [NSColor(white: 0.95, alpha: 1).cgColor, NSColor(white: 0.55, alpha: 1).cgColor, NSColor(white: 0.8, alpha: 1).cgColor] as CFArray,
                                locations: [0, 0.6, 1])!
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 2.5, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setFillColor(NSColor(white: 0.35, alpha: 1).cgColor)
        ctx.fillEllipse(in: cap)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: cap.insetBy(dx: 2.5, dy: 2.5))
        ctx.clip()
        ctx.drawRadialGradient(chrome, startCenter: CGPoint(x: cap.midX - 3, y: cap.midY + 3), startRadius: 0,
                               endCenter: CGPoint(x: cap.midX, y: cap.midY), endRadius: cap.width / 2, options: [])
        ctx.restoreGState()
        Analog.jack(ctx, at: CGPoint(x: r.midX, y: r.minY + 14), radius: 6)
        let attrs: [NSAttributedString.Key: Any] = [.font: look.letterFont(12), .foregroundColor: loaded ? look.ink : look.ink.withAlphaComponent(0.4),
                                                    .kern: 1.2]
        drawUpright(ctx, text: name.uppercased(), attrs: attrs, centerX: r.midX, from: r.minY + 28, to: cap.minY - 6)
    }
}
