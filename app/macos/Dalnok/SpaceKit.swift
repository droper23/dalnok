// The guitar editors' look: white plastic and black glass modules on a near-white field with a few quiet space
// marks, lit in orange and blue. Drawing helpers, the round-screen control (each one a small display whose picture
// implies its value), and the power button. Everything is drawn from shapes; nothing is taken from any product.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
enum Space {
    nonisolated static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    static let field = hex(0xf1f0ec)
    static let ink = hex(0x2a2b2f)
    static let inkDim = hex(0x8a8c92)
    static let orange = hex(0xff7a1f)
    static let amber = hex(0xffb347)
    static let blue = hex(0x3d8bff)
    static let ice = hex(0x9fd4ff)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        let names: [NSFont.Weight: String] = [.medium: "AvenirNext-Regular", .semibold: "AvenirNext-Medium", .bold: "AvenirNext-Medium",
                                              .regular: "AvenirNext-Regular", .light: "AvenirNext-UltraLight"]
        return names[weight].flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size, weight: weight)
    }
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .medium) }

    static func gradient(_ colors: [NSColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: locations)!
    }
    static func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
    }
    /// A rect with its own radius at each side (snapped modules: round only at the ends of a row).
    static func capsule(_ r: CGRect, left: CGFloat, right: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + left, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - right, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + right), radius: right)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - right))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - right, y: r.maxY), radius: right)
        p.addLine(to: CGPoint(x: r.minX + left, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - left), radius: left)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + left))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + left, y: r.minY), radius: left)
        p.closeSubpath()
        return p
    }
    static func fillVertical(_ ctx: CGContext, _ path: CGPath, _ colors: [NSColor], _ locations: [CGFloat]? = nil) {
        let r = path.boundingBox
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient(colors, locations), start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        ctx.restoreGState()
    }
    static func radial(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ colors: [NSColor], _ locations: [CGFloat]? = nil, focus: CGPoint? = nil) {
        ctx.drawRadialGradient(gradient(colors, locations), startCenter: focus ?? c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }
    /// An inner shadow along a shape's edge.
    static func innerShadow(_ ctx: CGContext, _ path: CGPath, alpha: CGFloat, blur: CGFloat, offset: CGSize = .zero, color: NSColor = .black) {
        // Fill everything outside the shape (clipped to the shape): only its shadow falls inside.
        let r = path.boundingBox.insetBy(dx: -blur * 3 - 20, dy: -blur * 3 - 20)
        let ring = CGMutablePath(); ring.addRect(r); ring.addPath(path)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setShadow(offset: offset, blur: blur, color: color.withAlphaComponent(alpha).cgColor)
        ctx.addPath(ring); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }
    static func text(_ s: String, _ rect: CGRect, font: NSFont, color: NSColor, align: NSTextAlignment = .center, kern: CGFloat = 0,
                     glow: NSColor? = nil) {
        let para = NSMutableParagraphStyle(); para.alignment = align; para.lineBreakMode = .byTruncatingTail
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para, .kern: kern]
        if let glow { let sh = NSShadow(); sh.shadowColor = glow; sh.shadowBlurRadius = font.pointSize * 0.6; attrs[.shadow] = sh }
        let h = (s as NSString).size(withAttributes: attrs).height
        (s as NSString).draw(in: CGRect(x: rect.minX, y: rect.midY - h / 2, width: rect.width, height: h + 2), withAttributes: attrs)
    }

    /// Seeded fine grain (the same every run, so snapshots compare).
    static let grainImage: CGImage = {
        let n = 192
        var seed: UInt32 = 0x2545F491
        var bytes = [UInt8](repeating: 0, count: n * n)
        for i in bytes.indices { seed = seed &* 1664525 &+ 1013904223; bytes[i] = UInt8(truncatingIfNeeded: 112 + (seed >> 26)) }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }()
    static func grain(_ ctx: CGContext, _ path: CGPath, alpha: CGFloat) {
        let r = path.boundingBox
        ctx.saveGState(); ctx.addPath(path); ctx.clip(); ctx.setAlpha(alpha); ctx.setBlendMode(.overlay)
        var y = r.minY
        while y < r.maxY { var x = r.minX; while x < r.maxX { ctx.draw(grainImage, in: CGRect(x: x, y: y, width: 96, height: 96)); x += 96 }; y += 96 }
        ctx.restoreGState()
    }
    /// Matte panel material: pale grey with a fine grain, lit from the upper left, its edges softly rounded over.
    static func plastic(_ ctx: CGContext, _ path: CGPath, lift: CGFloat = 1) {
        let r = path.boundingBox
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 6 * lift, height: -12 * lift), blur: 26 * lift, color: hex(0x000000, 0.35).cgColor)
        ctx.addPath(path); ctx.setFillColor(hex(0xe6e6e4).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient([hex(0xf1f1ef), hex(0xe7e7e5), hex(0xdcdcda)]), start: CGPoint(x: r.minX, y: r.minY),
                               end: CGPoint(x: r.maxX, y: r.maxY), options: [])
        ctx.restoreGState()
        grain(ctx, path, alpha: 0.35)
        innerShadow(ctx, path, alpha: 0.95, blur: 2.5, offset: CGSize(width: 1.5, height: -1.5), color: .white)
        innerShadow(ctx, path, alpha: 0.22, blur: 5, offset: CGSize(width: -2, height: 2.5))
    }
    /// A raised plinth of panel material (under a main screen): a soft shadow to the lower right, a lit upper-left edge.
    static func plinth(_ ctx: CGContext, _ path: CGPath) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 6, height: -10), blur: 18, color: hex(0x000000, 0.30).cgColor)
        ctx.addPath(path); ctx.setFillColor(hex(0xe4e4e2).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 1, height: -1.5), blur: 2, color: hex(0x000000, 0.25).cgColor)
        ctx.addPath(path); ctx.setFillColor(hex(0xe9e9e7).cgColor); ctx.fillPath()
        ctx.restoreGState()
        grain(ctx, path, alpha: 0.3)
        innerShadow(ctx, path, alpha: 1, blur: 2, offset: CGSize(width: 1.2, height: -1.2), color: .white)
        innerShadow(ctx, path, alpha: 0.18, blur: 4, offset: CGSize(width: -1.5, height: 2))
    }
    /// A raised matte black disc (a control): a soft shadow cast to the lower right, a fine light rim on its upper left.
    static func disc(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, pressed: Bool = false) {
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: pressed ? 2 : 5, height: pressed ? -3 : -8), blur: pressed ? 6 : 12, color: hex(0x000000, 0.42).cgColor)
        ctx.setFillColor(hex(0x111113).cgColor); ctx.fillEllipse(in: rect)
        ctx.setShadow(offset: CGSize(width: 0.5, height: -1), blur: 1.5, color: hex(0x000000, 0.5).cgColor)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.saveGState(); ctx.addEllipse(in: rect); ctx.clip()
        radial(ctx, CGPoint(x: c.x - r * 0.25, y: c.y - r * 0.3), r * 1.3, [hex(0x222225), hex(0x141416), hex(0x0a0a0b)], [0, 0.55, 1])
        ctx.restoreGState()
        // The rim: light on the upper left, falling away to dark on the lower right.
        let ring = CGMutablePath(); ring.addEllipse(in: rect); ring.addEllipse(in: rect.insetBy(dx: 1.6, dy: 1.6))
        ctx.saveGState(); ctx.addPath(ring); ctx.clip(using: .evenOdd)
        ctx.drawLinearGradient(gradient([NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0.05), NSColor.black.withAlphaComponent(0.4)], [0, 0.5, 1]),
                               start: CGPoint(x: rect.minX + r * 0.3, y: rect.minY + r * 0.3), end: CGPoint(x: rect.maxX - r * 0.3, y: rect.maxY - r * 0.3), options: [])
        ctx.restoreGState()
    }

    /// Black glass set into the plastic: a recessed bezel, deep glass, and a reflection over the top.
    static func glass(_ ctx: CGContext, _ path: CGPath, glow: NSColor? = nil, glowLevel: CGFloat = 0) {
        let r = path.boundingBox
        ctx.addPath(path); ctx.setFillColor(hex(0x0a0a0b).cgColor); ctx.fillPath()
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        radial(ctx, CGPoint(x: r.midX, y: r.midY), max(r.width, r.height) * 0.75, [hex(0x141517), hex(0x0b0b0c), hex(0x070708)], [0, 0.6, 1])
        if let glow, glowLevel > 0 {
            ctx.setBlendMode(.screen)
            radial(ctx, CGPoint(x: r.midX, y: r.midY), max(r.width, r.height) * 0.7, [glow.withAlphaComponent(0.22 * glowLevel), .clear])
        }
        ctx.restoreGState()
        innerShadow(ctx, path, alpha: 0.9, blur: 6, offset: CGSize(width: 2, height: -2.5))
    }
    /// The glass's reflection: drawn after the screen's picture.
    static func glassShine(_ ctx: CGContext, _ path: CGPath) {
        let r = path.boundingBox
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        let sheen = CGMutablePath()
        sheen.move(to: CGPoint(x: r.minX, y: r.minY))
        sheen.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        sheen.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.18))
        sheen.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.46), control: CGPoint(x: r.midX, y: r.minY + r.height * 0.42))
        sheen.closeSubpath()
        ctx.addPath(sheen); ctx.clip()
        ctx.drawLinearGradient(gradient([NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0.02)]),
                               start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.minY + r.height * 0.45), options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.06).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        ctx.restoreGState()
    }

    /// A convex glass top: a bright window reflection upper left, a soft rim of light lower right.
    static func domeShine(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat) {
        let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState(); ctx.addEllipse(in: disc); ctx.clip()
        let hl = CGRect(x: c.x - r * 0.78, y: c.y - r * 0.9, width: r * 1.25, height: r * 0.72)
        ctx.saveGState(); ctx.addEllipse(in: hl); ctx.clip()
        ctx.drawLinearGradient(gradient([NSColor.white.withAlphaComponent(0.42), NSColor.white.withAlphaComponent(0.03)]),
                               start: CGPoint(x: c.x, y: hl.minY), end: CGPoint(x: c.x, y: hl.maxY), options: [])
        ctx.restoreGState()
        ctx.setBlendMode(.screen)
        ctx.drawRadialGradient(gradient([.clear, .clear, NSColor.white.withAlphaComponent(0.16)], [0, 0.78, 1]),
                               startCenter: CGPoint(x: c.x - r * 0.15, y: c.y - r * 0.2), startRadius: 0, endCenter: c, endRadius: r, options: [])
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r * 0.52, y: c.y - r * 0.62, width: r * 0.16, height: r * 0.1))
    }

    /// A light trace with a soft bloom (additive): the screens' orange and blue lines.
    static func glowStroke(_ ctx: CGContext, _ path: CGPath, _ color: NSColor, width: CGFloat, bloom: CGFloat = 1) {
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setShadow(offset: .zero, blur: 6 * bloom, color: color.withAlphaComponent(0.7).cgColor)
        ctx.addPath(path); ctx.setStrokeColor(color.withAlphaComponent(0.35).cgColor); ctx.setLineWidth(width * 1.8); ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(path); ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.strokePath()
        ctx.addPath(path); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(max(0.5, width * 0.35)); ctx.strokePath()
        ctx.restoreGState()
    }
    static func glowDot(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: NSColor, intensity: CGFloat = 1) {
        ctx.saveGState()
        ctx.setBlendMode(.screen)
        radial(ctx, c, r * 4, [color.withAlphaComponent(0.55 * intensity), color.withAlphaComponent(0.12 * intensity), .clear], [0, 0.35, 1])
        ctx.setFillColor(color.withAlphaComponent(min(1, 0.6 + 0.4 * intensity)).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.7 * intensity).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45, width: r * 0.9, height: r * 0.9))
        ctx.restoreGState()
    }

    /// A status light set into white plastic: a small glass well with the light in it.
    static func lamp(_ ctx: CGContext, _ c: CGPoint, _ color: NSColor, lit: Bool, intensity: CGFloat = 1) {
        let well = CGPath(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12), transform: nil)
        glass(ctx, well)
        if lit { glowDot(ctx, c, 2.8, color, intensity: intensity) } else {
            ctx.setFillColor(hex(0xffffff, 0.18).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
        }
        glassShine(ctx, well)
    }

    /// The field behind the modules: off-white with a few faint orbits, a ringed planet and specks.
    static func field(_ ctx: CGContext, _ rect: CGRect) {
        ctx.setFillColor(field.cgColor); ctx.fill(rect)
        radial(ctx, CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.35), max(rect.width, rect.height) * 0.75,
               [NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0)])
        ctx.saveGState()
        ctx.setStrokeColor(hex(0x9a9ca3, 0.18).cgColor); ctx.setLineWidth(1)
        let c = CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY + rect.height * 0.16)
        for (k, rr) in [CGFloat(90), 170, 280, 430].enumerated() {
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y); ctx.rotate(by: -0.32); ctx.scaleBy(x: 1, y: 0.36)
            if k == 2 { ctx.setLineDash(phase: 0, lengths: [2, 6]) }
            ctx.strokeEllipse(in: CGRect(x: -rr, y: -rr, width: 2 * rr, height: 2 * rr))
            ctx.restoreGState()
        }
        // A small ringed planet on the third orbit, and a far moon.
        let p = CGPoint(x: c.x - 250, y: c.y + 60)
        radial(ctx, p, 13, [hex(0xffffff), hex(0xd9d9dc), hex(0xb9bbc1)], focus: CGPoint(x: p.x - 4, y: p.y - 5))
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y); ctx.rotate(by: -0.32); ctx.scaleBy(x: 1, y: 0.28)
        ctx.setStrokeColor(hex(0x9a9ca3, 0.45).cgColor); ctx.setLineWidth(2.4)
        ctx.strokeEllipse(in: CGRect(x: -24, y: -24, width: 48, height: 48))
        ctx.restoreGState()
        ctx.setFillColor(orange.withAlphaComponent(0.8).cgColor); ctx.fillEllipse(in: CGRect(x: c.x + 82, y: c.y - 14, width: 6, height: 6))
        ctx.setFillColor(blue.withAlphaComponent(0.55).cgColor); ctx.fillEllipse(in: CGRect(x: rect.minX + 70, y: rect.maxY - 60, width: 4, height: 4))
        var seed: UInt32 = 7
        ctx.setFillColor(hex(0x9a9ca3, 0.35).cgColor)
        for _ in 0..<40 { // specks
            seed = seed &* 1664525 &+ 1013904223; let x = rect.minX + CGFloat(seed % 10_000) / 10_000 * rect.width
            seed = seed &* 1664525 &+ 1013904223; let y = rect.minY + CGFloat(seed % 10_000) / 10_000 * rect.height
            seed = seed &* 1664525 &+ 1013904223; let s = 0.8 + CGFloat(seed % 100) / 100 * 1.4
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: s, height: s))
        }
        ctx.restoreGState()
    }
}

/// What a round screen draws to show its value.
enum DialPicture {
    case arc        // a lit arc around the rim, a core that brightens
    case orbit      // a moon orbiting, faster as the value rises (rates)
    case rings      // concentric rings spreading further (times, sizes, decays)
    case spectrum   // a blue-to-orange band with a marker (tone, frequency)
    case blend      // two overlapping discs, blue (dry) and orange (wet)
    case steps(Int) // positions around the rim, the chosen one lit
    case bipolar    // centred arc, orange above zero, blue below (EQ gains, tone tilts)

    static func of(name: String, steps: Int) -> DialPicture {
        if steps > 0 { return .steps(steps + 1) }
        switch name.lowercased() {
        case "rate", "auto": return .orbit
        case "mix", "dry/wet", "output mix": return .blend
        case "tone", "treble", "presence", "high-cut", "low-cut", "frequency", "freq", "pedal", "manual": return .spectrum
        case "decay", "size", "pre-delay", "time", "delay", "release", "attack", "retune", "distance", "drip": return .rings
        case "bass", "middle": return .bipolar
        default: return .arc
        }
    }
}

/// A control as a small round screen in a raised white bezel. Drag up or down (⇧ fine), scroll, double-click or ⌥-click
/// for the default. The screen shows a picture of the value; while hovered or dragged, the value itself.
@MainActor
final class SpaceDial: NSView {
    let name: String
    var picture: DialPicture
    var value: Double = 0 { didSet { if value != oldValue { needsDisplay = true } } }
    var defaultValue: Double = 0.5
    var steps = 0
    var bipolarDefault = false
    var valueText: () -> String = { "" }
    var onChange: ((Double) -> Void)?
    /// Animation time and how lit the module is (0-1), set by the editor's tick.
    var time: Double = 0 { didSet { if case .orbit = picture { needsDisplay = true } } }
    var light: CGFloat = 0 { didSet { if abs(light - oldValue) > 0.02 { needsDisplay = true } } }
    var accent = Space.orange
    private(set) var dragging = false
    private var hovering = false
    private var lastY: CGFloat = 0
    private var precise = 0.0
    static let diameter: CGFloat = 50, labelHeight: CGFloat = 18
    static var size: CGSize { CGSize(width: diameter + 22, height: diameter + 26 + labelHeight) }

    init(name: String, picture: DialPicture) {
        self.name = name
        self.picture = picture
        super.init(frame: CGRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // A raised matte black disc, its picture drawn on it.
        let d = Self.diameter, r = d / 2, c = CGPoint(x: bounds.midX + (dragging ? 1 : 0), y: 8 + r + (dragging ? 1 : 0))
        Space.disc(ctx, c, r, pressed: dragging)
        let screen = CGPath(ellipseIn: CGRect(x: c.x - r + 1.6, y: c.y - r + 1.6, width: d - 3.2, height: d - 3.2), transform: nil)
        if light > 0 {
            ctx.saveGState(); ctx.addPath(screen); ctx.clip(); ctx.setBlendMode(.screen)
            Space.radial(ctx, c, r, [accent.withAlphaComponent(0.2 * light), .clear])
            ctx.restoreGState()
        }
        ctx.saveGState(); ctx.addPath(screen); ctx.clip()
        let showValue = dragging || hovering
        drawPicture(ctx, c, r * 0.86, dimmed: showValue)
        if showValue {
            Space.text(valueText(), CGRect(x: c.x - r + 3, y: c.y - 7, width: d - 6, height: 14), font: Space.mono(9.5), color: .white,
                       glow: accent.withAlphaComponent(0.9))
        }
        ctx.restoreGState()
        Space.text(name.uppercased(), CGRect(x: -8, y: bounds.height - Self.labelHeight, width: bounds.width + 16, height: Self.labelHeight - 2),
                   font: Space.font(8.5, .regular), color: Space.ink, kern: 1.4)
    }

    private func drawPicture(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, dimmed: Bool) {
        let v = CGFloat(value), a = dimmed ? 0.35 : 1.0
        let start = CGFloat.pi * 0.75, sweep = CGFloat.pi * 1.5 // flipped coordinates: clockwise from lower left
        let track = CGMutablePath(); track.addArc(center: c, radius: r - 2, startAngle: start, endAngle: start + sweep, clockwise: false)
        switch picture {
        case .arc:
            ctx.addPath(track); ctx.setStrokeColor(Space.hex(0xffffff, 0.08).cgColor); ctx.setLineWidth(2.5); ctx.strokePath()
            if v > 0.005 {
                let lit = CGMutablePath(); lit.addArc(center: c, radius: r - 2, startAngle: start, endAngle: start + sweep * v, clockwise: false)
                Space.glowStroke(ctx, lit, accent.withAlphaComponent(a), width: 2.4)
            }
            Space.glowDot(ctx, c, 2.5 + 5 * v, accent.withAlphaComponent(a), intensity: (0.25 + 0.75 * v) * a)
        case .orbit:
            ctx.setStrokeColor(Space.blue.withAlphaComponent(0.35 * a).cgColor); ctx.setLineWidth(1)
            ctx.strokeEllipse(in: CGRect(x: c.x - r * 0.68, y: c.y - r * 0.68, width: r * 1.36, height: r * 1.36))
            Space.glowDot(ctx, c, 4.5, Space.amber.withAlphaComponent(a), intensity: 0.7 * a)
            let ang = CGFloat(time * (0.3 + 3.2 * Double(v)) * 2 * .pi) - .pi / 2
            Space.glowDot(ctx, CGPoint(x: c.x + cos(ang) * r * 0.68, y: c.y + sin(ang) * r * 0.68), 2.6, Space.ice.withAlphaComponent(a), intensity: a)
            let tail = CGMutablePath(); tail.addArc(center: c, radius: r * 0.68, startAngle: ang - 0.25 - 0.9 * v, endAngle: ang, clockwise: false)
            Space.glowStroke(ctx, tail, Space.blue.withAlphaComponent(0.6 * a), width: 1.6, bloom: 0.6)
        case .rings:
            for k in 0..<4 {
                let rr = r * (0.18 + 0.82 * v * CGFloat(k + 1) / 4)
                let ring = CGPath(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr), transform: nil)
                Space.glowStroke(ctx, ring, (k == 3 ? accent : Space.blue).withAlphaComponent(a * (1 - CGFloat(k) * 0.18)), width: 1.2, bloom: 0.5)
            }
            Space.glowDot(ctx, c, 2.2, accent.withAlphaComponent(a), intensity: a)
        case .spectrum:
            let band = CGRect(x: c.x - r * 0.78, y: c.y - 2.5, width: r * 1.56, height: 5)
            ctx.saveGState(); ctx.addPath(Space.rounded(band, 2.5)); ctx.clip()
            ctx.drawLinearGradient(Space.gradient([Space.blue.withAlphaComponent(a), Space.hex(0xd8d8ff, a), accent.withAlphaComponent(a)]),
                                   start: CGPoint(x: band.minX, y: c.y), end: CGPoint(x: band.maxX, y: c.y), options: [])
            ctx.restoreGState()
            let x = band.minX + band.width * v
            let marker = CGMutablePath(); marker.move(to: CGPoint(x: x, y: c.y - r * 0.5)); marker.addLine(to: CGPoint(x: x, y: c.y + r * 0.5))
            Space.glowStroke(ctx, marker, (v < 0.5 ? Space.ice : Space.amber).withAlphaComponent(a), width: 1.6)
        case .blend:
            let off = r * 0.32
            Space.glowDot(ctx, CGPoint(x: c.x - off, y: c.y), r * 0.26 * (1.2 - v * 0.6), Space.blue.withAlphaComponent(a), intensity: (1 - v * 0.7) * a)
            Space.glowDot(ctx, CGPoint(x: c.x + off, y: c.y), r * 0.26 * (0.6 + v * 0.6), accent.withAlphaComponent(a), intensity: (0.3 + v * 0.7) * a)
        case .steps(let n):
            let sel = Int((v * Double(n - 1)).rounded())
            for k in 0..<n {
                let ang = start + sweep * CGFloat(k) / CGFloat(max(1, n - 1))
                let p = CGPoint(x: c.x + cos(ang) * (r - 4), y: c.y + sin(ang) * (r - 4))
                if k == sel { Space.glowDot(ctx, p, 2.6, accent.withAlphaComponent(a), intensity: a) } else {
                    ctx.setFillColor(Space.hex(0xffffff, 0.18 * a).cgColor); ctx.fillEllipse(in: CGRect(x: p.x - 1.4, y: p.y - 1.4, width: 2.8, height: 2.8))
                }
            }
            if !dimmed {
                let t = valueText(), short = t.count > 5 ? String(t.prefix(3)).uppercased() : t
                Space.text(short, CGRect(x: c.x - r, y: c.y - 6, width: 2 * r, height: 12), font: Space.mono(8.5), color: Space.hex(0xffffff, 0.85))
            }
        case .bipolar:
            ctx.addPath(track); ctx.setStrokeColor(Space.hex(0xffffff, 0.08).cgColor); ctx.setLineWidth(2.5); ctx.strokePath()
            let mid = start + sweep / 2
            let lit = CGMutablePath(); lit.addArc(center: c, radius: r - 2, startAngle: min(mid, start + sweep * v), endAngle: max(mid, start + sweep * v), clockwise: false)
            Space.glowStroke(ctx, lit, (v >= 0.5 ? accent : Space.blue).withAlphaComponent(a), width: 2.4)
            Space.glowDot(ctx, c, 3 + 4 * abs(v - 0.5) * 2, (v >= 0.5 ? accent : Space.blue).withAlphaComponent(a), intensity: (0.3 + abs(v - 0.5) * 1.4) * a)
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
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 || event.modifierFlags.contains(.option) { commit(defaultValue); return }
        lastY = event.locationInWindow.y
        precise = value
        dragging = true
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let y = event.locationInWindow.y
        precise = max(0, min(1, precise + Double(y - lastY) / (event.modifierFlags.contains(.shift) ? 900 : 180) * (steps > 0 ? 1.6 : 1)))
        lastY = y
        commit(precise)
    }
    override func mouseUp(with event: NSEvent) { dragging = false; needsDisplay = true }
    override func scrollWheel(with event: NSEvent) {
        let d = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        if steps > 0 { if abs(d) > 0.001 { commit(value + (d > 0 ? 1 : -1) / Double(steps)) } } else { commit(value + d) }
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func accessibilityValue() -> Any? { valueText() }
    override func accessibilityPerformIncrement() -> Bool { commit(value + (steps > 0 ? 1 / Double(steps) : 0.05)); return true }
    override func accessibilityPerformDecrement() -> Bool { commit(value - (steps > 0 ? 1 / Double(steps) : 0.05)); return true }
}

/// A module's footswitch: a raised white plastic dome in a ring that lights orange when the module is on (brighter
/// with the signal). Click to switch.
@MainActor
final class SpacePower: NSView {
    var isOn = true { didSet { if isOn != oldValue { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } } }
    var light: CGFloat = 0 { didSet { if abs(light - oldValue) > 0.02 { needsDisplay = true } } }
    var onPress: (() -> Void)?
    private var down = false
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 76, height: 76))
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        toolTip = "Switch this module on or off"
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY - 3), R = bounds.width / 2 - 6
        Space.disc(ctx, CGPoint(x: c.x + (down ? 1 : 0), y: c.y + (down ? 1 : 0)), R, pressed: down)
        let ring = CGPath(ellipseIn: CGRect(x: c.x - R * 0.56, y: c.y - R * 0.56, width: R * 1.12, height: R * 1.12), transform: nil)
        if isOn { Space.glowStroke(ctx, ring, Space.orange.withAlphaComponent(0.75 + 0.25 * light), width: 1.6, bloom: 0.6 + light) } else {
            ctx.addPath(ring); ctx.setStrokeColor(Space.hex(0xffffff, 0.2).cgColor); ctx.setLineWidth(1.2); ctx.strokePath()
        }
    }
    override func mouseDown(with event: NSEvent) { down = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        down = false; needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}
