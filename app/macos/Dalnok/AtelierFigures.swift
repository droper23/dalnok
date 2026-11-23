// Atelier's plug-in figures as instruments (the owner, fourth round: "the drawing is the control"). Each family is one
// engraved figure whose lettered parts are dragged: a flyball governor for dynamics, a vaulted chamber for reverbs, a
// pendulum for delays, a sine through its clipping curve for distortion, a crank and disc for modulation. The letters
// are the key's letters for the same parameters. Figures are drawn from the plug-in's parameters and live data; nothing
// ornamental animates (guardrail 5). Data first: labels sit on clean plate.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

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

    func v(_ r: FigureRole, _ fallback: Double = 0.5) -> Double { ids[r].flatMap(value) ?? fallback }
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
        case .governor: "The Governor"
        case .chamber: "Acoustic Chamber"
        case .pendulum: "Pendulum of Echoes"
        case .clipping: "Construction of the Clipped Wave"
        case .crank: "Crank and Disc"
        }
    }
}

extension FaceplateScreen {
    // MARK: Drawing

    /// Draws one of the new figures in `f` (y down) and records its handles. Live values come from the screen's data.
    func drawFigure(_ fig: AtelierFigure, _ ctx: CGContext, _ f: CGRect, live: Double) {
        var handles: [FigureHandle] = []
        let link = figureLink ?? FigureLink()
        switch fig {
        case .governor: handles = governor(ctx, f, link, reductionDb: live)
        case .chamber: handles = chamberFigure(ctx, f, link, energyDb: live)
        case .pendulum: handles = pendulum(ctx, f, link, energyDb: live)
        case .clipping: handles = clipping(ctx, f, link)
        case .crank: handles = crank(ctx, f, link)
        }
        figureHandles = handles
        // Drag marks: a small ring at every part that can be dragged (thicker while dragged).
        for h in handles where link.ids[h.role] != nil {
            let r = CGRect(x: h.point.x - 3.2, y: h.point.y - 3.2, width: 6.4, height: 6.4)
            ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: r)
            Atelier.loop(ctx, r, weight: figureDrag?.role == h.role ? Atelier.heavy : Atelier.fine, color: Theme.text)
        }
        // Margin notes: live facts in the annotation hand, right-aligned at the field's foot.
        var y = f.minY
        for n in (marginNotes + link.notes()).prefix(2) {
            Atelier.note(ctx, n, at: CGPoint(x: f.maxX - 2, y: y), size: 8.5, color: Theme.textDim, align: .right)
            y += 11
        }
    }

    private func letterCallout(_ ctx: CGContext, _ link: FigureLink, _ role: FigureRole, at p: CGPoint, to q: CGPoint) {
        guard let letter = link.l(role) else { return }
        Atelier.callout(ctx, letter, from: p, to: q)
    }
    private func readout(_ ctx: CGContext, _ link: FigureLink, _ role: FigureRole, at p: CGPoint, align: NSTextAlignment = .left) {
        guard let t = link.t(role) else { return }
        Atelier.note(ctx, t, at: p, size: 9.5, color: Theme.text, align: align, roman: true)
    }

    /// The flyball governor: a spindle on a base, two arms hinged at its head carrying turned balls, links to a collar.
    /// The collar's height is the threshold (A), the arms' length the ratio (B); the balls swing out with the live
    /// gain reduction.
    private func governor(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink, reductionDb: Double) -> [FigureHandle] {
        let ink = Theme.text, cx = f.minX + f.width * 0.42
        let top = f.minY + 12, baseY = f.maxY - 14
        let thr = link.v(.threshold, 0.6), ratio = link.v(.ratio, 0.4)
        let red = min(1, abs(reductionDb) / 18)
        let theta = (28 + 36 * red) * .pi / 180
        let L = 30 + 24 * CGFloat(ratio)
        // Base: a slab in the shared oblique; the spindle stands on it.
        let base = CGRect(x: cx - 26, y: baseY, width: 52, height: 7)
        solid(ctx, base)
        Atelier.rule(ctx, CGPoint(x: cx - 1.2, y: top), CGPoint(x: cx - 1.2, y: baseY), weight: Atelier.fine, color: ink)
        Atelier.rule(ctx, CGPoint(x: cx + 1.2, y: top), CGPoint(x: cx + 1.2, y: baseY), weight: Atelier.fine, color: ink)
        // Head and pivot.
        let head = CGRect(x: cx - 5, y: top - 6, width: 10, height: 6)
        solid(ctx, head)
        let pivot = CGPoint(x: cx, y: top + 2)
        // Collar: its travel is the threshold scale (graduated beside the spindle).
        let travel = (top + 20)...(baseY - 12)
        let cy = travel.upperBound - CGFloat(thr) * (travel.upperBound - travel.lowerBound)
        for i in 0...8 {
            let gy = travel.lowerBound + (travel.upperBound - travel.lowerBound) * CGFloat(i) / 8
            Atelier.rule(ctx, CGPoint(x: cx - 14, y: gy), CGPoint(x: cx - (i % 4 == 0 ? 20 : 17), y: gy), weight: Atelier.hair, color: Theme.ink(0.55))
        }
        // Arms, balls and links, both sides.
        var ballR = CGPoint.zero
        for s in [CGFloat(-1), 1] {
            let ball = CGPoint(x: pivot.x + s * sin(theta) * L, y: pivot.y + cos(theta) * L)
            let mid = CGPoint(x: pivot.x + s * sin(theta) * L * 0.5, y: pivot.y + cos(theta) * L * 0.5)
            Atelier.rule(ctx, pivot, ball, weight: Atelier.medium, color: ink)
            Atelier.rule(ctx, mid, CGPoint(x: cx + s * 4, y: cy), weight: Atelier.fine, color: ink)
            let r: CGFloat = 9.5
            let disc = CGRect(x: ball.x - r, y: ball.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: disc)
            ctx.saveGState(); ctx.addEllipse(in: disc); ctx.clip(); Atelier.globeShade(ctx, disc); ctx.restoreGState()
            Atelier.loop(ctx, disc, weight: Atelier.fine, color: ink)
            if s > 0 { ballR = ball }
        }
        let collar = CGRect(x: cx - 6, y: cy - 3, width: 12, height: 6)
        solid(ctx, collar)
        // The swing's arc, dotted, so the reduction reads as an angle.
        let arc = CGMutablePath()
        arc.addArc(center: pivot, radius: L, startAngle: .pi / 2 - 70 * .pi / 180, endAngle: .pi / 2 - 10 * .pi / 180, clockwise: false)
        ctx.addPath(arc); ctx.setStrokeColor(Theme.ink(0.4).cgColor); ctx.setLineWidth(0.5); ctx.setLineDash(phase: 0, lengths: [1, 2]); ctx.strokePath(); ctx.setLineDash(phase: 0, lengths: [])
        // Letters and readouts.
        letterCallout(ctx, link, .threshold, at: CGPoint(x: cx - 6, y: cy), to: CGPoint(x: cx - 24, y: cy + 12))
        readout(ctx, link, .threshold, at: CGPoint(x: cx - 22, y: cy + 14), align: .right)
        letterCallout(ctx, link, .ratio, at: CGPoint(x: ballR.x + 7, y: ballR.y - 3), to: CGPoint(x: ballR.x + 18, y: ballR.y - 14))
        readout(ctx, link, .ratio, at: CGPoint(x: min(f.maxX - 2, ballR.x + 14), y: ballR.y + 6))
        marginNotes = [abs(reductionDb) < 0.05 ? "no reduction now" : String(format: "reduction now −%.1f dB", abs(reductionDb))]
        return [FigureHandle(role: .threshold, point: CGPoint(x: cx + 9, y: cy), axis: CGVector(dx: 0, dy: -1), span: travel.upperBound - travel.lowerBound),
                FigureHandle(role: .ratio, point: ballR, axis: CGVector(dx: sin(theta), dy: cos(theta)), span: 22)]
    }

    /// The vaulted chamber in one-point perspective: the back arch shrinks as the room grows (A, drag the back wall),
    /// and sound rays from the source A reach further and fainter with the decay (B, drag the longest ray's end).
    private func chamberFigure(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink, energyDb: Double) -> [FigureHandle] {
        let size = link.v(.size, 0.5), decay = link.v(.decay, 0.5)
        let front = CGRect(x: f.minX + 6, y: f.minY + 8, width: f.width * 0.78, height: f.height - 28)
        let depth = 0.28 + 0.42 * CGFloat(size)
        let back = front.insetBy(dx: front.width * depth / 2, dy: front.height * depth / 2).offsetBy(dx: 0, dy: front.height * depth * 0.08)
        func arch(_ r: CGRect) -> CGPath {
            let p = CGMutablePath(), spring = r.minY + r.width / 2
            p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: max(r.minY + 2, spring)))
            p.addArc(center: CGPoint(x: r.midX, y: max(r.minY + 2, spring)), radius: r.width / 2, startAngle: .pi, endAngle: 0, clockwise: false)
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); return p
        }
        let ink = Theme.text
        // Floor, hatched in perspective; the receding edges; both arches; voussoir lines on the vault.
        let floor = CGMutablePath()
        floor.addLines(between: [CGPoint(x: front.minX, y: front.maxY), CGPoint(x: back.minX, y: back.maxY), CGPoint(x: back.maxX, y: back.maxY), CGPoint(x: front.maxX, y: front.maxY)]); floor.closeSubpath()
        ctx.saveGState(); ctx.addPath(floor); ctx.clip(); Atelier.hatch(ctx, floor.boundingBox, spacing: 2.2, color: Theme.ink(0.3), weight: 0.4, angle: 0); ctx.restoreGState()
        for (a, b) in [(CGPoint(x: front.minX, y: front.maxY), CGPoint(x: back.minX, y: back.maxY)), (CGPoint(x: front.maxX, y: front.maxY), CGPoint(x: back.maxX, y: back.maxY))] {
            Atelier.rule(ctx, a, b, weight: Atelier.fine, color: ink)
        }
        for i in 1...5 {
            let a = CGFloat.pi + CGFloat.pi * CGFloat(i) / 6
            let fr = front.width / 2, br = back.width / 2
            let fc = CGPoint(x: front.midX, y: front.minY + fr), bc = CGPoint(x: back.midX, y: back.minY + br)
            Atelier.rule(ctx, CGPoint(x: fc.x + cos(a) * fr, y: fc.y + sin(a) * fr), CGPoint(x: bc.x + cos(a) * br, y: bc.y + sin(a) * br), weight: Atelier.hair, color: Theme.ink(0.45))
        }
        for (r, w) in [(front, Atelier.medium), (back, Atelier.fine)] {
            ctx.addPath(arch(r)); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(w); ctx.strokePath()
        }
        // Rays from the source: more and longer with decay, fading with each bounce; live energy brightens them.
        let src = CGPoint(x: front.minX + front.width * 0.22, y: front.maxY - 10)
        let live = CGFloat(max(0, min(1, (energyDb + 60) / 60)))
        let count = 3 + Int(decay * 6)
        var far = src
        for i in 0..<count {
            let a = -CGFloat.pi / 2 + (CGFloat(i) - CGFloat(count - 1) / 2) * 0.32
            let reach = (34 + 50 * CGFloat(decay)) * (1 - CGFloat(i % 3) * 0.12)
            let end = CGPoint(x: src.x + cos(a + 0.5) * reach, y: src.y + sin(a + 0.5) * reach * 0.8)
            Atelier.rule(ctx, src, end, weight: 0.5, color: Theme.ink(0.35 + 0.4 * live), dash: i % 2 == 0 ? [] : [2, 1.5])
            if hypot(end.x - src.x, end.y - src.y) > hypot(far.x - src.x, far.y - src.y) { far = end }
        }
        ctx.setFillColor(ink.cgColor); ctx.fillEllipse(in: CGRect(x: src.x - 2, y: src.y - 2, width: 4, height: 4))
        letterCallout(ctx, link, .size, at: CGPoint(x: back.maxX, y: back.midY), to: CGPoint(x: front.maxX + 10, y: back.minY))
        readout(ctx, link, .size, at: CGPoint(x: front.maxX + 6, y: back.minY + 4))
        letterCallout(ctx, link, .decay, at: far, to: CGPoint(x: far.x + 10, y: far.y - 10))
        readout(ctx, link, .decay, at: CGPoint(x: front.maxX + 6, y: back.minY + 28))
        marginNotes = energyDb > -80 ? [String(format: "sound now %.0f dB", energyDb)] : []
        let dir = CGVector(dx: far.x - src.x, dy: far.y - src.y), len = max(1, hypot(dir.dx, dir.dy))
        return [FigureHandle(role: .size, point: CGPoint(x: back.maxX, y: back.midY), axis: CGVector(dx: -1, dy: 0), span: front.width * 0.21),
                FigureHandle(role: .decay, point: far, axis: CGVector(dx: dir.dx / len, dy: dir.dy / len), span: 50)]
    }

    /// The pendulum: its swing is the delay time (A, drag the bob along its arc); each repeat is a fainter arc below,
    /// as many as the feedback gives (B, drag the last arc up or down).
    private func pendulum(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink, energyDb: Double) -> [FigureHandle] {
        let ink = Theme.text, time = link.v(.time, 0.4), fb = link.v(.feedback, 0.4)
        let pivot = CGPoint(x: f.minX + f.width * 0.42, y: f.minY + 10), rod = min(f.height - 46, 86)
        let alpha = (8 + 34 * CGFloat(time)) * .pi / 180
        // Bracket: a beam in the shared oblique, the pivot pin beneath.
        solid(ctx, CGRect(x: pivot.x - 30, y: pivot.y - 8, width: 60, height: 5))
        // Graduated arc of the swing, and the rest position dotted.
        let arc = CGMutablePath()
        arc.addArc(center: pivot, radius: rod + 6, startAngle: .pi / 2 - 0.85, endAngle: .pi / 2 + 0.85, clockwise: false)
        ctx.addPath(arc); ctx.setStrokeColor(Theme.ink(0.55).cgColor); ctx.setLineWidth(0.5); ctx.strokePath()
        for i in -6...6 {
            let a = .pi / 2 + CGFloat(i) * 0.14
            Atelier.rule(ctx, CGPoint(x: pivot.x + cos(a) * (rod + 6), y: pivot.y + sin(a) * (rod + 6)),
                         CGPoint(x: pivot.x + cos(a) * (rod + (i % 3 == 0 ? 11 : 9)), y: pivot.y + sin(a) * (rod + (i % 3 == 0 ? 11 : 9))), weight: Atelier.hair, color: Theme.ink(0.6))
        }
        Atelier.rule(ctx, pivot, CGPoint(x: pivot.x, y: pivot.y + rod), weight: 0.4, color: Theme.ink(0.35), dash: [1, 2])
        // Repeats: concentric arcs under the bob, fading.
        let repeats = 1 + Int(fb * 6)
        var lastY = pivot.y + rod
        for i in 1...repeats {
            let r = rod + 14 + CGFloat(i) * 5
            let rep = CGMutablePath()
            rep.addArc(center: pivot, radius: r, startAngle: .pi / 2 - alpha * 0.8, endAngle: .pi / 2 + alpha * 0.8, clockwise: false)
            ctx.addPath(rep); ctx.setStrokeColor(Theme.ink(max(0.12, 0.7 - CGFloat(i) * 0.09)).cgColor); ctx.setLineWidth(0.6); ctx.strokePath()
            lastY = pivot.y + r
        }
        // The rod and bob at the swing's extreme, its other extreme ghosted.
        for (s, a) in [(CGFloat(-1), 0.3), (1, 1.0)] as [(CGFloat, CGFloat)] {
            let bob = CGPoint(x: pivot.x + s * sin(alpha) * rod, y: pivot.y + cos(alpha) * rod)
            Atelier.rule(ctx, pivot, bob, weight: a > 0.5 ? Atelier.medium : Atelier.hair, color: Theme.ink(a))
            let r: CGFloat = 8, disc = CGRect(x: bob.x - r, y: bob.y - r, width: 2 * r, height: 2 * r)
            if a > 0.5 {
                Atelier.obliqueSide(ctx, circle: disc)
                ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: disc)
                ctx.saveGState(); ctx.addEllipse(in: disc); ctx.clip(); Atelier.globeShade(ctx, disc); ctx.restoreGState()
            }
            Atelier.loop(ctx, disc, weight: Atelier.fine, color: Theme.ink(a))
        }
        ctx.setFillColor(ink.cgColor); ctx.fillEllipse(in: CGRect(x: pivot.x - 1.8, y: pivot.y - 1.8, width: 3.6, height: 3.6))
        let bob = CGPoint(x: pivot.x + sin(alpha) * rod, y: pivot.y + cos(alpha) * rod)
        letterCallout(ctx, link, .time, at: CGPoint(x: bob.x + 8, y: bob.y), to: CGPoint(x: bob.x + 20, y: bob.y - 12))
        readout(ctx, link, .time, at: CGPoint(x: min(f.maxX - 40, bob.x + 14), y: bob.y + 4))
        letterCallout(ctx, link, .feedback, at: CGPoint(x: pivot.x - 4, y: lastY), to: CGPoint(x: f.minX + 8, y: lastY - 6))
        readout(ctx, link, .feedback, at: CGPoint(x: f.minX + 2, y: lastY - 2))
        marginNotes = energyDb > -80 ? [String(format: "echoes now %.0f dB", energyDb)] : []
        let tangent = CGVector(dx: cos(alpha), dy: -sin(alpha))
        return [FigureHandle(role: .time, point: bob, axis: tangent, span: rod * 0.6),
                FigureHandle(role: .feedback, point: CGPoint(x: pivot.x, y: lastY), axis: CGVector(dx: 0, dy: 1), span: 34)]
    }

    /// The clipped wave by construction: input sine below, the transfer curve in its square, the output sine at the
    /// side, joined by dotted projection lines. Drive (A) is the curve's knee: drag it along the diagonal.
    private func clipping(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink) -> [FigureHandle] {
        let ink = Theme.text, drive = link.v(.drive, 0.4)
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
        // Input sine below the square (time runs down), output sine to its right (time runs right).
        let inTop = sq.maxY + 6, inH = f.maxY - inTop - 4
        let input = (0...40).map { i -> CGPoint in
            let t = Double(i) / 40
            return CGPoint(x: sq.midX + CGFloat(sin(t * 2 * .pi)) * side / 2 * 0.9, y: inTop + CGFloat(t) * inH)
        }
        ctx.addPath(Codex.path(input)); ctx.setStrokeColor(Theme.ink(0.7).cgColor); ctx.setLineWidth(Atelier.fine); ctx.strokePath()
        let outLeft = sq.maxX + 8, outW = f.maxX - outLeft - 4
        let output = (0...60).map { i -> CGPoint in
            let t = Double(i) / 60
            return CGPoint(x: outLeft + CGFloat(t) * outW, y: sq.midY - CGFloat(curve(sin(t * 2 * .pi) * 0.9)) * side / 2)
        }
        ctx.addPath(Codex.path(output)); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(Atelier.fine); ctx.strokePath()
        // Projection of one point: input at its peak, up to the curve, across to the output.
        let peakX = sq.midX + side / 2 * 0.9, py = sq.midY - CGFloat(curve(0.9)) * side / 2
        Codex.dotted(ctx, CGPoint(x: peakX, y: inTop + inH * 0.25), CGPoint(x: peakX, y: py), alpha: 0.5)
        Codex.dotted(ctx, CGPoint(x: peakX, y: py), CGPoint(x: outLeft + outW * 0.25, y: py), alpha: 0.5)
        // Live input/output points from the transfer data, on the curve.
        for p in liveTransfer.suffix(40) {
            let c = CGPoint(x: sq.midX + p.x * side / 2, y: sq.midY - p.y * side / 2)
            guard sq.contains(c) else { continue }
            ctx.setFillColor(Theme.ink(0.6).cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 0.8, y: c.y - 0.8, width: 1.6, height: 1.6))
        }
        let knee = CGPoint(x: sq.midX + side / 2 * CGFloat(0.35), y: sq.midY - CGFloat(curve(0.35)) * side / 2)
        letterCallout(ctx, link, .drive, at: CGPoint(x: knee.x + 3, y: knee.y - 3), to: CGPoint(x: knee.x + 14, y: sq.minY + 6))
        readout(ctx, link, .drive, at: CGPoint(x: outLeft + 2, y: sq.maxY + 8))
        Atelier.note(ctx, "in", at: CGPoint(x: sq.midX + 4, y: f.maxY - 12), size: 8, color: Theme.textDim)
        Atelier.note(ctx, "out", at: CGPoint(x: f.maxX - 2, y: sq.midY + 2), size: 8, color: Theme.textDim, align: .right)
        marginNotes = []
        return [FigureHandle(role: .drive, point: knee, axis: CGVector(dx: -0.707, dy: -0.707), span: side * 0.5)]
    }

    /// The crank and disc: a turned disc whose pin radius is the depth (B, drag the pin), driving a rod whose trace is
    /// the LFO drawn out to the right; its period is the rate (A, drag the first crest left or right).
    private func crank(_ ctx: CGContext, _ f: CGRect, _ link: FigureLink) -> [FigureHandle] {
        let ink = Theme.text, rate = link.v(.rate, 0.4), depth = link.v(.depth, 0.5)
        let R: CGFloat = min(26, f.height * 0.22)
        let c = CGPoint(x: f.minX + R + 10, y: f.midY - 6)
        let disc = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)
        Atelier.obliqueSide(ctx, circle: disc)
        ctx.setFillColor(Theme.panelRaised.cgColor); ctx.fillEllipse(in: disc)
        Atelier.loop(ctx, disc, weight: Atelier.fine, color: ink)
        Atelier.loop(ctx, disc.insetBy(dx: 3, dy: 3), weight: Atelier.hair, color: Theme.ink(0.45))
        let pinR = R * (0.2 + 0.7 * CGFloat(depth)), a = -CGFloat.pi / 4
        let pin = CGPoint(x: c.x + cos(a) * pinR, y: c.y + sin(a) * pinR)
        Atelier.rule(ctx, c, pin, weight: Atelier.hair, color: Theme.ink(0.5), dash: [1, 1.5])
        ctx.setFillColor(ink.cgColor); ctx.fillEllipse(in: CGRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2))
        // The trace: amplitude from the pin's radius, cycles across the field from the rate.
        let x0 = disc.maxX + 14, x1 = f.maxX - 4, amp = pinR
        let cycles = 0.75 + 3.25 * rate
        let trace = (0...90).map { i -> CGPoint in
            let t = Double(i) / 90
            return CGPoint(x: x0 + CGFloat(t) * (x1 - x0), y: c.y - CGFloat(sin(t * cycles * 2 * .pi + Double(a))) * amp)
        }
        Atelier.rule(ctx, CGPoint(x: x0, y: c.y), CGPoint(x: x1, y: c.y), weight: Atelier.hair, color: Theme.ink(0.4))
        ctx.addPath(Codex.path(trace)); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(Atelier.fine); ctx.strokePath()
        // The connecting rod from the pin to the trace's start, and the slider block on the guide.
        let start = trace[0]
        Atelier.rule(ctx, pin, start, weight: Atelier.medium, color: ink)
        solid(ctx, CGRect(x: start.x - 4, y: start.y - 3, width: 8, height: 6))
        let crestT = 0.25 / cycles
        let crest = CGPoint(x: x0 + CGFloat(min(1, crestT)) * (x1 - x0), y: c.y - amp)
        letterCallout(ctx, link, .rate, at: CGPoint(x: crest.x + 2, y: crest.y - 3), to: CGPoint(x: crest.x + 12, y: f.minY + 6))
        readout(ctx, link, .rate, at: CGPoint(x: crest.x + 14, y: f.minY + 2))
        letterCallout(ctx, link, .depth, at: CGPoint(x: pin.x + 3, y: pin.y - 3), to: CGPoint(x: pin.x + 6, y: disc.minY - 6))
        readout(ctx, link, .depth, at: CGPoint(x: disc.minX, y: disc.maxY + 8))
        marginNotes = []
        return [FigureHandle(role: .rate, point: crest, axis: CGVector(dx: -1, dy: 0), span: (x1 - x0) * 0.6),
                FigureHandle(role: .depth, point: pin, axis: CGVector(dx: cos(a), dy: sin(a)), span: R * 0.7)]
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
