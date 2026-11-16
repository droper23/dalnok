// Arrangement timeline: ruler, track lanes, clips with waveforms, playhead,
// selection, and clip move/trim with snapping.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine
import QuartzCore

@MainActor
final class TimelineView: NSView {
    let session: Session
    var sampleRate: Double { session.engine.sampleRate }

    /// Leftmost visible timeline frame and zoom (frames per point).
    var scrollFrame: Double = 0 { didSet { if scrollFrame < 0 { scrollFrame = 0 }; needsDisplay = true; updatePlayhead() } }
    var framesPerPoint: Double = 480 { didSet { needsDisplay = true; updatePlayhead() } }
    var scrollY: CGFloat = 0 { didSet { needsDisplay = true; onVerticalScroll?(scrollY) } }
    var onVerticalScroll: ((CGFloat) -> Void)?
    var onSeek: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    var selectedClip: DalnokClipId? { didSet { needsDisplay = true; onSelectionChange?() } }
    var onClipSelected: ((ClipView) -> Void)?
    private var hoveredClip: DalnokClipId? { didSet { if hoveredClip != oldValue { needsDisplay = true } } }

    private let playheadLayer = CALayer()
    private var mins: [Float] = [], maxs: [Float] = []

    private enum Zone { case body, leftEdge, rightEdge, fadeIn, fadeOut }
    private let titleH: CGFloat = 16
    private let fadeHandleZone: CGFloat = 14
    private struct Drag {
        let clip: ClipView
        let zone: Zone
        let startX: CGFloat
        var changed = false
        var stretch = false // ⌥-drag on the right edge: time-stretch instead of trim
    }
    private var drag: Drag?
    private let edgeWidth: CGFloat = 7

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.laneA.cgColor
        playheadLayer.backgroundColor = Theme.playhead.cgColor
        playheadLayer.zPosition = 10
        layer?.addSublayer(playheadLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func xPos(forFrame f: Double) -> CGFloat { CGFloat((f - scrollFrame) / framesPerPoint) }
    func frame(forX x: CGFloat) -> Double { scrollFrame + Double(x) * framesPerPoint }
    func laneY(_ index: Int) -> CGFloat { Theme.rulerHeight + CGFloat(index) * Theme.trackHeight - scrollY }
    func trackIndex(atY y: CGFloat) -> Int? {
        guard y >= Theme.rulerHeight else { return nil }
        let i = Int(floor((y - Theme.rulerHeight + scrollY) / Theme.trackHeight))
        return i >= 0 && i < session.tracks.count ? i : nil
    }

    func zoomToFit() {
        let len = Double(max(session.length, Int64(sampleRate * 10)))
        framesPerPoint = max(1, len * 1.05 / Double(max(bounds.width, 200)))
        scrollFrame = 0
    }

    // MARK: Playhead

    func updatePlayhead() {
        let x = xPos(forFrame: Double(session.engine.position))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.frame = CGRect(x: x - 0.75, y: 0, width: 1.5, height: bounds.height)
        playheadLayer.isHidden = x < -2 || x > bounds.width + 2
        CATransaction.commit()
    }

    /// Page-follow while playing.
    func followPlayhead() {
        guard session.engine.isPlaying, drag == nil else { return }
        let x = xPos(forFrame: Double(session.engine.position))
        if x > bounds.width - 24 || x < 0 {
            scrollFrame = Double(session.engine.position) - 24 * framesPerPoint
        }
    }

    // MARK: Grid & snapping

    /// A "nice" ruler step in seconds so labels sit >= ~90 pt apart.
    func gridStep() -> Double {
        let target = framesPerPoint / sampleRate * 90
        let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { $0 >= target } ?? 600
    }

    /// Snaps to the minor grid (a quarter of the ruler step). Hold Control to bypass.
    func snap(_ frame: Double, bypass: Bool) -> Int64 {
        let f = max(0, frame)
        guard !bypass else { return Int64(f.rounded()) }
        let q = gridStep() / 4 * sampleRate
        return Int64((f / q).rounded() * q)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        drawLanes(ctx)
        drawGrid(ctx, scale: scale)
        for (i, track) in session.tracks.enumerated() {
            let y = laneY(i)
            guard y + Theme.trackHeight > Theme.rulerHeight, y < bounds.height else { continue }
            for clip in track.clips { drawClip(ctx, clip, track: track, laneY: y, scale: scale) }
        }
        drawRuler(ctx, scale: scale)
        if session.tracks.isEmpty { drawEmptyState() }
    }

    private func drawEmptyState() {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                     .foregroundColor: Theme.textDim, .paragraphStyle: p]
        let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                   .foregroundColor: Theme.textDim.withAlphaComponent(0.7), .paragraphStyle: p]
        let mid = bounds.midY
        ("Drop audio files here" as NSString).draw(in: CGRect(x: 0, y: mid - 22, width: bounds.width, height: 22), withAttributes: title)
        ("or press ⌘I to import  ·  ⌘O to open a project" as NSString)
            .draw(in: CGRect(x: 0, y: mid + 4, width: bounds.width, height: 18), withAttributes: sub)
    }

    private func drawLanes(_ ctx: CGContext) {
        for i in 0..<max(session.tracks.count, 1) {
            let y = laneY(i)
            ctx.setFillColor((i % 2 == 0 ? Theme.laneA : Theme.laneB).cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: Theme.trackHeight))
            ctx.setFillColor(Theme.separator.cgColor)
            ctx.fill(CGRect(x: 0, y: y + Theme.trackHeight - 1, width: bounds.width, height: 1))
        }
    }

    private func drawGrid(_ ctx: CGContext, scale: CGFloat) {
        let step = gridStep()
        var t = floor(frame(forX: 0) / sampleRate / step) * step
        let endT = frame(forX: bounds.width) / sampleRate
        let px = 1 / scale
        while t <= endT {
            let x = (xPos(forFrame: t * sampleRate) * scale).rounded() / scale
            ctx.setFillColor(Theme.gridMajor.cgColor)
            ctx.fill(CGRect(x: x, y: Theme.rulerHeight, width: px, height: bounds.height))
            let mx = xPos(forFrame: (t + step / 2) * sampleRate)
            ctx.setFillColor(Theme.gridMinor.cgColor)
            ctx.fill(CGRect(x: (mx * scale).rounded() / scale, y: Theme.rulerHeight, width: px, height: bounds.height))
            t += step
        }
    }

    private func drawRuler(_ ctx: CGContext, scale: CGFloat) {
        ctx.setFillColor(Theme.panel.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: Theme.rulerHeight))
        ctx.setFillColor(Theme.separator.cgColor)
        ctx.fill(CGRect(x: 0, y: Theme.rulerHeight - 1, width: bounds.width, height: 1))

        let step = gridStep()
        var t = floor(frame(forX: 0) / sampleRate / step) * step
        let endT = frame(forX: bounds.width) / sampleRate
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(10.5), .foregroundColor: Theme.textDim]
        while t <= endT + step {
            let x = xPos(forFrame: t * sampleRate)
            ctx.setFillColor(Theme.textDim.withAlphaComponent(0.6).cgColor)
            ctx.fill(CGRect(x: (x * scale).rounded() / scale, y: Theme.rulerHeight - 9, width: 1 / scale, height: 8))
            for k in 1..<4 {
                let tx = xPos(forFrame: (t + step * Double(k) / 4) * sampleRate)
                ctx.fill(CGRect(x: (tx * scale).rounded() / scale, y: Theme.rulerHeight - 5, width: 1 / scale, height: 4))
            }
            (Self.formatTime(t, step: step) as NSString).draw(at: CGPoint(x: x + 4, y: 6), withAttributes: attrs)
            t += step
        }
    }

    static func formatTime(_ t: Double, step: Double = 0.001) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        if step >= 1 { return String(format: "%d:%02d", m, Int(s.rounded())) }
        if step >= 0.1 { return String(format: "%d:%04.1f", m, s) }
        if step >= 0.01 { return String(format: "%d:%05.2f", m, s) }
        return String(format: "%d:%06.3f", m, s)
    }

    private func clipRect(_ clip: ClipView, laneY: CGFloat) -> CGRect {
        let x0 = xPos(forFrame: Double(clip.start)), x1 = xPos(forFrame: Double(clip.end))
        return CGRect(x: x0, y: laneY + 3, width: max(2, x1 - x0), height: Theme.trackHeight - 7)
    }

    private func drawClip(_ ctx: CGContext, _ clip: ClipView, track: TrackView, laneY: CGFloat, scale: CGFloat) {
        let rect = clipRect(clip, laneY: laneY)
        guard rect.maxX > 0, rect.minX < bounds.width else { return }
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let base = clip.offline ? Theme.textDim : track.color
        let selected = clip.id == selectedClip
        let dim = track.muted || clip.offline

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(base.withAlphaComponent(dim ? 0.08 : (selected ? 0.32 : 0.22)).cgColor)
        ctx.fill(rect)
        ctx.setFillColor(base.withAlphaComponent(dim ? 0.25 : (selected ? 0.95 : 0.75)).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleH))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: Theme.hex(0x101113, 0.9),
        ]
        var title = clip.offline ? "\(clip.name) — offline" : clip.name
        if clip.isStretched {
            var tags: [String] = []
            if abs(clip.rate - 1) > 1e-9 { tags.append(String(format: "%.0f%% speed", clip.rate * 100)) }
            if clip.pitch != 0 { tags.append(String(format: "%+.1f st", clip.pitch)) }
            if !clip.preservePitch { tags.append("varispeed") }
            title += "  " + tags.joined(separator: " ")
        }
        if clip.processing { title += "  · rendering…" }
        (title as NSString).draw(at: CGPoint(x: max(rect.minX, 0) + 6, y: rect.minY + 1.5), withAttributes: attrs)

        if let media = session.engine.poolMedia(clip.media) {
            drawWaveform(ctx, media: media, clip: clip, rect: rect, top: rect.minY + titleH + 2, color: base, dim: dim, scale: scale)
        }
        drawFades(ctx, clip, rect: rect)
        ctx.restoreGState()
        if selected || clip.id == hoveredClip { drawFadeHandles(ctx, clip, rect: rect) }

        ctx.addPath(path)
        ctx.setStrokeColor((selected ? Theme.text : base.withAlphaComponent(0.9)).cgColor)
        ctx.setLineWidth(selected ? 1.5 : 1)
        ctx.strokePath()
    }

    private func fadeWidths(_ c: ClipView, _ rect: CGRect) -> (CGFloat, CGFloat) {
        // Mirror the engine's clamping so what you see is what you hear.
        var fi = min(c.fadeIn, c.length), fo = min(c.fadeOut, c.length)
        if fi + fo > c.length && fi + fo > 0 {
            let k = Double(c.length) / Double(fi + fo)
            fi = Int64(Double(fi) * k); fo = c.length - fi
        }
        return (CGFloat(Double(fi) / framesPerPoint), CGFloat(Double(fo) / framesPerPoint))
    }

    /// Shades the faded-out area above the fade curve and strokes the curve.
    private func drawFades(_ ctx: CGContext, _ c: ClipView, rect: CGRect) {
        let (wi, wo) = fadeWidths(c, rect)
        let top = rect.minY + titleH, bottom = rect.maxY
        func curvePoints(from x0: CGFloat, width w: CGFloat, rising: Bool) -> [CGPoint] {
            let n = max(2, Int(w / 3))
            return (0...n).map { k in
                let u = CGFloat(k) / CGFloat(n)
                let x = rising ? u : 1 - u
                let env = c.fadeCurve == Int32(DALNOK_FADE_EQUAL_POWER.rawValue) ? sin(x * .pi / 2) : x
                return CGPoint(x: x0 + u * w, y: bottom - env * (bottom - top))
            }
        }
        for (w, rising) in [(wi, true), (wo, false)] where w >= 1 {
            let x0 = rising ? rect.minX : rect.maxX - w
            let pts = curvePoints(from: x0, width: w, rising: rising)
            let shade = CGMutablePath()
            shade.move(to: CGPoint(x: x0, y: top))
            shade.addLine(to: CGPoint(x: x0 + w, y: top))
            for p in pts.reversed() { shade.addLine(to: p) }
            shade.closeSubpath()
            ctx.addPath(shade)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
            ctx.fillPath()
            ctx.addLines(between: pts)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(1.25)
            ctx.strokePath()
        }
    }

    private func drawFadeHandles(_ ctx: CGContext, _ c: ClipView, rect: CGRect) {
        let (wi, wo) = fadeWidths(c, rect)
        for x in [rect.minX + max(wi, 4), rect.maxX - max(wo, 4)] {
            let r = CGRect(x: x - 4, y: rect.minY + titleH - 4, width: 8, height: 8)
            ctx.setFillColor(Theme.text.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(Theme.window.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: r)
        }
    }

    /// One min/max column per device pixel across the visible span.
    private func drawWaveform(_ ctx: CGContext, media: OpaquePointer, clip: ClipView, rect: CGRect, top: CGFloat,
                              color: NSColor, dim: Bool, scale: CGFloat) {
        let visX0 = max(rect.minX, 0), visX1 = min(rect.maxX, bounds.width)
        let columns = Int(((visX1 - visX0) * scale).rounded(.up))
        guard columns > 0 else { return }
        if mins.count < columns { mins = [Float](repeating: 0, count: columns); maxs = mins }
        // Stretched clips draw their source at `rate` source frames per timeline frame.
        let fpc = framesPerPoint / Double(scale) * clip.rate
        let sourceStart = Int64((frame(forX: visX0) - Double(clip.start)) * clip.rate) + clip.offset
        let waveH = rect.maxY - top - 3
        let chans = min(Int(dalnok_media_channels(media)), 2)
        let laneH = waveH / CGFloat(chans)
        ctx.setStrokeColor(color.blended(withFraction: 0.35, of: .white)!.withAlphaComponent(dim ? 0.3 : 0.95).cgColor)
        ctx.setLineWidth(1 / scale)
        for ch in 0..<chans {
            dalnok_media_peaks(media, Int32(ch), sourceStart, fpc, &mins, &maxs, Int64(columns))
            let mid = top + laneH * (CGFloat(ch) + 0.5)
            let half = laneH * 0.48
            for i in 0..<columns {
                let px = visX0 + (CGFloat(i) + 0.5) / scale
                var t = mid - CGFloat(maxs[i]) * half, b = mid - CGFloat(mins[i]) * half
                if b - t < 1 / scale { t = mid - 0.5 / scale; b = mid + 0.5 / scale }
                ctx.move(to: CGPoint(x: px, y: t))
                ctx.addLine(to: CGPoint(x: px, y: b))
            }
            ctx.strokePath()
        }
    }

    // MARK: Hit testing

    private func hit(_ p: CGPoint) -> (ClipView, Zone)? {
        guard let ti = trackIndex(atY: p.y) else { return nil }
        let track = session.tracks[ti]
        // Topmost clip first.
        for clip in track.clips.reversed() {
            let r = clipRect(clip, laneY: laneY(ti))
            guard r.insetBy(dx: -2, dy: 0).contains(p) else { continue }
            let edge = min(edgeWidth, r.width / 3)
            if p.y <= r.minY + titleH + 4 {
                let (wi, wo) = fadeWidths(clip, r)
                let zone = min(fadeHandleZone, r.width / 3)
                if abs(p.x - (r.minX + max(wi, 4))) <= zone / 2 || p.x <= r.minX + zone { return (clip, .fadeIn) }
                if abs(p.x - (r.maxX - max(wo, 4))) <= zone / 2 || p.x >= r.maxX - zone { return (clip, .fadeOut) }
            }
            if p.x <= r.minX + edge { return (clip, .leftEdge) }
            if p.x >= r.maxX - edge { return (clip, .rightEdge) }
            return (clip, .body)
        }
        return nil
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let h = hit(p)
        hoveredClip = h?.0.id
        switch h?.1 {
        case .leftEdge?, .rightEdge?: NSCursor.resizeLeftRight.set()
        case .fadeIn?, .fadeOut?: NSCursor.crosshair.set()
        case .body?: NSCursor.openHand.set()
        case nil: NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y < Theme.rulerHeight { seek(toX: p.x); return }
        guard let (clip, zone) = hit(p) else {
            selectedClip = nil
            seek(toX: p.x)
            return
        }
        selectedClip = clip.id
        onClipSelected?(clip)
        let stretch = zone == .rightEdge && event.modifierFlags.contains(.option)
        drag = Drag(clip: clip, zone: zone, startX: p.x, stretch: stretch)
        session.engine.beginGroup(stretch ? "Time Stretch" : zone == .body ? "Move Clip"
                                  : (zone == .fadeIn || zone == .fadeOut) ? "Fade" : "Trim Clip")
        if zone == .body { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard var d = drag else {
            if p.y < Theme.rulerHeight { seek(toX: p.x) }
            return
        }
        let bypass = event.modifierFlags.contains(.control)
        let delta = Double(p.x - d.startX) * framesPerPoint
        let c = d.clip
        guard let current = session.clip(c.id) else { return }
        switch d.zone {
        case .body:
            let start = snap(Double(c.start) + delta, bypass: bypass)
            let track = trackIndex(atY: p.y).map { session.tracks[$0].id } ?? current.track
            if start != current.start || track != current.track {
                session.moveClip(c.id, track: track, start: start)
                d.changed = true
            }
        case .leftEdge:
            // Keep the right edge fixed; reveal or hide audio on the left.
            var start = snap(Double(c.start) + delta, bypass: bypass)
            start = max(start, c.start - c.offset)            // can't reveal before media start
            start = min(start, c.end - 1)                      // keep at least one frame
            let offset = c.offset + (start - c.start)
            if start != current.start {
                session.setRegion(c.id, start: start, offset: offset, length: c.end - start)
                d.changed = true
            }
        case .fadeIn, .fadeOut:
            // Fades are not snapped; they follow the mouse exactly.
            let curve = DalnokFadeCurve(rawValue: UInt32(current.fadeCurve))
            if d.zone == .fadeIn {
                let len = Int64(max(0, frame(forX: p.x) - Double(current.start)))
                let fi = min(len, current.length - current.fadeOut)
                if fi != current.fadeIn {
                    session.setFades(c.id, fadeIn: fi, fadeOut: current.fadeOut, curve: curve)
                    d.changed = true
                }
            } else {
                let len = Int64(max(0, Double(current.end) - frame(forX: p.x)))
                let fo = min(len, current.length - current.fadeIn)
                if fo != current.fadeOut {
                    session.setFades(c.id, fadeIn: current.fadeIn, fadeOut: fo, curve: curve)
                    d.changed = true
                }
            }
        case .rightEdge where d.stretch:
            // Keep the same source audio, change its timeline length (rate = source span / length).
            var end = snap(Double(c.end) + delta, bypass: bypass)
            end = max(end, c.start + max(1, Int64(Double(c.sourceSpan) / 20)))
            end = min(end, c.start + c.sourceSpan * 20)
            let length = end - c.start
            if length != current.length {
                session.setStretch(c.id, length: length, rate: Double(c.sourceSpan) / Double(length), pitch: c.pitch,
                                   preservePitch: c.preservePitch)
                d.changed = true
            }
        case .rightEdge:
            var end = snap(Double(c.end) + delta, bypass: bypass)
            end = min(end, c.start + (c.mediaFrames - c.offset)) // can't extend past media end
            end = max(end, c.start + 1)
            if end != current.end {
                session.setRegion(c.id, start: c.start, offset: c.offset, length: end - c.start)
                d.changed = true
            }
        }
        drag = d
    }

    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        session.engine.endGroup()
        drag = nil
        mouseMoved(with: event)
        onSelectionChange?()
    }

    private func seek(toX x: CGFloat) {
        session.engine.seek(Int64(max(0, frame(forX: x))))
        updatePlayhead()
        onSeek?()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            zoom(by: exp(-event.scrollingDeltaY * 0.01), around: convert(event.locationInWindow, from: nil).x)
            return
        }
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        scrollFrame -= Double(dx) * framesPerPoint
        if event.modifierFlags.contains(.shift) && dx == 0 {
            scrollFrame -= Double(dy) * framesPerPoint
        } else {
            let content = CGFloat(session.tracks.count) * Theme.trackHeight
            scrollY = min(max(0, scrollY - dy), max(0, content - (bounds.height - Theme.rulerHeight)))
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 / (1 + event.magnification), around: convert(event.locationInWindow, from: nil).x)
    }

    func zoom(by factor: Double, around x: CGFloat) {
        let anchor = frame(forX: x)
        framesPerPoint = min(max(framesPerPoint * factor, 0.25), sampleRate * 10)
        scrollFrame = anchor - Double(x) * framesPerPoint
    }

    /// Window-coordinate center of a clip (used by the self-test to synthesize drags).
    func windowPoint(ofClip id: DalnokClipId, zone: String = "body") -> CGPoint? {
        for (i, t) in session.tracks.enumerated() {
            guard let c = t.clips.first(where: { $0.id == id }) else { continue }
            let r = clipRect(c, laneY: laneY(i))
            if zone == "fadeIn" { return convert(CGPoint(x: r.minX + 4, y: r.minY + titleH - 2), to: nil) }
            if zone == "fadeOut" { return convert(CGPoint(x: r.maxX - 4, y: r.minY + titleH - 2), to: nil) }
            let x = zone == "left" ? r.minX + 2 : zone == "right" ? r.maxX - 2 : min(max(r.midX, 10), bounds.width - 10)
            return convert(CGPoint(x: x, y: r.midY), to: nil)
        }
        return nil
    }

    override func layout() {
        super.layout()
        updatePlayhead()
    }
}
