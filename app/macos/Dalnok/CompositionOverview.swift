// View ▸ Composition Overview: the project as a roadmap. Columns are sections (from the project's markers; without
// markers, plain 8-bar ranges, labelled as bars and never given invented names). Rows are tracks: how much of each
// section a track plays (its clips' coverage, from real clip positions) and a sparkline of its volume automation.
// Click a section (or arrow to it and press Return) to show it in the arrangement; Esc returns as you were.
// Drawn in every theme's own language (Atelier typesets it; Prism floats it on glass).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class CompositionOverview: NSView {
    struct Section: Equatable { let title: String; let start: Int64; let end: Int64; let firstBar: Int; let lastBar: Int; let named: Bool }
    let session: Session
    var onChoose: ((Section) -> Void)?
    var onClose: (() -> Void)?
    private(set) var sections: [Section] = []
    private(set) var selected = 0 { didSet { needsDisplay = true; NSAccessibility.post(element: self, notification: .valueChanged) } }
    private var axSections: [AXItem] = []

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Composition overview")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Sections from real data: the markers, or 8-bar ranges when there are none.
    static func sections(_ s: Session) -> [Section] {
        func bar(_ f: Int64) -> Int { s.bar(atBeat: s.frameToBeat(Double(f))).bar + 1 }
        let markers = s.markers.sorted { $0.frame < $1.frame }
        // The project runs to its last clip, or a bar past its last marker if that is later.
        let barAfterLast = markers.last.map { m in Int64(s.beatToFrame(s.barToBeat(bar(m.frame)))) } ?? 0
        let length = max(s.length, barAfterLast, 1)
        var out: [Section] = []
        if markers.isEmpty {
            var b = 0
            while true {
                let start = Int64(s.beatToFrame(s.barToBeat(b))), end = min(length, Int64(s.beatToFrame(s.barToBeat(b + 8))))
                guard start < length else { break }
                out.append(Section(title: "Bars \(b + 1)–\(b + 8)", start: start, end: end, firstBar: b + 1, lastBar: b + 8, named: false))
                b += 8
            }
            return out
        }
        if markers[0].frame > 0 { out.append(Section(title: "Start", start: 0, end: markers[0].frame, firstBar: 1, lastBar: max(1, bar(markers[0].frame) - 1), named: false)) }
        for (i, m) in markers.enumerated() {
            let end = i + 1 < markers.count ? markers[i + 1].frame : length
            let name = fixedString(m.name).trimmingCharacters(in: .whitespaces)
            out.append(Section(title: name.isEmpty ? "Marker \(i + 1)" : name, start: m.frame, end: end, firstBar: bar(m.frame), lastBar: max(bar(m.frame), bar(end) - 1), named: !name.isEmpty))
        }
        return out
    }

    /// Fraction of `section` a track's clips cover (0…1).
    static func coverage(_ t: TrackView, _ sec: Section) -> Double {
        let span = Double(max(1, sec.end - sec.start))
        var covered: [(Int64, Int64)] = []
        for c in t.clips where !c.muted && c.end > sec.start && c.start < sec.end { covered.append((max(c.start, sec.start), min(c.end, sec.end))) }
        covered.sort { $0.0 < $1.0 }
        var total: Int64 = 0, reach = sec.start
        for (a, b) in covered where b > reach { total += b - max(a, reach); reach = b }
        return Double(total) / span
    }

    func reload() {
        sections = Self.sections(session)
        selected = min(selected, max(0, sections.count - 1))
        layoutSubtreeIfNeeded()
        let cols = columns
        axSections = sections.enumerated().map { i, sec in
            AXItem.make(in: self, rect: cols.indices.contains(i) ? cols[i] : .zero, role: .button,
                        label: "\(sec.title), bars \(sec.firstBar) to \(sec.lastBar)") { [weak self] in
                guard let self else { return false }
                self.selected = i
                self.onChoose?(sec)
                return true
            }
        }
        needsDisplay = true
    }
    override func accessibilityChildren() -> [Any]? { axSections }
    override func accessibilityValue() -> Any? { sections.indices.contains(selected) ? sections[selected].title : nil }

    // MARK: Layout
    private let titleH: CGFloat = 50, headerH: CGFloat = 64, rowH: CGFloat = 30, nameW: CGFloat = 170, pad: CGFloat = 16
    private var columns: [CGRect] {
        let total = Double(max(1, (sections.last?.end ?? 1) - (sections.first?.start ?? 0)))
        let x0 = pad + nameW, w = bounds.width - x0 - pad
        let minW: CGFloat = 64
        // Widths follow each section's length, but every section stays readable.
        var widths = sections.map { max(minW, CGFloat(Double($0.end - $0.start) / total) * w) }
        let scale = min(1, w / max(1, widths.reduce(0, +)))
        widths = widths.map { $0 * scale }
        var x = x0
        return widths.map { wd in defer { x += wd }; return CGRect(x: x, y: pad + titleH, width: wd, height: bounds.height - 2 * pad - titleH) }
    }
    private func column(at p: CGPoint) -> Int? { columns.firstIndex { $0.minX <= p.x && p.x < $0.maxX } }

    // MARK: Drawing
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let family = Theme.look.arrangement
        switch family {
        case .glass: Prism.drawField(in: self, frosted: false); Prism.liquidPane(self, bounds.insetBy(dx: 4, dy: 4), radius: 16)
        case .manuscript: Theme.laneA.setFill(); bounds.fill()
        case .flat: Theme.panel.setFill(); bounds.fill()
        }
        let titleFont = Theme.title(13, .semibold), noteFont = Theme.note(10.5), figure = Theme.mono(9.5)
        let tracks = session.tracks.filter { !$0.isStack }
        ("Composition" as NSString).draw(at: CGPoint(x: pad + 2, y: pad + 2), withAttributes: [.font: Theme.title(16, .semibold), .foregroundColor: Theme.text])
        let hint = sections.contains(where: \.named) ? "Sections from your markers · click one to go there · Esc returns"
                                                     : "No markers yet: shown in 8-bar ranges · add markers to name sections · Esc returns"
        (hint as NSString).draw(at: CGPoint(x: pad + 2, y: pad + 26), withAttributes: [.font: noteFont, .foregroundColor: Theme.textDim])
        let cols = columns
        for (i, (sec, r)) in zip(sections, cols).enumerated() {
            let head = CGRect(x: r.minX, y: r.minY, width: r.width, height: headerH)
            if i == selected {
                switch family {
                case .glass: Prism.slab(ctx, CGRect(x: r.minX + 2, y: r.minY, width: r.width - 4, height: r.height), radius: 10, tint: Theme.accent, body: 0.1, lift: 0.6)
                case .manuscript: Atelier.wash(ctx, r.insetBy(dx: 2, dy: 2), color: Theme.cycle, alpha: 0.12, seed: i &* 13)
                                  Atelier.pen(ctx, Atelier.handPoints(CGPoint(x: r.minX + 4, y: r.minY + headerH - 1), CGPoint(x: r.maxX - 4, y: r.minY + headerH - 1), seed: i),
                                              weight: 1.8, color: Atelier.vermilion, seed: i)
                case .flat: Theme.selectedHeader.setFill(); CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height).fill()
                }
            }
            // Section heading: "§ Verse" with its bar range in figures.
            let label = (family == .manuscript && sec.named ? "§ " : "") + sec.title
            ctx.saveGState(); ctx.clip(to: head.insetBy(dx: 4, dy: 0))
            (label as NSString).draw(at: CGPoint(x: head.minX + 8, y: head.minY + 8 + 40 - 28), withAttributes: [.font: titleFont, .foregroundColor: Theme.text])
            ((sec.firstBar == sec.lastBar ? "bar \(sec.firstBar)" : "bars \(sec.firstBar)–\(sec.lastBar)") as NSString).draw(at: CGPoint(x: head.minX + 8, y: head.minY + 40), withAttributes: [.font: figure, .foregroundColor: Theme.textDim])
            ctx.restoreGState()
            // Column rule.
            ctx.setFillColor(Theme.ink(family == .manuscript ? 0.25 : 0.08).cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.minY + 8, width: family == .manuscript && i % 4 == 0 ? 0.75 : 0.5, height: r.height - 8))
        }
        // Rows: name, then per section a coverage bar and a volume sparkline.
        for (k, t) in tracks.enumerated() {
            let y = pad + titleH + headerH + 8 + CGFloat(k) * rowH
            guard y + rowH <= bounds.height - pad else { break }
            if family == .manuscript {
                Atelier.pen(ctx, Atelier.handPoints(CGPoint(x: pad + 3.5, y: y + 6), CGPoint(x: pad + 3.5, y: y + rowH - 6), seed: Int(truncatingIfNeeded: t.id)), weight: 3, color: t.color, seed: 1)
            } else { ctx.setFillColor(t.color.cgColor); ctx.fill(CGRect(x: pad + 2, y: y + 6, width: 3, height: rowH - 12)) }
            (t.name as NSString).draw(at: CGPoint(x: pad + 12, y: y + 7), withAttributes: [.font: Theme.title(11.5, .semibold), .foregroundColor: t.muted ? Theme.textFaint : Theme.text])
            ctx.setFillColor(Theme.ink(0.06).cgColor); ctx.fill(CGRect(x: pad, y: y + rowH - 0.5, width: bounds.width - 2 * pad, height: 0.5))
            for (sec, r) in zip(sections, cols) {
                let cov = Self.coverage(t, sec)
                let bar = CGRect(x: r.minX + 6, y: y + 9, width: max(0, (r.width - 12) * CGFloat(cov)), height: rowH - 18)
                if cov > 0 {
                    switch family {
                    case .glass: Prism.slab(ctx, bar, radius: bar.height / 2, tint: t.color, body: 0.25)
                    case .manuscript: let bs = Int(truncatingIfNeeded: t.id) &* 17 &+ Int(bar.minX)
                                      Atelier.hatch(ctx, bar, spacing: 3, color: t.color.withAlphaComponent(0.6), weight: 0.7, seed: bs)
                                      Atelier.box(ctx, bar.insetBy(dx: 0.5, dy: 0.5), weight: Atelier.fine, color: t.color, seed: bs, overshoot: 2.5)
                    case .flat: ctx.setFillColor(t.color.withAlphaComponent(0.55).cgColor); ctx.fill(bar)
                    }
                }
                drawAutomation(ctx, t.volumeAuto, sec, in: CGRect(x: r.minX + 6, y: y + 4, width: r.width - 12, height: rowH - 8), color: t.color)
            }
        }
        if window?.firstResponder === self, cols.indices.contains(selected) {
            if family == .manuscript { // the chosen section: a double rule in the codex's red, heavy then fine
                Atelier.box(ctx, cols[selected].insetBy(dx: 2, dy: 2), weight: Atelier.heavy, color: Atelier.vermilion)
                Atelier.box(ctx, cols[selected].insetBy(dx: 5, dy: 5), weight: Atelier.hair, color: Atelier.vermilion)
            }
            else {
                ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(2)
                ctx.stroke(cols[selected].insetBy(dx: 2, dy: 2))
            }
        }
    }

    /// Volume automation inside a section as a sparkline (amplitude^(1/4) values, as stored).
    private func drawAutomation(_ ctx: CGContext, _ pts: [DalnokAutoPoint], _ sec: Section, in r: CGRect, color: NSColor) {
        guard pts.count >= 2 else { return }
        func value(at f: Int64) -> Double {
            guard let i = pts.firstIndex(where: { $0.frame >= f }) else { return Double(pts.last!.value) }
            if i == 0 { return Double(pts[0].value) }
            let a = pts[i - 1], b = pts[i], u = Double(f - a.frame) / Double(max(1, b.frame - a.frame))
            return Double(a.value) + (Double(b.value) - Double(a.value)) * u
        }
        let inside = pts.filter { $0.frame > sec.start && $0.frame < sec.end }
        let first = value(at: sec.start), last = value(at: sec.end)
        guard !inside.isEmpty || abs(first - last) > 1e-4 else { return }
        let path = CGMutablePath()
        let span = Double(max(1, sec.end - sec.start))
        for (i, f) in ([sec.start] + inside.map(\.frame) + [sec.end]).enumerated() {
            let p = CGPoint(x: r.minX + r.width * CGFloat(Double(f - sec.start) / span), y: r.maxY - r.height * CGFloat(min(1, max(0, value(at: f)))))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.addPath(path); ctx.setStrokeColor(OKLCH.adjust(color, dl: Theme.isLight ? -0.2 : 0.15, chromaScale: 1).cgColor); ctx.setLineWidth(1.25); ctx.strokePath()
    }

    // MARK: Interaction
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let i = column(at: convert(event.locationInWindow, from: nil)), sections.indices.contains(i) else { return }
        selected = i
        if event.clickCount >= 1 { onChoose?(sections[i]) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: selected = max(0, selected - 1)
        case .rightArrow?: selected = min(max(0, sections.count - 1), selected + 1)
        case .carriageReturn?, .enter?: if sections.indices.contains(selected) { onChoose?(sections[selected]) }
        default:
            if event.keyCode == 53 { onClose?(); return } // Esc
            if !forwardShortcut(event) { super.keyDown(with: event) }
        }
    }
    override func cancelOperation(_ sender: Any?) { onClose?() }
}
