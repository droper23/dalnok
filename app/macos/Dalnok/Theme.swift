// Design tokens and the track color system ("06 - Design/Track Colors.md").
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum Theme {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    enum Style: String, CaseIterable {
        case graphite, warmAnalog
        var title: String { self == .graphite ? "Graphite" : "Warm Analog" }
    }
    private static let preferenceKey = "appearanceStyle"
    static var preferredStyle: Style {
        get { UserDefaults.standard.string(forKey: preferenceKey).flatMap(Style.init(rawValue:)) ?? .graphite }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }
    // The style the windows are drawn with. Changing it live rebuilds the windows (AppDelegate.switchTheme);
    // tokens are computed so the rebuilt views pick up the new palette.
    nonisolated(unsafe) static var activeStyle: Style = { // main thread only
        if let override = ProcessInfo.processInfo.environment["DALNOK_THEME"], let style = Style(rawValue: override) { return style }
        return preferredStyle
    }()
    private static func tone(_ graphite: UInt32, _ warm: UInt32) -> NSColor {
        hex(activeStyle == .warmAnalog ? warm : graphite)
    }

    // MARK: Neutrals (cool graphite, 4 elevation steps)
    static var window: NSColor { tone(0x111214, 0x18130F) }
    static var panel: NSColor { tone(0x17181B, 0x211A15) }        // ruler, control bar
    static var panelRaised: NSColor { tone(0x1D1F23, 0x2A211A) }  // track headers
    static var control: NSColor { tone(0x2A2D33, 0x403229) }      // fader grooves, chip backgrounds
    static var controlHi: NSColor { tone(0x3A3E46, 0x584638) }
    static var laneA: NSColor { tone(0x141518, 0x1C1713) }
    static var laneB: NSColor { tone(0x16171A, 0x201A15) }
    static var laneHighlight: NSColor { tone(0x1C1E22, 0x2A2019) } // selected track's lane
    static var lcd: NSColor { tone(0x0B0C0E, 0x120D0A) }           // position display well
    static let hairline = hex(0xFFFFFF, 0.07)
    static let separator = hex(0x000000, 0.55)
    static let gridMajor = hex(0xFFFFFF, 0.06)
    static let gridMinor = hex(0xFFFFFF, 0.025)
    static var text: NSColor { tone(0xE8E9EC, 0xF2E7D7) }
    static var textDim: NSColor { tone(0x9A9EA6, 0xC0AB96) }
    static var textFaint: NSColor { tone(0x898E97, 0x9B8876) }

    // MARK: Reserved state colors (never used for tracks alone; always paired with form)
    static var accent: NSColor { tone(0xE8B25C, 0xE6AB69) }        // time display / brand
    static var playhead: NSColor { tone(0xF4F4F5, 0xF6E5CE) }
    static let selection = hex(0xFFFFFF)
    static var cycle: NSColor { tone(0xE9C24A, 0xE8B54F) } // cycle region in the ruler (Logic users know it as yellow)
    static let muteOn = hex(0x5B9BFF)        // blue chip (Logic convention)
    static let soloOn = hex(0xF5C451)        // yellow chip
    static let clipRed = hex(0xFF5A4F)
    static let recordOn = hex(0xE5484D)      // record arm / recording (always with an "R" or ● shape)
    static var selectedHeader: NSColor { tone(0x262930, 0x3A2B21) }
    static var knobHover: NSColor { tone(0x44484F, 0x685344) }

    // MARK: Metrics (4-pt grid)
    static let rulerHeight: CGFloat = 28
    static let baseTrackHeight: CGFloat = 88
    /// Vertical zoom (View ▸ Taller/Shorter Tracks): 88 to 220 pt, remembered between launches.
    static var trackHeight: CGFloat {
        get {
            if let h = cachedTrackHeight { return h }
            let v = UserDefaults.standard.double(forKey: "trackHeight")
            let h = v >= 88 ? min(220, CGFloat(v)) : baseTrackHeight
            cachedTrackHeight = h
            return h
        }
        set {
            let h = min(220, max(88, newValue))
            cachedTrackHeight = h
            UserDefaults.standard.set(Double(h), forKey: "trackHeight")
        }
    }
    nonisolated(unsafe) private static var cachedTrackHeight: CGFloat?
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
    /// Graphite: rainbow gradient starting at green, 12 steps of 30° in OKLCH, equal lightness/chroma,
    /// odd steps slightly lighter so adjacent tracks also differ in lightness (color-blind safety).
    static func gradientColor(step: Int) -> NSColor {
        let n = gradientSteps
        let i = ((step % n) + n) % n
        if activeStyle == .warmAnalog {
            // Vintage console cap colours: warm and cool alternate so neighbours separate, and the muddy olive
            // and brown hues are left out (they sink into the brown canvas). Steady lightness, softer chroma.
            let hues: [Double] = [70, 255, 42, 150, 0, 228, 95, 292, 25, 128, 322, 195]
            return OKLCH.color(l: 0.73 + (i % 2 == 1 ? 0.04 : 0), c: i == 11 ? 0.075 : 0.115, h: hues[i])
        }
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
