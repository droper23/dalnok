// Atelier's plug-in figures as instruments (the owner, fourth round: "the drawing is the control"). Each family is one
// engraved figure whose lettered parts are dragged: a flyball governor for dynamics, a vaulted chamber for reverbs, a
// pendulum for delays, a sine through its clipping curve for distortion, a crank and disc for modulation. The letters
// are the key's letters for the same parameters. Figures are drawn from the plug-in's parameters and live data, and move
// (owner, 2026-11-22: the governor spins, the pendulum swings, the crank turns), holding still under the pointer, under
// Reduce Motion and in stills. Data first: labels sit on clean plate.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import QuartzCore

/// What a figure part controls; found among a plug-in's parameters by name.
enum FigureRole: String, CaseIterable {
    case threshold, ratio, size, decay, time, feedback, drive, rate, depth

    var keys: [String] {
        switch self {
        case .threshold: ["threshold", "thresh"]
        case .ratio: ["ratio"]
        case .size: ["room size", "size", "room"]
        case .decay: ["decay", "rt60", "reverb time", "length"]
        case .time: ["delay time", "time", "delay"]
        case .feedback: ["feedback", "regen"]
        case .drive: ["drive", "pre-gain", "pregain", "distortion", "saturation", "amount", "gain"]
        case .rate: ["rate", "speed"]
        case .depth: ["depth", "intensity", "amount"]
        }
    }
    /// Finds each role's parameter (first title containing a key, most specific key first); one parameter per role.
    static func match(_ params: [(id: UInt32, title: String)], roles: [FigureRole]) -> [FigureRole: UInt32] {
        var used = Set<UInt32>(), out: [FigureRole: UInt32] = [:]
        for role in roles {
            for key in role.keys {
                if let p = params.first(where: { !used.contains($0.id) && $0.title.lowercased().contains(key) }) {
                    out[role] = p.id; used.insert(p.id); break
                }
            }
        }
        return out
    }
}

/// The bridge from a figure to its unit's parameters (DeviceView fills it).
struct FigureLink {
    var ids: [FigureRole: UInt32] = [:]
    var value: (UInt32) -> Double? = { _ in nil }
    var text: (UInt32) -> String? = { _ in nil }
    var letter: (UInt32) -> String? = { _ in nil }
    var set: (UInt32, Double) -> Void = { _, _ in }
    var begin: () -> Void = {}
    var end: () -> Void = {}
    /// Margin facts (latency, sidechain…), set by the unit.
    var notes: () -> [String] = { [] }
    /// The parameter's name, for the part's tag.
    var name: (UInt32) -> String? = { _ in nil }

    /// The part's value, 0…1 (never NaN or out of range: figures count and loop with it).
    func v(_ r: FigureRole, _ fallback: Double = 0.5) -> Double {
        let x = ids[r].flatMap(value) ?? fallback
        return x.isFinite ? max(0, min(1, x)) : fallback
    }
    func t(_ r: FigureRole) -> String? { ids[r].flatMap(text) }
    func l(_ r: FigureRole) -> String? { ids[r].flatMap(letter) }
}

/// A draggable part: where it is, which way dragging moves its value, and over how many points the whole range runs.
struct FigureHandle {
    let role: FigureRole
    let point: CGPoint
    let axis: CGVector
    let span: CGFloat
}

/// The new figures and which display draws which.
enum AtelierFigure {
    case governor, chamber, pendulum, clipping, crank

    static func of(kind: FaceplateDisplay.Kind, subject: Codex.Subject) -> AtelierFigure? {
        switch (kind, subject) {
        case (.gainReduction, _): .governor
        case (_, .chamber): .chamber
        case (_, .echo): .pendulum
        case (.transfer, _): .clipping
        case (_, .modulation): .crank
        default: nil
        }
    }
    var roles: [FigureRole] {
        switch self {
        case .governor: [.threshold, .ratio]
        case .chamber: [.size, .decay]
        case .pendulum: [.time, .feedback]
        case .clipping: [.drive]
        case .crank: [.rate, .depth]
        }
    }
    var title: String {
        switch self {
        case .governor: "The Seismograph"
        case .chamber: "Acoustic Chamber"
        case .pendulum: "Pendulum of Echoes"
        case .clipping: "Construction of the Clipped Wave"
        case .crank: "Crank and Disc"
        }
    }
}

/// Drives the figures' motion (the owner: "the crank should actually rotate, the governor should spin, the pendulum
/// should swing"). One 30 Hz timer for every figure on screen; a figure holds still while the pointer is on one of its
/// parts or drags it, under Reduce Motion, in stills and tests (Motion off), and while its window is hidden.
protocol FigureAnimating: NSView {
    func advanceFigure(_ dt: Double)
}
extension FaceplateScreen: FigureAnimating {}

@MainActor
final class FigureClock {
    static let shared = FigureClock()
    private let screens = NSHashTable<NSView>.weakObjects()
    private var timer: Timer?
    private var last = CACurrentMediaTime()
    func add(_ s: some FigureAnimating) {
        screens.add(s)
        guard timer == nil else { return }
        last = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in MainActor.assumeIsolated { FigureClock.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    func remove(_ s: some FigureAnimating) {
        screens.remove(s)
        if screens.allObjects.isEmpty { timer?.invalidate(); timer = nil }
    }
    private func tick() {
        let now = CACurrentMediaTime(), dt = min(0.1, now - last)
        last = now
        // Held while Dalnok is in the background or under Reduce Motion; a figure moves only while some of it shows
        // (scrolled out of the device panel, hidden, or in a minimised or covered window it costs nothing).
        guard !Motion.reduced, NSApp.isActive else { return }
        for case let s as FigureAnimating in screens.allObjects {
            guard let w = s.window, w.isVisible, !w.isMiniaturized, w.occlusionState.contains(.visible),
                  !s.isHiddenOrHasHiddenAncestor, !s.visibleRect.isEmpty else { continue }
            s.advanceFigure(dt)
        }
    }
}

extension FaceplateScreen {
    /// One step of the figure's motion; its speed comes from its parameters and live data.
    func advanceFigure(_ dt: Double) {
        guard let fig = atelierFigure, figureDrag == nil, hoverRole == nil else { return }
        let link = figureLink ?? FigureLink()
        let speed: Double = switch fig {
        case .governor: 2 * .pi * (0.22 + 1.6 * min(1, abs(figureLive) / 18)) // spins up as it reduces
        case .pendulum: 2 * .pi / (0.7 + 1.8 * link.v(.time, 0.4))           // a longer delay, a longer swing
        case .clipping: 2 * .pi * 0.35
        case .crank: 2 * .pi * (0.12 + 1.1 * link.v(.rate, 0.4))              // turns at the rate
        case .chamber: 2 * .pi / (1.2 + 2.5 * link.v(.decay, 0.5))            // a longer decay, slower waves
        }
        figureAngle = (figureAngle + dt * speed).truncatingRemainder(dividingBy: 2 * .pi * 64)
        needsDisplay = true
    }

    // MARK: Drawing

    /// Draws one of the new figures in `f` (y down) and records its handles. Live values come from the screen's data.
    func drawFigure(_ fig: AtelierFigure, _ ctx: CGContext, _ f: CGRect, live: Double) {
        var handles: [FigureHandle] = []
        let link = figureLink ?? FigureLink()
        switch fig {
        case .governor: handles = seismograph(ctx, f, link, reductionDb: live)
        case .chamber: handles = chamberFigure(ctx, f, link, energyDb: live)
        case .pendulum: handles = pendulum(ctx, f, link, energyDb: live)
        case .clipping: handles = clipping(ctx, f, link)
        case .crank: handles = crank(ctx, f, link)
        }
        figureHandles = handles
        // Drag marks: a ring at every part that can be dragged, with engraved arrows along the way it moves (owner:
        // "not intuitive what to change"). The part under the pointer, being dragged, or whose key row is under the
        // pointer is lit in gold with its parameter's name and value beside it.
        for h in handles where link.ids[h.role] != nil {
            let lit = figureDrag?.role == h.role || hoverRole == h.role || highlightRole == h.role
            let ink = lit ? Atelier.gold : Theme.text
            arrows(ctx, h, color: lit ? Atelier.gold : Theme.ink(0.55))
            let r = CGRect(x: h.point.x - (lit ? 4.2 : 3.2), y: h.point.y - (lit ? 4.2 : 3.2), width: lit ? 8.4 : 6.4, height: lit ? 8.4 : 6.4)
            ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: r)
            Atelier.loop(ctx, r, weight: lit ? Atelier.medium : Atelier.fine, color: ink)
        }
        // Margin notes: live facts in the annotation hand, right-aligned at the field's foot.
        var y = f.minY
        for n in (marginNotes + link.notes()).prefix(2) {
            Atelier.note(ctx, n, at: CGPoint(x: f.maxX - 2, y: y), size: 8.5, color: Theme.textDim, align: .right)
            y += 11
        }
    }

    /// Two small engraved arrowheads either side of a part, along the direction it drags.
    private func arrows(_ ctx: CGContext, _ h: FigureHandle, color: NSColor) {
        let len = hypot(h.axis.dx, h.axis.dy)
        guard len > 0 else { return }
        let ux = h.axis.dx / len, uy = h.axis.dy / len, gap: CGFloat = 9
        for s in [CGFloat(1), -1] {
            let tip = CGPoint(x: h.point.x + s * ux * (gap + 4), y: h.point.y + s * uy * (gap + 4))
            Atelier.rule(ctx, CGPoint(x: h.point.x + s * ux * gap * 0.62, y: h.point.y + s * uy * gap * 0.62), tip, weight: Atelier.hair, color: color)
            Atelier.arrowhead(ctx, at: tip, angle: atan2(s * uy, s * ux), color: color, size: 3.6)
        }
    }

    private func letterCallout(_ ctx: CGContext, _ link: FigureLink, _ role: FigureRole, at p: CGPoint, to q: CGPoint) {
        guard let letter = link.l(role) else { return }
        Atelier.callout(ctx, letter, from: p, to: q)
    }
    /// A part's value where the figure prints it; while the part is lit (pointed at, dragged, or its key row pointed at)
    /// the value becomes a gold-ruled tag with the parameter's name, in the same place so it never covers another label.
    private func readout(_ ctx: CGContext, _ link: FigureLink, _ role: FigureRole, at p: CGPoint, align: NSTextAlignment = .left) {
        let lit = figureDrag?.role == role || hoverRole == role || highlightRole == role
        guard lit, let id = link.ids[role] else {
            if let t = link.t(role) { Atelier.note(ctx, t, at: p, size: 9.5, color: Theme.text, align: align, roman: true) }
            return
        }
        let name = link.name(id) ?? role.rawValue.capitalized
        let text = link.text(id).map { "\(name)  \($0)" } ?? name
        let w = (text as NSString).size(withAttributes: [.font: Theme.title(10, .regular)]).width + 8
        var box = CGRect(x: align == .right ? p.x - w + 4 : p.x - 4, y: p.y - 1, width: w, height: 15)
        let room = bounds.insetBy(dx: 3, dy: 3)
        box.origin.x = max(room.minX, min(room.maxX - w, box.origin.x))
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fill(box)
        Atelier.box(ctx, box, weight: Atelier.hair, color: Atelier.gold)
        Atelier.note(ctx, text, at: CGPoint(x: box.minX + 4, y: box.minY + 1), size: 10, color: Theme.text, roman: true)
    }
    private func ball(_ ctx: CGContext, _ c: CGPoint, r: CGFloat, alpha: CGFloat = 1) {
        let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: disc)
        ctx.saveGState(); ctx.setAlpha(alpha); ctx.addEllipse(in: disc); ctx.clip(); Atelier.globeShade(ctx, disc); ctx.restoreGState()
        Atelier.loop(ctx, disc, weight: Atelier.fine, color: Theme.ink(alpha))
    }
    /// A number from a parameter's printed value ("−20.00 dB" → −20, "4.00 : 1" → 4).
    private func number(_ text: String?) -> Double? {
        guard let t = text?.replacingOccurrences(of: "−", with: "-") else { return nil }
        let scanner = Scanner(string: t)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ")
        return scanner.scanDouble()
    }

    /// Fig. 2, the seismograph (owner, 2026-11-23): a paper strip runs left under two pens. The faint pen writes the
    /// input, the bold pen the output; where the signal rises past the threshold rails (A, drag up or down) the output
    /// pen is held back by the ratio, set on the inclined plane at the left (B, drag down for a flatter slope, a higher
    /// ratio), and the difference between the two traces is hatched: what the compressor took off. With sound playing
    /// the traces are the real levels and reduction; at rest they draw a sample rhythm through the current settings.
    private func seismograph(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink, reductionDb: Double) -> [FigureHandle] {
        let ink = Theme.text, faint = Theme.ink(0.42)
        // Parameters, in decibels and as a ratio when the plug-in prints them; otherwise from the normalised values.
        let thrDb = number(link.t(.threshold)) ?? (-48 + 48 * link.v(.threshold, 0.6))
        let ratio = max(1, number(link.t(.ratio)) ?? (1 + 9 * link.v(.ratio, 0.4)))
        // The plane at the left (ratio), the strip to its right.
        let plane = CGRect(x: f.minX + 4, y: f.minY + 16, width: 30, height: 30)
        // The strip starts below the margin note (which is written at the field's top, right-aligned).
        let strip = CGRect(x: plane.maxX + 26, y: f.minY + 15, width: f.maxX - plane.maxX - 40, height: f.height - 24)
        let mid = strip.midY, half = strip.height / 2 - 4
        func amp(_ db: Double) -> CGFloat { CGFloat(max(0, min(1, (db + 48) / 48))) * half } // −48…0 dBFS
        // The paper: a ruled strip with time marks scrolling with it.
        Atelier.box(ctx, strip, weight: Atelier.fine, color: Theme.ink(0.6))
        Atelier.rule(ctx, CGPoint(x: strip.minX, y: mid), CGPoint(x: strip.maxX, y: mid), weight: Atelier.hair, color: Theme.ink(0.25), dash: [1, 3])
        let scroll = CGFloat(figureAngle) * 6
        var tx = strip.maxX - scroll.truncatingRemainder(dividingBy: 24)
        while tx > strip.minX { Atelier.rule(ctx, CGPoint(x: tx, y: strip.maxY - 3), CGPoint(x: tx, y: strip.maxY), weight: Atelier.hair, color: Theme.ink(0.4)); tx -= 24 }
        // The levels: live when there is sound, else a sample rhythm (a beat and a quieter off-beat) through the settings.
        let columns = Int(strip.width / 2)
        let meter = self as? MovingCoilMeter
        let live = (meter?.traceHistory ?? []).suffix(columns)
        let hasSound = live.contains { $0.input > -60 }
        func curve(_ inDb: Double) -> Double { inDb <= thrDb ? inDb : thrDb + (inDb - thrDb) / ratio }
        var levels: [(input: Double, output: Double)] = []
        if hasSound { // eased over a few columns, so a sudden change bends the pen rather than jumping it
            var e: (Double, Double)?
            levels = live.map { lv in
                let now = (max(-60, lv.input), max(-60, lv.input - lv.reduction))
                let eased = e.map { ($0.0 + (now.0 - $0.0) * 0.35, $0.1 + (now.1 - $0.1) * 0.35) } ?? now
                e = eased
                return (eased.0, eased.1)
            }
        } else {
            for i in 0..<columns {
                let t = Double(i) * 0.022 + Double(figureAngle) * 0.25
                let beat = exp(-4 * t.truncatingRemainder(dividingBy: 1.0)), off = 0.55 * exp(-6 * (t + 0.5).truncatingRemainder(dividingBy: 1.0))
                let inDb = -36 + 34 * max(beat, off)
                levels.append((inDb, curve(inDb)))
            }
        }
        // The traces, written right to left (newest at the needle): a pen swing whose height is the level.
        let x0 = strip.maxX - CGFloat(levels.count) * 2
        func trace(_ level: (Int) -> CGFloat) -> CGMutablePath {
            let p = CGMutablePath()
            for i in levels.indices {
                let x = x0 + CGFloat(i) * 2, y = mid - sin(Double(i) * 0.42 + Double(scroll) * 0.07) * Double(level(i))
                i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
            }
            return p
        }
        ctx.saveGState(); ctx.clip(to: strip.insetBy(dx: 1, dy: 1))
        // What was taken off: hatched between the input's and the output's reach, above and below the line.
        for i in levels.indices where levels[i].input - levels[i].output > 0.3 { // between the two pens, nowhere else
            let x = x0 + CGFloat(i) * 2, swing = sin(Double(i) * 0.42 + Double(scroll) * 0.07)
            let yIn = mid - CGFloat(swing) * amp(levels[i].input), yOut = mid - CGFloat(swing) * amp(levels[i].output)
            Atelier.rule(ctx, CGPoint(x: x, y: yOut), CGPoint(x: x, y: yIn), weight: 0.9, color: Atelier.gold.withAlphaComponent(0.7))
        }
        let input = trace { amp(levels[$0].input) }, output = trace { amp(levels[$0].output) }
        ctx.saveGState(); ctx.setLineDash(phase: 0, lengths: [1.5, 1.5])
        ctx.addPath(input); ctx.setStrokeColor(Theme.ink(0.55).cgColor); ctx.setLineWidth(0.7); ctx.strokePath(); ctx.restoreGState()
        ctx.addPath(output); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(1.3); ctx.setLineJoin(.round); ctx.strokePath()
        ctx.restoreGState()
        // The threshold rails, above and below the line.
        let railY = mid - amp(thrDb), railY2 = mid + amp(thrDb)
        for y in [railY, railY2] {
            Atelier.rule(ctx, CGPoint(x: strip.minX - 4, y: y), CGPoint(x: strip.maxX + 4, y: y), weight: Atelier.medium, color: ink)
            Atelier.rule(ctx, CGPoint(x: strip.minX - 4, y: y + (y < mid ? -2 : 2)), CGPoint(x: strip.maxX + 4, y: y + (y < mid ? -2 : 2)), weight: Atelier.hair, color: Theme.ink(0.5))
        }
        // The needle at the right edge, its arm pivoted beyond the strip.
        let tipY = levels.last.map { mid - CGFloat(sin(Double(levels.count - 1) * 0.42 + Double(scroll) * 0.07)) * amp($0.output) } ?? mid
        let pivot = CGPoint(x: f.maxX - 4, y: mid)
        Atelier.rule(ctx, pivot, CGPoint(x: strip.maxX, y: tipY), weight: Atelier.fine, color: ink)
        Atelier.loop(ctx, CGRect(x: pivot.x - 2.5, y: pivot.y - 2.5, width: 5, height: 5), weight: Atelier.fine, color: ink)
        // The inclined plane: input along, output up; its slope is 1 : ratio above the knee.
        let base = CGPoint(x: plane.minX, y: plane.maxY), knee = CGPoint(x: plane.minX + plane.width * 0.45, y: plane.maxY - plane.height * 0.45)
        let top = CGPoint(x: plane.maxX, y: knee.y - (plane.maxX - knee.x) / CGFloat(ratio))
        Atelier.rule(ctx, base, CGPoint(x: plane.maxX, y: plane.maxY), weight: Atelier.fine, color: ink)
        Atelier.rule(ctx, base, CGPoint(x: plane.maxX, y: plane.minY), weight: Atelier.hair, color: faint, dash: [1, 2]) // 1 : 1
        let slope = CGMutablePath(); slope.addLines(between: [base, knee, top, CGPoint(x: plane.maxX, y: plane.maxY)]); slope.closeSubpath()
        ctx.saveGState(); ctx.addPath(slope); ctx.clip(); Atelier.hatch(ctx, plane, spacing: 2.2, color: Theme.ink(0.3), weight: 0.45); ctx.restoreGState()
        Atelier.rule(ctx, base, knee, weight: Atelier.medium, color: ink)
        Atelier.rule(ctx, knee, top, weight: Atelier.medium, color: ink)
        // Lettering and readouts.
        // Letters by their parts; the values in the left column, under the plane, clear of the strip.
        letterCallout(ctx, link, .threshold, at: CGPoint(x: strip.maxX + 4, y: railY), to: CGPoint(x: strip.maxX + 9, y: railY - 9))
        letterCallout(ctx, link, .ratio, at: top, to: CGPoint(x: top.x + 7, y: top.y - 7))
        // A lit part's tag (name and value) is wider than the column: it goes in the band above the strip, where the
        // margin note gives way to it.
        let litRole: FigureRole? = [FigureRole.ratio, .threshold].first { figureDrag?.role == $0 || hoverRole == $0 || highlightRole == $0 }
        for (role, y) in [(FigureRole.ratio, plane.maxY + 4), (FigureRole.threshold, plane.maxY + 19)] where role != litRole {
            readout(ctx, link, role, at: CGPoint(x: plane.minX, y: y))
        }
        if let shown = litRole {
            readout(ctx, link, shown, at: CGPoint(x: strip.minX, y: f.minY - 1))
            marginNotes = []
            return [FigureHandle(role: .threshold, point: CGPoint(x: strip.maxX - 10, y: railY), axis: CGVector(dx: 0, dy: -1), span: half),
                    FigureHandle(role: .ratio, point: top, axis: CGVector(dx: 0, dy: 1), span: 24)]
        }
        marginNotes = [reductionDb < 0.05 ? "no reduction now" : String(format: "taken off now −%.1f dB", reductionDb)]
        return [FigureHandle(role: .threshold, point: CGPoint(x: strip.maxX - 10, y: railY), axis: CGVector(dx: 0, dy: -1), span: half),
                FigureHandle(role: .ratio, point: top, axis: CGVector(dx: 0, dy: 1), span: 24)]
    }

    /// The vaulted chamber, as first drawn for the Codex (the owner wanted it back): the hall in one-point perspective on
    /// its dark field, rays from the source to the listener by way of the walls; the sound travels along them and spreads
    /// from the source in rings, slower as the decay grows. The vault is the room's size (drag it up or down), the
    /// listener the decay (drag it along the floor).
    private func chamberFigure(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink, energyDb: Double) -> [FigureHandle] {
        guard let hall = self as? HistoryScreen else { return [] }
        ctx.setFillColor(Theme.lcd.cgColor); ctx.fill(f)
        Atelier.screen(ctx, f)
        let linked = link.ids[.size] != nil || link.ids[.decay] != nil
        let p = hall.chamber(ctx, f.insetBy(dx: 1, dy: 1), letters: linked ? (nil, link.l(.size), link.l(.decay)) : ("A", "B", "C"), phase: figureAngle)
        readout(ctx, link, .size, at: CGPoint(x: p.vault.x + 4, y: p.vault.y + 4))
        readout(ctx, link, .decay, at: CGPoint(x: min(f.maxX - 34, p.listener.x - 6), y: p.listener.y + 4))
        marginNotes = energyDb > -80 ? [String(format: "sound now %.0f dB", energyDb)] : []
        return [FigureHandle(role: .size, point: p.vault, axis: CGVector(dx: 0, dy: -1), span: 40),
                FigureHandle(role: .decay, point: p.listener, axis: CGVector(dx: 1, dy: 0), span: 60)]
    }

    /// The pendulum: it swings between the marks of its reach, which is the delay time (A, drag the right mark along the
    /// arc); each repeat is a fainter arc below, lighting in turn as the bob passes, as many as the feedback gives (B,
    /// drag the last arc up or down).
    private func pendulum(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink, energyDb: Double) -> [FigureHandle] {
        let ink = Theme.text, time = link.v(.time, 0.4), fb = link.v(.feedback, 0.4)
        let pivot = CGPoint(x: f.minX + f.width * 0.42, y: f.minY + 10), rod = min(f.height - 46, 86)
        let alpha = (8 + 34 * CGFloat(time)) * .pi / 180
        solid(ctx, CGRect(x: pivot.x - 30, y: pivot.y - 8, width: 60, height: 5))
        let arc = CGMutablePath()
        arc.addArc(center: pivot, radius: rod + 6, startAngle: .pi / 2 - 0.85, endAngle: .pi / 2 + 0.85, clockwise: false)
        ctx.addPath(arc); ctx.setStrokeColor(Theme.ink(0.55).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()
        for i in -6...6 {
            let a = .pi / 2 + CGFloat(i) * 0.14
            Atelier.rule(ctx, CGPoint(x: pivot.x + cos(a) * (rod + 6), y: pivot.y + sin(a) * (rod + 6)),
                         CGPoint(x: pivot.x + cos(a) * (rod + (i % 3 == 0 ? 11 : 9)), y: pivot.y + sin(a) * (rod + (i % 3 == 0 ? 11 : 9))), weight: Atelier.hair, color: Theme.ink(0.6))
        }
        Atelier.rule(ctx, pivot, CGPoint(x: pivot.x, y: pivot.y + rod), weight: 0.4, color: Theme.ink(0.35), dash: [1, 2])
        // Repeats: concentric arcs under the bob, fading; the echo running down them follows the swing.
        let repeats = 1 + Int(fb * 6)
        let wave = (figureAngle / .pi).truncatingRemainder(dividingBy: 1) * Double(repeats + 1)
        var lastY = pivot.y + rod
        for i in 1...repeats {
            let r = rod + 14 + CGFloat(i) * 5
            let rep = CGMutablePath()
            rep.addArc(center: pivot, radius: r, startAngle: .pi / 2 - alpha * 0.8, endAngle: .pi / 2 + alpha * 0.8, clockwise: false)
            let glow = CGFloat(max(0, 1 - abs(wave - Double(i)))) * 0.35
            ctx.addPath(rep); ctx.setStrokeColor(Theme.ink(min(1, max(0.12, 0.7 - CGFloat(i) * 0.09) + glow)).cgColor); ctx.setLineWidth(0.6 + glow); ctx.strokePath()
            lastY = pivot.y + r
        }
        // The reach: both extremes ghosted; the rod and bob swing between them.
        let mark = { (s: CGFloat) in CGPoint(x: pivot.x + s * sin(alpha) * rod, y: pivot.y + cos(alpha) * rod) }
        for s in [CGFloat(-1), 1] {
            let b = mark(s)
            Atelier.rule(ctx, pivot, b, weight: Atelier.hair, color: Theme.ink(0.25))
            Atelier.loop(ctx, CGRect(x: b.x - 8, y: b.y - 8, width: 16, height: 16), weight: Atelier.hair, color: Theme.ink(0.3))
        }
        let now = alpha * CGFloat(cos(figureAngle))
        let bob = CGPoint(x: pivot.x + sin(now) * rod, y: pivot.y + cos(now) * rod)
        Atelier.rule(ctx, pivot, bob, weight: Atelier.medium, color: ink)
        let disc = CGRect(x: bob.x - 8, y: bob.y - 8, width: 16, height: 16)
        Atelier.obliqueSide(ctx, circle: disc)
        ball(ctx, bob, r: 8)
        ctx.setFillColor(ink.cgColor); ctx.fillEllipse(in: CGRect(x: pivot.x - 1.8, y: pivot.y - 1.8, width: 3.6, height: 3.6))
        let reach = mark(1)
        letterCallout(ctx, link, .time, at: CGPoint(x: reach.x + 8, y: reach.y), to: CGPoint(x: reach.x + 20, y: reach.y - 12))
        readout(ctx, link, .time, at: CGPoint(x: min(f.maxX - 40, reach.x + 22), y: reach.y + 10)) // clear of the arc's end
        letterCallout(ctx, link, .feedback, at: CGPoint(x: pivot.x - 4, y: lastY), to: CGPoint(x: f.minX + 8, y: lastY - 6))
        readout(ctx, link, .feedback, at: CGPoint(x: f.minX + 2, y: lastY - 2))
        marginNotes = energyDb > -80 ? [String(format: "echoes now %.0f dB", energyDb)] : []
        let tangent = CGVector(dx: cos(alpha), dy: -sin(alpha))
        return [FigureHandle(role: .time, point: reach, axis: tangent, span: rod * 0.6),
                FigureHandle(role: .feedback, point: CGPoint(x: pivot.x, y: lastY), axis: CGVector(dx: 0, dy: 1), span: 34)]
    }

    /// The clipped wave by construction: the input sine runs down from under the square, through the transfer curve, and
    /// out to the right as the clipped wave; a dotted projection carries the present sample across. Drive (A) is the
    /// curve's knee: drag it along the diagonal.
    private func clipping(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink) -> [FigureHandle] {
        let ink = Theme.text, drive = link.v(.drive, 0.4), phase = figureAngle
        let side = min(f.height * 0.56, f.width * 0.42)
        let sq = CGRect(x: f.minX + 14, y: f.minY + 6, width: side, height: side)
        let k = 1 + 9 * drive
        func curve(_ x: Double) -> Double { tanh(k * x) / tanh(k) }
        Atelier.box(ctx, sq, weight: Atelier.hair, color: Theme.ink(0.55))
        Atelier.rule(ctx, CGPoint(x: sq.minX, y: sq.midY), CGPoint(x: sq.maxX, y: sq.midY), weight: Atelier.hair, color: Theme.ink(0.4))
        Atelier.rule(ctx, CGPoint(x: sq.midX, y: sq.minY), CGPoint(x: sq.midX, y: sq.maxY), weight: Atelier.hair, color: Theme.ink(0.4))
        Atelier.rule(ctx, CGPoint(x: sq.minX, y: sq.maxY), CGPoint(x: sq.maxX, y: sq.minY), weight: 0.4, color: Theme.ink(0.3), dash: [1, 2])
        let pts = (0...60).map { i -> CGPoint in
            let x = -1 + 2 * Double(i) / 60
            return CGPoint(x: sq.midX + CGFloat(x) * side / 2, y: sq.midY - CGFloat(curve(x)) * side / 2)
        }
        ctx.addPath(Codex.path(pts)); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(Atelier.medium); ctx.strokePath()
        // Time runs away from the curve: down the input, right along the output; the present sample is at t = 0.
        func sample(_ t: Double) -> Double { 0.9 * sin(phase - t * 2 * .pi + .pi / 2) }
        let inTop = sq.maxY + 6, inH = f.maxY - inTop - 4
        let input = (0...40).map { i -> CGPoint in
            let t = Double(i) / 40
            return CGPoint(x: sq.midX + CGFloat(sample(t)) * side / 2, y: inTop + CGFloat(t) * inH)
        }
        ctx.addPath(Codex.path(input)); ctx.setStrokeColor(Theme.ink(0.7).cgColor); ctx.setLineWidth(Atelier.fine); ctx.strokePath()
        let outLeft = sq.maxX + 8, outW = f.maxX - outLeft - 4
        let output = (0...60).map { i -> CGPoint in
            let t = Double(i) / 60
            return CGPoint(x: outLeft + CGFloat(t) * outW, y: sq.midY - CGFloat(curve(sample(t))) * side / 2)
        }
        ctx.saveGState(); ctx.clip(to: CGRect(x: outLeft - 1, y: f.minY, width: outW + 2, height: f.height)) // inside the plate (audit V22)
        ctx.addPath(Codex.path(output)); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(Atelier.fine); ctx.strokePath()
        ctx.restoreGState()
        // Projection of the present sample: from the input, up to the curve, across to the output.
        let x0 = sample(0), px = sq.midX + CGFloat(x0) * side / 2, py = sq.midY - CGFloat(curve(x0)) * side / 2
        Codex.dotted(ctx, CGPoint(x: px, y: inTop), CGPoint(x: px, y: py), alpha: 0.5)
        Codex.dotted(ctx, CGPoint(x: px, y: py), CGPoint(x: outLeft, y: py), alpha: 0.5)
        ctx.setFillColor(Theme.text.cgColor); ctx.fillEllipse(in: CGRect(x: px - 1.6, y: py - 1.6, width: 3.2, height: 3.2))
        for p in liveTransfer.suffix(40) {
            let c = CGPoint(x: sq.midX + p.x * side / 2, y: sq.midY - p.y * side / 2)
            guard sq.contains(c) else { continue }
            ctx.setFillColor(Theme.ink(0.6).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 0.8, y: c.y - 0.8, width: 1.6, height: 1.6))
        }
        let knee = CGPoint(x: sq.midX + side / 2 * CGFloat(0.35), y: sq.midY - CGFloat(curve(0.35)) * side / 2)
        letterCallout(ctx, link, .drive, at: CGPoint(x: knee.x + 3, y: knee.y - 3), to: CGPoint(x: knee.x + 14, y: sq.minY + 6))
        readout(ctx, link, .drive, at: CGPoint(x: outLeft + 2, y: sq.maxY + 8))
        Atelier.note(ctx, "in", at: CGPoint(x: sq.minX - 2, y: f.maxY - 12), size: 8, color: Theme.textDim, align: .right)
        Atelier.note(ctx, "out", at: CGPoint(x: f.maxX - 2, y: sq.minY - 11), size: 8, color: Theme.textDim, align: .right)
        marginNotes = []
        return [FigureHandle(role: .drive, point: knee, axis: CGVector(dx: -0.707, dy: -0.707), span: side * 0.5)]
    }

    /// The crank and disc (a Scotch yoke): the disc turns at the rate, its pin drives a slider up and down a guide, and
    /// the slider draws the LFO out to the right. The pin's radius is the depth (B, drag the ring on the fixed radius);
    /// the bracket over one period is the rate (A, drag its end: shorter is faster).
    private func crank(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink) -> [FigureHandle] {
        let ink = Theme.text, rate = link.v(.rate, 0.4), depth = link.v(.depth, 0.5)
        let R: CGFloat = min(26, f.height * 0.22)
        let c = CGPoint(x: f.minX + R + 10, y: f.midY - 6)
        let disc = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)
        Atelier.obliqueSide(ctx, circle: disc)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: disc)
        Atelier.loop(ctx, disc, weight: Atelier.fine, color: ink)
        Atelier.loop(ctx, disc.insetBy(dx: 3, dy: 3), weight: Atelier.hair, color: Theme.ink(0.45))
        let turn = -CGFloat(figureAngle)
        for k in 0..<6 { // spokes turn with the disc
            let a = turn + CGFloat(k) * .pi / 3
            Atelier.rule(ctx, CGPoint(x: c.x + cos(a) * 4, y: c.y + sin(a) * 4), CGPoint(x: c.x + cos(a) * (R - 4), y: c.y + sin(a) * (R - 4)), weight: Atelier.hair, color: Theme.ink(0.35))
        }
        let pinR = R * (0.2 + 0.7 * CGFloat(depth)), a0 = -CGFloat.pi / 4, a = a0 + turn
        let pin = CGPoint(x: c.x + cos(a) * pinR, y: c.y + sin(a) * pinR)
        let setting = CGPoint(x: c.x + cos(a0) * pinR, y: c.y + sin(a0) * pinR)
        Atelier.rule(ctx, c, CGPoint(x: c.x + cos(a0) * (R + 6), y: c.y + sin(a0) * (R + 6)), weight: Atelier.hair, color: Theme.ink(0.45), dash: [1, 1.5])
        ctx.setFillColor(ink.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2))
        // The slider on its guide, level with the pin; its trace runs out to the right.
        let x0 = disc.maxX + 14, x1 = f.maxX - 4, amp = pinR
        let cycles = 0.75 + 3.25 * rate
        Atelier.rule(ctx, CGPoint(x: x0, y: c.y - R - 4), CGPoint(x: x0, y: c.y + R + 4), weight: Atelier.hair, color: Theme.ink(0.5))
        let trace = (0...90).map { i -> CGPoint in
            let t = Double(i) / 90
            return CGPoint(x: x0 + CGFloat(t) * (x1 - x0), y: c.y + CGFloat(sin(Double(a) + t * cycles * 2 * .pi)) * amp)
        }
        Atelier.rule(ctx, CGPoint(x: x0, y: c.y), CGPoint(x: x1, y: c.y), weight: Atelier.hair, color: Theme.ink(0.4))
        ctx.addPath(Codex.path(trace)); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(Atelier.fine); ctx.strokePath()
        let slider = CGPoint(x: x0, y: pin.y)
        Atelier.rule(ctx, pin, slider, weight: Atelier.medium, color: ink)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: CGRect(x: pin.x - 2.4, y: pin.y - 2.4, width: 4.8, height: 4.8))
        Atelier.loop(ctx, CGRect(x: pin.x - 2.4, y: pin.y - 2.4, width: 4.8, height: 4.8), weight: Atelier.fine, color: ink)
        solid(ctx, CGRect(x: slider.x - 4, y: slider.y - 3, width: 8, height: 6))
        // One period, measured over the trace.
        let periodW = (x1 - x0) / CGFloat(cycles), by = c.y - R - 10
        let end = CGPoint(x: min(x1, x0 + periodW), y: by)
        Atelier.rule(ctx, CGPoint(x: x0, y: by), end, weight: Atelier.hair, color: Theme.ink(0.6))
        for x in [x0, end.x] { Atelier.rule(ctx, CGPoint(x: x, y: by - 3), CGPoint(x: x, y: by + 3), weight: Atelier.hair, color: Theme.ink(0.6)) }
        Atelier.note(ctx, "T", at: CGPoint(x: (x0 + end.x) / 2, y: by - 12), size: 8.5, color: Theme.textDim, align: .center)
        letterCallout(ctx, link, .rate, at: CGPoint(x: end.x + 2, y: by - 2), to: CGPoint(x: end.x + 12, y: max(f.minY + 6, by - 10)))
        readout(ctx, link, .rate, at: CGPoint(x: min(f.maxX - 40, end.x + 24), y: max(f.minY + 2, by - 13)))
        letterCallout(ctx, link, .depth, at: CGPoint(x: setting.x + 3, y: setting.y - 3), to: CGPoint(x: setting.x + 6, y: disc.minY - 6))
        readout(ctx, link, .depth, at: CGPoint(x: disc.minX, y: disc.maxY + 8))
        marginNotes = []
        return [FigureHandle(role: .rate, point: end, axis: CGVector(dx: -1, dy: 0), span: (x1 - x0) * 0.6),
                FigureHandle(role: .depth, point: setting, axis: CGVector(dx: cos(a0), dy: sin(a0)), span: R * 0.7)]
    }

    /// A small solid in the shared oblique (y down): front, top and right faces, the right one hatched.
    func solid(_ ctx: CGContext, _ front: CGRect) {
        let v = Atelier.recede
        let top = CGMutablePath(), side = CGMutablePath()
        top.addLines(between: [CGPoint(x: front.minX, y: front.minY), CGPoint(x: front.minX + v.dx, y: front.minY + v.dy),
                               CGPoint(x: front.maxX + v.dx, y: front.minY + v.dy), CGPoint(x: front.maxX, y: front.minY)]); top.closeSubpath()
        side.addLines(between: [CGPoint(x: front.maxX, y: front.minY), CGPoint(x: front.maxX + v.dx, y: front.minY + v.dy),
                                CGPoint(x: front.maxX + v.dx, y: front.maxY + v.dy), CGPoint(x: front.maxX, y: front.maxY)]); side.closeSubpath()
        ctx.saveGState()
        ctx.setFillColor(Theme.panelRaised.cgColor)
        ctx.addPath(top); ctx.fillPath(); ctx.addPath(side); ctx.fillPath(); ctx.fill(front)
        ctx.addPath(side); ctx.clip(); Atelier.hatch(ctx, side.boundingBox.insetBy(dx: -1, dy: -1), spacing: 1.2, color: Theme.ink(0.5), weight: 0.4)
        ctx.restoreGState()
        for p in [top, side] { ctx.addPath(p); ctx.setStrokeColor(Theme.ink(0.75).cgColor); ctx.setLineWidth(0.55); ctx.strokePath() }
        Atelier.box(ctx, front, weight: Atelier.fine, color: Theme.text)
    }

    // MARK: Dragging

    func figureHandle(at p: CGPoint) -> FigureHandle? {
        guard let link = figureLink else { return nil }
        return figureHandles.filter { link.ids[$0.role] != nil }
            .min { hypot($0.point.x - p.x, $0.point.y - p.y) < hypot($1.point.x - p.x, $1.point.y - p.y) }
            .flatMap { hypot($0.point.x - p.x, $0.point.y - p.y) <= 12 ? $0 : nil }
    }
    func figureMouseDown(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        guard let h = figureHandle(at: p), let link = figureLink, let id = link.ids[h.role] else { return false }
        figureDrag = (h.role, p, link.value(id) ?? 0, h)
        link.begin()
        needsDisplay = true
        return true
    }
    func figureMouseDragged(_ event: NSEvent) {
        guard let d = figureDrag, let link = figureLink, let id = link.ids[d.role] else { return }
        let p = convert(event.locationInWindow, from: nil)
        let along = (p.x - d.start.x) * d.handle.axis.dx + (p.y - d.start.y) * d.handle.axis.dy
        let fine = event.modifierFlags.contains(.shift) ? 0.2 : 1.0
        link.set(id, max(0, min(1, d.value + Double(along / max(10, d.handle.span)) * fine)))
        needsDisplay = true
    }
    func figureMouseUp() {
        guard figureDrag != nil else { return }
        figureDrag = nil
        figureLink?.end()
        needsDisplay = true
    }
}
