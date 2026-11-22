// Prism: drawing primitives for the spatial-glass theme ("06 - Design/Prism.md").
// Material rules: surfaces are tinted glass over a dark, softly lit depth; elevation (shadow, rim brightness, opacity)
// says what is selected or being touched; light is static and cached, never animated during playback.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
enum Prism {
    /// The dispersed spectrum (cyan → blue → violet → magenta → amber), the theme's signature gradient.
    static let spectrum: [NSColor] = [Theme.hex(0x7FE7FF), Theme.hex(0x7FA8FF), Theme.hex(0xB18CFF), Theme.hex(0xF08CD8), Theme.hex(0xFFC889)]
    static var spectrumGradient: CGGradient {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: spectrum.map(\.cgColor) as CFArray, locations: [0, 0.27, 0.52, 0.76, 1])!
    }

    /// The canvas behind the lanes: a deep gradient with two soft light pools, rendered once per size and cached.
    private static var backdropCache: (size: CGSize, scale: CGFloat, image: CGImage)?
    static func backdrop(_ size: CGSize, scale: CGFloat) -> CGImage? {
        let size = CGSize(width: ceil(size.width / 64) * 64, height: ceil(size.height / 64) * 64) // re-render only on real growth
        if let c = backdropCache, c.size == size, c.scale == scale { return c.image }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let space = CGColorSpaceCreateDeviceRGB()
        let base = CGGradient(colorsSpace: space, colors: [Theme.hex(0x0D1020).cgColor, Theme.hex(0x080A13).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
        // Two pools of light: cool blue upper left, faint violet lower right (a lit room seen through frosted glass).
        for (c, color, r) in [(CGPoint(x: size.width * 0.18, y: size.height * 0.92), Theme.hex(0x3D6BFF, 0.10), max(size.width, size.height) * 0.55),
                              (CGPoint(x: size.width * 0.86, y: size.height * 0.08), Theme.hex(0x9B5CFF, 0.07), max(size.width, size.height) * 0.5)] {
            let g = CGGradient(colorsSpace: space, colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        }
        guard let image = ctx.makeImage() else { return nil }
        backdropCache = (size, scale, image)
        return image
    }

    /// A piece of tinted glass: a body that is lighter at the top, a specular top edge, and a thin rim of its own colour.
    /// `lift` 0…1 raises it (brighter rim, more opaque body, a soft coloured shadow): selection and touch.
    static func slab(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, tint: NSColor, body: CGFloat, lift: CGFloat = 0, flipped: Bool = true) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if lift > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: flipped ? 3 * lift : -3 * lift), blur: 12 * lift, color: tint.withAlphaComponent(0.45 * lift).cgColor)
            ctx.addPath(path); ctx.setFillColor(tint.withAlphaComponent(body * 0.6).cgColor); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let top = tint.withAlphaComponent(min(1, body * (1.6 + 0.6 * lift))), bottom = tint.withAlphaComponent(body * (0.7 + 0.5 * lift))
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: flipped ? rect.minY : rect.maxY), end: CGPoint(x: 0, y: flipped ? rect.maxY : rect.minY), options: [])
        // Specular edge: light caught by the top of the glass.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.16 + 0.14 * lift).cgColor)
        ctx.fill(CGRect(x: rect.minX + radius * 0.6, y: flipped ? rect.minY + 0.5 : rect.maxY - 1.5, width: rect.width - radius * 1.2, height: 1))
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(OKLCH.adjust(tint, dl: 0.12, chromaScale: 0.9).withAlphaComponent(0.42 + 0.5 * lift).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    /// A frosted panel (control bar, headers, mixer modules): a faint cool sheet with a hairline rim and top light.
    static func pane(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, alpha: CGFloat = 1, flipped: Bool = false) {
        slab(ctx, rect, radius: radius, tint: Theme.hex(0x8FA4FF), body: 0.055 * alpha, flipped: flipped)
    }

    /// A light pipe meter: a dark glass tube; the level is light inside it, cool to warm to red near 0 dBFS,
    /// with a small bright bead holding the peak. `level`, `peak`: 0…1 positions. Vertical when taller than wide.
    static func lightPipe(_ ctx: CGContext, _ rect: CGRect, level: CGFloat, peak: CGFloat, clipped: Bool) {
        let vertical = rect.height > rect.width
        let r = min(rect.width, rect.height) / 2
        let tube = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.saveGState()
        ctx.addPath(tube); ctx.setFillColor(Theme.well.cgColor); ctx.fillPath()
        ctx.addPath(tube); ctx.clip()
        let lit = vertical ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * level)
                           : CGRect(x: rect.minX, y: rect.minY, width: rect.width * level, height: rect.height)
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [Theme.hex(0x5FD8FF).cgColor, Theme.hex(0x7FA8FF).cgColor, Theme.hex(0xC79BFF).cgColor, Theme.hex(0xFFB27A).cgColor, Theme.hex(0xFF5C6C).cgColor] as CFArray,
                           locations: [0, 0.55, 0.78, 0.9, 1])!
        ctx.clip(to: lit)
        ctx.drawLinearGradient(g, start: rect.origin, end: vertical ? CGPoint(x: rect.minX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.minY), options: [])
        ctx.restoreGState()
        // Glass: rim and a highlight running along the tube.
        ctx.addPath(tube); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(0.75); ctx.strokePath()
        if peak > 0.01 {
            let bead = vertical ? CGRect(x: rect.minX, y: rect.minY + rect.height * peak - 1, width: rect.width, height: 2)
                                : CGRect(x: rect.minX + rect.width * peak - 1, y: rect.minY, width: 2, height: rect.height)
            ctx.setFillColor((clipped ? Theme.clipRed : NSColor.white).withAlphaComponent(0.95).cgColor); ctx.fill(bead)
        }
    }

    /// A glass knob: a clear disc with a coloured light arc for the value and a bright pointer dot.
    static func knob(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, value: CGFloat, from start: CGFloat = 0, color: NSColor, active: Bool) {
        let a0 = CGFloat.pi * 1.25, sweep = CGFloat.pi * 1.5
        func angle(_ v: CGFloat) -> CGFloat { a0 - sweep * v }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(2.5)
        ctx.setStrokeColor(Theme.ink(0.08).cgColor)
        ctx.addArc(center: c, radius: r, startAngle: angle(0), endAngle: angle(1), clockwise: true); ctx.strokePath()
        ctx.setStrokeColor(color.withAlphaComponent(active ? 1 : 0.85).cgColor)
        if active { ctx.setShadow(offset: .zero, blur: 6, color: color.withAlphaComponent(0.8).cgColor) }
        let (lo, hi) = (min(start, value), max(start, value))
        if hi - lo > 0.002 { ctx.addArc(center: c, radius: r, startAngle: angle(lo), endAngle: angle(hi), clockwise: true); ctx.strokePath() }
        ctx.restoreGState()
        let disc = CGRect(x: c.x - r + 4, y: c.y - r + 4, width: 2 * r - 8, height: 2 * r - 8)
        slab(ctx, disc, radius: disc.width / 2, tint: Theme.hex(0xA8B8FF), body: active ? 0.16 : 0.10, flipped: false)
        let p = CGPoint(x: c.x + cos(angle(value)) * (r - 7), y: c.y + sin(angle(value)) * (r - 7))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2))
    }
}
