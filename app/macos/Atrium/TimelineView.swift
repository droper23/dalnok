// Arrangement timeline: ruler, track lanes, clips with waveforms, playhead.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import QuartzCore

@MainActor
final class TimelineView: NSView {
    let session: Session
    var sampleRate: Double { session.engine.sampleRate }

    /// Leftmost visible timeline frame and zoom (frames per point).
    var scrollFrame: Double = 0 { didSet { clampScroll(); needsDisplay = true; updatePlayhead() } }
    var framesPerPoint: Double = 480 { didSet { needsDisplay = true; updatePlayhead() } }
    var scrollY: CGFloat = 0 { didSet { needsDisplay = true; onVerticalScroll?(scrollY) } }
    var onVerticalScroll: ((CGFloat) -> Void)?
    var onSeek: (() -> Void)?

    private let playheadLayer = CALayer()
    private var mins: [Float] = [], maxs: [Float] = []

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

    private func clampScroll() {
        if scrollFrame < 0 { scrollFrame = 0 }
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
        guard session.engine.isPlaying else { return }
        let x = xPos(forFrame: Double(session.engine.position))
        if x > bounds.width - 24 || x < 0 {
            scrollFrame = Double(session.engine.position) - 24 * framesPerPoint
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = window?.backingScaleFactor ?? 2
        drawLanes(ctx)
        drawGrid(ctx, scale: scale)
        for (i, track) in session.tracks.enumerated() {
            let laneY = Theme.rulerHeight + CGFloat(i) * Theme.trackHeight - scrollY
            guard laneY + Theme.trackHeight > Theme.rulerHeight, laneY < bounds.height else { continue }
            for clip in track.clips { drawClip(ctx, clip, track: track, laneY: laneY, scale: scale) }
        }
        drawRuler(ctx, scale: scale)
    }

    private func drawLanes(_ ctx: CGContext) {
        for i in 0..<max(session.tracks.count, 1) {
            let y = Theme.rulerHeight + CGFloat(i) * Theme.trackHeight - scrollY
            ctx.setFillColor((i % 2 == 0 ? Theme.laneA : Theme.laneB).cgColor)
            ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: Theme.trackHeight))
            ctx.setFillColor(Theme.separator.cgColor)
            ctx.fill(CGRect(x: 0, y: y + Theme.trackHeight - 1, width: bounds.width, height: 1))
        }
    }

    /// Picks a "nice" grid step in seconds so labels sit >= ~90 pt apart.
    private func gridStep() -> Double {
        let secondsPerPoint = framesPerPoint / sampleRate
        let target = secondsPerPoint * 90
        let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { $0 >= target } ?? 600
    }

    private func drawGrid(_ ctx: CGContext, scale: CGFloat) {
        let step = gridStep()
        let first = floor(frame(forX: 0) / sampleRate / step) * step
        var t = first
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

    private func drawClip(_ ctx: CGContext, _ clip: ClipModel, track: TrackModel, laneY: CGFloat, scale: CGFloat) {
        let x0 = xPos(forFrame: Double(clip.start)), x1 = xPos(forFrame: Double(clip.start + clip.length))
        guard x1 > 0, x0 < bounds.width else { return }
        let rect = CGRect(x: x0, y: laneY + 3, width: max(2, x1 - x0), height: Theme.trackHeight - 7)
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let base = track.color

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(base.withAlphaComponent(track.muted ? 0.08 : 0.22).cgColor)
        ctx.fill(rect)
        // Title strip
        let titleH: CGFloat = 16
        ctx.setFillColor(base.withAlphaComponent(track.muted ? 0.25 : 0.75).cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleH))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: Theme.hex(0x101113, 0.9),
        ]
        (clip.media.name as NSString).draw(at: CGPoint(x: max(rect.minX, 0) + 6, y: rect.minY + 1.5), withAttributes: attrs)

        // Waveform: one min/max column per device pixel across the visible span.
        let visX0 = max(x0, 0), visX1 = min(x1, bounds.width)
        let columns = Int(((visX1 - visX0) * scale).rounded(.up))
        if columns > 0 {
            let fpc = framesPerPoint / Double(scale)
            let startFrame = Int64(frame(forX: visX0)) - clip.start
            let waveTop = rect.minY + titleH + 2, waveH = rect.maxY - waveTop - 3
            let chans = min(clip.media.channels, 2)
            let laneH = waveH / CGFloat(chans)
            ctx.setStrokeColor(base.blended(withFraction: 0.35, of: .white)!.withAlphaComponent(track.muted ? 0.3 : 0.95).cgColor)
            ctx.setLineWidth(1 / scale)
            for ch in 0..<chans {
                clip.media.peaks(channel: ch, start: startFrame, framesPerColumn: fpc, count: columns, mins: &mins, maxs: &maxs)
                let mid = waveTop + laneH * (CGFloat(ch) + 0.5)
                let half = laneH * 0.48
                for i in 0..<columns {
                    let px = visX0 + (CGFloat(i) + 0.5) / scale
                    var top = mid - CGFloat(maxs[i]) * half, bot = mid - CGFloat(mins[i]) * half
                    if bot - top < 1 / scale { top = mid - 0.5 / scale; bot = mid + 0.5 / scale }
                    ctx.move(to: CGPoint(x: px, y: top))
                    ctx.addLine(to: CGPoint(x: px, y: bot))
                }
                ctx.strokePath()
            }
        }
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(base.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    // MARK: Interaction

    override func mouseDown(with event: NSEvent) { seek(to: event) }
    override func mouseDragged(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y < Theme.rulerHeight { seek(to: event) }
    }

    private func seek(to event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        session.engine.seek(Int64(max(0, frame(forX: p.x))))
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

    override func layout() {
        super.layout()
        updatePlayhead()
    }
}
