// Design tokens, typography and presentation families ("06 - Design/Theme System.md") and the track colour
// system ("06 - Design/Track Colors.md").
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum Theme {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    enum Style: String, CaseIterable {
        case graphite, warmAnalog, prism, atelier
        /// A theme is a title, a palette, a look and a typography (A-17, "06 - Design/Theme System.md"). Views read
        /// tokens and look families, never the style itself, so a new theme is a new case here.
        var title: String {
            switch self { case .graphite: "Graphite"; case .warmAnalog: "Warm Analog"; case .prism: "Prism"; case .atelier: "Atelier" }
        }
        var summary: String {
            switch self {
            case .graphite: "Modern digital workstation: efficient, clear, minimal"
            case .warmAnalog: "Physical recording studio: tactile hardware and warm light"
            case .prism: "Spatial glass canvas: light, depth and colour"
            case .atelier: "Sketchbook: everything drawn by hand in pen, ink wash and hatching"
            }
        }
        /// The light and dark versions a theme offers (Graphite and Warm Analog are dark studios only).
        var variants: [Variant] { switch self { case .graphite, .warmAnalog: [.dark]; case .prism, .atelier: [.dark, .light] } }
        /// The version used when the system's appearance isn't followed and none was chosen.
        var defaultVariant: Variant { self == .atelier ? .light : .dark }
        func palette(_ v: Variant) -> Palette {
            switch self {
            case .graphite: .graphite
            case .warmAnalog: .warmAnalog
            case .prism: v == .light ? .prismLight : .prism
            case .atelier: v == .light ? .atelier : .atelierDark
            }
        }
        var palette: Palette { palette(Theme.activeStyle == self ? Theme.activeVariant : defaultVariant) }
        var look: Look { switch self { case .graphite: .graphite; case .warmAnalog: .warmAnalog; case .prism: .prism; case .atelier: .atelier } }
        var typography: Typography {
            switch self { case .graphite, .warmAnalog: .system; case .prism: .prism; case .atelier: .atelier }
        }
    }

    /// Light or dark version of a theme.
    enum Variant: String, CaseIterable { case dark, light; var title: String { self == .light ? "Light" : "Dark" } }
    /// Settings ▸ Appearance ▸ Light/Dark: "system" follows macOS, else "light" or "dark".
    static var variantPreference: String {
        get { UserDefaults.standard.string(forKey: "appearanceVariant") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "appearanceVariant") }
    }
    /// The version a style shows under the current preference and system appearance.
    static func resolvedVariant(for style: Style, preference: String = variantPreference) -> Variant {
        guard style.variants.count > 1 else { return style.variants[0] }
        if let v = Variant(rawValue: preference) { return v }
        // The system setting itself (readable from any thread, unlike NSApp.effectiveAppearance).
        let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        return dark ? .dark : .light
    }

    /// The colour tokens of a theme.
    struct Palette {
        var window, panel, panelRaised, control, controlHi, laneA, laneB, laneHighlight, lcd: UInt32
        var text, textDim, textFaint, accent, playhead, cycle, selectedHeader, knobHover: UInt32
        var launcher: UInt32 // the clip launcher's background
        /// Overlay colours: `ink` draws marks over surfaces (grid, hairlines, highlights), `shade` darkens them
        /// (separators, shadows). Dark themes: white ink, black shade; light themes the other way round.
        var ink: UInt32 = 0xFFFFFF, shade: UInt32 = 0x000000
        var light = false            // a light canvas: overlays are dark, shadows soft
        var well: UInt32 = 0x0A0B0D  // recessed grooves (fader tracks, meter wells)
        var selection: UInt32 = 0xFFFFFF
        // State colours (always paired with a letter or shape).
        var muteOn: UInt32 = 0x5B9BFF, soloOn: UInt32 = 0xF5C451, monitorOn: UInt32 = 0xE8892B, recordOn: UInt32 = 0xE5484D
        var clipRed: UInt32 = 0xFF5A4F
        static let graphite = Palette(window: 0x111214, panel: 0x17181B, panelRaised: 0x1D1F23, control: 0x2A2D33, controlHi: 0x3A3E46,
                                      laneA: 0x141518, laneB: 0x16171A, laneHighlight: 0x1C1E22, lcd: 0x0B0C0E,
                                      text: 0xE8E9EC, textDim: 0x9A9EA6, textFaint: 0x898E97, accent: 0xE8B25C, playhead: 0xF4F4F5,
                                      cycle: 0xE9C24A, selectedHeader: 0x262930, knobHover: 0x44484F, launcher: 0x17181B)
        static let warmAnalog = Palette(window: 0x18130F, panel: 0x211A15, panelRaised: 0x2A211A, control: 0x403229, controlHi: 0x584638,
                                        laneA: 0x1C1713, laneB: 0x201A15, laneHighlight: 0x2A2019, lcd: 0x120D0A,
                                        text: 0xF2E7D7, textDim: 0xC0AB96, textFaint: 0x9B8876, accent: 0xE6AB69, playhead: 0xF6E5CE,
                                        cycle: 0xE8B54F, selectedHeader: 0x3A2B21, knobHover: 0x685344, launcher: 0x15100C)
        /// Prism: night glass. Deep blue-violet depths, cool white light, an iridescent cyan-to-violet accent.
        static let prism = Palette(window: 0x090B14, panel: 0x10131F, panelRaised: 0x151929, control: 0x232A42, controlHi: 0x323A5C,
                                   laneA: 0x0C0F1A, laneB: 0x0E111D, laneHighlight: 0x171C31, lcd: 0x060812,
                                   text: 0xEEF1FF, textDim: 0xA9B0CF, textFaint: 0x8A92B6, accent: 0x8CD3FF, playhead: 0xF4F8FF,
                                   cycle: 0xF0CF6E, selectedHeader: 0x1F2643, knobHover: 0x3B4468, launcher: 0x0B0E18,
                                   well: 0x05070E, muteOn: 0x6EA8FF, soloOn: 0xF6D36A, monitorOn: 0xF0A050, recordOn: 0xFF5C6C, clipRed: 0xFF6A72)
        /// Prism Light: daylight glass. Pale frosted panes over a soft pastel light field, ink-blue type.
        static let prismLight = Palette(window: 0xE9EDF8, panel: 0xEEF1FA, panelRaised: 0xF4F6FC, control: 0xD6DCEE, controlHi: 0xC3CBE4,
                                        laneA: 0xEDF0F9, laneB: 0xE9ECF7, laneHighlight: 0xDCE3F6, lcd: 0xF7F9FE,
                                        text: 0x141A33, textDim: 0x434B6B, textFaint: 0x5F6788, accent: 0x2F6BFF, playhead: 0x1A2A6C,
                                        cycle: 0xC99212, selectedHeader: 0xD9E1F7, knobHover: 0xC9D2EE, launcher: 0xE7EBF7,
                                        ink: 0x141A33, shade: 0x2A3566, light: true, well: 0xD3D9EC, selection: 0x2F6BFF,
                                        muteOn: 0x2F6BFF, soloOn: 0xE0A81C, monitorOn: 0xE07B1C, recordOn: 0xE5364A, clipRed: 0xE5364A)
        /// Atelier Dark: white gel pen in a black sketchbook. Warm off-white ink, the same vermilion, brighter pigments.
        static let atelierDark = Palette(window: 0x1A1916, panel: 0x1F1E1A, panelRaised: 0x24231F, control: 0x34322C, controlHi: 0x45423A,
                                         laneA: 0x1D1C19, laneB: 0x21201C, laneHighlight: 0x2C2A24, lcd: 0x171613,
                                         text: 0xEDE6D6, textDim: 0xBDB4A1, textFaint: 0x9A917F, accent: 0xE8684A, playhead: 0xE8684A,
                                         cycle: 0xD8A63E, selectedHeader: 0x34302A, knobHover: 0x47433B, launcher: 0x1B1A17,
                                         ink: 0xEDE6D6, well: 0x121110, selection: 0xEDE6D6,
                                         muteOn: 0x6FA8C6, soloOn: 0xD9AB4A, monitorOn: 0xD9873A, recordOn: 0xE8684A, clipRed: 0xE8684A)
        /// Atelier: a sketchbook. Cream drawing paper, sepia-black pen, a red pen for the few things that must be seen.
        static let atelier = Palette(window: 0xF0E8D7, panel: 0xF4EDDF, panelRaised: 0xF9F4E9, control: 0xE1D6C0, controlHi: 0xCDC0A5,
                                     laneA: 0xFBF7EE, laneB: 0xF6F0E3, laneHighlight: 0xEFE4CC, lcd: 0xFBF8F1,
                                     text: 0x231D16, textDim: 0x51483B, textFaint: 0x6B6253, accent: 0xC73E26, playhead: 0xC73E26,
                                     cycle: 0xB9861F, selectedHeader: 0xE9DFC9, knobHover: 0xD6C9AE, launcher: 0xF1ECE1,
                                     ink: 0x231D16, shade: 0x3B2F1E, light: true, well: 0xE3DACA, selection: 0x231D16,
                                     muteOn: 0x2B5C8A, soloOn: 0xC9962E, monitorOn: 0xB86A1F, recordOn: 0xC4422A, clipRed: 0xC4422A)
    }

    /// How a theme draws each part of the window, by area (presentation families). Views ask for the family they
    /// draw ("how are clips drawn?"), never which theme is on, so a fifth theme picks families or adds one.
    struct Look {
        enum Arrangement { case flat, glass, manuscript }          // lanes, grid, ruler, clips, playhead
        enum Headers { case rows, channelStrips, glass, scoreLabels } // track headers
        enum Transport { case lcd, tapeDeck, glassCapsule, typeset }
        enum Mixer { case flat, console, glass, instrument }
        enum Controls { case flat, hardware, glass, drafted }      // knobs, faders, chips
        enum Meters { case bars, ledLadder, lightPipe, graduated }
        enum Editors { case grid, tape, glass, engraved }          // piano roll, comp editor
        enum Devices { case rack, pedalboard, cards, schematic }   // device chain
        enum TrackColors { case rainbow, console, spectral, inks }
        enum Motion { case standard, lamp, glass, drafting }       // personality of the shared Motion helpers
        var arrangement: Arrangement, headers: Headers, transport: Transport, mixer: Mixer, controls: Controls
        var meters: Meters, editors: Editors, devices: Devices, trackColors: TrackColors, motion: Motion

        // Capability questions the views already ask (derived, so each family has one source of truth).
        var pedalboard: Bool { devices == .pedalboard }            // stomp boxes patched with cables on a board
        var consoleMixer: Bool { mixer == .console }               // walnut cheeks, needle meter, channel modules
        var channelStripHeaders: Bool { headers == .channelStrips } // channel modules with scribble strips
        var tapeDeck: Bool { transport == .tapeDeck }              // tape strip, reels, VFD position display
        var hardwareControls: Bool { controls == .hardware }       // knobs with caps, filament lamps, moulded buttons
        var ledLadderMeters: Bool { meters == .ledLadder }
        var tapeEditors: Bool { editors == .tape }                 // comp editor as tape, piano roll on ledger paper
        var consoleTrackColors: Bool { trackColors == .console }

        static let graphite = Look(arrangement: .flat, headers: .rows, transport: .lcd, mixer: .flat, controls: .flat, meters: .bars,
                                   editors: .grid, devices: .rack, trackColors: .rainbow, motion: .standard)
        static let warmAnalog = Look(arrangement: .flat, headers: .channelStrips, transport: .tapeDeck, mixer: .console, controls: .hardware,
                                     meters: .ledLadder, editors: .tape, devices: .pedalboard, trackColors: .console, motion: .lamp)
        static let prism = Look(arrangement: .glass, headers: .glass, transport: .glassCapsule, mixer: .glass, controls: .glass,
                                meters: .lightPipe, editors: .glass, devices: .cards, trackColors: .spectral, motion: .glass)
        static let atelier = Look(arrangement: .manuscript, headers: .scoreLabels, transport: .typeset, mixer: .instrument, controls: .drafted,
                                  meters: .graduated, editors: .engraved, devices: .schematic, trackColors: .inks, motion: .drafting)
    }

    /// A theme's type system: which faces set interface labels, figures (tabular numbers), titles (track and clip
    /// names, headings) and the large position display. Faces are bundled (Resources/Fonts) and fall back to the
    /// system's when missing.
    struct Typography {
        enum Face { case system, sora, plexCondensed }
        enum Figures { case system, geistMono, plexMono }
        enum Titles { case asLabels, serif }
        var face: Face, figures: Figures, titles: Titles
        /// Labels set in spaced capitals (section heads, small legends).
        var capsLabels: Bool
        /// Size factor for the label face (wide faces set slightly smaller to keep layouts).
        var labelScale: CGFloat
        static let system = Typography(face: .system, figures: .system, titles: .asLabels, capsLabels: false, labelScale: 1)
        static let prism = Typography(face: .sora, figures: .geistMono, titles: .asLabels, capsLabels: false, labelScale: 0.93)
        static let atelier = Typography(face: .plexCondensed, figures: .plexMono, titles: .serif, capsLabels: true, labelScale: 1.04)
    }

    static var palette: Palette { activeStyle.palette(activeVariant) }
    static var look: Look { activeStyle.look }
    static var typography: Typography { activeStyle.typography }
    static var isLight: Bool { palette.light }
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
    /// The version the windows are drawn with. DALNOK_VARIANT (captures, tests) sets it at launch only.
    nonisolated(unsafe) static var activeVariant: Variant = { // main thread only
        if let v = ProcessInfo.processInfo.environment["DALNOK_VARIANT"].flatMap(Variant.init(rawValue:)), activeStyle.variants.contains(v) { return v }
        return resolvedVariant(for: activeStyle)
    }()
    /// The system appearance under the theme (menus, sheets, scroll bars, text fields): Aqua for light themes.
    static var appearance: NSAppearance? { NSAppearance(named: palette.light ? .aqua : .darkAqua) }
    private static func tone(_ token: KeyPath<Palette, UInt32>) -> NSColor { hex(palette[keyPath: token]) }

    // MARK: Neutrals (4 elevation steps)
    static var window: NSColor { tone(\.window) }
    static var panel: NSColor { tone(\.panel) }        // ruler, control bar
    static var panelRaised: NSColor { tone(\.panelRaised) }  // track headers
    static var control: NSColor { tone(\.control) }      // fader grooves, chip backgrounds
    static var controlHi: NSColor { tone(\.controlHi) }
    static var laneA: NSColor { tone(\.laneA) }
    static var laneB: NSColor { tone(\.laneB) }
    static var laneHighlight: NSColor { tone(\.laneHighlight) } // selected track's lane
    static var lcd: NSColor { tone(\.lcd) }           // position display well
    static var well: NSColor { tone(\.well) }         // recessed grooves
    /// A mark over any surface: white on dark themes, ink on light ones (scaled so the same call reads alike).
    static func ink(_ alpha: CGFloat) -> NSColor { hex(palette.ink, min(1, alpha * (isLight ? 1.6 : 1))) }
    /// A shadow or separator over any surface.
    static func shade(_ alpha: CGFloat) -> NSColor { hex(palette.shade, isLight ? alpha * 0.4 : alpha) }
    static var hairline: NSColor { ink(0.07) }
    static var separator: NSColor { shade(0.55) }
    static var gridMajor: NSColor { ink(0.06) }
    static var gridMinor: NSColor { ink(0.025) }
    static var text: NSColor { tone(\.text) }
    static var textDim: NSColor { tone(\.textDim) }
    static var textFaint: NSColor { tone(\.textFaint) }

    // MARK: Reserved state colors (never used for tracks alone; always paired with form)
    static var accent: NSColor { tone(\.accent) }        // time display / brand
    static var playhead: NSColor { tone(\.playhead) }
    static var selection: NSColor { tone(\.selection) }
    static var cycle: NSColor { tone(\.cycle) } // cycle region in the ruler (Logic users know it as yellow)
    static var muteOn: NSColor { tone(\.muteOn) }        // blue chip (Logic convention)
    static var soloOn: NSColor { tone(\.soloOn) }        // yellow chip
    static var monitorOn: NSColor { tone(\.monitorOn) }  // orange chip: Input Monitoring (as in Logic)
    static var clipRed: NSColor { tone(\.clipRed) }
    static var recordOn: NSColor { tone(\.recordOn) }    // record arm / recording (always with an "R" or ● shape)
    static var selectedHeader: NSColor { tone(\.selectedHeader) }
    static var knobHover: NSColor { tone(\.knobHover) }
    /// Text on a lit state chip (mute, record, monitoring): white on saturated chips, ink on pale ones.
    static func onState(_ c: NSColor) -> NSColor { TrackTint.textColor(on: c, over: c) }

    // MARK: Metrics (4-pt grid)
    static let rulerHeight: CGFloat = 28
    static let baseTrackHeight: CGFloat = 88
    /// Default lane height (View ▸ Taller/Shorter Tracks, ⌥-scroll): 48 to 400 pt, remembered between launches.
    /// A track can also have its own height (drag a header's bottom edge).
    static var trackHeight: CGFloat {
        get {
            if let h = cachedTrackHeight { return h }
            let v = UserDefaults.standard.double(forKey: "trackHeight")
            let h = v >= 48 ? min(400, CGFloat(v)) : baseTrackHeight
            cachedTrackHeight = h
            return h
        }
        set {
            let h = min(400, max(48, newValue))
            cachedTrackHeight = h
            UserDefaults.standard.set(Double(h), forKey: "trackHeight")
        }
    }
    nonisolated(unsafe) private static var cachedTrackHeight: CGFloat?
    static let headerWidth: CGFloat = 248
    static let transportHeight: CGFloat = 52
    static let trafficLightInset: CGFloat = 78

    // MARK: Type scale (roles; the theme's Typography picks the faces)
    /// Figures: tabular numbers for counters, values, dB scales and the clock.
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        switch typography.figures {
        case .system: break
        case .geistMono:
            if let f = BundledFonts.font(weight >= .medium ? "GeistMono-Medium" : weight <= .light ? "GeistMono-Light" : "GeistMono-Regular", size) { return f }
        case .plexMono:
            if let f = BundledFonts.font(weight >= .medium ? "IBMPlexMono-Medium" : "IBMPlexMono-Regular", size) { return f }
        }
        return .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
    /// Interface labels.
    static func ui(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let t = typography, s = (size * t.labelScale * 2).rounded() / 2
        switch t.face {
        case .system: break
        case .sora:
            if let f = BundledFonts.font(weight >= .medium ? "Sora-SemiBold" : "Sora-Regular", s) { return tabular(f) }
        case .plexCondensed:
            let name = weight >= .semibold ? "IBMPlexSansCond-SemiBold" : weight >= .medium ? "IBMPlexSansCond-Medium" : "IBMPlexSansCond-Regular"
            if let f = BundledFonts.font(name, s) { return f }
        }
        return .systemFont(ofSize: size, weight: weight)
    }
    /// Titles: track names, clip names, headings. Atelier sets them in a text serif; the others use the label face.
    static func title(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        guard typography.titles == .serif else { return ui(size, weight) }
        let name = weight >= .semibold ? "SourceSerif4Roman-16ptSemiBold" : "SourceSerif4Roman-16pt"
        return BundledFonts.font(name, size * 1.08) ?? ui(size, weight)
    }
    /// The large position display and other display figures.
    static func display(_ size: CGFloat) -> NSFont {
        switch activeStyle {
        case .prism: BundledFonts.font("GeistMono-Light", size) ?? mono(size, .light)
        case .atelier: BundledFonts.font("SourceSerif4Roman-48pt", size * 1.12).map(lining) ?? mono(size, .medium)
        default: mono(size, .medium)
        }
    }
    /// Italic annotations (Atelier's marginal notes); the label face elsewhere.
    static func note(_ size: CGFloat) -> NSFont {
        guard typography.titles == .serif, let f = BundledFonts.font("SourceSerif4Italic-16ptItalic", size * 1.06) else { return ui(size) }
        return f
    }
    /// A label as the theme sets it: spaced capitals in Atelier, as written elsewhere.
    static func label(_ text: String) -> String { typography.capsLabels ? text.uppercased() : text }
    /// Letter spacing for `label` text (points).
    static var labelTracking: CGFloat { typography.capsLabels ? 0.8 : 0 }
    /// Tabular, lining figures, so values don't jitter as they change.
    static func tabular(_ f: NSFont) -> NSFont {
        let d = f.fontDescriptor.addingAttributes([.featureSettings: [
            [NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: d, size: f.pointSize) ?? f
    }
    static func lining(_ f: NSFont) -> NSFont {
        let d = f.fontDescriptor.addingAttributes([.featureSettings: [
            [NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType, NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector],
            [NSFontDescriptor.FeatureKey.typeIdentifier: kNumberCaseType, NSFontDescriptor.FeatureKey.selectorIdentifier: kUpperCaseNumbersSelector]]])
        return NSFont(descriptor: d, size: f.pointSize) ?? f
    }

    // MARK: Track colors

    static let gradientSteps = 12
    /// Graphite: rainbow gradient starting at green, 12 steps of 30° in OKLCH, equal lightness/chroma,
    /// odd steps slightly lighter so adjacent tracks also differ in lightness (color-blind safety).
    static func gradientColor(step: Int) -> NSColor {
        let n = gradientSteps
        let i = ((step % n) + n) % n
        switch look.trackColors {
        case .spectral:
            // Prism: light through a prism. Bright, clear spectral hues that hold up as tinted glass on the dark canvas;
            // neighbours alternate a little in lightness.
            let hue = 200.0 + 360.0 / Double(n) * Double(i)
            return OKLCH.color(l: (isLight ? 0.64 : 0.76) + (i % 2 == 1 ? 0.05 : 0), c: 0.15, h: hue)
        case .inks:
            // Atelier: drawing inks on ivory. Deep, slightly muted pigments (vermilion, ochre, teal, indigo, ...) at a
            // lightness that keeps dark waveforms and white-on-ink labels readable; warm and cool alternate.
            let hues: [Double] = [35, 230, 85, 165, 330, 255, 60, 195, 10, 140, 290, 110]
            return OKLCH.color(l: (isLight ? 0.56 : 0.72) + (i % 2 == 1 ? 0.05 : 0), c: 0.115, h: hues[i])
        case .rainbow, .console: break
        }
        if look.consoleTrackColors {
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
    private var family: Theme.Look.Arrangement { Theme.look.arrangement }
    var body: NSColor { base.withAlphaComponent(family == .glass ? 0.13 : family == .manuscript ? 0.12 : 0.17) }
    var bodySelected: NSColor { base.withAlphaComponent(family == .glass ? 0.30 : family == .manuscript ? 0.22 : 0.27) }
    var title: NSColor { base.withAlphaComponent(family == .glass ? 0.36 : family == .manuscript ? 0.9 : 0.48) }
    var titleSelected: NSColor { base.withAlphaComponent(family == .glass ? 0.62 : 1) }
    var waveform: NSColor {
        switch family {
        case .manuscript: OKLCH.adjust(base, dl: Theme.isLight ? -0.22 : 0.1, chromaScale: 0.9)   // ink drawn on the paper
        case .glass: OKLCH.adjust(base, dl: Theme.isLight ? -0.2 : 0.14, chromaScale: 0.85)     // light suspended in the glass
        case .flat: OKLCH.adjust(base, dl: 0.12, chromaScale: 0.85)
        }
    }
    var border: NSColor { OKLCH.adjust(base, dl: Theme.isLight ? -0.12 : -0.18, chromaScale: 0.9).withAlphaComponent(0.9) }
    var muted: NSColor { OKLCH.adjust(base, dl: Theme.isLight ? 0.18 : -0.25, chromaScale: 0.15) }

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
