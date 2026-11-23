// Graphite faceplate displays: the instrument panel each kind of plug-in gets beside its controls.
// Dynamics get a backlit moving-coil gain-reduction meter; EQs and filters a response screen (the exact curve for
// Dalnok's own EQs, a curve measured from the signal for hosted ones, over a live spectrum); everything else a
// phosphor oscilloscope. They read the engine's per-plug-in meters and display tap (live playback only).
// SPDX-License-Identifier: GPL-3.0-or-later
import Accelerate
import DalnokEngine
import AppKit

@MainActor
enum FaceplateDisplay {
    enum Kind: String, CaseIterable, Equatable {
        case gainReduction, vu, response, transfer, history, goniometer, analyzer, scope
        var title: String {
            switch self {
            case .gainReduction: "Gain-Reduction Meter"
            case .vu: "VU Meter"
            case .response: "EQ Response"
            case .transfer: "Transfer Curve"
            case .history: "Level History"
            case .goniometer: "Goniometer"
            case .analyzer: "Spectrum Analyzer"
            case .scope: "Oscilloscope"
            }
        }
    }

    /// The display a plug-in gets. In order: the owner's choice for that plug-in; what the plug-in declares (VST3
    /// subcategories, CLAP features, Audio Unit tags and Apple subtypes); what its parameters say it does; its name.
    /// Every step is a fixed rule, so any plug-in, known or not, gets the same answer every time.
    static func kind(name: String, path: String, instrument: Bool, declared: [String] = [], parameters: [String] = []) -> Kind {
        if let chosen = override(name) { return chosen }
        if instrument { return .scope }
        let parts = path.split(separator: ":")
        let format = parts.count == 3 && parts.allSatisfy({ $0.count == 4 }) ? "AU" : path.hasSuffix(".clap") ? "CLAP" : "VST3"
        let cats = declared.isEmpty ? (Self.declared[path] ?? []) : declared
        // The same classification the plug-in browser shows (declaration first, then name).
        let category = PluginTaxonomy.classify(name: name, kind: "effect", format: format, path: path, categories: cats).category
        let weak = category == "Other Effects"
            || category == "Utility / Gain" && PluginTaxonomy.classify(name: name, kind: "effect", format: format, path: path, categories: []).category == "Other Effects"
        if !weak { return kind(category: category) }
        // Nothing specific declared or in the name: the parameters decide.
        return kind(parameters: parameters) ?? kind(category: category)
    }

    static func kind(category: String) -> Kind {
        switch category {
        case "Compression", "Limiting", "Gate / Expander": .gainReduction
        case "EQ", "Filtering": .response
        case "Distortion / Saturation": .transfer
        case "Reverb", "Delay / Echo": .history
        case "Chorus / Flanger / Phaser", "Modulation", "Stereo Imaging", "Spatial Audio": .goniometer
        case "Pitch / Time", "Restoration / Noise Reduction", "Metering / Analysis": .analyzer
        case "Utility / Gain": .vu
        default: .scope
        }
    }

    /// What a plug-in's parameter names say it does, when it declares nothing specific. Nil if they don't say.
    static func kind(parameters titles: [String]) -> Kind? {
        let t = titles.map { $0.lowercased() }
        func count(_ keys: [String]) -> Int { t.filter { title in keys.contains { title.contains($0) } }.count }
        func any(_ keys: [String]) -> Bool { count(keys) > 0 }
        // Many bands with frequency and gain is an EQ even when it also has dynamics per band (dynamic EQs).
        if count(["freq", "hz"]) >= 3 && count(["gain"]) >= 3 && !any(["crossover", "xover"]) { return .response }
        if any(["threshold", "ceiling"]) && any(["ratio", "attack", "release", "knee", "ceiling", "range", "hold"]) { return .gainReduction }
        if count(["freq", "hz"]) >= 2 && count(["gain", " db"]) >= 2 || any(["cutoff"]) && any(["resonance", "reso", " q"]) { return .response }
        if count(["decay", "room", "size", "pre-delay", "predelay", "diffusion", "damping", "reverb", "early", "late"]) >= 2 { return .history }
        // Modulation before delay: flangers and choruses have delay and feedback controls too.
        if any(["rate", "speed"]) && any(["depth", "intensity", "amount"]) || any(["width", "spread", "stereo"]) { return .goniometer }
        if any(["delay time", "echo"]) || any(["time", "delay"]) && any(["feedback"]) { return .history }
        if any(["drive", "saturat", "distort", "fuzz", "overdrive", "crush", "bias"]) { return .transfer }
        if any(["pitch", "semitone", "transpose", "formant", "cents"]) { return .analyzer }
        if !t.isEmpty && t.count <= 4 && t.allSatisfy({ ["gain", "trim", "volume", "pan", "balance", "polarity", "phase", "mute"].contains(where: $0.contains) }) { return .vu }
        return nil
    }

    /// The owner's choice of display for a plug-in (right-click a unit ▸ Display). Nil: automatic.
    static func override(_ name: String) -> Kind? {
        UserDefaults.standard.string(forKey: "faceplate.display." + name).flatMap(Kind.init(rawValue:))
    }
    static func setOverride(_ name: String, _ kind: Kind?) {
        UserDefaults.standard.set(kind?.rawValue, forKey: "faceplate.display." + name)
    }

    /// Categories plug-ins declare (VST3 subcategories, CLAP features), from the plug-in metadata, by path. Read once.
    static let declared: [String: [String]] = {
        let n = dalnok_plugins_scan(nil, true, nil, 0)
        guard n > 0 else { return [:] }
        var buf = [CChar](repeating: 0, count: n + 1)
        dalnok_plugins_scan(nil, true, &buf, buf.count)
        var merged: [String: [String]] = PluginManagerController.cachedCategories().reduce(into: [:]) { out, e in
            if let colon = e.key.firstIndex(of: ":") { out[String(e.key[e.key.index(after: colon)...])] = e.value }
        }
        let text = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? []
        for p in list { if let path = p["path"] as? String, let c = p["categories"] as? [String], !c.isEmpty { merged[path] = c } }
        return merged
    }()

    /// Display size for a unit whose controls take `rows` rows.
    static func size(_ kind: Kind, rows: Int) -> NSSize {
        let s = baseSize(kind, rows: rows)
        // Atelier: the figure is the plate's centre, as tall as the plate allows, with its caption.
        guard Theme.look.devices == .schematic else { return s }
        let w: CGFloat = switch kind {
        case .response: 250
        case .history: 236
        case .gainReduction: 196
        case .transfer: 210
        case .goniometer: 216
        default: max(s.width, 176)
        }
        return NSSize(width: w, height: 158 + Codex.captionHeight + DevicePanel.extra)
    }
    private static func baseSize(_ kind: Kind, rows: Int) -> NSSize {
        switch kind {
        case .gainReduction, .vu: NSSize(width: rows > 1 ? 172 : 150, height: rows > 1 ? 120 : 104)
        case .response, .history, .analyzer: NSSize(width: rows > 1 ? 236 : 200, height: rows > 1 ? 140 : 104)
        case .transfer, .goniometer: NSSize(width: rows > 1 ? 140 : 112, height: rows > 1 ? 140 : 104)
        case .scope: NSSize(width: rows > 1 ? 168 : 150, height: rows > 1 ? 120 : 104)
        }
    }

    // MARK: Shared drawing

    /// A recessed bezel around a display window: dark machined frame, inner shadow, and the window's rect.
    static func bezel(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat = 5) -> CGRect {
        switch Theme.look.devices {
        case .schematic: return rect.insetBy(dx: 4, dy: 4) // the plot's frame is drawn after the ink pass
        case .cards: // no well: the screen is drawn straight onto the card's glass (FaceplateScreen.drawOnGlass)
            return rect.insetBy(dx: 4, dy: 4)
        case .rack, .pedalboard: break
        }
        let outer = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.addPath(outer); ctx.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(outer); ctx.clip()
        let colors = [NSColor(white: 0.20, alpha: 1).cgColor, NSColor(white: 0.10, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(outer); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        return rect.insetBy(dx: 4, dy: 4)
    }

    /// Glass over a window: a soft diagonal glare and an inner shadow at the top edge.
    static func glass(_ ctx: CGContext, _ window: CGRect, radius: CGFloat) {
        if Theme.look.devices == .schematic || Theme.look.devices == .cards { return }
        let path = CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let glare = [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glare, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: window.minX, y: window.minY), end: CGPoint(x: window.minX + window.width * 0.45, y: window.midY),
                                   options: [])
        }
        let inner = [NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: inner, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: window.minY), end: CGPoint(x: 0, y: window.minY + 6), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1); ctx.strokePath()
    }

    static func text(_ s: String, at rect: CGRect, font: NSFont, color: NSColor, align: NSTextAlignment = .center) {
        let para = NSMutableParagraphStyle(); para.alignment = align
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
    }
}

// MARK: Power and wear

/// Base for the faceplate's displays. Their backlight follows the unit's power (bypassed: the screen goes dark, the
/// meter's lamps go out), and their glass gathers dust, smudges and hairline scratches with Settings ▸ wear.
@MainActor
class FaceplateScreen: NSView {
    var poweredOff = false { didSet { if poweredOff != oldValue { needsDisplay = true } } }
    /// How lit the backlight or lamps are (0 … 1): fades with bypass (DeviceView drives it).
    var light: CGFloat = 1 { didSet { if light != oldValue { needsDisplay = true } } }
    /// Stable per unit (its name), so each unit's dust stays where it is.
    var seed: UInt64 = 1 { didSet { needsDisplay = true } }
    /// Atelier: the figure's number in the chain ("Fig. 2"), its display kind and what it depicts (Codex figures).
    var figureNumber = 1 { didSet { if figureNumber != oldValue { needsDisplay = true } } }
    var codexKind: FaceplateDisplay.Kind = .scope
    var codexSubject: Codex.Subject = .plain
    /// Atelier figures as instruments (AtelierFigures.swift): the parameter link, the parts drawn last, a drag in progress.
    var figureLink: FigureLink? { didSet { needsDisplay = true } }
    var figureHandles: [FigureHandle] = []
    var figureDrag: (role: FigureRole, start: CGPoint, value: Double, handle: FigureHandle)?
    var marginNotes: [String] = []
    /// The figure's own motion (radians, advanced by `FigureClock`; 0 in stills and under Reduce Motion): the governor
    /// spins, the pendulum swings, the crank turns, the waves run, the chamber's sound travels.
    var figureAngle: Double = 0
    /// The last live value the figure was drawn with (the governor spins faster as it reduces).
    var figureLive: Double = -90
    /// The part under the pointer (lit with its key row, and the machine holds still so it can be taken), and the part
    /// whose key row is under the pointer.
    var hoverRole: FigureRole? { didSet { if hoverRole != oldValue { needsDisplay = true; onHoverRole?(hoverRole) } } }
    var highlightRole: FigureRole? { didSet { if highlightRole != oldValue { needsDisplay = true } } }
    var onHoverRole: ((FigureRole?) -> Void)?
    /// The latest input/output pairs (transfer figures), normalised to the input's peak.
    var liveTransfer: [CGPoint] { [] }
    /// The family's figure (Atelier engraves it; Graphite and Prism draw it in their own idiom, LookFigures.swift).
    var atelierFigure: AtelierFigure? {
        switch Theme.look.devices {
        case .schematic, .rack, .cards: AtelierFigure.of(kind: codexKind, subject: codexSubject)
        case .pedalboard: nil
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if !(atelierFigure != nil && figureMouseDown(event)) { super.mouseDown(with: event) } }
    override func mouseDragged(with event: NSEvent) { if figureDrag != nil { figureMouseDragged(event) } else { super.mouseDragged(with: event) } }
    override func mouseUp(with event: NSEvent) { if figureDrag != nil { figureMouseUp() } else { super.mouseUp(with: event) } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard atelierFigure != nil else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        guard atelierFigure != nil, figureDrag == nil else { return super.mouseMoved(with: event) }
        hoverRole = figureHandle(at: convert(event.locationInWindow, from: nil))?.role
    }
    override func mouseExited(with event: NSEvent) { if figureDrag == nil { hoverRole = nil } }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && atelierFigure != nil { FigureClock.shared.add(self) } else { FigureClock.shared.remove(self) }
    }
    /// Displays that render their own unlit state (the moving-coil meter keeps its face, just without lamps).
    var drawsOwnOffState: Bool { false }
    /// A light face behind the glass (the VU meter's paper): dirt shows dark on it rather than pale.
    var lightFace: Bool { false }
    override var isFlipped: Bool { true }
    /// Prism: displays that already draw themselves for the glass (the moving-coil meter).
    var drawsOnGlass: Bool { false }
    final override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if drawLookFigure(ctx) { return }
        if Theme.look.devices == .cards && !drawsOnGlass { drawOnGlass(ctx, dirtyRect); return }
        if Theme.look.devices == .schematic && drawCodex(ctx) { return }
        // The screen's contents fade with its backlight into dark glass (fully dark: only the glass is drawn).
        let off = drawsOwnOffState ? 0 : 1 - light
        if off < 0.99 { drawScreen(dirtyRect) }
        if off > 0.01 {
            let w = off >= 0.99 ? FaceplateDisplay.bezel(ctx, bounds) : bounds.insetBy(dx: 4, dy: 4)
            ctx.saveGState()
            ctx.setAlpha(min(1, off))
            ctx.addPath(CGPath(roundedRect: w, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.clip()
            let bg = [NSColor(white: 0.035, alpha: 1).cgColor, NSColor(white: 0.055, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: w.minY), end: CGPoint(x: 0, y: w.maxY), options: [])
            }
            ctx.restoreGState()
            if off >= 0.99 { FaceplateDisplay.glass(ctx, w, radius: 3) }
        }
        if Theme.look.devices == .schematic {
            Self.inkOnPaper(ctx, bounds.insetBy(dx: 4, dy: 4), invert: !lightFace)
            return
        }
        if Theme.look.devices == .cards { return } // glass doesn't gather dust
        FaceplateDisplay.wear(ctx, bounds.insetBy(dx: 4, dy: 4), radius: 3, seed: seed, amount: Faceplate.wear, lightFace: lightFace)
    }

    /// Prism: the screen has no window of its own. It is drawn offscreen as usual (light on a dark screen), then only its
    /// light is kept, with brightness as coverage, so the traces sit straight on the card's glass. One pass for every
    /// display, so each keeps its own drawing code. On the light version the light becomes ink of the same hue.
    private func drawOnGlass(_ ctx: CGContext, _ dirtyRect: NSRect) {
        let alpha = poweredOff ? 0.25 : max(0.25, light)
        let scale = window?.backingScaleFactor ?? 2
        let w = Int((bounds.width * scale).rounded(.up)), h = Int((bounds.height * scale).rounded(.up))
        guard w > 0, h > 0,
              let off = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        off.setFillColor(NSColor.black.cgColor); off.fill(CGRect(x: 0, y: 0, width: w, height: h))
        off.scaleBy(x: scale, y: scale)
        off.translateBy(x: 0, y: bounds.height); off.scaleBy(x: 1, y: -1) // this view is flipped
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: off, flipped: true)
        drawScreen(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = off.makeImage(),
              let grey = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
        grey.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Coverage from brightness: the screen's own background (up to about 14 %) drops out, and faint traces (grids,
        // spectra) are lifted so they still read on the glass.
        if let data = grey.data {
            let px = data.bindMemory(to: UInt8.self, capacity: grey.bytesPerRow * h)
            for i in 0..<(grey.bytesPerRow * h) { px[i] = Self.glassCurve[Int(px[i])] }
        }
        guard let mask = grey.makeImage() else { return }
        let r = bounds.insetBy(dx: 2, dy: 2)
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1) // images draw upright
        ctx.clip(to: bounds, mask: mask)
        ctx.setAlpha(alpha)
        if Theme.isLight {
            // Ink on milky glass: deep text colour, carrying each trace's hue.
            ctx.setFillColor(Theme.text.cgColor); ctx.fill(bounds)
            ctx.setBlendMode(.color); ctx.draw(image, in: bounds)
        } else {
            // Light in smoky glass: the traces, then the same light again added on top so dim fills still glow.
            ctx.draw(image, in: bounds)
            ctx.setBlendMode(.plusLighter); ctx.setAlpha(alpha * 0.6); ctx.draw(image, in: bounds)
        }
        if self is ResponseScreen || self is LedAnalyzer {
            // Dispersion: the response and spectrum take the spectrum's colour by frequency, lows red to highs violet.
            ctx.setBlendMode(.color); ctx.setAlpha(alpha * (Theme.isLight ? 0.75 : 0.9))
            let hues = (0...6).map { NSColor(calibratedHue: 0.78 * CGFloat($0) / 6, saturation: Theme.isLight ? 0.8 : 0.65, brightness: Theme.isLight ? 0.7 : 1, alpha: 1).cgColor } as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: hues, locations: nil) {
                ctx.drawLinearGradient(g, start: CGPoint(x: r.minX + 6, y: 0), end: CGPoint(x: r.maxX - 6, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        ctx.restoreGState()
    }

    private static let glassCurve: [UInt8] = (0..<256).map { i in
        let v = max(0, (Double(i) / 255 - 0.14) / 0.86)
        return UInt8(min(255, (pow(v, 0.55) * 255).rounded()))
    }

    /// Atelier: turns a lit screen into a plot in an engineering notebook. Light traces on dark glass become ink lines
    /// on the paper (inverted, then greyed and multiplied by the paper colour), with a fine graph-paper grid and an ink
    /// frame. One pass for every display, so each keeps its own drawing code.
    static func inkOnPaper(_ ctx: CGContext, _ r: CGRect, invert: Bool) {
        ctx.saveGState()
        ctx.clip(to: r)
        if Theme.isLight {
            if invert { ctx.setBlendMode(.difference); ctx.setFillColor(NSColor.white.cgColor); ctx.fill(r) }
            ctx.setBlendMode(.saturation); ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor); ctx.fill(r)
            ctx.setBlendMode(.multiply); ctx.setFillColor(Theme.lcd.cgColor); ctx.fill(r)
        } else {
            // Atelier Dark: chalk on the board. Traces keep their brightness (greyed, tinted chalk); black lifts to the board.
            ctx.setBlendMode(.saturation); ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor); ctx.fill(r)
            ctx.setBlendMode(.multiply); ctx.setFillColor(Theme.text.cgColor); ctx.fill(r)
            ctx.setBlendMode(.screen); ctx.setFillColor(Theme.lcd.cgColor); ctx.fill(r)
        }
        ctx.setBlendMode(.normal)
        // Graph paper: 8 pt squares, heavier every 4.
        var x = r.minX, i = 0
        while x <= r.maxX { ctx.setFillColor(Theme.ink(i % 4 == 0 ? 0.07 : 0.035).cgColor); ctx.fill(CGRect(x: x, y: r.minY, width: 0.5, height: r.height)); x += 8; i += 1 }
        var y = r.minY; i = 0
        while y <= r.maxY { ctx.setFillColor(Theme.ink(i % 4 == 0 ? 0.07 : 0.035).cgColor); ctx.fill(CGRect(x: r.minX, y: y, width: r.width, height: 0.5)); y += 8; i += 1 }
        ctx.restoreGState()
        Atelier.screen(ctx, r.insetBy(dx: 0.5, dy: 0.5), seed: Atelier.seed(r.origin, CGPoint(x: r.width, y: r.height)))
    }
    func drawScreen(_ dirtyRect: NSRect) {}
}

extension FaceplateDisplay {
    /// What years of use leave on a display's glass: dust specks, a few greasy smudges, hairline scratches and grime
    /// settled along the bottom of the bezel. `amount` 0 is factory new; the pattern is fixed by `seed`.
    static func wear(_ ctx: CGContext, _ window: CGRect, radius: CGFloat, seed: UInt64, amount: Double, lightFace: Bool = false) {
        guard amount > 0.001 else { return }
        var rng = Faceplate.Random(seed: seed ^ 0xA5A5_5A5A_1234_8765)
        let a = CGFloat(amount)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
        let space = CGColorSpaceCreateDeviceRGB()
        // Smudges: soft, uneven haze catching the light.
        // On a light face a smudge is a greasy, slightly brown film; on a dark screen it catches the light.
        let film = lightFace ? NSColor(srgbRed: 0.42, green: 0.36, blue: 0.26, alpha: 1) : NSColor(white: 0.85, alpha: 1)
        for _ in 0..<Int((1 + 4 * amount).rounded()) {
            let c = CGPoint(x: window.minX + rng.unit * window.width, y: window.minY + rng.unit * window.height)
            let r = (0.18 + 0.30 * rng.unit) * min(window.width, window.height)
            let alpha = (lightFace ? 0.16 : 0.075) * a * (0.5 + rng.unit)
            let colors = [film.withAlphaComponent(alpha).cgColor, film.withAlphaComponent(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y); ctx.scaleBy(x: 1, y: 0.55 + 0.4 * rng.unit); ctx.rotate(by: rng.unit * .pi)
                ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r, options: [])
                ctx.restoreGState()
            }
        }
        // Grime settled at the bottom edge and in the corners.
        let grime = [NSColor(srgbRed: 0.16, green: 0.13, blue: 0.09, alpha: 0.40 * a).cgColor, NSColor(srgbRed: 0.16, green: 0.13, blue: 0.09, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: grime, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: window.maxY), end: CGPoint(x: 0, y: window.maxY - 7 * a - 2), options: [])
            for corner in [CGPoint(x: window.minX, y: window.maxY), CGPoint(x: window.maxX, y: window.maxY),
                           CGPoint(x: window.minX, y: window.minY), CGPoint(x: window.maxX, y: window.minY)] {
                ctx.drawRadialGradient(g, startCenter: corner, startRadius: 0, endCenter: corner, endRadius: 6 + 10 * a, options: [])
            }
        }
        // Hairline scratches in the glass.
        for _ in 0..<Int((lightFace ? 10 : 6) * amount + rng.unit * 2 * amount) {
            let p = CGPoint(x: window.minX + rng.unit * window.width, y: window.minY + rng.unit * window.height)
            let ang = (rng.unit - 0.5) * 1.2 + (rng.unit < 0.5 ? 0 : .pi / 2), len = 8 + rng.unit * 34
            ctx.setStrokeColor((lightFace ? NSColor(white: 0.15, alpha: 0.14 + 0.22 * a * rng.unit) : NSColor(white: 1, alpha: 0.10 + 0.12 * a * rng.unit)).cgColor)
            ctx.setLineWidth(lightFace ? 0.45 : 0.35)
            ctx.move(to: p)
            ctx.addQuadCurve(to: CGPoint(x: p.x + cos(ang) * len, y: p.y + sin(ang) * len),
                             control: CGPoint(x: p.x + cos(ang + 0.15) * len / 2, y: p.y + sin(ang + 0.15) * len / 2))
            ctx.strokePath()
        }
        // Dust: pale specks, a few with a soft halo.
        let specks = Int(Double(window.width * window.height) / (lightFace ? 150 : 260) * amount)
        for _ in 0..<specks {
            let p = CGPoint(x: window.minX + rng.unit * window.width, y: window.minY + rng.unit * window.height)
            let r = 0.25 + 0.65 * rng.unit * rng.unit
            ctx.setFillColor((lightFace ? NSColor(srgbRed: 0.25, green: 0.21, blue: 0.16, alpha: 0.25 + 0.45 * rng.unit)
                                        : NSColor(srgbRed: 0.90, green: 0.88, blue: 0.82, alpha: 0.18 + 0.35 * rng.unit)).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        ctx.restoreGState()
    }
}

// MARK: Signal analysis

/// Power spectra of the tap's input and output (Hann window, 4096 points), averaged over time. From them come the
/// output spectrum and, where the input has energy, the measured magnitude response of the plug-in.
@MainActor
final class SpectrumAnalyzer {
    static let n = 4096
    nonisolated(unsafe) private let setup: vDSP_DFT_Setup?
    private let window: [Float]
    private(set) var inPower: [Float], outPower: [Float]
    private(set) var frames = 0

    init() {
        setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(Self.n), .FORWARD)
        var w = [Float](repeating: 0, count: Self.n)
        vDSP_hann_window(&w, vDSP_Length(Self.n), Int32(vDSP_HANN_NORM))
        window = w
        inPower = [Float](repeating: 0, count: Self.n / 2)
        outPower = inPower
    }
    deinit { if let setup { vDSP_DFT_DestroySetup(setup) } }

    private func power(_ x: [Float]) -> [Float] {
        guard let setup, x.count == Self.n else { return [Float](repeating: 0, count: Self.n / 2) }
        var windowed = [Float](repeating: 0, count: Self.n)
        vDSP_vmul(x, 1, window, 1, &windowed, 1, vDSP_Length(Self.n))
        let half = Self.n / 2
        var re = [Float](repeating: 0, count: half), im = re, outRe = re, outIm = re
        for i in 0..<half { re[i] = windowed[2 * i]; im[i] = windowed[2 * i + 1] }
        vDSP_DFT_Execute(setup, re, im, &outRe, &outIm)
        var p = [Float](repeating: 0, count: half)
        for i in 0..<half { p[i] = outRe[i] * outRe[i] + outIm[i] * outIm[i] }
        p[0] = 0 // DC and Nyquist share bin 0 in the packed format
        return p
    }

    /// Adds the latest block; `fast` follows changes quickly (spectrum), the response averages slower.
    func push(input: [Float], output: [Float]) {
        let pi = power(input), po = power(output)
        let a: Float = frames == 0 ? 1 : 0.25
        for i in 0..<pi.count {
            inPower[i] += (pi[i] - inPower[i]) * a
            outPower[i] += (po[i] - outPower[i]) * a
        }
        frames += 1
    }

    /// Output level (dB, relative) at `hz`, smoothed over a third of an octave.
    func outputDb(at hz: Double, rate: Double) -> Float { band(outPower, hz, rate, 1.0 / 3).map { 10 * log10($0 + 1e-20) } ?? -200 }
    /// Measured response (dB) at `hz`: output over input power in a sixth of an octave; nil where the input is too quiet.
    func responseDb(at hz: Double, rate: Double, floor: Float) -> Float? {
        guard let i = band(inPower, hz, rate, 1.0 / 6), let o = band(outPower, hz, rate, 1.0 / 6), i > floor else { return nil }
        return 10 * log10((o + 1e-20) / i)
    }
    /// Loudest input band power, for choosing a validity floor.
    var inputPeak: Float { inPower.max() ?? 0 }

    private func band(_ p: [Float], _ hz: Double, _ rate: Double, _ octaves: Double) -> Float? {
        let binHz = rate / Double(Self.n)
        let lo = max(1, Int(hz * pow(2, -octaves / 2) / binHz)), hi = min(p.count - 1, max(lo, Int(hz * pow(2, octaves / 2) / binHz)))
        guard lo <= hi else { return nil }
        var sum: Float = 0
        for i in lo...hi { sum += p[i] }
        return sum / Float(hi - lo + 1)
    }
}

// MARK: Moving-coil (VU) meter

/// A backlit moving-coil VU meter, drawn after real VU movements: a cream face with a −20…+3 VU scale (0 VU about
/// two-thirds across, a red band past 0), a 0–100 % scale beneath, a tapered needle on a damped movement (about
/// 300 ms to settle with roughly 1.5 % overshoot), a black bridge over the pivot, and curved glass.
/// In gain-reduction mode the needle rests at 0 VU and falls left by the reduction, as on classic compressors.
@MainActor
final class MovingCoilMeter: FaceplateScreen {
    enum Mode { case gainReduction, output }
    let mode: Mode
    private var needle: Double, velocity: Double = 0, target: Double
    private var last = CACurrentMediaTime()
    private var makeup: Double = 0, makeupSeen = false
    private(set) var reductionDb: Double = 0
    private(set) var levelVu: Double = -20
    override var drawsOwnOffState: Bool { true }
    override var lightFace: Bool { true }
    override var drawsOnGlass: Bool { true }

    override var isFlipped: Bool { true }
    init(mode: Mode) {
        self.mode = mode
        needle = mode == .gainReduction ? Self.position(0) : 0
        target = needle
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(mode == .gainReduction ? "Gain reduction" : "Output level (VU)")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Needle travel (0…1 of the scale) for a reading in VU: proportional to voltage, full scale at +3 VU.
    static func position(_ vu: Double) -> Double { min(1.04, pow(10, vu / 20) / pow(10, 3.0 / 20)) }
    /// Kept for callers that think in reduction: the needle travel for `db` of gain reduction.
    static func reductionPosition(_ db: Double) -> Double { position(-max(0, db)) }

    /// Gain-reduction mode: the plug-in's reported reduction (dB, positive), else input/output RMS (linear).
    func update(reported: Double?, inRms: Float, outRms: Float) {
        if let r = reported {
            reductionDb = abs(r)
        } else if inRms > 0.003 && outRms > 0 {
            // Level change through the plug-in, relative to its make-up gain (the highest change seen recently).
            let change = 20 * log10(Double(outRms / inRms))
            if !makeupSeen || change > makeup { makeup = change; makeupSeen = true } else { makeup -= 0.02 }
            reductionDb = max(0, makeup - change)
        } else {
            reductionDb = 0
        }
        target = Self.reductionPosition(reductionDb)
        setAccessibilityValue(String(format: "%.1f dB", reductionDb))
        step()
    }
    /// Output mode: the signal's RMS (linear, full scale = 1); 0 VU reads −18 dBFS RMS.
    func update(rms: Float) {
        levelVu = rms > 0 ? 20 * log10(Double(rms)) + 18 : -60
        target = rms > 0 ? Self.position(levelVu) : 0
        setAccessibilityValue(String(format: "%.1f VU", levelVu))
        step()
    }

    private func step() {
        let now = CACurrentMediaTime(), dt = min(0.05, now - last)
        last = now
        guard !Motion.reduced else { needle = target; needsDisplay = true; return }
        let wn = Faceplate.fastVU ? 57.0 : 19.0, zeta = 0.79 // ≈ 300 ms (or 100 ms) to 99 %, ≈ 1.5 % overshoot
        for _ in 0..<6 {
            let h = dt / 6
            velocity += (wn * wn * (target - needle) - 2 * zeta * wn * velocity) * h
            needle += velocity * h
        }
        needle = max(-0.01, min(1.06, needle)) // the movement's end stops
        needsDisplay = true
    }

    override func drawScreen(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if Theme.look.devices == .cards { drawGlass(ctx); return }
        let window = FaceplateDisplay.bezel(ctx, bounds, radius: 6)
        let faceR: CGFloat = 3
        let facePath = CGPath(roundedRect: window, cornerWidth: faceR, cornerHeight: faceR, transform: nil)
        let space = CGColorSpaceCreateDeviceRGB()
        ctx.saveGState()
        ctx.addPath(facePath); ctx.clip()
        // Face: warm paper, lit from two lamps behind the lower corners, falling off towards the edges.
        ctx.setFillColor(NSColor(srgbRed: 0.80, green: 0.73, blue: 0.56, alpha: 1).cgColor); ctx.fill(window)
        let paper = [NSColor(srgbRed: 0.97, green: 0.93, blue: 0.80, alpha: 1).cgColor, NSColor(srgbRed: 0.84, green: 0.77, blue: 0.60, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: paper, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: window.midX, y: window.midY + window.height * 0.15), startRadius: 0,
                                   endCenter: CGPoint(x: window.midX, y: window.midY + window.height * 0.15), endRadius: window.width * 0.62, options: [])
        }
        let lamp = [NSColor(srgbRed: 1.0, green: 0.86, blue: 0.55, alpha: 0.38).cgColor, NSColor(srgbRed: 1.0, green: 0.86, blue: 0.55, alpha: 0).cgColor] as CFArray
        if light > 0.01, let g = CGGradient(colorsSpace: space, colors: lamp, locations: [0, 1]) {
            ctx.setAlpha(light); defer { ctx.setAlpha(1) }
            for fx in [0.22, 0.78] {
                let c = CGPoint(x: window.minX + window.width * fx, y: window.maxY + 2)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: window.height * 0.75, options: [])
            }
        }
        // Age: the paper yellows with use (Settings ▸ wear).
        if Faceplate.wear > 0 {
            ctx.setFillColor(NSColor(srgbRed: 0.62, green: 0.46, blue: 0.18, alpha: 0.16 * Faceplate.wear).cgColor); ctx.fill(window)
        }
        // Scale geometry: the pivot sits under the bridge at the bottom centre.
        let pivot = CGPoint(x: window.midX, y: window.maxY + window.height * 0.10)
        let R = window.height * 0.80, span = 0.80
        func ang(_ pos: Double) -> CGFloat { CGFloat(-span + 2 * span * pos) }
        func pt(_ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: pivot.x + r * sin(a), y: pivot.y - r * cos(a)) }
        func arc(_ p0: Double, _ p1: Double, _ r: CGFloat) {
            ctx.addArc(center: pivot, radius: r, startAngle: -.pi / 2 + ang(p0), endAngle: -.pi / 2 + ang(p1), clockwise: false)
        }
        let ink = NSColor(srgbRed: 0.08, green: 0.07, blue: 0.06, alpha: 0.92), red = NSColor(srgbRed: 0.74, green: 0.10, blue: 0.08, alpha: 1)
        let p0 = Self.position(0)
        ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1.0); arc(0, p0, R); ctx.strokePath()
        ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(3.2); arc(p0, 1, R + 1.6); ctx.strokePath()
        ctx.setLineWidth(1.0); arc(p0, 1, R); ctx.strokePath()
        let numFont = NSFont(name: "Futura-Medium", size: 7.6) ?? NSFont.systemFont(ofSize: 7.6, weight: .medium)
        for vu in [-20.0, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3] {
            let a = ang(Self.position(vu)), plus = vu >= 0
            ctx.setStrokeColor((plus ? red : ink).cgColor); ctx.setLineWidth(vu == 0 ? 1.4 : 1.0)
            ctx.move(to: pt(a, R)); ctx.addLine(to: pt(a, R + (vu == 0 || vu == -20 ? 7 : 5.5))); ctx.strokePath()
            let label = vu == 0 ? "0" : String(format: "%.0f", abs(vu))
            let p = pt(a, R + 12)
            FaceplateDisplay.text(label, at: CGRect(x: p.x - 9, y: p.y - 5, width: 18, height: 10), font: numFont, color: plus ? red : ink)
        }
        for vu in [-15.0, -6, -4, -0.5, 0.5, 1.5, 2.5] {
            let a = ang(Self.position(vu))
            ctx.setStrokeColor((vu >= 0 ? red : ink).cgColor); ctx.setLineWidth(0.7)
            ctx.move(to: pt(a, R)); ctx.addLine(to: pt(a, R + 3)); ctx.strokePath()
        }
        // Signs at the scale ends, and the percentage scale beneath the arc.
        let signFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let minus = pt(ang(Self.position(-20)) - 0.05, R + 20), plusPt = pt(ang(1) + 0.07, R + 12)
        FaceplateDisplay.text("−", at: CGRect(x: minus.x - 6, y: minus.y - 6, width: 12, height: 12), font: signFont, color: ink)
        FaceplateDisplay.text("+", at: CGRect(x: plusPt.x - 6, y: plusPt.y - 6, width: 12, height: 12), font: signFont, color: red)
        let small = NSFont.systemFont(ofSize: 5, weight: .medium)
        for pct in stride(from: 0.0, through: 100, by: 20) {
            let a = ang(pct / 100 * p0)
            ctx.setStrokeColor(ink.withAlphaComponent(0.8).cgColor); ctx.setLineWidth(0.6)
            ctx.move(to: pt(a, R - 1)); ctx.addLine(to: pt(a, R - 4)); ctx.strokePath()
            let p = pt(a, R - 9)
            FaceplateDisplay.text(String(format: "%.0f", pct), at: CGRect(x: p.x - 8, y: p.y - 3.5, width: 16, height: 7), font: small, color: ink.withAlphaComponent(0.75))
        }
        let vuFont = NSFont(name: "Futura-Bold", size: window.height * 0.17) ?? NSFont.systemFont(ofSize: window.height * 0.17, weight: .heavy)
        FaceplateDisplay.text("VU", at: CGRect(x: window.minX, y: window.maxY - window.height * 0.52, width: window.width, height: window.height * 0.22),
                              font: vuFont, color: ink)
        FaceplateDisplay.text(mode == .gainReduction ? "GAIN REDUCTION" : "OUTPUT", at: CGRect(x: window.minX, y: window.maxY - window.height * 0.31,
                              width: window.width, height: 8), font: NSFont.systemFont(ofSize: 5.2, weight: .semibold), color: ink.withAlphaComponent(0.7))
        // Needle: tapered, with its shadow on the face (light from the front, slightly above).
        let a = ang(needle)
        func needlePath(_ off: CGPoint) -> CGPath {
            let base = pt(a, R * 0.30), tip = pt(a, R + 8)
            let nx = cos(a), ny = sin(a) // perpendicular to the needle in flipped coordinates
            let p = CGMutablePath()
            p.move(to: CGPoint(x: base.x - nx * 1.0 + off.x, y: base.y - ny * 1.0 + off.y))
            p.addLine(to: CGPoint(x: tip.x - nx * 0.28 + off.x, y: tip.y - ny * 0.28 + off.y))
            p.addLine(to: CGPoint(x: tip.x + nx * 0.28 + off.x, y: tip.y + ny * 0.28 + off.y))
            p.addLine(to: CGPoint(x: base.x + nx * 1.0 + off.x, y: base.y + ny * 1.0 + off.y))
            p.closeSubpath()
            return p
        }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 1.6, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.addPath(needlePath(CGPoint(x: 2.2, y: 2.4))); ctx.setFillColor(NSColor.black.withAlphaComponent(0.16).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(needlePath(.zero)); ctx.setFillColor(NSColor(white: 0.05, alpha: 1).cgColor); ctx.fillPath()
        // The bridge over the movement: a black arch with a soft top highlight and the zero-adjust screw.
        let bridgeR = R * 0.36
        let bridge = CGRect(x: pivot.x - bridgeR, y: pivot.y - bridgeR, width: 2 * bridgeR, height: 2 * bridgeR)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor(white: 0.07, alpha: 1).cgColor); ctx.fillEllipse(in: bridge)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: bridge); ctx.clip()
        let gloss = [NSColor(white: 0.34, alpha: 1).cgColor, NSColor(white: 0.07, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: gloss, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: bridge.minY), end: CGPoint(x: 0, y: bridge.minY + bridgeR * 0.45), options: [])
        }
        ctx.restoreGState()
        Faceplate.screw(ctx, CGPoint(x: pivot.x, y: window.maxY - bridgeR * 0.45))
        // Lamps out: the face falls into shadow (the glass still catches the room's light).
        if light < 0.99 { ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.035, blue: 0.03, alpha: 0.66 * (1 - light)).cgColor); ctx.fill(window) }
        // Curved glass: a soft reflection across the upper face and an inner shadow from the bezel.
        let sheen = CGMutablePath()
        sheen.move(to: CGPoint(x: window.minX, y: window.minY + window.height * 0.30))
        sheen.addQuadCurve(to: CGPoint(x: window.maxX, y: window.minY + window.height * 0.18), control: CGPoint(x: window.midX, y: window.minY + window.height * 0.05))
        sheen.addLine(to: CGPoint(x: window.maxX, y: window.minY)); sheen.addLine(to: CGPoint(x: window.minX, y: window.minY)); sheen.closeSubpath()
        ctx.addPath(sheen); ctx.setFillColor(NSColor.white.withAlphaComponent(0.13).cgColor); ctx.fillPath()
        let shade = [NSColor.black.withAlphaComponent(0.35).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: shade, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: window.minY), end: CGPoint(x: 0, y: window.minY + 7), options: [])
            ctx.drawLinearGradient(g, start: CGPoint(x: window.minX, y: 0), end: CGPoint(x: window.minX + 5, y: 0), options: [])
            ctx.drawLinearGradient(g, start: CGPoint(x: window.maxX, y: 0), end: CGPoint(x: window.maxX - 5, y: 0), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(facePath); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1); ctx.strokePath()
    }
}

extension MovingCoilMeter {
    /// Prism: the meter etched into the card's glass. No paper and no bridge: a fine printed scale, a red zone that
    /// glows, and a needle of light that pivots on a small glass bead. Same scale geometry as the paper meter.
    fileprivate func drawGlass(_ ctx: CGContext) {
        let window = bounds.insetBy(dx: 4, dy: 4)
        let lit = poweredOff ? 0.3 : max(0.3, light)
        let ink: NSColor = Theme.isLight ? Theme.text : .white
        let red = Theme.isLight ? Theme.hex(0xD8354A) : Theme.hex(0xFF5C6C)
        let pivot = CGPoint(x: window.midX, y: window.maxY + window.height * 0.10)
        let R = window.height * 0.80, span = 0.80
        func ang(_ pos: Double) -> CGFloat { CGFloat(-span + 2 * span * pos) }
        func pt(_ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: pivot.x + r * sin(a), y: pivot.y - r * cos(a)) }
        func arc(_ p0: Double, _ p1: Double, _ r: CGFloat) {
            ctx.addArc(center: pivot, radius: r, startAngle: -.pi / 2 + ang(p0), endAngle: -.pi / 2 + ang(p1), clockwise: false)
        }
        let p0 = Self.position(0)
        ctx.saveGState()
        ctx.clip(to: window)
        ctx.setLineCap(.round)
        // Scale: a hairline arc of light, and the red zone as a glowing band.
        ctx.setStrokeColor(ink.withAlphaComponent(0.42).cgColor); ctx.setLineWidth(0.8); arc(0, p0, R); ctx.strokePath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 5, color: red.withAlphaComponent(0.7 * lit).cgColor)
        ctx.setStrokeColor(red.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(2.4); arc(p0, 1, R + 1.4); ctx.strokePath()
        ctx.restoreGState()
        let numFont = Theme.ui(7, .medium)
        for vu in [-20.0, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3] {
            let a = ang(Self.position(vu)), plus = vu >= 0
            ctx.setStrokeColor((plus ? red : ink.withAlphaComponent(0.55)).cgColor); ctx.setLineWidth(vu == 0 ? 1.2 : 0.8)
            ctx.move(to: pt(a, R)); ctx.addLine(to: pt(a, R + (vu == 0 || vu == -20 ? 6.5 : 5))); ctx.strokePath()
            let label = vu == 0 ? "0" : String(format: "%.0f", abs(vu))
            let p = pt(a, R + 11.5)
            FaceplateDisplay.text(label, at: CGRect(x: p.x - 9, y: p.y - 5, width: 18, height: 10), font: numFont,
                                  color: plus ? red : ink.withAlphaComponent(0.62))
        }
        for vu in [-15.0, -6, -4, -0.5, 0.5, 1.5, 2.5] {
            let a = ang(Self.position(vu))
            ctx.setStrokeColor((vu >= 0 ? red : ink.withAlphaComponent(0.4)).cgColor); ctx.setLineWidth(0.6)
            ctx.move(to: pt(a, R)); ctx.addLine(to: pt(a, R + 3)); ctx.strokePath()
        }
        FaceplateDisplay.text("VU", at: CGRect(x: window.minX, y: window.maxY - window.height * 0.50, width: window.width, height: window.height * 0.2),
                              font: Theme.ui(window.height * 0.15, .semibold), color: ink.withAlphaComponent(0.22))
        FaceplateDisplay.text(mode == .gainReduction ? "GAIN REDUCTION" : "OUTPUT", at: CGRect(x: window.minX, y: window.maxY - window.height * 0.29,
                              width: window.width, height: 8), font: Theme.ui(5.5, .semibold), color: ink.withAlphaComponent(0.4))
        // The needle: a beam of light, bright at the tip, from a glass bead at the pivot.
        let a = ang(needle)
        let base = pt(a, R * 0.32), tip = pt(a, R + 7)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6, color: (Theme.isLight ? Theme.hex(0x5B7CFF) : NSColor.white).withAlphaComponent(0.85 * lit).cgColor)
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [ink.withAlphaComponent(0.15).cgColor, ink.withAlphaComponent(0.95 * lit).cgColor] as CFArray, locations: [0, 1]) {
            let path = CGMutablePath()
            let nx = cos(a), ny = sin(a)
            path.move(to: CGPoint(x: base.x - nx * 1.1, y: base.y - ny * 1.1))
            path.addLine(to: CGPoint(x: tip.x - nx * 0.35, y: tip.y - ny * 0.35))
            path.addLine(to: CGPoint(x: tip.x + nx * 0.35, y: tip.y + ny * 0.35))
            path.addLine(to: CGPoint(x: base.x + nx * 1.1, y: base.y + ny * 1.1))
            path.closeSubpath()
            ctx.setFillColor(ink.withAlphaComponent(0.9 * lit).cgColor); ctx.addPath(path); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path); ctx.clip()
            ctx.drawLinearGradient(g, start: base, end: tip, options: [])
        }
        ctx.restoreGState()
        let beadR = R * 0.13
        let bead = CGRect(x: pivot.x - beadR, y: window.maxY - beadR * 1.2, width: 2 * beadR, height: 2 * beadR)
        Prism.slab(ctx, bead, radius: beadR, tint: Theme.hex(0xA8B8FF), body: 0.22, lift: 0.3)
        ctx.restoreGState()
    }
}

// MARK: EQ bands from parameter names

/// One EQ band found among a plug-in's parameters: its frequency, and where they exist its gain, on/off and Q.
struct EqBand: Equatable {
    var label: String
    var freq: UInt32?
    /// Graphic EQs: a band at a fixed frequency (its slider is named after it, "1.25 kHz"); only its gain moves.
    var fixedHz: Double?
    var gain: UInt32?
    var enable: UInt32?
    var enableInverted = false // a "Bypass" switch rather than an "On" switch
    var q: UInt32?
}

/// Finds EQ bands in any plug-in by its parameter names, without knowing the plug-in: a continuous parameter named
/// like a frequency ("Band 2 Freq", "Peak 1 Frequency", "LF Cutoff", "freq3") is a band; parameters whose names differ
/// from it only by "gain", "on"/"active"/"bypass" or "Q"/"width" belong to it. Crossovers, LFOs, dynamics and
/// side-chain filters are left out.
enum EqBands {
    struct Param { let id: UInt32; let title: String; let steps: Int32; let readOnly: Bool }
    static let freqWords: Set<String> = ["frequency", "freq", "frq", "cutoff", "hz", "fc", "f"]
    static let gainWords: Set<String> = ["gain", "boost", "cut", "g"]
    static let enableWords: Set<String> = ["on", "off", "onoff", "active", "enable", "enabled", "power", "bypass", "bypassed", "use", "in"]
    static let qWords: Set<String> = ["q", "qfactor", "factor", "width", "bandwidth", "bw", "resonance", "res", "slope"]
    static let excluded: Set<String> = ["lfo", "rate", "speed", "sync", "depth", "dyn", "dynamic", "threshold", "sidechain", "sc", "key",
                                        "detector", "split", "crossover", "xover", "mod", "modulation", "env", "envelope", "attack", "release",
                                        "ratio", "lookahead", "analyzer", "analyser", "display", "range", "smooth", "tilt", "drive", "mix"]

    /// Lower-case words, split at spaces, punctuation, case changes and letter/digit boundaries ("bandFreq_2" → band freq 2).
    static func words(_ title: String) -> [String] {
        var out: [String] = [], cur = ""
        var prev: Character?
        for ch in title {
            if !(ch.isLetter || ch.isNumber) { if !cur.isEmpty { out.append(cur) }; cur = ""; prev = nil; continue }
            if let p = prev, (p.isLowercase && ch.isUppercase) || (p.isLetter && ch.isNumber) || (p.isNumber && ch.isLetter) {
                out.append(cur); cur = ""
            }
            cur.append(ch); prev = ch
        }
        if !cur.isEmpty { out.append(cur) }
        return out.map { $0.lowercased() }
    }

    static func find(_ params: [Param]) -> [EqBand] {
        // Plug-ins that repeat the same names for every band ("Frequency", "Gain", "Frequency", …) are told apart
        // by position: the n-th "Frequency" goes with the n-th "Gain".
        var seen: [String: Int] = [:], total: [String: Int] = [:]
        for p in params { total[p.title, default: 0] += 1 }
        var wordsOf: [UInt32: [String]] = [:]
        for p in params {
            let n = seen[p.title, default: 0]
            seen[p.title] = n + 1
            wordsOf[p.id] = words(p.title) + (total[p.title, default: 0] > 1 ? ["#\(n)"] : [])
        }
        func key(_ w: [String], removing set: Set<String>) -> String? {
            let rest = w.filter { !set.contains($0) }
            return rest.count < w.count ? rest.joined(separator: " ") : nil
        }
        // Graphic EQ: sliders named by their frequency alone are fixed bands whose value is the gain.
        let graphic = params.filter { p in
            !p.readOnly && p.steps == 0 && hz(p.title) != nil && p.title.lowercased().allSatisfy { $0.isNumber || " .,khz".contains($0) }
        }
        if graphic.count >= 3 {
            return graphic.enumerated().map { i, p in EqBand(label: String(i + 1), freq: nil, fixedHz: hz(p.title), gain: p.id) }
        }
        var bands: [(key: String, band: EqBand)] = []
        for p in params where !p.readOnly && p.steps == 0 {
            let w = wordsOf[p.id] ?? []
            guard w.contains(where: freqWords.contains), !w.contains(where: excluded.contains),
                  let k = key(w, removing: freqWords), !bands.contains(where: { $0.key == k }) else { continue }
            // A lone "f" or "fc" only counts with a band number or name beside it.
            if !w.contains(where: { ["frequency", "freq", "frq", "cutoff", "hz"].contains($0) }) && k.isEmpty { continue }
            bands.append((k, EqBand(label: "", freq: p.id)))
        }
        guard !bands.isEmpty, bands.count <= 32 else { return [] }
        // A single-band filter or EQ ("Center Frequency", "Gain", "Q") also takes the unqualified controls.
        let single = bands.count == 1
        func matches(_ k: String?, _ band: String) -> Bool { k == band || (single && k == "") }
        for p in params where !p.readOnly {
            let w = wordsOf[p.id] ?? []
            guard !w.contains(where: excluded.contains) else { continue }
            for i in bands.indices {
                if bands[i].band.gain == nil, p.steps == 0, matches(key(w, removing: gainWords), bands[i].key),
                   !w.contains(where: ["output", "input", "master", "makeup", "auto"].contains) {
                    bands[i].band.gain = p.id
                } else if bands[i].band.enable == nil, p.steps == 1, matches(key(w, removing: enableWords), bands[i].key) {
                    bands[i].band.enable = p.id
                    bands[i].band.enableInverted = w.contains("bypass") || w.contains("bypassed") || (w.contains("off") && !w.contains("on"))
                } else if bands[i].band.q == nil, p.steps == 0, matches(key(w, removing: qWords), bands[i].key) {
                    bands[i].band.q = p.id
                }
            }
        }
        return bands.enumerated().map { i, b in var band = b.band; band.label = String(i + 1); return band }
    }

    /// A frequency in Hz from a plug-in's value text ("80 Hz", "1.20 kHz", "2.5k", "12000"), or nil.
    static func hz(_ text: String) -> Double? {
        let t = text.lowercased()
        guard let (v, rest) = number(t) else { return nil }
        let unit = rest.trimmingCharacters(in: .whitespaces)
        let hz = unit.hasPrefix("k") ? v * 1000 : unit.hasPrefix("m") && !unit.hasPrefix("ms") ? v * 1_000_000 : v
        return hz > 0 ? hz : nil
    }
    /// A level in dB from value text ("+3.5 dB", "-12", "-inf").
    static func db(_ text: String) -> Double? {
        let t = text.lowercased()
        if t.contains("-inf") || t.contains("−inf") { return -100 }
        return number(t.replacingOccurrences(of: "−", with: "-"))?.0
    }
    /// The first number in `t` (a lone comma counts as the decimal point) and the text after it.
    private static func number(_ t: String) -> (Double, Substring)? {
        let chars = Array(t)
        guard let start = chars.indices.first(where: { chars[$0].isNumber || ((chars[$0] == "-" || chars[$0] == "+" || chars[$0] == ".") && $0 + 1 < chars.count && chars[$0 + 1].isNumber) })
        else { return nil }
        var end = start + 1, sep = false
        while end < chars.count, chars[end].isNumber || (!sep && (chars[end] == "." || chars[end] == ",") && end + 1 < chars.count && chars[end + 1].isNumber) {
            if !chars[end].isNumber { sep = true }
            end += 1
        }
        guard let v = Double(String(chars[start..<end]).replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (v, Substring(String(chars[end...])))
    }
}

// MARK: Response screen

/// An EQ screen: log-frequency grid, the live output spectrum, and the response curve with a soft glow.
@MainActor
final class ResponseScreen: FaceplateScreen {
    var curve: [Double]? { didSet { needsDisplay = true } }       // dB at `ResponseScreen.frequencies`
    var measured = false { didSet { needsDisplay = true } }
    /// A band handle: where it sits (frequency, and gain when the band has one) and its number.
    struct Marker: Equatable { var hz: Double; var db: Double?; var label: String; var on = true; var fixedFrequency = false }
    /// Band handles on the screen (any EQ whose bands Dalnok can find). Drag one to move the band (left/right:
    /// frequency, up/down: gain); scroll over it to change its Q; double-click to switch it on or off.
    var markers: [Marker] = [] { didSet { if markers != oldValue { needsDisplay = true } } }
    var onBandDrag: ((Int, Double, Double) -> Void)?
    var onBandEnd: (() -> Void)?
    var onBandScroll: ((Int, Double) -> Void)?
    var onBandToggle: ((Int) -> Void)?
    /// Index of the band being dragged (its handle is drawn lit).
    private(set) var dragging: Int?
    /// The plotting area inside the bezel (as drawn).
    private var plotRect: CGRect {
        Theme.look.devices == .schematic ? Self.codexPlot(bounds) : bounds.insetBy(dx: 4, dy: 4).insetBy(dx: 2, dy: 3)
    }
    /// Atelier: the plot inside the figure (axes lettered on the left and below).
    static func codexPlot(_ bounds: CGRect) -> CGRect {
        let f = CGRect(x: bounds.minX + 5, y: bounds.minY + 5, width: bounds.width - 10, height: bounds.height - 10 - Codex.captionHeight).insetBy(dx: 1, dy: 1)
        return CGRect(x: f.minX + 16, y: f.minY + 5, width: f.width - 20, height: f.height - 16)
    }
    /// Where a band's handle sits: on its gain when it has one, else on the curve (cuts, shelves without gain), else 0 dB.
    func center(of m: Marker) -> CGPoint {
        let plot = plotRect
        var level = m.db ?? 0
        if m.db == nil, let c = curve, c.count == Self.frequencies.count {
            let pos = max(0, min(Double(c.count - 1), log10(m.hz / 20) / 3 * Double(c.count - 1)))
            let i = min(c.count - 2, Int(pos)), t = pos - Double(i)
            level = c[i] + (c[i + 1] - c[i]) * t
        }
        let x = plot.minX + plot.width * CGFloat(log10(max(20, min(20_000, m.hz)) / 20) / 3)
        let y = plot.midY - plot.height / 2 * CGFloat(max(-1.05, min(1.05, level / Self.range)))
        return CGPoint(x: x, y: y)
    }
    private var centers: [(index: Int, point: CGPoint)] {
        markers.enumerated().filter { $0.element.hz >= 20 && $0.element.hz <= 20_000 }.map { ($0.offset, center(of: $0.element)) }
    }
    var spectrum: [Float]? { didSet { needsDisplay = true } }      // dB at the same frequencies (relative)
    var tint: NSColor = Theme.accent
    static let range: Double = 18 // ±dB
    static let frequencies: [Double] = (0..<160).map { 20 * pow(1000, Double($0) / 159) }

    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Frequency response")
    }
    required init?(coder: NSCoder) { fatalError() }

    // Band handles: press near one to grab it. Presses elsewhere on the screen do nothing (the unit doesn't move).
    private func band(at p: CGPoint) -> Int? {
        centers.min { hypot($0.point.x - p.x, $0.point.y - p.y) < hypot($1.point.x - p.x, $1.point.y - p.y) }
            .flatMap { hypot($0.point.x - p.x, $0.point.y - p.y) <= 9 ? $0.index : nil }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = band(at: p) else { return }
        if event.clickCount == 2 { onBandToggle?(i); return }
        dragging = i
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let i = dragging, plotRect.width > 0, markers.indices.contains(i) else { return }
        let p = convert(event.locationInWindow, from: nil)
        let fx = Double(max(0, min(1, (p.x - plotRect.minX) / plotRect.width)))
        let hz = 20 * pow(1000, fx)
        let db = Double(max(-1, min(1, (plotRect.midY - p.y) / (plotRect.height / 2)))) * Self.range
        if !markers[i].fixedFrequency { markers[i].hz = hz }
        if markers[i].db != nil { markers[i].db = db }
        onBandDrag?(i, hz, db)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { return }
        dragging = nil
        needsDisplay = true
        onBandEnd?()
    }
    override func scrollWheel(with event: NSEvent) {
        guard let i = band(at: convert(event.locationInWindow, from: nil)), onBandScroll != nil else { return super.scrollWheel(with: event) }
        let d = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 30)
        if d != 0 { onBandScroll?(i, d) }
    }

    override func drawScreen(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let window = FaceplateDisplay.bezel(ctx, bounds)
        let r: CGFloat = 3
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.clip()
        let bg = [NSColor(srgbRed: 0.035, green: 0.055, blue: 0.07, alpha: 1).cgColor, NSColor(srgbRed: 0.055, green: 0.085, blue: 0.10, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: window.minY), end: CGPoint(x: 0, y: window.maxY), options: [])
        }
        let plot = window.insetBy(dx: 2, dy: 3)
        func x(_ hz: Double) -> CGFloat { plot.minX + plot.width * CGFloat(log10(hz / 20) / 3) }
        func y(_ db: Double) -> CGFloat { plot.midY - plot.height / 2 * CGFloat(max(-1.05, min(1.05, db / Self.range))) }
        // Grid.
        let grid = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.70, alpha: 1)
        for hz in [30.0, 40, 50, 60, 70, 80, 90, 200, 300, 400, 500, 600, 700, 800, 900, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000] {
            ctx.setStrokeColor(grid.withAlphaComponent(0.07).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: x(hz), y: plot.minY)); ctx.addLine(to: CGPoint(x: x(hz), y: plot.maxY)); ctx.strokePath()
        }
        for hz in [100.0, 1000, 10000] {
            ctx.setStrokeColor(grid.withAlphaComponent(0.18).cgColor); ctx.setLineWidth(0.6)
            ctx.move(to: CGPoint(x: x(hz), y: plot.minY)); ctx.addLine(to: CGPoint(x: x(hz), y: plot.maxY)); ctx.strokePath()
        }
        for db in stride(from: -12.0, through: 12, by: 6) {
            ctx.setStrokeColor(grid.withAlphaComponent(db == 0 ? 0.26 : 0.09).cgColor); ctx.setLineWidth(db == 0 ? 0.7 : 0.5)
            ctx.move(to: CGPoint(x: plot.minX, y: y(db))); ctx.addLine(to: CGPoint(x: plot.maxX, y: y(db))); ctx.strokePath()
        }
        let small = Theme.mono(6.5)
        for (hz, t) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
            FaceplateDisplay.text(t, at: CGRect(x: x(hz) + 2, y: plot.maxY - 9, width: 24, height: 9), font: small, color: grid.withAlphaComponent(0.55), align: .left)
        }
        for db in [12.0, -12] {
            FaceplateDisplay.text(String(format: "%+.0f", db), at: CGRect(x: plot.minX + 1, y: y(db) - 9, width: 22, height: 9), font: small,
                                  color: grid.withAlphaComponent(0.45), align: .left)
        }
        // Spectrum (output), a soft filled mountain behind the curve.
        if let raw = spectrum, raw.count == Self.frequencies.count, let top = raw.max(), top > -150 {
            // Low bands span few FFT bins: smooth across neighbouring points so the outline reads as a spectrum, not steps.
            let s = raw.indices.map { i -> Float in
                let lo = max(0, i - 3), hi = min(raw.count - 1, i + 3)
                return raw[lo...hi].reduce(0, +) / Float(hi - lo + 1)
            }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            var prev: CGPoint?
            for (i, hz) in Self.frequencies.enumerated() {
                let level = Double(max(0, min(1, (s[i] - top + 60) / 60))) // top 60 dB of the spectrum
                let p = CGPoint(x: x(hz), y: plot.maxY - plot.height * 0.85 * CGFloat(level))
                if let q = prev { path.addQuadCurve(to: CGPoint(x: (q.x + p.x) / 2, y: (q.y + p.y) / 2), control: q) } else { path.addLine(to: p) }
                prev = p
            }
            if let q = prev { path.addLine(to: q) }
            path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)); path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            let fill = [NSColor(srgbRed: 0.40, green: 0.70, blue: 0.85, alpha: 0.30).cgColor, NSColor(srgbRed: 0.40, green: 0.70, blue: 0.85, alpha: 0.03).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: fill, locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: plot.minY), end: CGPoint(x: 0, y: plot.maxY), options: [])
            }
            ctx.restoreGState()
        }
        // Response curve: filled to 0 dB, then the line with a glow.
        if let c = curve, c.count == Self.frequencies.count {
            let line = CGMutablePath()
            for (i, hz) in Self.frequencies.enumerated() {
                let p = CGPoint(x: x(hz), y: y(c[i]))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            let area = line.mutableCopy()!
            area.addLine(to: CGPoint(x: plot.maxX, y: y(0))); area.addLine(to: CGPoint(x: plot.minX, y: y(0))); area.closeSubpath()
            ctx.addPath(area); ctx.setFillColor(tint.withAlphaComponent(0.14).cgColor); ctx.fillPath()
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 6, color: tint.withAlphaComponent(0.9).cgColor)
            ctx.addPath(line); ctx.setStrokeColor(tint.cgColor); ctx.setLineWidth(1.7); ctx.setLineJoin(.round)
            if measured { ctx.setLineDash(phase: 0, lengths: [4, 2]) }
            ctx.strokePath()
            ctx.restoreGState()
        }
        for (index, m) in markers.enumerated() where m.hz >= 20 && m.hz <= 20_000 {
            let center = center(of: m)
            let lit = dragging == index
            let r: CGFloat = lit ? 6 : 5
            let dot = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            let color = m.on ? tint : NSColor(white: 0.55, alpha: 1)
            ctx.saveGState()
            if m.on { ctx.setShadow(offset: .zero, blur: lit ? 7 : 4, color: tint.withAlphaComponent(0.8).cgColor) }
            ctx.setFillColor((lit ? tint.withAlphaComponent(0.35) : NSColor(srgbRed: 0.05, green: 0.08, blue: 0.10, alpha: 0.95)).cgColor)
            ctx.fillEllipse(in: dot)
            ctx.restoreGState()
            ctx.setStrokeColor(color.withAlphaComponent(m.on ? 1 : 0.7).cgColor); ctx.setLineWidth(1.2)
            if !m.on { ctx.setLineDash(phase: 0, lengths: [1.5, 1.5]) }
            ctx.strokeEllipse(in: dot)
            ctx.setLineDash(phase: 0, lengths: [])
            FaceplateDisplay.text(m.label, at: CGRect(x: dot.minX - 2, y: center.y - 4.5, width: dot.width + 4, height: 9),
                                  font: NSFont.systemFont(ofSize: 6.5, weight: .bold), color: lit ? .white : color)
        }
        if measured {
            FaceplateDisplay.text("MEASURED", at: CGRect(x: plot.maxX - 52, y: plot.minY + 1, width: 50, height: 9), font: small,
                                  color: grid.withAlphaComponent(0.55), align: .right)
        }
        ctx.restoreGState()
        FaceplateDisplay.glass(ctx, window, radius: r)
    }
}

// MARK: Oscilloscope

/// A phosphor oscilloscope: the plug-in's output, triggered on a rising zero crossing, with a little persistence.
@MainActor
final class ScopeScreen: FaceplateScreen {
    private var traces: [[Float]] = [] // newest last
    private(set) var gain: Float = 1    // automatic vertical scale (volts per division), so quiet signals still fill the screen
    override var isFlipped: Bool { true }
    static let phosphor = NSColor(srgbRed: 0.50, green: 1.0, blue: 0.70, alpha: 1)

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Oscilloscope")
    }
    required init?(coder: NSCoder) { fatalError() }

    var traceCount: Int { traces.count }

    /// Adds the latest output block (about 20 ms shown).
    func push(_ samples: [Float]) {
        let span = min(samples.count / 2, 960)
        guard span > 16 else { return }
        var start = samples.count - span - 1
        // Trigger: the latest rising zero crossing that still leaves a full sweep after it.
        var i = samples.count - span - 1
        while i > 1 { if samples[i - 1] <= 0 && samples[i] > 0 { start = i; break }; i -= 1 }
        let peak = samples.map(abs).max() ?? 0
        gain += (min(16, max(1, 0.8 / max(peak, 1e-4))) - gain) * 0.25
        traces.append(Array(samples[start..<min(samples.count, start + span)]))
        if traces.count > 4 { traces.removeFirst() }
        needsDisplay = true
    }
    func clear() { if !traces.isEmpty { traces = []; needsDisplay = true } }

    override func drawScreen(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let window = FaceplateDisplay.bezel(ctx, bounds)
        let r: CGFloat = 3
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.clip()
        let bg = [NSColor(srgbRed: 0.03, green: 0.07, blue: 0.05, alpha: 1).cgColor, NSColor(srgbRed: 0.015, green: 0.035, blue: 0.025, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: window.midX, y: window.midY), startRadius: 0,
                                   endCenter: CGPoint(x: window.midX, y: window.midY), endRadius: window.width * 0.7, options: [.drawsAfterEndLocation])
        }
        // Graticule: 8 × 6 divisions with minor ticks on the centre lines.
        let p = Self.phosphor
        ctx.setStrokeColor(p.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(0.5)
        for i in 1..<8 { let x = window.minX + window.width * CGFloat(i) / 8; ctx.move(to: CGPoint(x: x, y: window.minY)); ctx.addLine(to: CGPoint(x: x, y: window.maxY)) }
        for i in 1..<6 { let y = window.minY + window.height * CGFloat(i) / 6; ctx.move(to: CGPoint(x: window.minX, y: y)); ctx.addLine(to: CGPoint(x: window.maxX, y: y)) }
        ctx.strokePath()
        ctx.setStrokeColor(p.withAlphaComponent(0.22).cgColor)
        for i in 0..<40 {
            let x = window.minX + window.width * CGFloat(i) / 40
            ctx.move(to: CGPoint(x: x, y: window.midY - 1.5)); ctx.addLine(to: CGPoint(x: x, y: window.midY + 1.5))
        }
        ctx.strokePath()
        // Traces, oldest faintest; the newest glows.
        for (k, t) in traces.enumerated() {
            let age = traces.count - 1 - k
            let path = CGMutablePath()
            for (i, v) in t.enumerated() {
                let pt = CGPoint(x: window.minX + window.width * CGFloat(i) / CGFloat(max(1, t.count - 1)),
                                 y: window.midY - window.height * 0.45 * CGFloat(max(-1, min(1, v * gain))))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.saveGState()
            if age == 0 { ctx.setShadow(offset: .zero, blur: 5, color: p.withAlphaComponent(0.9).cgColor) }
            ctx.addPath(path); ctx.setStrokeColor(p.withAlphaComponent(age == 0 ? 0.95 : 0.35 / CGFloat(age)).cgColor)
            ctx.setLineWidth(age == 0 ? 1.3 : 1); ctx.setLineJoin(.round); ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
        FaceplateDisplay.glass(ctx, window, radius: r)
    }
}

// MARK: Screens shared by the newer displays

@MainActor
enum Screen {
    /// A dark glass screen in its bezel: returns the drawing area (clip is set; call `finish` afterwards).
    static func begin(_ ctx: CGContext, _ bounds: CGRect, top: NSColor, bottom: NSColor) -> CGRect {
        let window = FaceplateDisplay.bezel(ctx, bounds)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: window, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.clip()
        let bg = [top.cgColor, bottom.cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bg, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: window.minY), end: CGPoint(x: 0, y: window.maxY), options: [])
        }
        return window
    }
    static func finish(_ ctx: CGContext, _ window: CGRect) {
        ctx.restoreGState()
        FaceplateDisplay.glass(ctx, window, radius: 3)
    }
    static let lcdTop = NSColor(srgbRed: 0.035, green: 0.055, blue: 0.07, alpha: 1)
    static let lcdBottom = NSColor(srgbRed: 0.055, green: 0.085, blue: 0.10, alpha: 1)
    static let grid = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.70, alpha: 1)
    static let amber = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.30, alpha: 1)
}

// MARK: Transfer curve (distortion)

/// The plug-in's transfer curve, measured: output plotted against input, sample by sample, on an amber phosphor
/// screen. A clean gain is a straight diagonal; saturation bends it; time effects blur it into a cloud.
@MainActor
final class TransferScreen: FaceplateScreen {
    private var frames: [[CGPoint]] = []
    override var isFlipped: Bool { true }
    init() { super.init(frame: .zero); setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Transfer curve") }
    required init?(coder: NSCoder) { fatalError() }
    var pointCount: Int { frames.last?.count ?? 0 }

    func push(input: [Float], output: [Float]) {
        let peak = max(input.map(abs).max() ?? 0, 1e-6)
        guard peak > 0.003 else { return clear() }
        var pts: [CGPoint] = []
        pts.reserveCapacity(input.count / 2)
        for i in stride(from: 0, to: min(input.count, output.count), by: 2) {
            pts.append(CGPoint(x: CGFloat(input[i] / peak), y: CGFloat(max(-1.2, min(1.2, output[i] / peak)))))
        }
        frames.append(pts)
        if frames.count > 3 { frames.removeFirst() }
        needsDisplay = true
    }
    func clear() { if !frames.isEmpty { frames = []; needsDisplay = true } }
    override var liveTransfer: [CGPoint] { frames.last ?? [] }

    override func drawScreen(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = Screen.begin(ctx, bounds, top: NSColor(srgbRed: 0.06, green: 0.04, blue: 0.02, alpha: 1), bottom: NSColor(srgbRed: 0.03, green: 0.02, blue: 0.01, alpha: 1))
        let plot = w.insetBy(dx: 6, dy: 6)
        let a = Screen.amber
        ctx.setStrokeColor(a.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(0.5)
        for i in 1..<4 {
            let x = plot.minX + plot.width * CGFloat(i) / 4, y = plot.minY + plot.height * CGFloat(i) / 4
            ctx.move(to: CGPoint(x: x, y: plot.minY)); ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
            ctx.move(to: CGPoint(x: plot.minX, y: y)); ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(a.withAlphaComponent(0.22).cgColor); ctx.setLineDash(phase: 0, lengths: [2, 2])
        ctx.move(to: CGPoint(x: plot.minX, y: plot.maxY)); ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.minY)); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        for (k, pts) in frames.enumerated() {
            let newest = k == frames.count - 1
            ctx.saveGState()
            if newest { ctx.setShadow(offset: .zero, blur: 3, color: a.withAlphaComponent(0.8).cgColor) }
            ctx.setFillColor(a.withAlphaComponent(newest ? 0.75 : 0.22).cgColor)
            for p in pts {
                let x = plot.midX + p.x * plot.width / 2, y = plot.midY - p.y * plot.height / 2
                ctx.fill(CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
            }
            ctx.restoreGState()
        }
        FaceplateDisplay.text("IN", at: CGRect(x: plot.maxX - 14, y: plot.maxY - 8, width: 14, height: 8), font: Theme.mono(6), color: a.withAlphaComponent(0.5), align: .right)
        FaceplateDisplay.text("OUT", at: CGRect(x: plot.minX, y: plot.minY, width: 20, height: 8), font: Theme.mono(6), color: a.withAlphaComponent(0.5), align: .left)
        Screen.finish(ctx, w)
    }
}

// MARK: Energy history (reverb, delay)

/// The output's level over the last few seconds, scrolling right to left, with the input as a thin line:
/// reverb tails and echo repeats show as energy that carries on after the input stops.
@MainActor
final class HistoryScreen: FaceplateScreen {
    static let columns = 180
    private var output = [Float](repeating: -90, count: columns), input = [Float](repeating: -90, count: columns)
    var tint: NSColor = Theme.accent
    override var isFlipped: Bool { true }
    init() { super.init(frame: .zero); setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Level history") }
    required init?(coder: NSCoder) { fatalError() }
    var latest: (input: Float, output: Float) { (input.last ?? -90, output.last ?? -90) }

    /// One column: input and output RMS (linear).
    func push(inRms: Float, outRms: Float) {
        func db(_ x: Float) -> Float { x > 1e-6 ? max(-90, 20 * log10(x)) : -90 }
        output.removeFirst(); output.append(db(outRms))
        input.removeFirst(); input.append(db(inRms))
        needsDisplay = true
    }

    override func drawScreen(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = Screen.begin(ctx, bounds, top: Screen.lcdTop, bottom: Screen.lcdBottom)
        let plot = w.insetBy(dx: 2, dy: 4)
        func y(_ db: Float) -> CGFloat { plot.minY + plot.height * CGFloat(max(0, min(1, -db / 60))) }
        func x(_ i: Int) -> CGFloat { plot.minX + plot.width * CGFloat(i) / CGFloat(Self.columns - 1) }
        let g = Screen.grid
        for db: Float in [-12, -24, -36, -48] {
            ctx.setStrokeColor(g.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: plot.minX, y: y(db))); ctx.addLine(to: CGPoint(x: plot.maxX, y: y(db))); ctx.strokePath()
            FaceplateDisplay.text(String(format: "%.0f", db), at: CGRect(x: plot.minX + 1, y: y(db) - 8, width: 20, height: 8), font: Theme.mono(6),
                                  color: g.withAlphaComponent(0.45), align: .left)
        }
        for sec in 1..<6 { // a tick each second (one column ≈ 33 ms)
            let i = Self.columns - 1 - sec * 30
            guard i > 0 else { continue }
            ctx.setStrokeColor(g.withAlphaComponent(0.08).cgColor)
            ctx.move(to: CGPoint(x: x(i), y: plot.minY)); ctx.addLine(to: CGPoint(x: x(i), y: plot.maxY)); ctx.strokePath()
        }
        let area = CGMutablePath()
        area.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        for (i, v) in output.enumerated() { area.addLine(to: CGPoint(x: x(i), y: y(v))) }
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)); area.closeSubpath()
        ctx.saveGState()
        ctx.addPath(area); ctx.clip()
        let fill = [tint.withAlphaComponent(0.55).cgColor, tint.withAlphaComponent(0.06).cgColor] as CFArray
        if let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: fill, locations: [0, 1]) {
            ctx.drawLinearGradient(gr, start: CGPoint(x: 0, y: plot.minY), end: CGPoint(x: 0, y: plot.maxY), options: [])
        }
        ctx.restoreGState()
        let top = CGMutablePath()
        for (i, v) in output.enumerated() { if i == 0 { top.move(to: CGPoint(x: x(i), y: y(v))) } else { top.addLine(to: CGPoint(x: x(i), y: y(v))) } }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 4, color: tint.withAlphaComponent(0.8).cgColor)
        ctx.addPath(top); ctx.setStrokeColor(tint.cgColor); ctx.setLineWidth(1.2); ctx.strokePath()
        ctx.restoreGState()
        let line = CGMutablePath()
        for (i, v) in input.enumerated() { if i == 0 { line.move(to: CGPoint(x: x(i), y: y(v))) } else { line.addLine(to: CGPoint(x: x(i), y: y(v))) } }
        ctx.addPath(line); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
        FaceplateDisplay.text("OUT", at: CGRect(x: plot.maxX - 40, y: plot.minY + 1, width: 18, height: 8), font: Theme.mono(6), color: tint, align: .right)
        FaceplateDisplay.text("IN", at: CGRect(x: plot.maxX - 18, y: plot.minY + 1, width: 16, height: 8), font: Theme.mono(6), color: NSColor.white.withAlphaComponent(0.55), align: .right)
        Screen.finish(ctx, w)
    }
}

// MARK: Goniometer (modulation, stereo)

/// A stereo goniometer: mid up, side across (L and R on the diagonals), with a correlation bar beneath.
/// Mono is a vertical line; wide stereo fills the screen; out-of-phase content leans horizontal.
@MainActor
final class GoniometerScreen: FaceplateScreen {
    private var frames: [[CGPoint]] = []
    private var gain: CGFloat = 1
    private(set) var correlation: Double = 1
    override var isFlipped: Bool { true }
    static let phosphor = NSColor(srgbRed: 0.55, green: 0.85, blue: 1.0, alpha: 1)
    init() { super.init(frame: .zero); setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Stereo goniometer") }
    required init?(coder: NSCoder) { fatalError() }

    func push(left: [Float], right: [Float]) {
        let n = min(left.count, right.count)
        var lr: Double = 0, ll: Double = 0, rr: Double = 0, peak: Float = 0
        var pts: [CGPoint] = []
        pts.reserveCapacity(n / 2)
        for i in 0..<n {
            let l = left[i], r = right[i]
            lr += Double(l * r); ll += Double(l * l); rr += Double(r * r)
            peak = max(peak, abs(l), abs(r))
            if i % 2 == 0 { pts.append(CGPoint(x: CGFloat(r - l) * 0.7071, y: CGFloat(l + r) * 0.7071)) }
        }
        guard peak > 0.002 else { return clear() }
        correlation += ((ll * rr > 0 ? lr / sqrt(ll * rr) : 1) - correlation) * 0.3
        gain += (min(8, 0.75 / CGFloat(peak)) - gain) * 0.2 // slow automatic gain, like a scope's AGC
        frames.append(pts)
        if frames.count > 3 { frames.removeFirst() }
        needsDisplay = true
    }
    func clear() { if !frames.isEmpty { frames = []; needsDisplay = true } }

    override func drawScreen(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = Screen.begin(ctx, bounds, top: NSColor(srgbRed: 0.02, green: 0.04, blue: 0.07, alpha: 1), bottom: NSColor(srgbRed: 0.01, green: 0.02, blue: 0.04, alpha: 1))
        let barH: CGFloat = 12
        let plot = CGRect(x: w.minX + 4, y: w.minY + 4, width: w.width - 8, height: w.height - barH - 10)
        let c = CGPoint(x: plot.midX, y: plot.midY), r = min(plot.width, plot.height) / 2
        let p = Self.phosphor
        ctx.setStrokeColor(p.withAlphaComponent(0.14).cgColor); ctx.setLineWidth(0.6)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        for a in [0.0, .pi / 4, .pi / 2, 3 * .pi / 4] {
            ctx.move(to: CGPoint(x: c.x - r * CGFloat(cos(a)), y: c.y - r * CGFloat(sin(a)))); ctx.addLine(to: CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a))))
        }
        ctx.strokePath()
        let tf = Theme.mono(6)
        FaceplateDisplay.text("L", at: CGRect(x: c.x - r * 0.72 - 8, y: c.y - r * 0.72 - 8, width: 8, height: 8), font: tf, color: p.withAlphaComponent(0.5))
        FaceplateDisplay.text("R", at: CGRect(x: c.x + r * 0.72, y: c.y - r * 0.72 - 8, width: 8, height: 8), font: tf, color: p.withAlphaComponent(0.5))
        FaceplateDisplay.text("M", at: CGRect(x: c.x + 2, y: plot.minY, width: 8, height: 8), font: tf, color: p.withAlphaComponent(0.5), align: .left)
        for (k, pts) in frames.enumerated() {
            let newest = k == frames.count - 1
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
            if newest { ctx.setShadow(offset: .zero, blur: 3, color: p.withAlphaComponent(0.8).cgColor) }
            ctx.setFillColor(p.withAlphaComponent(newest ? 0.7 : 0.2).cgColor)
            for q in pts { ctx.fill(CGRect(x: c.x + q.x * gain * r - 0.6, y: c.y - q.y * gain * r - 0.6, width: 1.2, height: 1.2)) }
            ctx.restoreGState()
        }
        // Correlation: −1 … +1, with the reading as a lit marker.
        let bar = CGRect(x: w.minX + 8, y: w.maxY - barH, width: w.width - 16, height: 4)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.fill(bar)
        ctx.setFillColor(NSColor(srgbRed: 0.9, green: 0.3, blue: 0.25, alpha: 0.35).cgColor); ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width / 2, height: bar.height))
        ctx.setFillColor(NSColor(srgbRed: 0.4, green: 0.9, blue: 0.5, alpha: 0.30).cgColor); ctx.fill(CGRect(x: bar.midX, y: bar.minY, width: bar.width / 2, height: bar.height))
        let mx = bar.minX + bar.width * CGFloat((correlation + 1) / 2)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 3, color: p.cgColor)
        ctx.setFillColor(p.cgColor); ctx.fill(CGRect(x: mx - 1.5, y: bar.minY - 1.5, width: 3, height: bar.height + 3))
        ctx.restoreGState()
        FaceplateDisplay.text("−1", at: CGRect(x: bar.minX - 2, y: bar.maxY + 0.5, width: 14, height: 7), font: Theme.mono(5.5), color: p.withAlphaComponent(0.5), align: .left)
        FaceplateDisplay.text("+1", at: CGRect(x: bar.maxX - 12, y: bar.maxY + 0.5, width: 14, height: 7), font: Theme.mono(5.5), color: p.withAlphaComponent(0.5), align: .right)
        Screen.finish(ctx, w)
    }
}

// MARK: LED spectrum analyzer (pitch, restoration, analysis)

/// A third-octave real-time analyzer built from LED columns, with peak-hold LEDs, like a hardware RTA.
@MainActor
final class LedAnalyzer: FaceplateScreen {
    static let bands: [Double] = (0..<24).map { 50 * pow(2, Double($0) / 3) } // 50 Hz … 10 kHz
    static let rows = 14
    private(set) var levels = [Float](repeating: -90, count: bands.count)
    private var peaks = [Float](repeating: -90, count: bands.count), peakAt = [Double](repeating: 0, count: bands.count)
    private var top: Float = -20
    override var isFlipped: Bool { true }
    init() { super.init(frame: .zero); setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Spectrum analyzer") }
    required init?(coder: NSCoder) { fatalError() }

    /// Band levels in dB (relative); the display ranges itself to the loudest band (48 dB shown).
    func push(_ db: [Float]) {
        guard db.count == levels.count else { return }
        let now = CACurrentMediaTime()
        let loud = db.max() ?? -90
        top = max(loud, top - 0.4)
        for i in levels.indices {
            levels[i] = max(db[i], levels[i] - 2.5)
            if levels[i] >= peaks[i] || now - peakAt[i] > 1.2 { peaks[i] = levels[i]; peakAt[i] = now }
        }
        needsDisplay = true
    }

    override func drawScreen(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let w = Screen.begin(ctx, bounds, top: NSColor(white: 0.03, alpha: 1), bottom: NSColor(white: 0.05, alpha: 1))
        let plot = w.insetBy(dx: 5, dy: 5).offsetBy(dx: 0, dy: -3)
        let n = levels.count, rows = Self.rows, gap: CGFloat = 1.2
        let colW = (plot.width - gap * CGFloat(n - 1)) / CGFloat(n)
        let rowH = (plot.height - 6 - gap * CGFloat(rows - 1)) / CGFloat(rows)
        for i in 0..<n {
            let lit = Int(((levels[i] - top + 48) / 48 * Float(rows)).rounded(.down))
            let peak = Int(((peaks[i] - top + 48) / 48 * Float(rows)).rounded(.down)) - 1
            for r in 0..<rows {
                let color: NSColor = r >= rows - 2 ? NSColor(srgbRed: 1, green: 0.3, blue: 0.22, alpha: 1)
                    : r >= rows - 5 ? NSColor(srgbRed: 1, green: 0.74, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.42, green: 0.95, blue: 0.5, alpha: 1)
                let rect = CGRect(x: plot.minX + CGFloat(i) * (colW + gap), y: plot.minY + plot.height - 6 - CGFloat(r + 1) * rowH - CGFloat(r) * gap,
                                  width: colW, height: rowH)
                let on = r < lit || r == peak
                if on {
                    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 2.5, color: color.withAlphaComponent(0.8).cgColor)
                    ctx.setFillColor(color.cgColor); ctx.fill(rect); ctx.restoreGState()
                } else {
                    ctx.setFillColor((color.blended(withFraction: 0.86, of: .black) ?? color).cgColor); ctx.fill(rect)
                }
            }
        }
        for (i, t) in [(2, "63"), (8, "250"), (14, "1k"), (20, "4k")] {
            FaceplateDisplay.text(t, at: CGRect(x: plot.minX + CGFloat(i) * (colW + gap) - 6, y: plot.maxY - 5, width: colW + 12, height: 7),
                                  font: Theme.mono(5.5), color: NSColor(white: 0.55, alpha: 1))
        }
        Screen.finish(ctx, w)
    }
}

// MARK: - Codex figures (Atelier)

/// Atelier draws every display as a numbered figure of an engraved plate: the same live data, set out like a diagram in
/// a natural-philosophy book: a neatline frame, axes lettered in the serif, construction lines, red-ochre ink for the
/// reading, engraved shading instead of glow, and a caption ("Fig. 2 · Frequency Atlas") beneath.
@MainActor
enum Codex {
    /// What a figure shows beyond its display kind (reverbs are drawn as an acoustic chamber).
    enum Subject { case plain, chamber, echo, modulation }
    static let captionHeight: CGFloat = 12

    /// What a history display depicts: a hall for reverbs, echoes for delays (from the name, then the parameters).
    static func subject(kind: FaceplateDisplay.Kind, name: String, parameters: [String]) -> Subject {
        let n = name.lowercased(), t = parameters.map { $0.lowercased() }
        if kind == .goniometer {
            // Modulation (an LFO to draw) rather than stereo imaging.
            let mod = ["chorus", "flang", "phase", "tremolo", "vibrato", "modulat", "rotary", "ensemble"].contains(where: n.contains)
                || t.contains { $0.contains("rate") || $0.contains("speed") } && t.contains { $0.contains("depth") || $0.contains("intensity") }
            return mod ? .modulation : .plain
        }
        guard kind == .history else { return .plain }
        let verb = ["reverb", "verb", "hall", "room", "plate", "chamber", "space"].contains(where: n.contains)
            || t.filter { p in ["decay", "room", "size", "pre-delay", "predelay", "diffusion", "damping", "reverb", "early", "late"].contains(where: p.contains) }.count >= 2
        if verb { return .chamber }
        return ["delay", "echo", "tape"].contains(where: n.contains) || t.contains { $0.contains("feedback") } ? .echo : .plain
    }

    static func title(_ kind: FaceplateDisplay.Kind, subject: Subject) -> String {
        switch (kind, subject) {
        case (_, .chamber): "Acoustic Chamber"
        case (_, .echo): "Chronograph of Echoes"
        case (_, .modulation): "Crank and Disc"
        case (.response, _): "Frequency Atlas"
        case (.gainReduction, _): "Indicator of Reduction"
        case (.vu, _): "Indicator of Level"
        case (.transfer, _): "Transfer Curve"
        case (.history, _): "Envelope in Time"
        case (.goniometer, _): "The Stereo Field"
        case (.analyzer, _): "Spectral Census"
        case (.scope, _): "Form of the Wave"
        }
    }

    /// The figure's field (above the caption) and the caption itself.
    static func frame(_ ctx: CGContext, _ bounds: CGRect, figure: Int, title: String) -> CGRect {
        let field = CGRect(x: bounds.minX + 5, y: bounds.minY + 5, width: bounds.width - 10, height: bounds.height - 10 - captionHeight)
        // On the plate itself (owner, fourth round: one continuous diagram, no screens): a single fine rule frames it.
        Atelier.box(ctx, field, weight: Atelier.hair, color: Theme.ink(0.4))
        Atelier.note(ctx, "Fig. \(figure) · \(title)", at: CGPoint(x: bounds.midX, y: field.maxY + 3.5), size: 8.5, color: Theme.textDim, align: .center)
        return field.insetBy(dx: 1, dy: 1)
    }

    static func label(_ ctx: CGContext, _ s: String, _ p: CGPoint, align: NSTextAlignment = .left, size: CGFloat = 6.5, color: NSColor = Theme.textDim) {
        Atelier.note(ctx, s, at: p, size: size, color: color, align: align, roman: true)
    }
    static func dotted(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, alpha: CGFloat = 0.25) {
        Atelier.rule(ctx, a, b, weight: 0.4, color: Theme.ink(alpha), dash: [1, 2])
    }
    /// Engraved fill: vertical rules between `top` and the baseline `y0`, clipped to `area`.
    static func engrave(_ ctx: CGContext, _ area: CGPath, in r: CGRect, color: NSColor, spacing: CGFloat = 1.8) {
        ctx.saveGState(); ctx.addPath(area); ctx.clip()
        Atelier.hatch(ctx, r, spacing: spacing, color: color, weight: 0.45, angle: .pi / 2)
        ctx.restoreGState()
    }
    static func path(_ pts: [CGPoint]) -> CGMutablePath {
        let p = CGMutablePath()
        if let f = pts.first { p.move(to: f); for q in pts.dropFirst() { p.addLine(to: q) } }
        return p
    }
}

extension FaceplateScreen {
    /// Atelier: draws this display as a Codex figure. Returns false where it keeps the plain ink rendering.
    func drawCodex(_ ctx: CGContext) -> Bool {
        if let fig = atelierFigure {
            // The figure is drawn straight on the plate (no screen): its caption below, its parts lettered as the key.
            let field = CGRect(x: bounds.minX + 3, y: bounds.minY + 3, width: bounds.width - 6, height: bounds.height - 6 - Codex.captionHeight)
            Atelier.note(ctx, "Fig. \(figureNumber) · \(fig.title)", at: CGPoint(x: bounds.midX, y: field.maxY + 2), size: 8.5, color: Theme.textDim, align: .center)
            ctx.saveGState()
            if poweredOff { ctx.setAlpha(0.45) }
            let live: Double = switch self {
            case let m as MovingCoilMeter: m.reductionDb
            case let h as HistoryScreen: Double(h.latest.output)
            default: -90
            }
            figureLive = live
            drawFigure(fig, ctx, field, live: live)
            ctx.restoreGState()
            return true
        }
        let f = Codex.frame(ctx, bounds, figure: figureNumber, title: Codex.title(codexKind, subject: codexSubject))
        ctx.saveGState(); ctx.clip(to: f.insetBy(dx: -0.5, dy: -0.5))
        defer { ctx.restoreGState() }
        if poweredOff { ctx.setAlpha(0.45) }
        switch self {
        case let s as ResponseScreen: s.codex(ctx, f)
        case let s as MovingCoilMeter: s.codex(ctx, f)
        case let s as TransferScreen: s.codex(ctx, f)
        case let s as HistoryScreen: if codexSubject == .chamber { s.chamber(ctx, f) } else { s.codex(ctx, f) }
        case let s as GoniometerScreen: s.codex(ctx, f)
        case let s as LedAnalyzer: s.codex(ctx, f)
        case let s as ScopeScreen: s.codex(ctx, f)
        default: return false
        }
        return true
    }
}

extension ResponseScreen {
    func codex(_ ctx: CGContext, _ f: CGRect) {
        let plot = Self.codexPlot(bounds)
        func x(_ hz: Double) -> CGFloat { plot.minX + plot.width * CGFloat(log10(hz / 20) / 3) }
        func y(_ db: Double) -> CGFloat { plot.midY - plot.height / 2 * CGFloat(max(-1.05, min(1.05, db / Self.range))) }
        for hz in [50.0, 200, 500, 2000, 5000] { Codex.dotted(ctx, CGPoint(x: x(hz), y: plot.minY), CGPoint(x: x(hz), y: plot.maxY), alpha: 0.13) }
        for hz in [100.0, 1000, 10000] { Codex.dotted(ctx, CGPoint(x: x(hz), y: plot.minY), CGPoint(x: x(hz), y: plot.maxY), alpha: 0.3) }
        for db in [-12.0, -6, 6, 12] { Codex.dotted(ctx, CGPoint(x: plot.minX, y: y(db)), CGPoint(x: plot.maxX, y: y(db)), alpha: 0.22) }
        Atelier.rule(ctx, CGPoint(x: plot.minX, y: y(0)), CGPoint(x: plot.maxX, y: y(0)), weight: 0.5, color: Theme.ink(0.55))
        Atelier.rule(ctx, CGPoint(x: plot.minX, y: plot.minY), CGPoint(x: plot.minX, y: plot.maxY), weight: 0.6, color: Theme.ink(0.7))
        for db in [12.0, 6, 0, -6, -12] {
            Codex.label(ctx, db == 0 ? "0" : String(format: "%+.0f", db), CGPoint(x: plot.minX - 2, y: y(db) - 4.5), align: .right)
        }
        for (hz, t) in [(20.0, "20"), (100, "100"), (1000, "1k"), (10000, "10k"), (20000, "20k")] {
            Codex.label(ctx, t, CGPoint(x: min(plot.maxX - 4, max(plot.minX + 4, x(hz))), y: plot.maxY + 1), align: .center)
        }
        // The spectrum: a fine dotted outline, like a measured profile.
        if let raw = spectrum, raw.count == Self.frequencies.count, let top = raw.max(), top > -150 {
            let pts = Self.frequencies.enumerated().map { i, hz -> CGPoint in
                let lo = max(0, i - 3), hi = min(raw.count - 1, i + 3)
                let v = raw[lo...hi].reduce(0, +) / Float(hi - lo + 1)
                return CGPoint(x: x(hz), y: plot.maxY - plot.height * 0.85 * CGFloat(max(0, min(1, (v - top + 60) / 60))))
            }
            ctx.saveGState(); ctx.addPath(Codex.path(pts)); ctx.setStrokeColor(Theme.ink(0.35).cgColor); ctx.setLineWidth(0.5)
            ctx.setLineDash(phase: 0, lengths: [0.8, 1.6]); ctx.strokePath(); ctx.restoreGState()
        }
        let red = Atelier.vermilion
        if let c = curve, c.count == Self.frequencies.count {
            let pts = Self.frequencies.enumerated().map { CGPoint(x: x($0.element), y: y(c[$0.offset])) }
            let area = Codex.path(pts); area.addLine(to: CGPoint(x: plot.maxX, y: y(0))); area.addLine(to: CGPoint(x: plot.minX, y: y(0))); area.closeSubpath()
            Codex.engrave(ctx, area, in: plot, color: red.withAlphaComponent(0.45))
            ctx.saveGState(); ctx.addPath(Codex.path(pts)); ctx.setStrokeColor(red.cgColor); ctx.setLineWidth(1.2); ctx.setLineJoin(.round)
            if measured { ctx.setLineDash(phase: 0, lengths: [3, 1.5]) }
            ctx.strokePath(); ctx.restoreGState()
        }
        // Bands: small turned rings, numbered; the moved ones annotated with frequency and gain on a leader.
        var annotated = 0
        for (i, m) in markers.enumerated() where m.hz >= 20 && m.hz <= 20_000 {
            let p = center(of: m), lit = dragging == i
            let d = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            ctx.setFillColor((lit ? red : Theme.lcd).cgColor); ctx.fillEllipse(in: d)
            Atelier.loop(ctx, d, weight: 0.7, color: m.on ? Theme.text : Theme.textFaint)
            if !m.on { Atelier.rule(ctx, CGPoint(x: d.minX, y: d.maxY), CGPoint(x: d.maxX, y: d.minY), weight: 0.5, color: Theme.textFaint) }
            Codex.label(ctx, m.label, CGPoint(x: p.x, y: p.y - 3.8), align: .center, size: 5.5, color: lit ? Theme.lcd : Theme.text)
            if let db = m.db, m.on, abs(db) >= 0.5 || lit, annotated < 3, plot.width > 150 {
                annotated += 1
                let up = db >= 0, ty = up ? p.y - 15 : p.y + 9
                Atelier.rule(ctx, CGPoint(x: p.x, y: up ? d.minY : d.maxY), CGPoint(x: p.x, y: up ? ty + 8 : ty), weight: 0.4, color: Theme.ink(0.4))
                let hz = m.hz >= 1000 ? String(format: "%.1f kHz", m.hz / 1000) : String(format: "%.0f Hz", m.hz)
                Atelier.note(ctx, "\(hz)  \(String(format: "%+.1f dB", db))", at: CGPoint(x: p.x, y: ty - (up ? 2 : 0)), size: 6.5, color: Theme.textDim, align: .center)
            }
        }
        if measured { Atelier.note(ctx, "measured", at: CGPoint(x: plot.maxX - 2, y: plot.minY), size: 7, align: .right) }
    }
}

extension MovingCoilMeter {
    /// An engraved indicator, like a dial on a surveying instrument: graduated arc, numerals in the serif, a red-ochre
    /// zone, and a long lozenge needle swinging from a pivot below the scale.
    func codex(_ ctx: CGContext, _ f: CGRect) {
        let pivot = CGPoint(x: f.midX, y: f.maxY + f.height * 0.25)
        let radius = min(f.width * 0.55, (pivot.y - f.minY) - 10)
        let span = 0.78
        func ang(_ pos: Double) -> CGFloat { CGFloat(-.pi / 2 - span + 2 * span * pos) }
        func pt(_ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: pivot.x + r * cos(a), y: pivot.y + r * sin(a)) }
        Atelier.construction(ctx, circle: CGRect(x: pivot.x - radius * 0.55, y: pivot.y - radius * 0.55, width: radius * 1.1, height: radius * 1.1))
        ctx.setStrokeColor(Theme.ink(0.75).cgColor); ctx.setLineWidth(0.6)
        ctx.addArc(center: pivot, radius: radius, startAngle: ang(0), endAngle: ang(1), clockwise: false); ctx.strokePath()
        ctx.setLineWidth(0.4)
        ctx.addArc(center: pivot, radius: radius - 6, startAngle: ang(0), endAngle: ang(1), clockwise: false); ctx.strokePath()
        let marks: [(Double, String)] = mode == .gainReduction
            ? [0, 1, 2, 3, 5, 7, 10, 20].map { (Self.reductionPosition(Double($0)), $0 == 0 ? "0" : "\($0)") }
            : [(-20.0, "20"), (-10, "10"), (-7, "7"), (-5, "5"), (-3, "3"), (-1, "1"), (0, "0"), (1, "1"), (3, "3")].map { (Self.position($0.0), $0.1) }
        // The hot zone (reduction past 10 dB, or level past 0 VU): engraved red between the two arcs.
        let hot = mode == .gainReduction ? (Self.reductionPosition(20), Self.reductionPosition(10)) : (Self.position(0), Self.position(3))
        let zone = CGMutablePath()
        zone.addArc(center: pivot, radius: radius, startAngle: ang(min(hot.0, hot.1)), endAngle: ang(max(hot.0, hot.1)), clockwise: false)
        zone.addArc(center: pivot, radius: radius - 6, startAngle: ang(max(hot.0, hot.1)), endAngle: ang(min(hot.0, hot.1)), clockwise: true)
        zone.closeSubpath()
        Codex.engrave(ctx, zone, in: f, color: Atelier.vermilion.withAlphaComponent(0.7), spacing: 1.4)
        for i in 0...40 {
            let pos = Double(i) / 40, a = ang(pos)
            Atelier.rule(ctx, pt(a, radius - 6), pt(a, radius - (i % 5 == 0 ? 0 : 3)), weight: 0.35, color: Theme.ink(0.55))
        }
        for (pos, t) in marks {
            let a = ang(pos)
            Atelier.rule(ctx, pt(a, radius - 6), pt(a, radius + 2), weight: 0.6, color: Theme.ink(0.85))
            let q = pt(a, radius + 7)
            Codex.label(ctx, t, CGPoint(x: q.x, y: q.y - 4.5), align: .center, size: 7, color: Theme.text)
        }
        Atelier.note(ctx, mode == .gainReduction ? "dB of reduction" : "VU", at: CGPoint(x: pivot.x, y: pivot.y - radius * 0.45 - 2), size: 7.5, align: .center)
        Atelier.needle(ctx, center: pivot, angle: ang(max(-0.01, min(1.06, needle))), length: radius + 1)
    }
}

extension TransferScreen {
    func codex(_ ctx: CGContext, _ f: CGRect) {
        let side = min(f.width - 16, f.height - 14)
        let plot = CGRect(x: f.midX - side / 2 + 4, y: f.minY + 4, width: side, height: side)
        Atelier.construction(ctx, circle: plot)
        Codex.dotted(ctx, CGPoint(x: plot.midX, y: plot.minY), CGPoint(x: plot.midX, y: plot.maxY), alpha: 0.35)
        Codex.dotted(ctx, CGPoint(x: plot.minX, y: plot.midY), CGPoint(x: plot.maxX, y: plot.midY), alpha: 0.35)
        Atelier.rule(ctx, CGPoint(x: plot.minX, y: plot.maxY), CGPoint(x: plot.maxX, y: plot.minY), weight: 0.4, color: Theme.ink(0.35), dash: [3, 2])
        Atelier.box(ctx, plot, weight: 0.5, color: Theme.ink(0.6))
        for (k, pts) in frames.enumerated() {
            ctx.setFillColor((k == frames.count - 1 ? Atelier.vermilion : Theme.ink(0.3)).cgColor)
            for p in pts { ctx.fill(CGRect(x: plot.midX + p.x * plot.width / 2 - 0.5, y: plot.midY - p.y * plot.height / 2 - 0.5, width: 1, height: 1)) }
        }
        Codex.label(ctx, "in", CGPoint(x: plot.maxX + 2, y: plot.midY - 4.5), size: 7)
        Codex.label(ctx, "out", CGPoint(x: plot.midX + 2, y: plot.minY), size: 7)
    }
}

extension HistoryScreen {
    func codex(_ ctx: CGContext, _ f: CGRect) {
        let plot = CGRect(x: f.minX + 16, y: f.minY + 6, width: f.width - 20, height: f.height - 12)
        func y(_ db: Float) -> CGFloat { plot.minY + plot.height * CGFloat(max(0, min(1, -db / 60))) }
        func x(_ i: Int) -> CGFloat { plot.minX + plot.width * CGFloat(i) / CGFloat(Self.columns - 1) }
        for db: Float in [-20, -40] { Codex.dotted(ctx, CGPoint(x: plot.minX, y: y(db)), CGPoint(x: plot.maxX, y: y(db))) }
        for db: Float in [0, -20, -40, -60] { Codex.label(ctx, db == 0 ? "0" : String(format: "%.0f", db), CGPoint(x: plot.minX - 2, y: y(db) - 4.5), align: .right) }
        Atelier.rule(ctx, CGPoint(x: plot.minX, y: plot.minY), CGPoint(x: plot.minX, y: plot.maxY), weight: 0.6, color: Theme.ink(0.7))
        Atelier.rule(ctx, CGPoint(x: plot.minX, y: plot.maxY), CGPoint(x: plot.maxX, y: plot.maxY), weight: 0.6, color: Theme.ink(0.7))
        Atelier.arrowhead(ctx, at: CGPoint(x: plot.maxX + 1, y: plot.maxY), angle: 0, color: Theme.ink(0.7), size: 5)
        let out = output.enumerated().map { CGPoint(x: x($0.offset), y: y($0.element)) }
        let area = Codex.path(out); area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY)); area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY)); area.closeSubpath()
        Codex.engrave(ctx, area, in: plot, color: Atelier.vermilion.withAlphaComponent(0.4))
        ctx.saveGState(); ctx.addPath(Codex.path(out)); ctx.setStrokeColor(Atelier.vermilion.cgColor); ctx.setLineWidth(1); ctx.strokePath()
        ctx.addPath(Codex.path(input.enumerated().map { CGPoint(x: x($0.offset), y: y($0.element)) }))
        ctx.setStrokeColor(Theme.ink(0.6).cgColor); ctx.setLineWidth(0.5); ctx.setLineDash(phase: 0, lengths: [2, 1.5]); ctx.strokePath(); ctx.restoreGState()
        Atelier.note(ctx, "A(t) = A₀ e^(−t/τ)", at: CGPoint(x: plot.maxX - 2, y: plot.minY), size: 7.5, align: .right)
        Codex.label(ctx, "t", CGPoint(x: plot.maxX - 4, y: plot.maxY - 10), size: 7)
    }

    /// Reverbs: a vaulted hall in one-point perspective (an arcade of columns down each side, a coffered floor), with
    /// sound rays from the source reflecting to the listener; the rays darken with the output level.
    @discardableResult
    func chamber(_ ctx: CGContext, _ f: CGRect, letters: (source: String?, vault: String?, listener: String?) = ("A", "B", "C"),
                 phase: Double = 0) -> (vault: CGPoint, listener: CGPoint) {
        let lvl = CGFloat(max(0, min(1, (latest.output + 60) / 60)))
        let ink = Theme.ink(0.7), faint = Theme.ink(0.3)
        let outer = CGRect(x: f.minX + 6, y: f.minY + 10, width: f.width - 12, height: f.height - 14)
        let back = CGRect(x: outer.midX - outer.width * 0.17, y: outer.minY + outer.height * 0.32, width: outer.width * 0.34, height: outer.height * 0.42)
        let vp = CGPoint(x: back.midX, y: back.midY)
        // Vault: the front arch and the back arch, joined by ribs.
        let front = CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: outer.height)
        // A flattened (elliptical) arch springing at `spring` below the top of `r`.
        func arch(_ r: CGRect, rise: CGFloat) -> CGPath {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.minY + rise))
            let t = CGAffineTransform(translationX: r.midX, y: r.minY + rise).scaledBy(x: r.width / 2, y: rise)
            p.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 2 * .pi, clockwise: false, transform: t)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); return p
        }
        func archPoint(_ r: CGRect, rise: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.minY + rise + sin(a) * rise) }
        let frontArch = front.insetBy(dx: 1, dy: 1), frontRise = frontArch.height * 0.38
        let backArch = CGRect(x: back.minX, y: back.minY - back.height * 0.45, width: back.width, height: back.height * 1.45), backRise = backArch.height * 0.32
        ctx.saveGState(); ctx.addPath(arch(frontArch, rise: frontRise)); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
        ctx.addPath(arch(backArch, rise: backRise)); ctx.setLineWidth(0.6); ctx.strokePath(); ctx.restoreGState()
        for k in 0...8 { // vault ribs (coffers) from the front arch to the back arch
            let a = CGFloat.pi + .pi * CGFloat(k) / 8
            Atelier.rule(ctx, archPoint(frontArch, rise: frontRise, a), archPoint(backArch, rise: backRise, a), weight: 0.35, color: faint)
        }
        for k in 1...3 { // transverse arches of the vault, receding
            let t = pow(CGFloat(k) / 4, 1.3)
            let r = CGRect(x: frontArch.minX + (backArch.minX - frontArch.minX) * t, y: frontArch.minY + (backArch.minY - frontArch.minY) * t,
                           width: frontArch.width + (backArch.width - frontArch.width) * t, height: 0)
            let rise = frontRise + (backRise - frontRise) * t
            let half = CGMutablePath()
            half.addArc(center: .zero, radius: 1, startAngle: .pi, endAngle: 2 * .pi, clockwise: false,
                        transform: CGAffineTransform(translationX: r.midX, y: r.minY + rise).scaledBy(x: r.width / 2, y: rise))
            ctx.saveGState(); ctx.addPath(half); ctx.setStrokeColor(faint.cgColor); ctx.setLineWidth(0.45); ctx.strokePath(); ctx.restoreGState()
        }
        // Floor: lines to the vanishing point and transverse joints closing up with distance.
        for k in 0...8 {
            let x0 = front.minX + front.width * CGFloat(k) / 8
            let t = (back.maxY - vp.y) / (front.maxY - vp.y)
            Atelier.rule(ctx, CGPoint(x: x0, y: front.maxY), CGPoint(x: vp.x + (x0 - vp.x) * t, y: back.maxY), weight: 0.35, color: faint)
        }
        for k in 1...5 {
            let t = pow(CGFloat(k) / 6, 1.6), yy = front.maxY + (back.maxY - front.maxY) * t
            let half = front.width / 2 + (back.width / 2 - front.width / 2) * t
            Atelier.rule(ctx, CGPoint(x: vp.x - half, y: yy), CGPoint(x: vp.x + half, y: yy), weight: 0.35, color: faint)
        }
        // Arcades: columns down each side, receding.
        for side in [-1.0, 1.0] as [CGFloat] {
            for k in 0..<4 {
                let t = CGFloat(k) / 4 + 0.08
                let xx = vp.x + side * (front.width / 2 + (back.width / 2 - front.width / 2) * t)
                let top = frontArch.minY + frontRise + (backArch.minY + backRise - frontArch.minY - frontRise) * t
                let bottom = front.maxY + (back.maxY - front.maxY) * t
                let w = 3.5 * (1 - t * 0.7)
                ctx.setFillColor(Theme.lcd.cgColor); ctx.fill(CGRect(x: xx - w / 2, y: top, width: w, height: bottom - top))
                Atelier.box(ctx, CGRect(x: xx - w / 2, y: top, width: w, height: bottom - top), weight: 0.4, color: ink)
                Atelier.hatch(ctx, CGRect(x: xx, y: top, width: w / 2, height: bottom - top), spacing: 1.2, color: faint, weight: 0.3, angle: .pi / 2)
            }
        }
        Atelier.box(ctx, back, weight: 0.5, color: ink)
        Atelier.hatch(ctx, back.insetBy(dx: 1, dy: 1), spacing: 2.5, color: Theme.ink(0.14), weight: 0.35, angle: .pi / 2)
        // Source and listener, and the rays between them by way of the walls.
        let src = CGPoint(x: front.minX + front.width * 0.28, y: front.maxY - front.height * 0.18)
        let lis = CGPoint(x: front.minX + front.width * 0.74, y: front.maxY - front.height * 0.14)
        let hits = [CGPoint(x: back.minX + 4, y: back.midY), CGPoint(x: back.maxX - 3, y: back.minY + 6), archPoint(backArch, rise: backRise, 1.5 * .pi),
                    CGPoint(x: front.maxX - front.width * 0.12, y: front.minY + front.height * 0.45)]
        let ray = Atelier.vermilion.withAlphaComponent(0.25 + 0.65 * lvl)
        // The sound travels: the rays' dashes run from the source to the listener (phase from the figure's motion).
        let run = CGFloat(phase / (2 * .pi) * 8).truncatingRemainder(dividingBy: 4)
        func travelling(_ a: CGPoint, _ b: CGPoint) {
            ctx.saveGState(); ctx.setStrokeColor(ray.cgColor); ctx.setLineWidth(0.6); ctx.setLineDash(phase: -run, lengths: [2.5, 1.5])
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath(); ctx.restoreGState()
        }
        for h in hits {
            travelling(src, h); travelling(h, lis)
            Atelier.arrowhead(ctx, at: CGPoint(x: (h.x + lis.x) / 2, y: (h.y + lis.y) / 2), angle: atan2(lis.y - h.y, lis.x - h.x), color: ray, size: 4)
        }
        // And spreads from the source in rings on the floor (flattened by the perspective), fading as they go.
        if phase != 0 {
            ctx.saveGState(); ctx.clip(to: front)
            for k in 0..<2 {
                let t = CGFloat((phase / (2 * .pi) + Double(k) * 0.5).truncatingRemainder(dividingBy: 1))
                let r = 6 + t * front.width * 0.45
                ctx.setStrokeColor(Atelier.vermilion.withAlphaComponent((1 - t) * (0.2 + 0.5 * lvl)).cgColor); ctx.setLineWidth(0.6)
                ctx.strokeEllipse(in: CGRect(x: src.x - r, y: src.y - r * 0.32, width: 2 * r, height: r * 0.64))
            }
            ctx.restoreGState()
        }
        ctx.setFillColor(Theme.text.cgColor)
        ctx.fillEllipse(in: CGRect(x: src.x - 2, y: src.y - 2, width: 4, height: 4))
        Atelier.rule(ctx, CGPoint(x: src.x, y: src.y + 2), CGPoint(x: src.x, y: src.y + 8), weight: 0.7, color: Theme.text)
        Atelier.loop(ctx, CGRect(x: lis.x - 2.5, y: lis.y - 2.5, width: 5, height: 5), weight: 0.7, color: Theme.text)
        if let l = letters.source { Atelier.callout(ctx, l, from: src, to: CGPoint(x: src.x - 10, y: src.y - 6)) }
        let crown = archPoint(frontArch, rise: frontRise, 1.5 * .pi)
        let vault = CGPoint(x: crown.x + 30, y: crown.y + 6)
        if let l = letters.vault { Atelier.callout(ctx, l, from: vault, to: CGPoint(x: crown.x + 44, y: crown.y + 2)) }
        if let l = letters.listener { Atelier.callout(ctx, l, from: lis, to: CGPoint(x: lis.x + 10, y: lis.y - 6)) }
        return (vault, lis)
    }
}

extension GoniometerScreen {
    func codex(_ ctx: CGContext, _ f: CGRect) {
        let bar: CGFloat = 12
        let r = min(f.width, f.height - bar) / 2 - 4
        let c = CGPoint(x: f.midX, y: f.minY + 4 + r)
        let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        Atelier.loop(ctx, disc, weight: 0.6, color: Theme.ink(0.7))
        Atelier.construction(ctx, circle: disc.insetBy(dx: r * 0.5, dy: r * 0.5))
        for a in [0.0, .pi / 4, .pi / 2, 3 * .pi / 4] {
            Codex.dotted(ctx, CGPoint(x: c.x - r * CGFloat(cos(a)), y: c.y - r * CGFloat(sin(a))), CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a))), alpha: 0.3)
        }
        Codex.label(ctx, "L", CGPoint(x: c.x - r * 0.72 - 6, y: c.y - r * 0.72 - 9), size: 7)
        Codex.label(ctx, "R", CGPoint(x: c.x + r * 0.72 + 1, y: c.y - r * 0.72 - 9), size: 7)
        Codex.label(ctx, "M", CGPoint(x: c.x + 2, y: disc.minY - 1), size: 7)
        ctx.saveGState(); ctx.addEllipse(in: disc); ctx.clip()
        for (k, pts) in frames.enumerated() {
            ctx.setFillColor((k == frames.count - 1 ? Atelier.vermilion : Theme.ink(0.25)).cgColor)
            for q in pts { ctx.fill(CGRect(x: c.x + q.x * gain * r - 0.5, y: c.y - q.y * gain * r - 0.5, width: 1, height: 1)) }
        }
        ctx.restoreGState()
        let line = CGRect(x: f.minX + 14, y: f.maxY - 6, width: f.width - 28, height: 0)
        Atelier.rule(ctx, CGPoint(x: line.minX, y: line.minY), CGPoint(x: line.maxX, y: line.minY), weight: 0.5, color: Theme.ink(0.7))
        for k in 0...4 { let x = line.minX + line.width * CGFloat(k) / 4; Atelier.rule(ctx, CGPoint(x: x, y: line.minY - 2), CGPoint(x: x, y: line.minY + 2), weight: 0.5, color: Theme.ink(0.7)) }
        Codex.label(ctx, "−1", CGPoint(x: line.minX - 2, y: line.minY - 4.5), align: .right)
        Codex.label(ctx, "+1", CGPoint(x: line.maxX + 2, y: line.minY - 4.5))
        let mx = line.minX + line.width * CGFloat((correlation + 1) / 2)
        Atelier.arrowhead(ctx, at: CGPoint(x: mx, y: line.minY), angle: .pi / 2, color: Atelier.vermilion, size: 5)
    }
}

extension LedAnalyzer {
    func codex(_ ctx: CGContext, _ f: CGRect) {
        let plot = CGRect(x: f.minX + 6, y: f.minY + 4, width: f.width - 12, height: f.height - 14)
        let n = Self.bands.count, w = plot.width / CGFloat(n)
        Atelier.rule(ctx, CGPoint(x: plot.minX, y: plot.maxY), CGPoint(x: plot.maxX, y: plot.maxY), weight: 0.6, color: Theme.ink(0.7))
        for i in 0..<n {
            let v = CGFloat(max(0, min(1, (levels[i] - top + 48) / 48)))
            let col = CGRect(x: plot.minX + CGFloat(i) * w + 1, y: plot.maxY - plot.height * v, width: w - 2, height: plot.height * v)
            if col.height > 0.5 {
                Atelier.hatch(ctx, col, spacing: 1.5, color: Theme.ink(0.65), weight: 0.45)
                Atelier.box(ctx, col, weight: 0.4, color: Theme.ink(0.75))
            }
            let pk = CGFloat(max(0, min(1, (peaks[i] - top + 48) / 48)))
            if pk > 0.02 { Atelier.rule(ctx, CGPoint(x: col.minX, y: plot.maxY - plot.height * pk), CGPoint(x: col.maxX, y: plot.maxY - plot.height * pk), weight: 0.8, color: Atelier.vermilion) }
        }
        for (i, t) in [(2, "63"), (9, "250"), (15, "1k"), (21, "4k")] where i < n {
            Codex.label(ctx, t, CGPoint(x: plot.minX + (CGFloat(i) + 0.5) * w, y: plot.maxY + 0.5), align: .center, size: 6)
        }
    }
}

extension ScopeScreen {
    func codex(_ ctx: CGContext, _ f: CGRect) {
        let plot = f.insetBy(dx: 6, dy: 6)
        for i in 1..<8 { let x = plot.minX + plot.width * CGFloat(i) / 8; Codex.dotted(ctx, CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY), alpha: 0.15) }
        Atelier.rule(ctx, CGPoint(x: plot.minX, y: plot.midY), CGPoint(x: plot.maxX, y: plot.midY), weight: 0.5, color: Theme.ink(0.5))
        Atelier.arrowhead(ctx, at: CGPoint(x: plot.maxX + 2, y: plot.midY), angle: 0, color: Theme.ink(0.5), size: 4)
        Atelier.construction(ctx, circle: CGRect(x: plot.midX - plot.height / 2, y: plot.minY, width: plot.height, height: plot.height))
        for (k, t) in traces.enumerated() {
            let pts = t.enumerated().map { CGPoint(x: plot.minX + plot.width * CGFloat($0.offset) / CGFloat(max(1, t.count - 1)),
                                                   y: plot.midY - plot.height * 0.45 * CGFloat(max(-1, min(1, $0.element * gain)))) }
            ctx.saveGState(); ctx.addPath(Codex.path(pts))
            ctx.setStrokeColor((k == traces.count - 1 ? Atelier.vermilion : Theme.ink(0.18)).cgColor); ctx.setLineWidth(k == traces.count - 1 ? 0.9 : 0.5)
            ctx.strokePath(); ctx.restoreGState()
        }
        Codex.label(ctx, "t", CGPoint(x: plot.maxX - 6, y: plot.midY + 1), size: 7)
        Codex.label(ctx, "A", CGPoint(x: plot.minX + 2, y: plot.minY), size: 7)
    }
}
