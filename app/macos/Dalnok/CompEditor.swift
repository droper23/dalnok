// Comp Editor: a take folder's takes as lanes. Swipe across a take to use it there (Quick Swipe Comping);
// click a take's name to use the whole take. The comp row at the bottom shows what plays. Each swipe is
// one undo step ("Comp"). Opened by double-clicking a comp in the arrangement or Clip ▸ Open Take Folder.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class CompEditorController: NSWindowController {
    let view: CompView
    init(session: Session) {
        view = CompView(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.window
        window.minSize = NSSize(width: 520, height: 220)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DalnokCompEditor")
        window.contentView = view
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(folder: Int32) {
        view.folder = folder
        view.fit()
        modelChanged()
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
    func modelChanged() {
        guard window?.isVisible == true || view.folder != 0 else { return }
        let track = view.trackView
        window?.title = "Takes — \(track?.name ?? "Track")"
        window?.subtitle = "\(view.takes.count) takes · swipe across a take to use it there · click a take's name for all of it"
        view.needsDisplay = true
    }
}

@MainActor
final class CompView: NSView {
    let session: Session
    var folder: Int32 = 0 { didSet { needsDisplay = true } }
    static let header: CGFloat = 92, ruler: CGFloat = 22, lane: CGFloat = 54, compLane: CGFloat = 40
    private var startFrame: Double = 0, framesPerPoint: Double = 100
    private var swipe: (take: Int, from: CGFloat, to: CGFloat)?

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        setAccessibilityLabel("Take folder")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var takes: [ClipView] { folder == 0 ? [] : session.takes(folder) }
    var trackView: TrackView? { takes.first.flatMap { session.track($0.track) } }
    private var span: (Int64, Int64) {
        let t = takes
        return (t.map(\.start).min() ?? 0, t.map(\.end).max() ?? 1)
    }
    /// Shows the folder's whole span with a little room on each side.
    func fit() {
        let (a, b) = span
        let width = max(200, bounds.width - Self.header - 24)
        framesPerPoint = max(1, Double(b - a) / Double(width))
        startFrame = Double(a) - 12 * framesPerPoint
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); fit() }

    func x(_ frame: Double) -> CGFloat { Self.header + CGFloat((frame - startFrame) / framesPerPoint) }
    func frame(atX x: CGFloat) -> Double { startFrame + Double(x - Self.header) * framesPerPoint }
    func laneTop(_ i: Int) -> CGFloat { Self.ruler + CGFloat(i) * Self.lane }
    var compTop: CGFloat { laneTop(takes.count) + 6 }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.laneA.setFill(); bounds.fill()
        let takes = self.takes, comp = session.comp(folder)
        let tint = TrackTint(base: trackView?.color ?? Theme.accent)
        drawRuler(ctx)
        for (i, take) in takes.enumerated() {
            let top = laneTop(i)
            (i % 2 == 0 ? Theme.laneA : Theme.laneB).setFill()
            CGRect(x: 0, y: top, width: bounds.width, height: Self.lane).fill()
            let r = CGRect(x: x(Double(take.start)), y: top + 4, width: CGFloat(Double(take.length) / framesPerPoint), height: Self.lane - 8)
            // The take, dim; the parts the comp uses, bright.
            ctx.setFillColor((Theme.look.tapeEditors ? Theme.hex(0x3A281C) : tint.body.withAlphaComponent(0.35)).cgColor); ctx.fill(r)
            if Theme.look.tapeEditors { // tape edges catch the light
                ctx.setFillColor(Theme.hex(0x6A4C36, 0.8).cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1)); ctx.fill(CGRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1))
            }
            for seg in comp where Int(seg.take) == i {
                let s = CGRect(x: x(Double(seg.from)), y: r.minY, width: CGFloat(Double(seg.to - seg.from) / framesPerPoint), height: r.height)
                ctx.setFillColor(tint.base.withAlphaComponent(0.85).cgColor); ctx.fill(s)
            }
            drawPeaks(ctx, take, in: r, color: Theme.hex(0xFFFFFF, 0.75))
            ctx.setStrokeColor(tint.border.cgColor); ctx.setLineWidth(1); ctx.stroke(r)
            if let sw = swipe, sw.take == i {
                let a = min(sw.from, sw.to), b = max(sw.from, sw.to)
                ctx.setFillColor(Theme.selection.withAlphaComponent(0.25).cgColor)
                ctx.fill(CGRect(x: a, y: r.minY, width: b - a, height: r.height))
                if Theme.look.tapeEditors { for x in [a, b] { cutLine(ctx, x: x, top: r.minY - 3, bottom: r.maxY + 3) } } // the razor
            }
            // Header: take name (click for the whole take).
            Theme.panelRaised.setFill(); CGRect(x: 0, y: top, width: Self.header - 1, height: Self.lane).fill()
            let used = comp.contains { Int($0.take) == i }
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(12, .semibold), .foregroundColor: used ? Theme.text : Theme.textDim]
            ("Take \(i + 1)" as NSString).draw(at: CGPoint(x: 12, y: top + 10), withAttributes: attrs)
            (TimelineView.formatTime(Double(take.length) / session.engine.sampleRate, step: 0.1) as NSString)
                .draw(at: CGPoint(x: 12, y: top + 28), withAttributes: [.font: Theme.mono(9.5), .foregroundColor: Theme.textFaint])
        }
        // The comp: which take plays where.
        let top = compTop
        Theme.panel.setFill(); CGRect(x: 0, y: top, width: bounds.width, height: Self.compLane).fill()
        ("COMP" as NSString).draw(at: CGPoint(x: 12, y: top + 12), withAttributes: [.font: Theme.mono(10, .semibold), .foregroundColor: Theme.accent])
        if Theme.look.tapeEditors { // the splicing block the comp is assembled on
            let block = CGRect(x: Self.header, y: top + 3, width: bounds.width - Self.header, height: Self.compLane - 6)
            ctx.setFillColor(Theme.hex(0x6E665D).cgColor); ctx.fill(block)
            ctx.setFillColor(Theme.hex(0x4A443E).cgColor); ctx.fill(CGRect(x: block.minX, y: block.midY - 0.5, width: block.width, height: 1))
        }
        for seg in comp {
            let s = CGRect(x: x(Double(seg.from)), y: top + 6, width: CGFloat(Double(seg.to - seg.from) / framesPerPoint), height: Self.compLane - 12)
            ctx.setFillColor(tint.base.cgColor); ctx.fill(s)
            if Theme.look.tapeEditors, seg.from > comp.map(\.from).min() ?? seg.from { // a splice: diagonal cut under a strip of splicing tape
                ctx.setStrokeColor(Theme.hex(0x1A120C, 0.8).cgColor); ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: s.minX - 4, y: s.maxY)); ctx.addLine(to: CGPoint(x: s.minX + 4, y: s.minY)); ctx.strokePath()
                ctx.setFillColor(Theme.hex(0xF2EBDD, 0.45).cgColor)
                ctx.fill(CGRect(x: s.minX - 6, y: s.minY + 4, width: 12, height: s.height - 8))
            } else if !Theme.look.tapeEditors {
                ctx.setStrokeColor(Theme.panel.cgColor); ctx.setLineWidth(1); ctx.stroke(s)
            }
            if s.width > 24 {
                ("\(seg.take + 1)" as NSString).draw(at: CGPoint(x: s.minX + 5, y: s.minY + 5),
                                                     withAttributes: [.font: Theme.mono(10, .semibold), .foregroundColor: TrackTint.textColor(on: tint.base)])
            }
        }
        Theme.separator.setFill(); CGRect(x: Self.header - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    /// Warm Analog: a razor cut at x (a 45° line as on a splicing block, with a bright edge).
    private func cutLine(_ ctx: CGContext, x: CGFloat, top: CGFloat, bottom: CGFloat) {
        let lean = (bottom - top) * 0.18
        ctx.setStrokeColor(NSColor(white: 0.92, alpha: 0.9).cgColor); ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: x + lean, y: top)); ctx.addLine(to: CGPoint(x: x - lean, y: bottom)); ctx.strokePath()
        ctx.setStrokeColor(Theme.recordOn.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: x + lean + 1.5, y: top)); ctx.addLine(to: CGPoint(x: x - lean + 1.5, y: bottom)); ctx.strokePath()
    }

    private func drawRuler(_ ctx: CGContext) {
        Theme.panel.setFill(); CGRect(x: 0, y: 0, width: bounds.width, height: Self.ruler).fill()
        let first = session.bar(atBeat: session.frameToBeat(frame(atX: Self.header))).bar
        var bar = max(0, first)
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(10), .foregroundColor: Theme.textDim]
        while bar < first + 1_000 {
            let px = x(session.beatToFrame(session.barToBeat(bar)))
            if px > bounds.width { break }
            if px >= Self.header {
                Theme.textFaint.setFill(); CGRect(x: px, y: 4, width: 1, height: Self.ruler - 5).fill()
                ("\(bar + 1)" as NSString).draw(at: CGPoint(x: px + 4, y: 4), withAttributes: attrs)
            }
            bar += 1
        }
    }

    private func drawPeaks(_ ctx: CGContext, _ take: ClipView, in r: CGRect, color: NSColor) {
        guard let media = dalnok_pool_media(session.engine.handle, take.media), r.width >= 1 else { return }
        let columns = Int(r.width.rounded(.down))
        var mins = [Float](repeating: 0, count: columns), maxs = mins
        _ = dalnok_media_peaks(media, 0, take.offset, Double(take.length) / Double(columns), &mins, &maxs, Int64(columns))
        ctx.setFillColor(color.cgColor)
        let mid = r.midY, half = r.height / 2 - 2
        for c in 0..<columns {
            let lo = CGFloat(max(-1, mins[c])), hi = CGFloat(min(1, maxs[c]))
            ctx.fill(CGRect(x: r.minX + CGFloat(c), y: mid - hi * half, width: 1, height: max(1, (hi - lo) * half)))
        }
    }

    // MARK: Swipe comping

    private func takeIndex(atY y: CGFloat) -> Int? {
        let i = Int(((y - Self.ruler) / Self.lane).rounded(.down))
        return i >= 0 && i < takes.count && y >= Self.ruler ? i : nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = takeIndex(atY: p.y) else { return }
        if p.x < Self.header { useWholeTake(i); return }
        swipe = (i, p.x, p.x)
    }
    override func mouseDragged(with event: NSEvent) {
        guard var s = swipe else { return }
        s.to = convert(event.locationInWindow, from: nil).x
        swipe = s
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let s = swipe else { return }
        swipe = nil
        let bypass = event.modifierFlags.contains(.control)
        if abs(s.to - s.from) < 3 { needsDisplay = true; return }
        let a = snap(frame(atX: min(s.from, s.to)), bypass: bypass), b = snap(frame(atX: max(s.from, s.to)), bypass: bypass)
        use(take: s.take, from: a, to: b)
    }

    /// Paints [from, to) of the comp with `take` (clamped to the take), keeping the rest.
    func use(take: Int, from: Int64, to: Int64) {
        guard takes.indices.contains(take) else { return }
        let t = takes[take]
        let a = max(from, t.start), b = min(to, t.end)
        guard b > a else { NSSound.beep(); return }
        var next: [DalnokCompSegment] = []
        for seg in session.comp(folder) {
            if seg.to <= a || seg.from >= b { next.append(seg); continue }
            if seg.from < a { next.append(DalnokCompSegment(from: seg.from, to: a, take: seg.take)) }
            if seg.to > b { next.append(DalnokCompSegment(from: b, to: seg.to, take: seg.take)) }
        }
        next.append(DalnokCompSegment(from: a, to: b, take: Int32(take)))
        next.sort { $0.from < $1.from }
        // Merge neighbors that use the same take.
        var merged: [DalnokCompSegment] = []
        for seg in next {
            if var last = merged.last, last.take == seg.take, last.to == seg.from { last.to = seg.to; merged[merged.count - 1] = last }
            else { merged.append(seg) }
        }
        if !session.setComp(folder, merged) { NSSound.beep() }
        needsDisplay = true
    }
    func useWholeTake(_ i: Int) {
        guard takes.indices.contains(i) else { return }
        use(take: i, from: takes[i].start, to: takes[i].end)
    }

    /// Snaps to the arrangement's 16th-note grid.
    private func snap(_ f: Double, bypass: Bool) -> Int64 {
        guard !bypass else { return Int64(f.rounded()) }
        let beat = session.frameToBeat(f)
        return Int64(session.beatToFrame((beat * 4).rounded() / 4).rounded())
    }
}
