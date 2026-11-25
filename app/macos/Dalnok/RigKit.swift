// Hardware drawing for the guitar plug-ins' editors: procedural tolex, grille cloth, brushed and painted metal, screws,
// lamps, jacks and cables, plus the controls that sit on them (knobs in several hardware styles, footswitches).
// Everything is drawn here from shapes and seeded noise: no bitmaps, nothing taken from any product.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
enum RigPaint {
    nonisolated static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    static func font(_ names: [String], _ size: CGFloat, fallback: NSFont.Weight = .heavy) -> NSFont {
        for n in names { if let f = NSFont(name: n, size: size) { return f } }
        return .systemFont(ofSize: size, weight: fallback)
    }

    /// Seeded grey noise (the same every run, so snapshots compare).
    static let noise: CGImage = {
        let n = 256
        var seed: UInt32 = 0x9E3779B9
        var bytes = [UInt8](repeating: 0, count: n * n)
        for i in bytes.indices { seed = seed &* 1664525 &+ 1013904223; bytes[i] = UInt8(truncatingIfNeeded: seed >> 24) }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }()
    /// Noise over `rect` (clipped to `path` when given): `scale` stretches the grain, `blend` mixes it in.
    static func grain(_ ctx: CGContext, _ rect: CGRect, path: CGPath? = nil, alpha: CGFloat, scale: CGSize = CGSize(width: 1, height: 1),
                      blend: CGBlendMode = .overlay) {
        ctx.saveGState()
        if let path { ctx.addPath(path); ctx.clip() } else { ctx.clip(to: rect) }
        ctx.setAlpha(alpha)
        ctx.setBlendMode(blend)
        let tile = CGSize(width: 256 * scale.width, height: 256 * scale.height)
        var y = rect.minY
        while y < rect.maxY {
            var x = rect.minX
            while x < rect.maxX { ctx.draw(noise, in: CGRect(origin: CGPoint(x: x, y: y), size: tile)); x += tile.width }
            y += tile.height
        }
        ctx.restoreGState()
    }

    static func gradient(_ colors: [NSColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: locations)!
    }
    static func vertical(_ ctx: CGContext, _ path: CGPath, _ colors: [NSColor], _ locations: [CGFloat]? = nil) {
        let r = path.boundingBox
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient(colors, locations), start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        ctx.restoreGState()
    }
    static func radial(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ colors: [NSColor], focus: CGPoint? = nil) {
        ctx.drawRadialGradient(gradient(colors), startCenter: focus ?? c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }
    static func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
    }

    /// A soft contact shadow under a unit standing on the floor.
    static func floorShadow(_ ctx: CGContext, _ r: CGRect) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.fillEllipse(in: CGRect(x: r.minX + 6, y: r.maxY - 10, width: r.width - 12, height: 14))
        ctx.restoreGState()
    }

    /// Vinyl covering: the base colour, a pebbled grain, a sheen from above and darker edges.
    static func tolex(_ ctx: CGContext, _ path: CGPath, _ base: NSColor) {
        let r = path.boundingBox
        ctx.saveGState(); ctx.addPath(path); ctx.setFillColor(base.cgColor); ctx.fillPath(); ctx.restoreGState()
        grain(ctx, r, path: path, alpha: 0.55, scale: CGSize(width: 0.5, height: 0.5), blend: .softLight)
        grain(ctx, r, path: path, alpha: 0.35, scale: CGSize(width: 1.6, height: 1.6), blend: .multiply)
        vertical(ctx, path, [.white.withAlphaComponent(0.16), .clear, .black.withAlphaComponent(0.28)], [0, 0.35, 1])
        innerEdge(ctx, path, dark: 0.55)
    }
    /// An inner shadow along a shape's edge (depth without a stroke).
    static func innerEdge(_ ctx: CGContext, _ path: CGPath, dark: CGFloat, blur: CGFloat = 6) {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setShadow(offset: .zero, blur: blur, color: NSColor.black.withAlphaComponent(dark).cgColor)
        ctx.setStrokeColor(NSColor.black.cgColor); ctx.setLineWidth(blur)
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
    }
    /// Woven grille cloth: two crossing thread directions and a slub of noise.
    static func grille(_ ctx: CGContext, _ path: CGPath, base: NSColor, thread: NSColor, pitch: CGFloat = 3.2) {
        let r = path.boundingBox
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.setFillColor(base.cgColor); ctx.fill(r)
        ctx.setLineWidth(pitch * 0.42)
        for (dir, a) in [(1.0, 0.55), (-1.0, 0.35)] as [(CGFloat, CGFloat)] {
            ctx.setStrokeColor(thread.withAlphaComponent(a).cgColor)
            var x = r.minX - r.height
            while x < r.maxX + r.height {
                ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x + dir * r.height, y: r.maxY))
                x += pitch
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
        grain(ctx, r, path: path, alpha: 0.45, scale: CGSize(width: 2, height: 0.6), blend: .softLight)
        vertical(ctx, path, [.white.withAlphaComponent(0.08), .clear, .black.withAlphaComponent(0.35)], [0, 0.4, 1])
        innerEdge(ctx, path, dark: 0.8, blur: 8)
    }
    /// Expanded steel mesh (a modern grille).
    static func mesh(_ ctx: CGContext, _ path: CGPath, base: NSColor) {
        let r = path.boundingBox
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(r)
        let w: CGFloat = 9, h: CGFloat = 5
        var row = 0
        var y = r.minY
        while y < r.maxY + h {
            var x = r.minX - (row % 2 == 0 ? 0 : w / 2)
            while x < r.maxX + w {
                let d = CGMutablePath()
                d.move(to: CGPoint(x: x, y: y)); d.addLine(to: CGPoint(x: x + w / 2, y: y + h / 2))
                d.addLine(to: CGPoint(x: x, y: y + h)); d.addLine(to: CGPoint(x: x - w / 2, y: y + h / 2)); d.closeSubpath()
                ctx.addPath(d)
                x += w
            }
            y += h / 2; row += 1
        }
        ctx.setStrokeColor(base.cgColor); ctx.setLineWidth(1.3); ctx.strokePath()
        ctx.restoreGState()
        vertical(ctx, path, [.white.withAlphaComponent(0.12), .clear, .black.withAlphaComponent(0.4)], [0, 0.4, 1])
        innerEdge(ctx, path, dark: 0.85, blur: 8)
    }
    /// Brushed metal: horizontal streaks over a soft vertical sheen.
    static func brushed(_ ctx: CGContext, _ path: CGPath, _ base: NSColor, streak: CGFloat = 0.5) {
        let r = path.boundingBox
        ctx.saveGState(); ctx.addPath(path); ctx.setFillColor(base.cgColor); ctx.fillPath(); ctx.restoreGState()
        grain(ctx, r, path: path, alpha: streak, scale: CGSize(width: 12, height: 0.35), blend: .overlay)
        vertical(ctx, path, [.white.withAlphaComponent(0.35), .white.withAlphaComponent(0.05), .black.withAlphaComponent(0.18), .white.withAlphaComponent(0.1)],
                 [0, 0.45, 0.8, 1])
    }
    /// A painted enclosure: base colour with a gloss, sparkle, hammertone or matte finish.
    enum Finish { case gloss, sparkle, hammertone, matte }
    static func paint(_ ctx: CGContext, _ path: CGPath, _ base: NSColor, _ finish: Finish) {
        let r = path.boundingBox
        ctx.saveGState(); ctx.addPath(path); ctx.setFillColor(base.cgColor); ctx.fillPath(); ctx.restoreGState()
        switch finish {
        case .gloss: grain(ctx, r, path: path, alpha: 0.08, blend: .overlay)
        case .sparkle:
            grain(ctx, r, path: path, alpha: 0.5, scale: CGSize(width: 0.35, height: 0.35), blend: .colorDodge)
            grain(ctx, r, path: path, alpha: 0.2, blend: .overlay)
        case .hammertone:
            grain(ctx, r, path: path, alpha: 0.7, scale: CGSize(width: 3, height: 3), blend: .softLight)
            grain(ctx, r, path: path, alpha: 0.45, scale: CGSize(width: 1.2, height: 1.2), blend: .overlay)
        case .matte: grain(ctx, r, path: path, alpha: 0.3, scale: CGSize(width: 0.5, height: 0.5), blend: .softLight)
        }
        let gloss: CGFloat = finish == .matte ? 0.06 : 0.22
        vertical(ctx, path, [.white.withAlphaComponent(gloss), .white.withAlphaComponent(gloss * 0.2), .clear, .black.withAlphaComponent(0.25)],
                 [0, 0.18, 0.6, 1])
    }
    /// A bevelled edge: light along the top-left, shadow along the bottom-right.
    static func bevel(_ ctx: CGContext, _ path: CGPath, width: CGFloat = 1.5) {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.translateBy(x: width * 0.5, y: width * 0.5)
        ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(width * 2); ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.translateBy(x: -width * 0.5, y: -width * 0.5)
        ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(width * 2); ctx.strokePath()
        ctx.restoreGState()
    }

    static func screw(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, angle: CGFloat = 0.6, phillips: Bool = true) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 1.5, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.setFillColor(hex(0x8d9196).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
        radial(ctx, c, r, [hex(0xf2f4f6), hex(0xa5aab0), hex(0x5d6166)], focus: CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.4))
        ctx.restoreGState()
        ctx.setStrokeColor(hex(0x2b2d30, 0.85).cgColor); ctx.setLineWidth(r * 0.28); ctx.setLineCap(.round)
        for a in phillips ? [angle, angle + .pi / 2] : [angle] {
            ctx.move(to: CGPoint(x: c.x + cos(a) * r * 0.62, y: c.y + sin(a) * r * 0.62))
            ctx.addLine(to: CGPoint(x: c.x - cos(a) * r * 0.62, y: c.y - sin(a) * r * 0.62))
        }
        ctx.strokePath()
    }
    /// A status LED in a chrome bezel; lit ones glow.
    static func led(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: NSColor, lit: Bool) {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r * 1.55, y: c.y - r * 1.55, width: r * 3.1, height: r * 3.1)); ctx.clip()
        radial(ctx, c, r * 1.55, [hex(0xe9ebed), hex(0x7b7f84), hex(0x2a2c2f)], focus: CGPoint(x: c.x - r * 0.6, y: c.y - r * 0.6))
        ctx.restoreGState()
        if lit {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: r * 5, color: color.cgColor)
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.setFillColor(color.cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
        let off = color.blended(withFraction: 0.75, of: .black) ?? .black
        radial(ctx, c, r, lit ? [.white, color, color.blended(withFraction: 0.3, of: .black) ?? color] : [off.blended(withFraction: 0.3, of: .white) ?? off, off, .black],
               focus: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.35))
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(lit ? 0.85 : 0.35).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r * 0.55, y: c.y - r * 0.65, width: r * 0.5, height: r * 0.4))
    }
    /// A faceted pilot-lamp jewel.
    static func jewel(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: NSColor, lit: Bool) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addEllipse(in: CGRect(x: c.x - r * 1.3, y: c.y - r * 1.3, width: r * 2.6, height: r * 2.6)); ctx.setFillColor(hex(0xb9bdc2).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r * 1.3, y: c.y - r * 1.3, width: r * 2.6, height: r * 2.6)); ctx.clip()
        radial(ctx, c, r * 1.3, [hex(0xffffff), hex(0x9aa0a6), hex(0x44484d)], focus: CGPoint(x: c.x - r, y: c.y - r))
        ctx.restoreGState()
        if lit {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: r * 4, color: color.cgColor)
            ctx.setFillColor(color.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
        }
        let body = lit ? color : (color.blended(withFraction: 0.7, of: .black) ?? color)
        for k in 0..<8 { // facets
            let a0 = CGFloat(k) * .pi / 4, a1 = a0 + .pi / 4
            let f = CGMutablePath()
            f.move(to: c)
            f.addLine(to: CGPoint(x: c.x + cos(a0) * r, y: c.y + sin(a0) * r))
            f.addLine(to: CGPoint(x: c.x + cos(a1) * r, y: c.y + sin(a1) * r))
            f.closeSubpath()
            let shade = 0.55 + 0.45 * (0.5 + 0.5 * sin(a0 * 1.7 + 1))
            ctx.addPath(f)
            ctx.setFillColor((body.blended(withFraction: 1 - shade, of: .black) ?? body).cgColor)
            ctx.fillPath()
        }
        ctx.setFillColor(NSColor.white.withAlphaComponent(lit ? 0.9 : 0.45).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r * 0.5, y: c.y - r * 0.6, width: r * 0.45, height: r * 0.35))
    }
    /// A 1/4" jack's nut and washer on a side or face.
    static func jack(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat) {
        let hexPath = CGMutablePath()
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            k == 0 ? hexPath.move(to: p) : hexPath.addLine(to: p)
        }
        hexPath.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(hexPath); ctx.setFillColor(hex(0xb7bbc0).cgColor); ctx.fillPath()
        ctx.restoreGState()
        vertical(ctx, hexPath, [hex(0xf4f5f6), hex(0x8b9096), hex(0x5f6368)])
        ctx.setFillColor(NSColor.black.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45, width: r * 0.9, height: r * 0.9))
    }

    /// Text set on a panel. `emboss` adds a highlight under it, as if printed into the surface.
    static func text(_ s: String, _ rect: CGRect, font: NSFont, color: NSColor, align: NSTextAlignment = .center, kern: CGFloat = 0,
                     emboss: CGFloat = 0, glow: NSColor? = nil) {
        let para = NSMutableParagraphStyle(); para.alignment = align; para.lineBreakMode = .byClipping
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para, .kern: kern]
        let h = (s as NSString).size(withAttributes: attrs).height
        let r = CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h + 2)
        if emboss > 0 {
            var e = attrs; e[.foregroundColor] = NSColor.white.withAlphaComponent(emboss)
            (s as NSString).draw(in: r.offsetBy(dx: 0, dy: 1), withAttributes: e)
        }
        if let glow {
            let shadow = NSShadow(); shadow.shadowColor = glow; shadow.shadowBlurRadius = font.pointSize * 0.5
            attrs[.shadow] = shadow
        }
        (s as NSString).draw(in: r, withAttributes: attrs)
    }

    /// A patch cable lying on the floor between two jacks, with its plugs.
    static func cable(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, floor: CGFloat, color: NSColor) {
        let p = CGMutablePath()
        p.move(to: a)
        let sag = max(floor, max(a.y, b.y) + 24)
        p.addCurve(to: b, control1: CGPoint(x: a.x + 40, y: sag + 18), control2: CGPoint(x: b.x - 40, y: sag + 18))
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 6, color: NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.addPath(p); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(6.5); ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -1.4)
        ctx.addPath(p); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(1.6); ctx.setLineCap(.round); ctx.strokePath()
        ctx.restoreGState()
        for (pt, dir) in [(a, CGFloat(1)), (b, CGFloat(-1))] { // right-angle plugs: a chrome barrel and a strain relief
            let barrel = CGRect(x: dir > 0 ? pt.x : pt.x - 16, y: pt.y - 5.5, width: 16, height: 11)
            let path = rounded(barrel, 2.5)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: NSColor.black.withAlphaComponent(0.7).cgColor)
            ctx.addPath(path); ctx.setFillColor(hex(0x9da2a8).cgColor); ctx.fillPath()
            ctx.restoreGState()
            vertical(ctx, path, [hex(0x6f7378), hex(0xf6f7f8), hex(0xa4a9ae), hex(0x4f5357)], [0, 0.3, 0.6, 1])
            let boot = CGRect(x: dir > 0 ? pt.x + 15 : pt.x - 23, y: pt.y - 4, width: 8, height: 8)
            vertical(ctx, rounded(boot, 2), [hex(0x3a3a3c), hex(0x111112)])
        }
    }
}

/// A hardware knob, its silkscreened name below. Drag up/down (⇧ for fine), scroll, double-click or ⌥-click for
/// the default. While dragged or hovered it shows the plug-in's own text for the value in place of its name.
@MainActor
final class RigKnob: NSView {
    enum Style {
        /// A pointer-shaped bakelite knob.
        case chicken(NSColor)
        /// A domed cap over a metal or coloured skirt.
        case skirted(cap: NSColor, skirt: NSColor)
        /// Machined aluminium with a knurled edge.
        case knurled(NSColor)
        /// Ribbed black plastic with a white line.
        case ribbed(NSColor)
    }
    enum Scale { case none, dots, numbers }
    let style: Style
    let diameter: CGFloat
    var scale: Scale = .none
    var name: String
    var labelColor = NSColor.white
    var labelFont: NSFont = RigPaint.font(["Futura-Bold"], 9)
    var value: Double = 0 { didSet { if value != oldValue { needsDisplay = true } } }
    var defaultValue: Double = 0.5
    /// Positions for a switch-like knob (0 = continuous).
    var steps = 0
    var valueText: () -> String = { "" }
    var onChange: ((Double) -> Void)?
    private(set) var dragging = false
    private var hovering = false
    private var dragStart: (y: CGFloat, value: Double)?

    static func size(_ diameter: CGFloat, scale: Scale) -> CGSize {
        let ring = scale == .numbers ? diameter * 1.55 : diameter * 1.3
        return CGSize(width: max(ring, 54), height: ring + 15)
    }
    init(diameter: CGFloat, style: Style, name: String, scale: Scale = .none) {
        self.diameter = diameter
        self.style = style
        self.name = name
        self.scale = scale
        super.init(frame: CGRect(origin: .zero, size: Self.size(diameter, scale: scale)))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Puts the knob's centre at `p` in the superview's coordinates.
    func place(_ p: CGPoint) {
        let s = Self.size(diameter, scale: scale)
        frame = CGRect(x: p.x - s.width / 2, y: p.y - (s.height - 15) / 2, width: s.width, height: s.height)
    }
    private var center: CGPoint { CGPoint(x: bounds.midX, y: (bounds.height - 15) / 2) }
    private func angle(_ v: Double) -> CGFloat { CGFloat(-0.75 * .pi + 1.5 * .pi * v) } // clockwise from straight up

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = center, r = diameter / 2
        drawScale(ctx, c, r)
        drawKnob(ctx, c, r, angle(value))
        let showValue = dragging || hovering
        let text = showValue ? valueText() : name.uppercased()
        RigPaint.text(text, CGRect(x: -6, y: bounds.height - 14, width: bounds.width + 12, height: 13), font: labelFont,
                      color: showValue ? labelColor.withAlphaComponent(1) : labelColor, kern: showValue ? 0 : 0.6)
    }
    private func drawScale(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat) {
        switch scale {
        case .none: return
        case .dots:
            ctx.setFillColor(labelColor.withAlphaComponent(0.85).cgColor)
            let n = steps > 0 ? steps + 1 : 11
            for k in 0..<n {
                let a = angle(Double(k) / Double(n - 1)), d = r + 5.5, s: CGFloat = k == 0 || k == n - 1 ? 2.4 : 1.6
                ctx.fillEllipse(in: CGRect(x: c.x + sin(a) * d - s / 2, y: c.y - cos(a) * d - s / 2, width: s, height: s))
            }
        case .numbers:
            let f = RigPaint.font(["Futura-Medium"], max(7, r * 0.34))
            for k in 0...10 {
                let a = angle(Double(k) / 10), d = r + r * 0.42
                RigPaint.text("\(k)", CGRect(x: c.x + sin(a) * d - 8, y: c.y - cos(a) * d - 5, width: 16, height: 10), font: f, color: labelColor)
            }
        }
    }
    private func drawKnob(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ a: CGFloat) {
        let dir = CGPoint(x: sin(a), y: -cos(a))
        func disc(_ rr: CGFloat) -> CGRect { CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr) }
        ctx.saveGState() // the knob's shadow on the panel
        ctx.setShadow(offset: CGSize(width: 1.5, height: -3), blur: r * 0.35, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        switch style { case .chicken: ctx.fillEllipse(in: disc(r * 0.72)); default: ctx.fillEllipse(in: disc(r)) }
        ctx.restoreGState()
        let light = CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.45)
        switch style {
        case .chicken(let color):
            ctx.saveGState(); ctx.addEllipse(in: disc(r * 0.72)); ctx.clip()
            RigPaint.radial(ctx, c, r * 0.72, [color.blended(withFraction: 0.35, of: .white) ?? color, color, color.blended(withFraction: 0.6, of: .black) ?? color], focus: light)
            ctx.restoreGState()
            let perp = CGPoint(x: -dir.y, y: dir.x)
            let p = CGMutablePath()
            let tip = CGPoint(x: c.x + dir.x * r, y: c.y + dir.y * r)
            let tail = CGPoint(x: c.x - dir.x * r * 0.62, y: c.y - dir.y * r * 0.62)
            p.move(to: CGPoint(x: tip.x + perp.x * r * 0.1, y: tip.y + perp.y * r * 0.1))
            p.addLine(to: CGPoint(x: tail.x + perp.x * r * 0.3, y: tail.y + perp.y * r * 0.3))
            p.addQuadCurve(to: CGPoint(x: tail.x - perp.x * r * 0.3, y: tail.y - perp.y * r * 0.3),
                           control: CGPoint(x: tail.x - dir.x * r * 0.32, y: tail.y - dir.y * r * 0.32))
            p.addLine(to: CGPoint(x: tip.x - perp.x * r * 0.1, y: tip.y - perp.y * r * 0.1))
            p.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 1, height: -2.5), blur: 3, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.addPath(p); ctx.setFillColor(color.cgColor); ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState(); ctx.addPath(p); ctx.clip()
            RigPaint.radial(ctx, c, r, [color.blended(withFraction: 0.45, of: .white) ?? color, color, color.blended(withFraction: 0.55, of: .black) ?? color], focus: light)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor); ctx.setLineWidth(max(1.2, r * 0.07)); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: c.x + dir.x * r * 0.25, y: c.y + dir.y * r * 0.25)); ctx.addLine(to: CGPoint(x: c.x + dir.x * r * 0.9, y: c.y + dir.y * r * 0.9))
            ctx.strokePath()
        case .skirted(let cap, let skirt):
            ctx.saveGState(); ctx.addEllipse(in: disc(r)); ctx.clip()
            RigPaint.radial(ctx, c, r, [skirt.blended(withFraction: 0.5, of: .white) ?? skirt, skirt, skirt.blended(withFraction: 0.5, of: .black) ?? skirt], focus: light)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor); ctx.setLineWidth(0.8) // knurls
            for k in 0..<36 {
                let t = CGFloat(k) / 36 * 2 * .pi
                ctx.move(to: CGPoint(x: c.x + cos(t) * r * 0.86, y: c.y + sin(t) * r * 0.86)); ctx.addLine(to: CGPoint(x: c.x + cos(t) * r, y: c.y + sin(t) * r))
            }
            ctx.strokePath()
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(max(1.3, r * 0.08)); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: c.x + dir.x * r * 0.7, y: c.y + dir.y * r * 0.7)); ctx.addLine(to: CGPoint(x: c.x + dir.x * r * 0.97, y: c.y + dir.y * r * 0.97))
            ctx.strokePath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0.5, height: -1.5), blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.setFillColor(cap.cgColor); ctx.fillEllipse(in: disc(r * 0.66))
            ctx.restoreGState()
            ctx.saveGState(); ctx.addEllipse(in: disc(r * 0.66)); ctx.clip()
            RigPaint.radial(ctx, c, r * 0.66, [cap.blended(withFraction: 0.55, of: .white) ?? cap, cap, cap.blended(withFraction: 0.45, of: .black) ?? cap], focus: light)
            ctx.restoreGState()
            ctx.setStrokeColor((cap.brightnessComponentSafe > 0.6 ? NSColor.black : .white).withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(max(1.1, r * 0.06))
            ctx.move(to: CGPoint(x: c.x + dir.x * r * 0.2, y: c.y + dir.y * r * 0.2)); ctx.addLine(to: CGPoint(x: c.x + dir.x * r * 0.6, y: c.y + dir.y * r * 0.6))
            ctx.strokePath()
        case .knurled(let tint):
            ctx.saveGState(); ctx.addEllipse(in: disc(r)); ctx.clip()
            for k in 0..<72 { // anisotropic reflection: brightness varies with the angle around the axis
                let t0 = CGFloat(k) / 72 * 2 * .pi, t1 = t0 + 2 * .pi / 72 + 0.01
                let b = 0.45 + 0.4 * cos(2 * (t0 - 0.8)) + (k % 2 == 0 ? 0.06 : -0.06)
                let w = CGMutablePath(); w.move(to: c); w.addArc(center: c, radius: r, startAngle: t0, endAngle: t1, clockwise: false); w.closeSubpath()
                ctx.addPath(w); ctx.setFillColor((tint.blended(withFraction: 1 - b, of: .black) ?? tint).cgColor); ctx.fillPath()
            }
            ctx.restoreGState()
            ctx.saveGState(); ctx.addEllipse(in: disc(r * 0.8)); ctx.clip() // the polished top
            for k in 0..<48 {
                let t0 = CGFloat(k) / 48 * 2 * .pi, t1 = t0 + 2 * .pi / 48 + 0.01
                let b = 0.62 + 0.3 * cos(2 * (t0 + 0.4))
                let w = CGMutablePath(); w.move(to: c); w.addArc(center: c, radius: r, startAngle: t0, endAngle: t1, clockwise: false); w.closeSubpath()
                ctx.addPath(w); ctx.setFillColor((tint.blended(withFraction: 1 - b, of: .black) ?? tint).cgColor); ctx.fillPath()
            }
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.4).cgColor); ctx.setLineWidth(0.8); ctx.strokeEllipse(in: disc(r * 0.8))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(max(1.6, r * 0.1)); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: c.x + dir.x * r * 0.25, y: c.y + dir.y * r * 0.25)); ctx.addLine(to: CGPoint(x: c.x + dir.x * r * 0.78, y: c.y + dir.y * r * 0.78))
            ctx.strokePath()
        case .ribbed(let color):
            ctx.saveGState(); ctx.addEllipse(in: disc(r)); ctx.clip()
            RigPaint.radial(ctx, c, r, [color.blended(withFraction: 0.25, of: .white) ?? color, color, .black], focus: light)
            ctx.restoreGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor) // ribs
            for k in 0..<28 {
                let t = CGFloat(k) / 28 * 2 * .pi + a
                ctx.fillEllipse(in: CGRect(x: c.x + cos(t) * r * 0.92 - 1.1, y: c.y + sin(t) * r * 0.92 - 1.1, width: 2.2, height: 2.2))
            }
            ctx.saveGState(); ctx.addEllipse(in: disc(r * 0.78)); ctx.clip()
            RigPaint.radial(ctx, c, r * 0.78, [color.blended(withFraction: 0.3, of: .white) ?? color, color, color.blended(withFraction: 0.5, of: .black) ?? color], focus: light)
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor); ctx.setLineWidth(max(1.4, r * 0.09)); ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: c.x + dir.x * r * 0.3, y: c.y + dir.y * r * 0.3)); ctx.addLine(to: CGPoint(x: c.x + dir.x * r * 0.92, y: c.y + dir.y * r * 0.92))
            ctx.strokePath()
        }
    }

    // MARK: Input

    private func commit(_ v: Double) {
        var v = max(0, min(1, v))
        if steps > 0 { v = (v * Double(steps)).rounded() / Double(steps) }
        guard v != value else { return }
        value = v
        onChange?(v)
        setAccessibilityValue(valueText())
        needsDisplay = true
    }
    private var precise: Double = 0
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 || event.modifierFlags.contains(.option) { commit(defaultValue); return }
        dragStart = (event.locationInWindow.y, value)
        precise = value
        dragging = true
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let fine = event.modifierFlags.contains(.shift), y = event.locationInWindow.y // window points: up is +y
        precise += Double(y - start.y) / (fine ? 900 : 180) * (steps > 0 ? 1.6 : 1)
        dragStart = (y, start.value)
        precise = max(0, min(1, precise))
        commit(precise)
    }
    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        dragging = false
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        let d = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        if steps > 0 {
            if abs(d) > 0.001 { commit(value + (d > 0 ? 1 : -1) / Double(steps)) }
        } else { commit(value + d) }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func accessibilityLabel() -> String? { name }
    override func accessibilityValue() -> Any? { valueText() }
    override func accessibilityPerformIncrement() -> Bool { commit(value + (steps > 0 ? 1 / Double(steps) : 0.05)); return true }
    override func accessibilityPerformDecrement() -> Bool { commit(value - (steps > 0 ? 1 / Double(steps) : 0.05)); return true }
}

private extension NSColor {
    var brightnessComponentSafe: CGFloat { (usingColorSpace(.sRGB) ?? self).brightnessComponent }
}

/// A chrome stomp switch: click to switch the unit on or off.
@MainActor
final class RigFootswitch: NSView {
    var onPress: (() -> Void)?
    var isOn = true { didSet { setAccessibilityValue(isOn ? "on" : "off") } }
    var name = ""
    private var down = false
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY), r = bounds.width / 2 - 2
        // The nut.
        let nut = CGMutablePath()
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3 + .pi / 6
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            k == 0 ? nut.move(to: p) : nut.addLine(to: p)
        }
        nut.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1, height: -3), blur: 4, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(nut); ctx.setFillColor(RigPaint.hex(0x9da1a6).cgColor); ctx.fillPath()
        ctx.restoreGState()
        RigPaint.vertical(ctx, nut, [RigPaint.hex(0xf3f4f5), RigPaint.hex(0xa0a5aa), RigPaint.hex(0x5b5f63)])
        // The domed button.
        let br = r * (down ? 0.56 : 0.6)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: down ? -0.5 : -2), blur: 3, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setFillColor(RigPaint.hex(0xb0b5ba).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - br, y: c.y - br, width: 2 * br, height: 2 * br))
        ctx.restoreGState()
        ctx.saveGState(); ctx.addEllipse(in: CGRect(x: c.x - br, y: c.y - br, width: 2 * br, height: 2 * br)); ctx.clip()
        RigPaint.radial(ctx, c, br, [RigPaint.hex(down ? 0xc9ccd0 : 0xffffff), RigPaint.hex(0xa9aeb3), RigPaint.hex(0x4c5054)],
                        focus: CGPoint(x: c.x - br * 0.35, y: c.y - br * 0.45))
        ctx.restoreGState()
    }
    override func mouseDown(with event: NSEvent) { down = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        down = false; needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityLabel() -> String? { "\(name) on/off" }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
