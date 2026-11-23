// Graphite: every plug-in in the device panel is a hardware unit on a brushed graphite faceplate.
// Parameters become the control that suits them (a scaled knob, a stepped selector, a lit push switch), related
// parameters ("Low Cut Frequency", "Low Cut Slope") share an engraved section, knob scales are printed with the
// plug-in's own values, and thin LED meters show the unit's input and output (Settings can hide them).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
enum Faceplate {
    /// Input/output meters on each unit (Settings ▸ Plug-ins).
    static var showMeters: Bool {
        get { UserDefaults.standard.object(forKey: "deviceMeters") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "deviceMeters")
            NotificationCenter.default.post(name: metersChanged, object: nil)
        }
    }
    static let metersChanged = Notification.Name("DalnokDeviceMetersChanged")

    /// How worn the units look (Settings ▸ Plug-ins): 0 factory new … 1 years on the road. Scratches and grime on the
    /// metal, dust and smudges on the glass.
    static var wear: Double {
        get { max(0, min(1, UserDefaults.standard.object(forKey: "faceplateWear") as? Double ?? 0.25)) }
        set {
            UserDefaults.standard.set(max(0, min(1, newValue)), forKey: "faceplateWear")
            NotificationCenter.default.post(name: wearChanged, object: nil)
        }
    }
    static let wearChanged = Notification.Name("DalnokFaceplateWearChanged")

    // Bypass and display preferences (Settings ▸ Plug-ins). Each posts `wearChanged` so the units redraw.
    private static func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
        (UserDefaults.standard.object(forKey: key) as? Double ?? fallback).clamped(to: range)
    }
    private static func store(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: wearChanged, object: nil)
    }
    /// How much a bypassed unit shrinks (fraction of its size, 0 … 0.1).
    static var bypassShrink: Double { get { number("bypassShrink", 0.045, 0...0.1) } set { store("bypassShrink", newValue) } }
    /// How much a bypassed unit darkens (0 … 0.5).
    static var bypassDim: Double { get { number("bypassDim", 0.12, 0...0.5) } set { store("bypassDim", newValue) } }
    /// Seconds a unit takes to sit back or come forward when bypassed (0.1 … 1.5).
    static var bypassMotion: Double { get { number("bypassMotion", 0.5, 0.1...1.5) } set { store("bypassMotion", newValue) } }
    /// Seconds its lights take to fade out or warm up (0 … 2).
    static var lightFade: Double { get { number("lightFade", 0.7, 0...2) } set { store("lightFade", newValue) } }
    /// Whether the dot-matrix readouts fade with the other lights (otherwise they switch off at once, like a VFD).
    static var readoutsFade: Bool { get { UserDefaults.standard.bool(forKey: "readoutsFade") } set { store("readoutsFade", newValue) } }
    /// White outline around the selected unit.
    static var selectionGlow: Bool { get { UserDefaults.standard.object(forKey: "selectionGlow") as? Bool ?? true } set { store("selectionGlow", newValue) } }
    /// Seconds the IN/OUT meters hold their peak (0 … 3).
    static var peakHold: Double { get { number("meterPeakHold", 1.5, 0...3) } set { store("meterPeakHold", newValue) } }
    /// VU needle ballistics: false = the standard 300 ms movement, true = a faster 100 ms one.
    static var fastVU: Bool { get { UserDefaults.standard.bool(forKey: "fastVU") } set { store("fastVU", newValue) } }
    /// Every key above, for tests that restore them.
    static let preferenceKeys = ["faceplateWear", "deviceMeters", "bypassShrink", "bypassDim", "bypassMotion", "lightFade", "readoutsFade",
                                 "selectionGlow", "meterPeakHold", "fastVU"]

    /// A stable seed from a unit's name (FNV-1a), so its scratches and dust stay put between launches.
    static func seed(_ name: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h == 0 ? 1 : h
    }
    /// Small deterministic generator for wear patterns.
    struct Random {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        /// Uniform in 0..<1.
        mutating func next01() -> Double { Double(next() >> 11) / Double(1 << 53) }
        var unit: CGFloat { mutating get { CGFloat(next01()) } }
    }

    // Palette: neutral graphite metal.
    static let plateTop = NSColor(srgbRed: 0.235, green: 0.243, blue: 0.259, alpha: 1)
    static let plateBottom = NSColor(srgbRed: 0.176, green: 0.184, blue: 0.196, alpha: 1)
    /// Lettering and legends: engraved metal (rack), light on glass (cards), ink on paper (schematic).
    static var engraving: NSColor {
        switch Theme.look.devices { case .cards: Theme.text; case .schematic: Theme.text; default: NSColor(srgbRed: 0.80, green: 0.82, blue: 0.84, alpha: 1) }
    }
    static var legend: NSColor {
        switch Theme.look.devices { case .cards, .schematic: Theme.textDim; default: NSColor(srgbRed: 0.56, green: 0.59, blue: 0.62, alpha: 1) }
    }
    static let readout = NSColor(srgbRed: 0.87, green: 0.89, blue: 0.91, alpha: 1)

    // MARK: Grouping

    struct Item { let id: UInt32; let label: String }
    struct Section { let title: String; var items: [Item] }

    /// Consecutive parameters that share all but their last word form a titled section
    /// ("Low Cut Frequency", "Low Cut Slope" → LOW CUT: Frequency, Slope); the rest share untitled sections.
    static func sections(_ params: [(id: UInt32, title: String)]) -> [Section] {
        func key(_ t: String) -> String {
            let words = t.split(separator: " ")
            return words.count >= 2 ? words.dropLast().joined(separator: " ") : ""
        }
        func short(_ t: String, _ k: String) -> String {
            let rest = String(t.dropFirst(k.count)).trimmingCharacters(in: .whitespaces)
            return rest.caseInsensitiveCompare("On/Off") == .orderedSame ? "On" : rest
        }
        var out: [Section] = []
        var i = 0
        while i < params.count {
            let k = key(params[i].title)
            var j = i + 1
            while !k.isEmpty, j < params.count, key(params[j].title) == k { j += 1 }
            if j - i >= 2 {
                out.append(Section(title: k, items: params[i..<j].map { Item(id: $0.id, label: short($0.title, k)) }))
            } else {
                let item = Item(id: params[i].id, label: params[i].title)
                if let last = out.indices.last, out[last].title.isEmpty { out[last].items.append(item) }
                else { out.append(Section(title: "", items: [item])) }
            }
            i = j
        }
        return out
    }

    /// Short legend for a printed scale: drops units, writes thousands as "k" ("20000 Hz" → "20k").
    static func legend(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if let space = t.firstIndex(of: " "), Double(t[..<space]) != nil { t = String(t[..<space]) }
        if let v = Double(t) {
            if abs(v) >= 1000 { let k = v / 1000; return (k == k.rounded() ? String(format: "%.0f", k) : String(format: "%.1f", k)) + "k" }
            if v == v.rounded() { return String(format: "%.0f", v) }
            return abs(v) >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
        }
        return t.count > 6 ? String(t.prefix(5)) + "." : t
    }

    // MARK: Drawing

    /// The unit's faceplate: brushed graphite with a bevel, an accent line in the track colour, and four screws.
    static func plate(_ ctx: CGContext, _ rect: CGRect, accent: NSColor, dimmed: Bool, seed: UInt64 = 1, wear: Double = 0) {
        switch Theme.look.devices {
        case .cards:
            // Prism: a floating card of glass tinted by the track; bypassed cards turn to clear frosted glass.
            Prism.slab(ctx, rect.insetBy(dx: 1, dy: 1), radius: 10, tint: dimmed ? Theme.textFaint : accent, body: dimmed ? 0.035 : 0.07, lift: dimmed ? 0 : 0.4)
            return
        case .schematic:
            // Atelier: the unit as a pen sketch of the hardware: a box in oblique projection with a hatched side, rack
            // ears and screws, the track's ink along its foot; bypassed units are cross-hatched through.
            let front = Atelier.hardware(ctx, rect, accent: accent, dimmed: dimmed, seed: Int(truncatingIfNeeded: seed))
            Atelier.rule(ctx, CGPoint(x: front.minX + 16, y: front.maxY - 22), CGPoint(x: front.maxX - 16, y: front.maxY - 22), weight: Atelier.hair,
                         color: Theme.ink(0.35), seed: Int(truncatingIfNeeded: seed) &+ 5)
            return
        case .rack, .pedalboard: break
        }
        let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let colors = [plateTop.cgColor, plateBottom.cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
        }
        // Brushing: fine horizontal grain, seeded so it is stable between redraws.
        var grain: UInt64 = 0x9E3779B97F4A7C15
        var y = rect.minY
        while y < rect.maxY {
            grain = grain &* 6364136223846793005 &+ 1442695040888963407
            let a = 0.018 + Double(grain >> 59) / 31 * 0.035
            ctx.setStrokeColor(NSColor(white: (grain >> 40) & 1 == 0 ? 1 : 0, alpha: a).cgColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y)); ctx.strokePath()
            y += 1 + CGFloat((grain >> 33) & 1)
        }
        plateWear(ctx, rect, seed: seed, amount: wear)
        ctx.restoreGState()
        // Bevel: light top edge, dark outline.
        ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.13).cgColor)
        ctx.move(to: CGPoint(x: rect.minX + 5, y: rect.maxY - 1.5)); ctx.addLine(to: CGPoint(x: rect.maxX - 5, y: rect.maxY - 1.5)); ctx.strokePath()
        for p in [CGPoint(x: rect.minX + 6, y: rect.minY + 6), CGPoint(x: rect.maxX - 6, y: rect.minY + 6),
                  CGPoint(x: rect.minX + 6, y: rect.maxY - 6), CGPoint(x: rect.maxX - 6, y: rect.maxY - 6)] {
            screw(ctx, p)
        }
    }

    /// Use marks on the metal (clipped to the plate by the caller): scuffs and fine scratches through the finish,
    /// rubbed-bright edges, and grime gathered in the corners and around the screws.
    static func plateWear(_ ctx: CGContext, _ rect: CGRect, seed: UInt64, amount: Double) {
        guard amount > 0.001 else { return }
        var rng = Random(seed: seed)
        let a = CGFloat(amount), space = CGColorSpaceCreateDeviceRGB()
        // Grime: darker, slightly warm, where fingers and dust collect.
        let grime = [NSColor(srgbRed: 0.07, green: 0.06, blue: 0.05, alpha: 0.55 * a).cgColor, NSColor(srgbRed: 0.07, green: 0.06, blue: 0.05, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: grime, locations: [0, 1]) {
            for corner in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)] {
                ctx.drawRadialGradient(g, startCenter: corner, startRadius: 0, endCenter: corner, endRadius: 16 + 26 * a, options: [])
            }
            for _ in 0..<Int(2 + 3 * amount) { // patches of handling grime
                let c = CGPoint(x: rect.minX + rng.unit * rect.width, y: rect.minY + rng.unit * rect.height)
                ctx.saveGState()
                ctx.setAlpha(0.35 + 0.3 * rng.unit)
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 14 + 30 * rng.unit, options: [])
                ctx.restoreGState()
            }
        }
        // Rubbed edges: the finish worn bright along parts of the rim.
        for _ in 0..<Int(3 + 8 * amount) {
            let horizontal = rng.unit < 0.6
            let len = (0.05 + 0.18 * rng.unit) * (horizontal ? rect.width : rect.height)
            let along = rng.unit * ((horizontal ? rect.width : rect.height) - len)
            let edge = rng.unit < 0.5
            ctx.setStrokeColor(NSColor(white: 0.85, alpha: (0.05 + 0.10 * rng.unit) * a).cgColor); ctx.setLineWidth(1.2 + rng.unit)
            if horizontal {
                let y = edge ? rect.minY + 1.4 : rect.maxY - 1.4
                ctx.move(to: CGPoint(x: rect.minX + along, y: y)); ctx.addLine(to: CGPoint(x: rect.minX + along + len, y: y))
            } else {
                let x = edge ? rect.minX + 1.4 : rect.maxX - 1.4
                ctx.move(to: CGPoint(x: x, y: rect.minY + along)); ctx.addLine(to: CGPoint(x: x, y: rect.minY + along + len))
            }
            ctx.strokePath()
        }
        // Scratches: bright cut through the finish with a dark shadow edge; mostly short, a few long.
        let count = Int(Double(rect.width * rect.height) / 2600 * amount)
        for _ in 0..<count {
            let p = CGPoint(x: rect.minX + rng.unit * rect.width, y: rect.minY + rng.unit * rect.height)
            let long = rng.unit < 0.15
            let len = long ? 30 + rng.unit * 70 : 3 + rng.unit * 16
            let ang = (rng.unit - 0.5) * 2.4
            let bend = (rng.unit - 0.5) * len * 0.25
            let end = CGPoint(x: p.x + cos(ang) * len, y: p.y + sin(ang) * len)
            let mid = CGPoint(x: (p.x + end.x) / 2 - sin(ang) * bend, y: (p.y + end.y) / 2 + cos(ang) * bend)
            let alpha = (0.10 + 0.22 * rng.unit) * (0.4 + 0.6 * a)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(alpha * 0.8).cgColor); ctx.setLineWidth(0.6)
            ctx.move(to: CGPoint(x: p.x, y: p.y - 0.5)); ctx.addQuadCurve(to: CGPoint(x: end.x, y: end.y - 0.5), control: CGPoint(x: mid.x, y: mid.y - 0.5)); ctx.strokePath()
            ctx.setStrokeColor(NSColor(white: 0.92, alpha: alpha).cgColor); ctx.setLineWidth(0.45)
            ctx.move(to: p); ctx.addQuadCurve(to: end, control: mid); ctx.strokePath()
        }
        ctx.setLineCap(.butt)
    }

    static func screw(_ ctx: CGContext, _ c: CGPoint) {
        let r: CGFloat = 3
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r - 0.5, y: c.y - r - 1, width: 2 * r + 1, height: 2 * r + 1))
        let colors = [NSColor(white: 0.62, alpha: 1).cgColor, NSColor(white: 0.30, alpha: 1).cgColor] as CFArray
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x - r, y: c.y + r), end: CGPoint(x: c.x + r, y: c.y - r), options: [])
        }
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 0.12, alpha: 0.9).cgColor); ctx.setLineWidth(0.9)
        ctx.move(to: CGPoint(x: c.x - r * 0.6, y: c.y - r * 0.25)); ctx.addLine(to: CGPoint(x: c.x + r * 0.6, y: c.y + r * 0.25)); ctx.strokePath()
    }

    /// Text cut into the plate: a dark shadow below light lettering.
    static func engrave(_ text: String, in rect: CGRect, font: NSFont, color: NSColor = engraving, align: NSTextAlignment = .center) {
        // A long name is set smaller (to three quarters) before it is ever cut short with an ellipsis.
        let natural = (text as NSString).size(withAttributes: [.font: font]).width
        let font = natural > rect.width && rect.width > 0
            ? (NSFont(descriptor: font.fontDescriptor, size: max(font.pointSize * 0.75, font.pointSize * rect.width / natural)) ?? font) : font
        let para = NSMutableParagraphStyle(); para.alignment = align; para.lineBreakMode = .byTruncatingTail
        if Theme.look.devices == .cards || Theme.look.devices == .schematic { // printed, not cut into metal
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            return
        }
        let shadow: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.6), .paragraphStyle: para]
        (text as NSString).draw(with: rect.offsetBy(dx: 0, dy: 0.8), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: shadow)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    /// Angle for a normalized value: 270° of travel from lower left, measured clockwise from 12 o'clock.
    static func angle(_ v: Double) -> CGFloat { CGFloat(-0.75 * .pi + 1.5 * .pi * max(0, min(1, v))) }
    /// Point on a circle in a flipped view.
    static func point(_ c: CGPoint, _ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a)) }

    /// A machined knob: knurled skirt, brushed cap and a white pointer line.
    static func knob(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, angle a: CGFloat) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.setFillColor(NSColor(white: 0.09, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
        // Knurling on the skirt.
        ctx.setStrokeColor(NSColor(white: 0.32, alpha: 0.9).cgColor); ctx.setLineWidth(0.8)
        for i in 0..<36 {
            let t = CGFloat(i) / 36 * 2 * .pi
            ctx.move(to: point(c, r * 0.84, t)); ctx.addLine(to: point(c, r - 0.6, t))
        }
        ctx.strokePath()
        // Cap.
        let cap = r * 0.74
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - cap, y: c.y - cap, width: 2 * cap, height: 2 * cap)); ctx.clip()
        let colors = [NSColor(white: 0.44, alpha: 1).cgColor, NSColor(white: 0.20, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x - cap * 0.35, y: c.y - cap * 0.45), startRadius: 0,
                                   endCenter: c, endRadius: cap * 1.1, options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: CGRect(x: c.x - cap, y: c.y - cap, width: 2 * cap, height: 2 * cap))
        // Pointer.
        ctx.setStrokeColor(NSColor(white: 0.96, alpha: 1).cgColor); ctx.setLineWidth(max(1.6, r * 0.12)); ctx.setLineCap(.round)
        ctx.move(to: point(c, cap * 0.25, a)); ctx.addLine(to: point(c, r * 0.95, a)); ctx.strokePath()
        ctx.setLineCap(.butt)
    }

    /// Printed scale around a knob: `ticks` marks over the travel, a dark track and the value arc in `color`.
    static func scale(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, ticks: Int, value: Double, bipolar: Bool, color: NSColor) {
        let arcR = r + 3
        // Value track (the arc is drawn clockwise on screen, which is counter-clockwise in flipped coordinates).
        func arc(_ from: Double, _ to: Double, _ col: CGColor, _ w: CGFloat) {
            let a0 = angle(min(from, to)) - .pi / 2, a1 = angle(max(from, to)) - .pi / 2
            ctx.setStrokeColor(col); ctx.setLineWidth(w)
            ctx.addArc(center: c, radius: arcR, startAngle: a0, endAngle: a1, clockwise: false); ctx.strokePath()
        }
        arc(0, 1, NSColor.black.withAlphaComponent(0.45).cgColor, 2.2)
        arc(bipolar ? 0.5 : 0, value, color.cgColor, 2.2)
        ctx.setStrokeColor(legend.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(1)
        let n = max(ticks, 2)
        for i in 0..<n {
            let v = Double(i) / Double(n - 1)
            let long = i == 0 || i == n - 1 || (bipolar && abs(v - 0.5) < 1e-9)
            ctx.move(to: point(c, arcR + 2.5, angle(v))); ctx.addLine(to: point(c, arcR + (long ? 6 : 4.5), angle(v)))
        }
        ctx.strokePath()
    }

    /// A lit push switch: a raised key with an LED window.
    static func pushSwitch(_ ctx: CGContext, _ rect: CGRect, on: Bool, color: NSColor, lit: CGFloat = 1) {
        switch Theme.look.devices {
        case .cards: // a glass capsule that fills with the colour's light when on
            Prism.slab(ctx, rect.insetBy(dx: 1, dy: 3), radius: (rect.height - 6) / 2, tint: on ? color : Theme.hex(0xA8B8FF), body: on ? 0.32 * max(0.3, lit) : 0.08, lift: on ? 0.6 * lit : 0)
            return
        case .schematic: // a sketched check box: empty when off, ticked when on
            Atelier.checkbox(ctx, CGRect(x: rect.midX - 7, y: rect.midY - 7, width: 14, height: 14), on: on)
            return
        case .rack, .pedalboard: break
        }
        let key = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: on ? -0.5 : -1.5), blur: on ? 1.5 : 3, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(key); ctx.setFillColor(NSColor(white: 0.17, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(key); ctx.clip()
        let colors = [NSColor(white: on ? 0.30 : 0.38, alpha: 1).cgColor, NSColor(white: 0.20, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(key); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
        let led = CGRect(x: rect.midX - rect.width * 0.3, y: rect.minY + 4, width: rect.width * 0.6, height: 3)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor); ctx.fill(led)
        if on && lit > 0.01 {
            ctx.saveGState()
            ctx.setAlpha(lit)
            ctx.setShadow(offset: .zero, blur: 5, color: color.cgColor)
            ctx.setFillColor(color.cgColor); ctx.fill(led)
            ctx.restoreGState()
        }
    }

    /// A small display under each control: a recessed window holding a dot-matrix readout (5 × 7 dots per
    /// character, every dot visible faintly when unlit, the lit ones glowing like a vacuum-fluorescent display).
    static func readoutWindow(_ ctx: CGContext, _ rect: CGRect, text: String, glow: CGFloat = 1) {
        if Theme.look.devices == .cards || Theme.look.devices == .schematic {
            let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
            if Theme.look.devices == .cards {
                // Prism: the value written straight on the glass, no window around it.
                let base: NSColor = Theme.isLight ? Theme.text.withAlphaComponent(0.72) : NSColor.white.withAlphaComponent(0.66)
                let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(9, .medium), .foregroundColor: base.withAlphaComponent(base.alphaComponent * max(0.45, min(1, glow))), .paragraphStyle: para]
                (text as NSString).draw(with: rect.offsetBy(dx: 0, dy: 1.5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
                return
            }
            Atelier.rule(ctx, CGPoint(x: rect.minX + 4, y: rect.maxY - 0.5), CGPoint(x: rect.maxX - 4, y: rect.maxY - 0.5), weight: Atelier.hair, color: Theme.ink(0.35))
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(8.5, .medium), .foregroundColor: Theme.text.withAlphaComponent(max(0.35, min(1, glow))), .paragraphStyle: para]
            (text as NSString).draw(with: rect.offsetBy(dx: 0, dy: 1.5), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            return
        }
        let frame = CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.addPath(frame); ctx.setFillColor(NSColor(white: 0.03, alpha: 1).cgColor); ctx.fillPath()
        let screen = rect.insetBy(dx: 1.5, dy: 1.5)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); ctx.clip()
        ctx.setFillColor(NSColor(srgbRed: 0.010, green: 0.045, blue: 0.040, alpha: 1).cgColor); ctx.fill(screen)
        DotMatrix.draw(ctx, text, in: screen.insetBy(dx: 1.5, dy: 1.2), color: dotColor.withAlphaComponent(max(0, min(1, glow))))
        // Glass: a faint sheen across the top half and a shadow under the bezel's top edge.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.045).cgColor)
        ctx.fill(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height * 0.45))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor); ctx.fill(CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: 0.8))
        ctx.restoreGState()
        // Lip of the cut-out: dark above, a catch of light below.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor); ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: rect.minX + 2, y: rect.maxY + 0.4)); ctx.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY + 0.4)); ctx.strokePath()
    }
    static let dotColor = NSColor(srgbRed: 0.47, green: 0.98, blue: 0.84, alpha: 1)
}

// MARK: A parameter on the faceplate

/// One parameter, drawn as the control that suits it, with its name above and its value in a readout below.
/// Drag vertically (⇧ for fine), scroll, use the arrow keys, double-click for the default.
@MainActor
final class FaceplateControl: NSControl, ParameterControl {
    enum Kind { case knob, selector, toggle }
    let kind: Kind
    let name: String
    // Setters redraw only on a real change: the device panel re-applies every control's state four times a second,
    // and redrawing all of them each time cost the main thread about 45 ms per refresh on a 4-unit chain.
    var value: Double = 0 { didSet { if value != oldValue { needsDisplay = true; setAccessibilityValue(format(value)) } } }
    var defaultValue: Double = 0
    var steps: Int32 = 0
    var bipolar = false
    var tint: NSColor = Theme.accent { didSet { if tint != oldValue { needsDisplay = true } } }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    /// How lit its lights are (0 … 1): fades with bypass (DeviceView drives it).
    var light: CGFloat = 1 { didSet { if light != oldValue { needsDisplay = true } } }
    /// Printed legends for the scale ends (and, for short selectors, every position).
    var legends: [String] = [] { didSet { if legends != oldValue { needsDisplay = true } } }
    var format: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }
    var onChange: ((Double) -> Void)?
    private(set) var tracking = false
    private var dragStart: (y: CGFloat, value: Double)?
    private var glideTimer: Timer?

    static let size = NSSize(width: 64, height: 70)

    init(name: String, steps: Int32) {
        self.name = name
        self.steps = steps
        kind = steps == 1 ? .toggle : (steps >= 2 && steps <= 11) ? .selector : .knob
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(kind == .toggle ? .checkBox : .slider)
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    private func quantized(_ v: Double) -> Double {
        let v = max(0, min(1, v))
        return steps > 0 ? (v * Double(steps)).rounded() / Double(steps) : v
    }
    func set(_ v: Double) {
        let q = quantized(v)
        guard q != value else { return }
        glideTimer?.invalidate()
        value = q
        onChange?(q)
    }
    /// Changes made elsewhere: continuous knobs turn smoothly, switches and selectors jump.
    func glide(to target: Double) {
        glideTimer?.invalidate()
        guard kind == .knob, !Motion.reduced else { value = target; return }
        glide = (value, target, CACurrentMediaTime())
        glideTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.glideStep() }
        }
    }
    private var glide: (from: Double, to: Double, began: CFTimeInterval)?
    private func glideStep() {
        guard let g = glide else { glideTimer?.invalidate(); return }
        let p = min(1, (CACurrentMediaTime() - g.began) / 0.18)
        value = g.from + (g.to - g.from) * (1 - pow(1 - p, 3))
        if p >= 1 { glideTimer?.invalidate(); glide = nil }
    }

    // Input
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { set(defaultValue); return }
        if kind == .toggle { set(value >= 0.5 ? 0 : 1); return }
        tracking = true
        dragStart = (convert(event.locationInWindow, from: nil).y, value)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = dragStart else { return }
        let fine = event.modifierFlags.contains(.shift) ? 0.2 : 1.0
        set(s.value + Double(s.y - convert(event.locationInWindow, from: nil).y) / 150 * fine)
    }
    override func mouseUp(with event: NSEvent) {
        if kind == .selector, dragStart.map({ abs($0.value - value) < 1e-9 }) == true, steps > 0 {
            set(value >= 1 - 1e-9 ? 0 : value + 1 / Double(steps)) // a click steps the selector round
        }
        tracking = false
        dragStart = nil
    }
    override func scrollWheel(with event: NSEvent) {
        let d = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 300 : event.scrollingDeltaY / 30)
        guard d != 0 else { return super.scrollWheel(with: event) }
        set(value + (steps > 0 ? (d > 0 ? 1 : -1) / Double(steps) : d))
    }
    private var stepSize: Double { steps > 0 ? 1 / Double(steps) : 0.02 }
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .upArrow?, .rightArrow?: set(value + stepSize)
        case .downArrow?, .leftArrow?: set(value - stepSize)
        default: if !forwardShortcut(event) { super.keyDown(with: event) }
        }
    }
    override func accessibilityPerformIncrement() -> Bool { set(value + stepSize); return true }
    override func accessibilityPerformDecrement() -> Bool { set(value - stepSize); return true }
    override func accessibilityPerformPress() -> Bool { if kind == .toggle { set(value >= 0.5 ? 0 : 1) }; return true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    /// The name's font: 9.5 pt, shrinking to 7.5 pt before the name is truncated.
    static func nameFont(_ name: String, width: CGFloat) -> NSFont {
        for size in stride(from: 9.5, through: 7.5, by: -0.5) {
            let f = Theme.ui(CGFloat(size), .medium)
            if (name as NSString).size(withAttributes: [.font: f]).width <= width - 2 { return f }
        }
        return Theme.ui(7.5, .medium)
    }

    // Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Bypassed: the metal stays as it is; only the lights go out (LED ring, switch lamp, readout).
        let w = bounds.width
        Faceplate.engrave(name, in: CGRect(x: 0, y: 0, width: w, height: 12), font: Self.nameFont(name, width: w))
        let c = CGPoint(x: w / 2, y: 34)
        let legendFont = Theme.mono(7.5)
        switch kind {
        case .toggle:
            Faceplate.pushSwitch(ctx, CGRect(x: c.x - 13, y: c.y - 9, width: 26, height: 19), on: value >= 0.5, color: tint, lit: light)
        case .knob, .selector where Theme.look.devices == .cards || Theme.look.devices == .schematic:
            // Glass bead (Prism) or drawn dial (Atelier); the kits draw upright, so un-flip around the knob.
            let r: CGFloat = kind == .knob ? 14 : 12
            ctx.saveGState(); ctx.translateBy(x: 0, y: 2 * c.y); ctx.scaleBy(x: 1, y: -1)
            let v = CGFloat(value), origin: CGFloat = bipolar ? 0.5 : 0
            if Theme.look.devices == .cards { Prism.knob(ctx, center: c, radius: r, value: v, from: origin, color: dimmed ? Theme.textFaint : tint, active: tracking) }
            else { Atelier.knob(ctx, center: c, radius: r, value: v, from: origin, color: dimmed ? Theme.textFaint : tint, active: tracking) }
            ctx.restoreGState()
            if legends.count >= 2 {
                let y = c.y + 11, gap: CGFloat = 12
                Faceplate.engrave(legends[0], in: CGRect(x: 0, y: y, width: c.x - gap, height: 10), font: legendFont, color: Faceplate.legend, align: .right)
                Faceplate.engrave(legends[legends.count - 1], in: CGRect(x: c.x + gap, y: y, width: w - c.x - gap, height: 10), font: legendFont, color: Faceplate.legend, align: .left)
            }
        case .knob, .selector:
            let r: CGFloat = kind == .knob ? 12.5 : 10.5
            Faceplate.scale(ctx, center: c, radius: r, ticks: kind == .selector ? Int(steps) + 1 : 11, value: value,
                            bipolar: bipolar, color: NSColor(white: 0.22, alpha: 1).blended(withFraction: light, of: tint) ?? tint)
            Faceplate.knob(ctx, center: c, radius: r, angle: Faceplate.angle(value))
            if legends.count >= 2 {
                // Printed at the ends of the scale, inside this control's own width.
                let y = c.y + 10.5, gap: CGFloat = 12
                Faceplate.engrave(legends[0], in: CGRect(x: 0, y: y, width: c.x - gap, height: 10), font: legendFont,
                                  color: Faceplate.legend, align: .right)
                Faceplate.engrave(legends[legends.count - 1], in: CGRect(x: c.x + gap, y: y, width: w - c.x - gap, height: 10),
                                  font: legendFont, color: Faceplate.legend, align: .left)
            }
        }
        // Readouts fade with the lights, or (by default) switch off at once like a vacuum-fluorescent display.
        let readout: CGFloat = Faceplate.readoutsFade ? light : (dimmed ? 0 : 1)
        Faceplate.readoutWindow(ctx, CGRect(x: 6, y: bounds.height - 14, width: w - 12, height: 13), text: readout > 0.01 ? format(value) : "", glow: readout)
        if window?.firstResponder === self {
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: c.x - 22, y: c.y - 22, width: 44, height: 44))
        }
    }
}

// MARK: Sections and meters

/// An engraved section of controls: its title across the top and a groove on its trailing edge.
@MainActor
final class FaceplateSection: NSView {
    let title: String
    var groove = true
    init(title: String, controls: [FaceplateControl], rows: Int) {
        self.title = title
        super.init(frame: .zero)
        let grid = NSGridView()
        grid.rowSpacing = 2
        grid.columnSpacing = 2
        let columns = max(1, Int((Double(controls.count) / Double(rows)).rounded(.up)))
        for row in stride(from: 0, to: controls.count, by: columns) {
            var cells: [NSView] = Array(controls[row..<min(row + columns, controls.count)])
            while cells.count < columns { cells.append(NSGridCell.emptyContentView) }
            grid.addRow(with: cells)
        }
        for c in controls {
            c.widthAnchor.constraint(equalToConstant: FaceplateControl.size.width).isActive = true
            c.heightAnchor.constraint(equalToConstant: FaceplateControl.size.height).isActive = true
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if !title.isEmpty {
            Faceplate.engrave(title.uppercased(), in: CGRect(x: 2, y: 0, width: bounds.width - 8, height: 11),
                              font: Theme.ui(8, .bold), color: Faceplate.legend)
        }
        guard groove else { return }
        let x = bounds.maxX - 1.5
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: x, y: 4)); ctx.addLine(to: CGPoint(x: x, y: bounds.height - 4)); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.move(to: CGPoint(x: x + 1, y: 4)); ctx.addLine(to: CGPoint(x: x + 1, y: bounds.height - 4)); ctx.strokePath()
    }
}

/// A unit's input or output meter: a recessed slot of LEDs (left and right), a peak-hold LED, and a printed dB scale.
@MainActor
final class FaceplateMeter: NSView {
    let caption: String
    /// Bypassed unit: every LED dark.
    var poweredOff = false { didSet { if poweredOff != oldValue { needsDisplay = true } } }
    /// How lit the LEDs are (0 … 1): fades with bypass.
    var light: CGFloat = 1 { didSet { if light != oldValue { needsDisplay = true } } }
    private var levelDb: (Float, Float) = (-120, -120)
    private var hold: (Float, Float) = (-120, -120)
    private var holdAt: (Double, Double) = (0, 0)
    private var last = CACurrentMediaTime()
    static let floorDb: Float = -48, segments = 16
    static let width: CGFloat = 24

    init(caption: String) {
        self.caption = caption
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(caption == "IN" ? "Input level" : "Output level")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// Linear peaks since the last frame. Instant attack, 24 dB/s fall, peak hold (Settings ▸ Plug-ins, 1.5 s by default).
    func push(_ l: Float, _ r: Float) {
        let now = CACurrentMediaTime(), dt = Float(now - last)
        last = now
        func db(_ x: Float) -> Float { x > 0 ? 20 * log10(x) : -120 }
        let next = (max(db(l), levelDb.0 - 24 * dt), max(db(r), levelDb.1 - 24 * dt))
        let holdFor = Faceplate.peakHold
        if next.0 >= hold.0 || now - holdAt.0 > holdFor { hold.0 = next.0; holdAt.0 = now }
        if next.1 >= hold.1 || now - holdAt.1 > holdFor { hold.1 = next.1; holdAt.1 = now }
        if Int(next.0 * 4) != Int(levelDb.0 * 4) || Int(next.1 * 4) != Int(levelDb.1 * 4) { needsDisplay = true }
        levelDb = next
        setAccessibilityValue(String(format: "%.0f dB", max(levelDb.0, levelDb.1)))
    }
    var level: (Float, Float) { levelDb }

    /// The printed dB scale beside a light-pipe or drawn meter (same law as the meter: linear in dB).
    private func drawScale(_ ctx: CGContext, slot: CGRect, scaleOnRight: Bool) {
        let font = Theme.mono(5.8)
        for db: Float in [0, -6, -12, -24, -48] {
            let y = slot.minY + slot.height * CGFloat(db / Self.floorDb) - 3.5
            let rect = scaleOnRight ? CGRect(x: slot.maxX + 1.5, y: y, width: bounds.width - slot.maxX - 1, height: 8)
                                    : CGRect(x: 0, y: y, width: slot.minX - 1.5, height: 8)
            Faceplate.engrave(String(format: "%.0f", abs(db)), in: rect, font: font, color: Faceplate.legend, align: scaleOnRight ? .left : .right)
        }
        Faceplate.engrave(caption, in: CGRect(x: slot.minX - 6, y: bounds.height - 10, width: slot.width + 12, height: 10),
                          font: Theme.ui(6.5, .heavy), color: Faceplate.legend)
    }

    private func segments(_ db: Float) -> Int { Int(((db - Self.floorDb) / -Self.floorDb * Float(Self.segments)).rounded(.down)) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scaleOnRight = caption == "IN" // the printed scale faces the controls
        let slotW: CGFloat = 12
        let slot = CGRect(x: scaleOnRight ? 0 : bounds.width - slotW, y: 0, width: slotW, height: bounds.height - 12)
        if Theme.look.devices == .cards || Theme.look.devices == .schematic {
            // Two light pipes (Prism) or drawn columns (Atelier); the kits fill upward, so un-flip around the slot.
            ctx.saveGState(); ctx.translateBy(x: 0, y: slot.minY + slot.maxY); ctx.scaleBy(x: 1, y: -1)
            for (ch, (db, held)) in [(levelDb.0, hold.0), (levelDb.1, hold.1)].enumerated() {
                let r = CGRect(x: slot.minX + 1 + CGFloat(ch) * 5.5, y: slot.minY, width: 4.5, height: slot.height)
                let f = { (d: Float) in CGFloat(max(0, min(1, (d - Self.floorDb) / -Self.floorDb))) }
                let lv = poweredOff ? 0 : f(db) * light, pk = poweredOff ? 0 : f(held)
                if Theme.look.devices == .cards { Prism.lightPipe(ctx, r, level: lv, peak: pk, clipped: held >= -0.1, well: false) }
                else { Atelier.meter(ctx, r, level: lv, peak: pk, clipped: held >= -0.1) }
            }
            ctx.restoreGState()
            if Theme.look.devices == .cards { // the top of the scale: a short hairline across both channels
                let top = CGRect(x: slot.minX, y: slot.minY, width: 11, height: 1)
                ctx.setFillColor((Theme.isLight ? Theme.text.withAlphaComponent(0.45) : NSColor.white.withAlphaComponent(0.55)).cgColor); ctx.fill(top)
            }
            drawScale(ctx, slot: slot, scaleOnRight: scaleOnRight)
            return
        }
        // Recessed slot: dark well, shadowed top, light lip at the bottom edge.
        let well = CGPath(roundedRect: slot, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(well); ctx.setFillColor(NSColor(white: 0.035, alpha: 1).cgColor); ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(well); ctx.clip()
        let inner = [NSColor.black.withAlphaComponent(0.8).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: inner, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: slot.minY), end: CGPoint(x: 0, y: slot.minY + 5), options: [])
        }
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: slot.minX + 1.5, y: slot.maxY + 0.4)); ctx.addLine(to: CGPoint(x: slot.maxX - 1.5, y: slot.maxY + 0.4)); ctx.strokePath()
        // LEDs.
        let n = Self.segments, gap: CGFloat = 1.3, pad: CGFloat = 1.8
        let ledH = (slot.height - 2 * pad - gap * CGFloat(n - 1)) / CGFloat(n)
        let ledW = (slot.width - 2 * pad - gap) / 2
        func ledY(_ i: Int) -> CGFloat { slot.maxY - pad - CGFloat(i + 1) * ledH - CGFloat(i) * gap }
        for (ch, (db, held)) in [(levelDb.0, hold.0), (levelDb.1, hold.1)].enumerated() {
            let lit = segments(db), peak = segments(held) - 1
            for i in 0..<n {
                let segDb = Self.floorDb * (1 - Float(i + 1) / Float(n))
                let color: NSColor = segDb >= -1.5 ? NSColor(srgbRed: 1.0, green: 0.27, blue: 0.20, alpha: 1)
                    : segDb >= -9 ? NSColor(srgbRed: 1.0, green: 0.72, blue: 0.22, alpha: 1) : NSColor(srgbRed: 0.42, green: 0.95, blue: 0.48, alpha: 1)
                let led = CGRect(x: slot.minX + pad + CGFloat(ch) * (ledW + gap), y: ledY(i), width: ledW, height: ledH)
                let on = light > 0.01 && (i < lit || i == peak && peak >= lit)
                let lens = CGPath(roundedRect: led, cornerWidth: 0.9, cornerHeight: 0.9, transform: nil)
                ctx.addPath(lens); ctx.setFillColor((color.blended(withFraction: 0.84, of: .black) ?? color).cgColor); ctx.fillPath()
                if on {
                    ctx.saveGState()
                    ctx.setAlpha(light)
                    ctx.setShadow(offset: .zero, blur: 3.5, color: color.withAlphaComponent(0.85).cgColor)
                    ctx.addPath(lens); ctx.setFillColor(color.cgColor); ctx.fillPath()
                    ctx.restoreGState()
                }
                // Domed lens: a highlight across the top of each LED.
                ctx.saveGState()
                ctx.addPath(lens); ctx.clip()
                let shine = [NSColor.white.withAlphaComponent(on ? 0.55 : 0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: shine, locations: [0, 1]) {
                    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: led.minY), end: CGPoint(x: 0, y: led.midY + 0.5), options: [])
                }
                ctx.restoreGState()
            }
        }
        // Printed scale beside the slot.
        let font = Theme.mono(5.8)
        for db: Float in [0, -6, -12, -24, -48] {
            let i = Int((db - Self.floorDb) / -Self.floorDb * Float(n)) - 1
            let y = i < 0 ? slot.maxY - pad - 3 : ledY(i) + ledH / 2 - 3.5
            let rect = scaleOnRight ? CGRect(x: slot.maxX + 1.5, y: y, width: bounds.width - slot.maxX - 1, height: 8)
                                    : CGRect(x: 0, y: y, width: slot.minX - 1.5, height: 8)
            Faceplate.engrave(String(format: "%.0f", abs(db)), in: rect, font: font, color: Faceplate.legend, align: scaleOnRight ? .left : .right)
        }
        Faceplate.engrave(caption, in: CGRect(x: slot.minX - 6, y: bounds.height - 10, width: slot.width + 12, height: 10),
                          font: Theme.ui(6.5, .heavy), color: Faceplate.legend)
    }
}

// MARK: Etched lettering and hardware keys

extension Faceplate {
    /// Outlines of `text` in `font` (y up, baseline at 0) and its typographic width.
    static func glyphs(_ text: String, font: NSFont, kern: CGFloat = 0) -> (path: CGPath, width: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .kern: kern]))
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let value = attrs[kCTFontAttributeName as String] else { continue }
            let runFont = value as! CTFont // swiftlint:disable:this force_cast
            let count = CTRunGetGlyphCount(run)
            var g = [CGGlyph](repeating: 0, count: count), pos = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &g)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &pos)
            for i in 0..<count {
                if let outline = CTFontCreatePathForGlyph(runFont, g[i], nil) {
                    path.addPath(outline, transform: CGAffineTransform(translationX: pos[i].x, y: pos[i].y))
                }
            }
        }
        return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// Lettering laser-etched into anodized metal: a frosted, slightly rough fill, a shadow inside the top edge of the
    /// cut and a faint light lip below it. Draws in a y-up context with the baseline at `origin`.
    static func etch(_ ctx: CGContext, _ text: String, font: NSFont, at origin: CGPoint, tone: CGFloat = 0.80, kern: CGFloat = 0) {
        var t = CGAffineTransform(translationX: origin.x, y: origin.y)
        guard let path = glyphs(text, font: font, kern: kern).path.copy(using: &t) else { return }
        let box = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -0.75)
        ctx.addPath(path); ctx.setFillColor(NSColor.white.withAlphaComponent(0.09).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let frost = [NSColor(white: tone * 0.90, alpha: 1).cgColor, NSColor(white: tone, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: frost, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: box.maxY), end: CGPoint(x: 0, y: box.minY), options: [])
        }
        // Laser grain: fine speckle, seeded so it doesn't shimmer between redraws.
        var seed: UInt64 = 0xD1B54A32D192ED03 &+ UInt64(text.utf8.count)
        var y = box.minY
        while y < box.maxY {
            var x = box.minX
            while x < box.maxX {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                if (seed >> 61) == 0 {
                    ctx.setFillColor(NSColor(white: (seed >> 40) & 1 == 0 ? 0 : 1, alpha: 0.06).cgColor)
                    ctx.fill(CGRect(x: x, y: y, width: 0.5, height: 0.5))
                }
                x += 0.5
            }
            y += 0.5
        }
        ctx.translateBy(x: 0, y: -0.55)
        ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.32).cgColor); ctx.setLineWidth(0.7); ctx.strokePath()
        ctx.restoreGState()
    }
}

/// A unit's name, laser-etched into the faceplate.
@MainActor
final class EtchedLabel: NSView {
    var text: String { didSet { guard text != oldValue else { return }; invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(text) } }
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    /// Atelier: the plate number before the name ("02 · "), lettered in gold italic.
    var prefix = "01 · " { didSet { if prefix != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    let font = NSFont.systemFont(ofSize: 12.5, weight: .bold)
    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        if Theme.look.devices == .schematic {
            let w = (prefix as NSString).size(withAttributes: [.font: Theme.note(12)]).width + (text as NSString).size(withAttributes: [.font: Theme.title(12.5, .semibold)]).width
            return NSSize(width: ceil(w) + 4, height: 17)
        }
        return NSSize(width: ceil(Faceplate.glyphs(text, font: font, kern: 0.3).width) + 2, height: 17)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clip(to: bounds)
        if Theme.look.devices == .schematic { // the plate's number in gold italic, then its name in the serif
            let num = Theme.note(12), f = Theme.title(12.5, .semibold)
            let w = (prefix as NSString).size(withAttributes: [.font: num]).width
            (prefix as NSString).draw(at: CGPoint(x: 1, y: (bounds.height - num.ascender + num.descender) / 2 - 1),
                                      withAttributes: [.font: num, .foregroundColor: dimmed ? Theme.textFaint : Atelier.gold])
            (text as NSString).draw(at: CGPoint(x: 1 + w, y: (bounds.height - f.ascender + f.descender) / 2 - 1),
                                    withAttributes: [.font: f, .foregroundColor: dimmed ? Theme.textFaint : Theme.text])
            return
        }
        if Theme.look.devices == .cards { // printed: the theme's title face, light
            let f = Theme.ui(12.5, .semibold)
            (text as NSString).draw(at: CGPoint(x: 1, y: (bounds.height - f.ascender + f.descender) / 2 - 1),
                                    withAttributes: [.font: f, .foregroundColor: dimmed ? Theme.textFaint : Theme.text])
            return
        }
        Faceplate.etch(ctx, text, font: font, at: CGPoint(x: 1, y: 4), tone: dimmed ? 0.50 : 0.92, kern: 0.3)
    }
}

/// A small machined key on the faceplate with an etched label, or (power) a round key with a lit ring.
/// Outside Graphite it draws as a plain button.
@MainActor
final class PlateButton: NSButton {
    enum Style { case system, key, power, powerIcon }
    var style: Style = .system { didSet { if style != .system { isBordered = false; title = "" }; invalidateIntrinsicContentSize(); needsDisplay = true } }
    var label = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var lit: NSColor = Theme.accent
    private let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .heavy)

    init(title: String, label: String) {
        self.label = label
        super.init(frame: .zero)
        self.title = title
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        switch style {
        case .system: super.intrinsicContentSize
        case .key: NSSize(width: ceil(Faceplate.glyphs(label, font: labelFont, kern: 0.9).width) + 18, height: 17)
        case .power: NSSize(width: 20, height: 20)
        case .powerIcon: NSSize(width: 24, height: 24) // the glowing symbol is 12 pt; the whole square takes the press
        }
    }
    /// Hardware keys take a press anywhere on them and act on release, even if the pointer drifted off a little or the
    /// unit is drawn shrunk (bypassed): AppKit's own button tracking doesn't know about the unit's scale.
    override func mouseDown(with event: NSEvent) {
        guard style != .system, isEnabled else { return super.mouseDown(with: event) }
        isHighlighted = true
        let start = event.locationInWindow
        var inside = true
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) < 24
            isHighlighted = inside
            if e.type == .leftMouseUp { break }
        }
        isHighlighted = false
        guard inside else { return }
        if style == .power || style == .powerIcon { state = state == .on ? .off : .on }
        sendAction(action, to: target)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard style != .system, let ctx = NSGraphicsContext.current?.cgContext else { return super.draw(dirtyRect) }
        let pressed = isHighlighted
        let enabled = isEnabled
        if isFlipped { ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1) } // draw y-up
        if style == .key && (Theme.look.devices == .cards || Theme.look.devices == .schematic) {
            // A glass capsule (Prism) or a boxed label (Atelier).
            let r = bounds.insetBy(dx: 1, dy: 2)
            if Theme.look.devices == .cards {
                Prism.slab(ctx, r, radius: r.height / 2, tint: Theme.hex(0xA8B8FF), body: pressed ? 0.2 : 0.09, flipped: false)
            } else {
                ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fill(r)
                if pressed { Atelier.hatch(ctx, r, spacing: 2.5, color: Theme.ink(0.35), weight: 0.6) }
                Atelier.box(ctx, r.insetBy(dx: 1, dy: 1), weight: Atelier.fine, color: Theme.ink(enabled ? 0.8 : 0.3), overshoot: 2)
            }
            let f = Theme.mono(8, .medium), text = label as NSString
            let size = text.size(withAttributes: [.font: f])
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2 + 0.5), withAttributes: [.font: f, .foregroundColor: enabled ? Theme.text : Theme.textFaint])
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if style == .powerIcon {
            // Just the symbol: glowing in the unit's colour when on, a dim etched mark when bypassed.
            let c = CGPoint(x: bounds.midX, y: bounds.midY), on = state == .on && enabled
            ctx.saveGState()
            if on { ctx.setShadow(offset: .zero, blur: 5, color: lit.withAlphaComponent(0.95).cgColor) }
            ctx.setStrokeColor((on ? lit : NSColor(white: 0.42, alpha: 1)).cgColor)
            ctx.setLineWidth(1.6); ctx.setLineCap(.round)
            ctx.addArc(center: CGPoint(x: c.x, y: c.y - 0.5), radius: 5, startAngle: .pi / 2 + 0.7, endAngle: .pi / 2 - 0.7, clockwise: false)
            ctx.strokePath()
            ctx.move(to: CGPoint(x: c.x, y: c.y - 0.5)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 5.6)); ctx.strokePath()
            ctx.restoreGState()
            return
        }
        if style == .power {
            let c = CGPoint(x: bounds.midX, y: bounds.midY), r: CGFloat = 8.5
            let on = state == .on && enabled
            // LED ring around the key.
            ctx.saveGState()
            if on { ctx.setShadow(offset: .zero, blur: 4, color: lit.withAlphaComponent(0.9).cgColor) }
            ctx.setStrokeColor((on ? lit : NSColor(white: 0.12, alpha: 1)).cgColor); ctx.setLineWidth(1.6)
            ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.restoreGState()
            key(ctx, CGPath(ellipseIn: CGRect(x: c.x - r + 2, y: c.y - r + 2, width: 2 * r - 4, height: 2 * r - 4), transform: nil),
                CGRect(x: c.x - r + 2, y: c.y - r + 2, width: 2 * r - 4, height: 2 * r - 4), pressed: pressed)
            // Power glyph, etched.
            ctx.setStrokeColor(NSColor(white: enabled ? 0.78 : 0.4, alpha: 1).cgColor); ctx.setLineWidth(1.1); ctx.setLineCap(.round)
            ctx.addArc(center: CGPoint(x: c.x, y: c.y - 0.4), radius: 3.1, startAngle: .pi / 2 + 0.7, endAngle: .pi / 2 - 0.7, clockwise: false)
            ctx.strokePath()
            ctx.move(to: CGPoint(x: c.x, y: c.y - 0.2)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 3.9)); ctx.strokePath()
            ctx.setLineCap(.butt)
            return
        }
        let rect = bounds.insetBy(dx: 1, dy: 1.5)
        key(ctx, CGPath(roundedRect: rect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil), rect, pressed: pressed)
        let w = Faceplate.glyphs(label, font: labelFont, kern: 0.9).width
        Faceplate.etch(ctx, label, font: labelFont, at: CGPoint(x: rect.midX - w / 2, y: rect.midY - 2.6 - (pressed ? 0.4 : 0)),
                       tone: enabled ? 0.90 : 0.45, kern: 0.9)
    }
    /// A raised metal key: drop shadow, brushed gradient, light top edge; pressed keys sit lower and darker.
    private func key(_ ctx: CGContext, _ path: CGPath, _ rect: CGRect, pressed: Bool) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: pressed ? -0.5 : -1.2), blur: pressed ? 1 : 2.2, color: NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.addPath(path); ctx.setFillColor(NSColor(white: 0.15, alpha: 1).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let top = rect.maxY, bottom = rect.minY
        let colors = [NSColor(white: pressed ? 0.24 : 0.36, alpha: 1).cgColor, NSColor(white: pressed ? 0.17 : 0.23, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
        }
        ctx.restoreGState()
        ctx.addPath(path); ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(0.8); ctx.strokePath()
        if !pressed {
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: rect.minX, y: top - 0.8)); ctx.addLine(to: CGPoint(x: rect.maxX, y: top - 0.8))
            ctx.strokePath(); ctx.restoreGState()
        }
    }
}

/// A 5 × 7 dot-matrix character set (upper case, digits and the symbols parameter values use) and its renderer.
@MainActor
enum DotMatrix {
    /// Rows top to bottom; bit 4 is the leftmost dot.
    static let glyphs: [Character: [UInt8]] = [
        "0": [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
        "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        "2": [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
        "3": [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110],
        "4": [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
        "5": [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
        "6": [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
        "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
        "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
        "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
        "A": [0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        "B": [0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110],
        "C": [0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110],
        "D": [0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100],
        "E": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111],
        "F": [0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000],
        "G": [0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111],
        "H": [0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001],
        "I": [0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        "J": [0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100],
        "K": [0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001],
        "L": [0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111],
        "M": [0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001],
        "N": [0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001],
        "O": [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        "P": [0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000],
        "Q": [0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101],
        "R": [0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001],
        "S": [0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110],
        "T": [0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100],
        "U": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
        "V": [0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100],
        "W": [0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010],
        "X": [0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001],
        "Y": [0b10001, 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100],
        "Z": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111],
        " ": [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000],
        ".": [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100],
        "-": [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000],
        "+": [0b00000, 0b00100, 0b00100, 0b11111, 0b00100, 0b00100, 0b00000],
        "%": [0b11000, 0b11001, 0b00010, 0b00100, 0b01000, 0b10011, 0b00011],
        "/": [0b00000, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b00000],
        ":": [0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000],
        "(": [0b00010, 0b00100, 0b01000, 0b01000, 0b01000, 0b00100, 0b00010],
        ")": [0b01000, 0b00100, 0b00010, 0b00010, 0b00010, 0b00100, 0b01000],
        "°": [0b01100, 0b10010, 0b10010, 0b01100, 0b00000, 0b00000, 0b00000],
        ",": [0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b00100, 0b01000],
        "=": [0b00000, 0b00000, 0b11111, 0b00000, 0b11111, 0b00000, 0b00000],
        "?": [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100],
        "#": [0b01010, 0b01010, 0b11111, 0b01010, 0b11111, 0b01010, 0b01010],
        "…": [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b10101]
    ]

    /// The glyph for a character: lower case as upper case, unknown characters as "?".
    static func glyph(_ c: Character) -> [UInt8] {
        if let g = glyphs[c] { return g }
        let mapped: Character = c == "\u{2212}" ? "-" : c == "\u{00B5}" ? "U" : Character(String(c).uppercased())
        return glyphs[mapped] ?? glyphs["?"]!
    }

    /// Draws `text` across a row of character cells filling `rect` (flipped context), centred; the dot pitch shrinks for
    /// long values and very long ones end in "…". Every cell shows its unlit dots.
    static func draw(_ ctx: CGContext, _ text: String, in rect: CGRect, color: NSColor) {
        var chars = Array(text)
        var pitch = min(1.15, rect.height / 7)
        var cells = max(1, Int((rect.width + pitch) / (6 * pitch)))
        if chars.count > cells {
            pitch = max(0.72, rect.width / CGFloat(chars.count * 6 - 1))
            cells = max(1, Int((rect.width + pitch) / (6 * pitch) + 0.001))
            if chars.count > cells { chars = Array(chars.prefix(cells - 1)) + ["…"] }
        }
        let dot = pitch * 0.8
        let used = CGFloat(cells * 6 - 1) * pitch
        let x0 = rect.midX - used / 2, y0 = rect.midY - 3.5 * pitch
        let first = (cells - chars.count) / 2
        let ghost = color.withAlphaComponent(0.07).cgColor
        let lit = CGMutablePath(), off = CGMutablePath()
        for cell in 0..<cells {
            let i = cell - first
            let g = i >= 0 && i < chars.count ? glyph(chars[i]) : glyphs[" "]!
            for (r, bits) in g.enumerated() {
                for col in 0..<5 {
                    let d = CGRect(x: x0 + CGFloat(cell * 6 + col) * pitch, y: y0 + CGFloat(r) * pitch, width: dot, height: dot)
                    if bits & (0b10000 >> UInt8(col)) != 0 { lit.addEllipse(in: d) } else { off.addEllipse(in: d) }
                }
            }
        }
        ctx.addPath(off); ctx.setFillColor(ghost); ctx.fillPath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 2.2, color: color.withAlphaComponent(0.85 * color.alphaComponent).cgColor)
        ctx.addPath(lit); ctx.setFillColor(color.cgColor); ctx.fillPath()
        ctx.restoreGState()
    }
}
