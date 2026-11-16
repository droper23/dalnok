// Design tokens and the track color system ("06 - Design/Track Colors.md").
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum Theme {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    // MARK: Neutrals (cool graphite, 4 elevation steps)
    static let window = hex(0x111214)
    static let panel = hex(0x17181B)        // ruler, control bar
    static let panelRaised = hex(0x1D1F23)  // track headers
    static let control = hex(0x2A2D33)      // fader grooves, chip backgrounds
    static let controlHi = hex(0x3A3E46)
    static let laneA = hex(0x141518)
    static let laneB = hex(0x16171A)
    static let hairline = hex(0xFFFFFF, 0.07)
    static let separator = hex(0x000000, 0.55)
    static let gridMajor = hex(0xFFFFFF, 0.06)
    static let gridMinor = hex(0xFFFFFF, 0.025)
    static let text = hex(0xE8E9EC)
    static let textDim = hex(0x9A9EA6)
    static let textFaint = hex(0x5F646D)

    // MARK: Reserved state colors (never used for tracks alone; always paired with form)
    static let accent = hex(0xE8B25C)        // time display / brand
    static let playhead = hex(0xF4F4F5)
    static let selection = hex(0xFFFFFF)
    static let muteOn = hex(0x5B9BFF)        // blue chip (Logic convention)
    static let soloOn = hex(0xF5C451)        // yellow chip
    static let clipRed = hex(0xFF5A4F)

    // MARK: Metrics (4-pt grid)
    static let rulerHeight: CGFloat = 28
    static let trackHeight: CGFloat = 88
    static let headerWidth: CGFloat = 248
    static let transportHeight: CGFloat = 52
    static let trafficLightInset: CGFloat = 78

    // MARK: Type scale
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    // MARK: Track colors

    static let gradientSteps = 12
    /// Rainbow gradient starting at green: 12 steps of 30° in OKLCH, equal lightness/chroma,
    /// odd steps slightly lighter so adjacent tracks also differ in lightness (color-blind safety).
    static func gradientColor(step: Int) -> NSColor {
        let n = gradientSteps
        let i = ((step % n) + n) % n
        let hue = 145.0 + 360.0 / Double(n) * Double(i)
        let lightness = 0.70 + (i % 2 == 1 ? 0.05 : 0)
        return OKLCH.color(l: lightness, c: 0.135, h: hue)
    }

    static func trackColor(step: Int, custom: Int32) -> NSColor {
        custom >= 0 ? hex(UInt32(custom)) : gradientColor(step: step)
    }

    /// Back-compat helper (index-only).
    static func trackColor(_ i: Int) -> NSColor { gradientColor(step: i) }

    /// Swatches offered in the color menu: the gradient steps.
    static var swatches: [NSColor] { (0..<gradientSteps).map { gradientColor(step: $0) } }
}

/// Everything derived from a track's base color (one source of truth).
struct TrackTint {
    let base: NSColor
    var strip: NSColor { base }
    var body: NSColor { base.withAlphaComponent(0.17) }
    var bodySelected: NSColor { base.withAlphaComponent(0.27) }
    var title: NSColor { base.withAlphaComponent(0.48) }
    var titleSelected: NSColor { base.withAlphaComponent(0.72) }
    var waveform: NSColor { OKLCH.adjust(base, dl: 0.12, chromaScale: 0.85) }
    var border: NSColor { OKLCH.adjust(base, dl: -0.18, chromaScale: 0.9).withAlphaComponent(0.9) }
    var muted: NSColor { OKLCH.adjust(base, dl: -0.25, chromaScale: 0.15) }

    /// Black or white text, whichever contrasts more on `background` composited over the lane.
    static func textColor(on background: NSColor, over lane: NSColor = Theme.laneA) -> NSColor {
        let bg = background.usingColorSpace(.sRGB) ?? background, ln = lane.usingColorSpace(.sRGB) ?? lane
        let a = bg.alphaComponent
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = bg.redComponent * a + ln.redComponent * (1 - a)
        let g = bg.greenComponent * a + ln.greenComponent * (1 - a)
        let b = bg.blueComponent * a + ln.blueComponent * (1 - a)
        let y = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        // Contrast vs white (1.05/(y+0.05)) and vs near-black.
        return (1.05 / (y + 0.05)) >= ((y + 0.05) / 0.06) ? Theme.hex(0xFFFFFF, 0.95) : Theme.hex(0x0E0F11, 0.92)
    }
}

/// OKLCH ↔ sRGB (Björn Ottosson's OKLab), with chroma reduction to stay in gamut.
enum OKLCH {
    static func color(l: Double, c: Double, h: Double) -> NSColor {
        var lo = 0.0, hi = c, rgb = toSRGB(l: l, c: c, h: h)
        if !inGamut(rgb) {
            for _ in 0..<24 { // binary-search the largest in-gamut chroma
                let mid = (lo + hi) / 2
                if inGamut(toSRGB(l: l, c: mid, h: h)) { lo = mid } else { hi = mid }
            }
            rgb = toSRGB(l: l, c: lo, h: h)
        }
        return NSColor(srgbRed: clamp(rgb.0), green: clamp(rgb.1), blue: clamp(rgb.2), alpha: 1)
    }

    static func adjust(_ color: NSColor, dl: Double, chromaScale: Double) -> NSColor {
        let (l, c, h) = fromSRGB(color)
        return self.color(l: min(0.98, max(0.02, l + dl)), c: c * chromaScale, h: h)
    }

    private static func clamp(_ x: Double) -> CGFloat { CGFloat(min(1, max(0, x))) }
    private static func inGamut(_ v: (Double, Double, Double)) -> Bool {
        [v.0, v.1, v.2].allSatisfy { $0 >= -0.0005 && $0 <= 1.0005 }
    }

    private static func toSRGB(l L: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func enc(_ x: Double) -> Double { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(max(x, 0), 1 / 2.4) - 0.055 }
        return (enc(r), enc(g), enc(bl))
    }

    static func fromSRGB(_ color: NSColor) -> (Double, Double, Double) {
        let c = color.usingColorSpace(.sRGB) ?? color
        func dec(_ x: CGFloat) -> Double { let v = Double(x); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = dec(c.redComponent), g = dec(c.greenComponent), b = dec(c.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let C = (A * A + B * B).squareRoot()
        var H = atan2(B, A) * 180 / .pi
        if H < 0 { H += 360 }
        return (L, C, H)
    }
}
