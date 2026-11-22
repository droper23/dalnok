// Prism: drawing primitives for the spatial-glass theme ("06 - Design/Prism.md").
// Material rules: surfaces are tinted glass over a dark, softly lit depth; elevation (shadow, rim brightness, opacity)
// says what is selected or being touched; light is static and cached, never animated during playback.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreImage

@MainActor
enum Prism {
    /// The dispersed spectrum (cyan → blue → violet → magenta → amber), the theme's signature gradient.
    static let spectrum: [NSColor] = [Theme.hex(0x7FE7FF), Theme.hex(0x7FA8FF), Theme.hex(0xB18CFF), Theme.hex(0xF08CD8), Theme.hex(0xFFC889)]
    static var spectrumGradient: CGGradient {
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: spectrum.map(\.cgColor) as CFArray, locations: [0, 0.27, 0.52, 0.76, 1])!
    }

    // MARK: Light field and glass

    /// The light field behind all of Prism's glass: large soft pools of colour (blue, violet, magenta, teal at night;
    /// sky, lilac, peach and mint by day). Rendered once per window size and variant, for the whole window, so every
    /// pane samples the same light. Static: nothing animates it during playback.
    private static var fieldCache: [String: CGImage] = [:]
    static func lightField(_ size: CGSize, scale: CGFloat, frosted: Bool) -> CGImage? {
        let size = CGSize(width: max(64, ceil(size.width / 64) * 64), height: max(64, ceil(size.height / 64) * 64))
        let key = "\(Int(size.width))x\(Int(size.height))@\(scale)-\(Theme.isLight)-\(frosted)"
        if let image = fieldCache[key] { return image }
        if fieldCache.count > 8 { fieldCache.removeAll() }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let space = CGColorSpaceCreateDeviceRGB()
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let light = Theme.isLight
        let base = CGGradient(colorsSpace: space, colors: (light ? [Theme.hex(0xF3F5FC), Theme.hex(0xE6EAF7)] : [Theme.hex(0x0C1024), Theme.hex(0x06070F)]).map(\.cgColor) as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        let span = max(size.width, size.height)
        let pools: [(CGFloat, CGFloat, UInt32, CGFloat, CGFloat)] = light
            ? [(0.12, 0.88, 0x7FB8FF, 0.55, 0.55), (0.55, 1.05, 0xC8B2FF, 0.5, 0.45), (0.92, 0.70, 0xFFC2B0, 0.45, 0.42),
               (0.30, 0.10, 0x9EEBD3, 0.42, 0.45), (0.80, 0.08, 0xA9C8FF, 0.4, 0.4)]
            : [(0.10, 0.90, 0x2E5BFF, 0.55, 0.55), (0.55, 1.05, 0x8A3FFC, 0.42, 0.5), (0.95, 0.72, 0xE0408A, 0.32, 0.4),
               (0.25, 0.05, 0x00A7B5, 0.30, 0.45), (0.82, 0.05, 0x3D3DCC, 0.35, 0.45)]
        for (x, y, color, alpha, radius) in pools {
            let c = CGPoint(x: size.width * x, y: size.height * y), tint = Theme.hex(color)
            let g = CGGradient(colorsSpace: space, colors: [tint.withAlphaComponent(alpha).cgColor, tint.withAlphaComponent(alpha * 0.35).cgColor, tint.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 0.45, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: span * radius, options: [])
        }
        guard var image = ctx.makeImage() else { return nil }
        if frosted, let blurred = blur(image, radius: 28 * scale) { image = blurred }
        fieldCache[key] = image
        return image
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static func blur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image).clampedToExtent()
        guard let f = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: radius]),
              let out = f.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height)) else { return nil }
        return ciContext.createCGImage(out, from: out.extent)
    }

    /// Draws the window's light field (raw, or frosted as seen through glass) into `view`, aligned to the window, so
    /// neighbouring views join seamlessly. `magnify` > 1 enlarges it about `lensCenter` (window coords): glass lensing.
    static func drawField(in view: NSView, frosted: Bool, clip: CGRect? = nil, magnify: CGFloat = 1, lensCenter: CGPoint? = nil) {
        guard let root = view.window?.contentView, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        guard let image = lightField(root.bounds.size, scale: scale, frosted: frosted) else { return }
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        // The field covers the window from its bottom-left corner; convert(_:from:) handles flipped views.
        var target = view.convert(CGRect(origin: .zero, size: size), from: root)
        if magnify != 1, let lc = lensCenter {
            let c = view.convert(lc, from: nil)
            target = CGRect(x: c.x + (target.minX - c.x) * magnify, y: c.y + (target.minY - c.y) * magnify,
                            width: target.width * magnify, height: target.height * magnify)
        }
        ctx.saveGState()
        ctx.clip(to: view.bounds) // views don't clip their own drawing by default (macOS 14+)
        if let clip { ctx.clip(to: clip) }
        NSImage(cgImage: image, size: size).draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ctx.restoreGState()
    }

    /// A pane of Liquid-style glass over the light field: the field frosted and slightly magnified behind it (light bends
    /// at the rim), a tint that keeps text legible, a specular rim that is brightest along the top-left edge, a soft
    /// refracted glow along the inner bottom edge, and a soft shadow beneath. `prominence` 0…1 lifts it.
    static func liquidPane(_ view: NSView, _ rect: CGRect, radius: CGFloat, tint: NSColor? = nil, prominence: CGFloat = 0) {
        guard let ctx = NSGraphicsContext.current?.cgContext, rect.width > 1, rect.height > 1 else { return }
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let light = Theme.isLight
        // Shadow under the pane (it floats).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: view.isFlipped ? 4 : -4), blur: 18 + 10 * prominence,
                      color: NSColor.black.withAlphaComponent(light ? 0.16 : 0.45).cgColor)
        ctx.addPath(path); ctx.setFillColor(Theme.window.withAlphaComponent(0.9).cgColor); ctx.fillPath()
        ctx.restoreGState()
        // The frosted field, lensed about the pane's centre.
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let centre = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil)
        drawField(in: view, frosted: true, magnify: 1.06, lensCenter: centre)
        // Body tint: daylight glass is milky, night glass smoky; a coloured tint tints it a little.
        ctx.setFillColor((light ? NSColor.white.withAlphaComponent(0.42 + 0.1 * prominence) : Theme.hex(0x0A0D1C, 0.42 - 0.1 * prominence)).cgColor)
        ctx.fill(rect)
        if let tint { ctx.setFillColor(tint.withAlphaComponent(light ? 0.10 : 0.12).cgColor); ctx.fill(rect) }
        // Inner light: a sheen across the top third, and light gathered along the bottom inner edge.
        let top = view.isFlipped ? rect.minY : rect.maxY, bottom = view.isFlipped ? rect.maxY : rect.minY
        let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(light ? 0.45 : 0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: top + (bottom - top) * 0.45), options: [])
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(light ? 0.35 : 0.08).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(glow, start: CGPoint(x: 0, y: bottom), end: CGPoint(x: 0, y: bottom - (bottom - top) * 0.18), options: [])
        ctx.restoreGState()
        // Specular rim: a bright line catching light at the top-left, fading around the pane; a darker outer line.
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setLineWidth(1)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        let rim = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.white.withAlphaComponent(light ? 0.95 : 0.6).cgColor,
                                                                                  NSColor.white.withAlphaComponent(light ? 0.35 : 0.10).cgColor,
                                                                                  NSColor.white.withAlphaComponent(light ? 0.75 : 0.35).cgColor] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: rect.minX, y: top), end: CGPoint(x: rect.maxX, y: bottom), options: [])
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -0.5, dy: -0.5), cornerWidth: radius + 0.5, cornerHeight: radius + 0.5, transform: nil))
        ctx.setStrokeColor((light ? Theme.hex(0x2A3566, 0.14) : NSColor.black.withAlphaComponent(0.35)).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()
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
        ctx.setFillColor(NSColor.white.withAlphaComponent((Theme.isLight ? 0.55 : 0.16) + 0.14 * lift).cgColor)
        ctx.fill(CGRect(x: rect.minX + radius * 0.6, y: flipped ? rect.minY + 0.5 : rect.maxY - 1.5, width: rect.width - radius * 1.2, height: 1))
        ctx.restoreGState()
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setStrokeColor(OKLCH.adjust(tint, dl: Theme.isLight ? -0.12 : 0.12, chromaScale: 0.9).withAlphaComponent(0.42 + 0.5 * lift).cgColor)
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
