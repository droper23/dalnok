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
    var scrollY: CGFloat = 0 { didSet { if scrollY != oldValue { needsDisplay = true; onVerticalScroll?(scrollY) } } }
    /// Largest vertical offset that still shows tracks (the track list is one shared vertical viewport).
    var maxScrollY: CGFloat {
        max(0, session.lanesHeight - max(0, bounds.height - Theme.rulerHeight))
    }
    /// Scrolls just enough to show the track at `index` (keyboard navigation).
    func revealTrack(at index: Int) {
        let top = session.laneTop(index), h = session.laneHeight(index), visible = max(0, bounds.height - Theme.rulerHeight)
        if top < scrollY { scrollY = top } else if top + h > scrollY + visible { scrollY = min(maxScrollY, top + h - visible) }
    }
    /// Keeps the shared vertical offset valid after tracks are removed, collapsed or the view shrinks.
    func clampScrollY() { scrollY = min(max(0, scrollY), maxScrollY) }
    var onVerticalScroll: ((CGFloat) -> Void)?
    var onSeek: (() -> Void)?
    var onSelectionChange: (() -> Void)?

    var selectedClip: DalnokClipId? {
        didSet {
            if !changingSelection { selectedClips = selectedClip.map { [$0] } ?? [] }
            if oldValue != selectedClip { animateSelection = true }; needsDisplay = true; onSelectionChange?()
        }
    }
    private(set) var selectedClips: Set<DalnokClipId> = [] { didSet { needsDisplay = true } }
    private var changingSelection = false
    private func select(_ ids: Set<DalnokClipId>, primary: DalnokClipId?) {
        changingSelection = true
        selectedClips = ids; selectedClip = primary
        changingSelection = false
    }
    /// Selects these clips (the first is the primary selection).
    func selectClips(_ ids: [DalnokClipId]) { select(Set(ids), primary: ids.first) }
    func pruneSelection() {
        let remaining = selectedClips.filter { session.clip($0) != nil }
        let primary = selectedClip.flatMap { remaining.contains($0) ? $0 : nil } ?? remaining.sorted().first
        if remaining != selectedClips || primary != selectedClip { select(remaining, primary: primary) }
    }
    /// A soft halo in the clip's color that glides from the old selection to the new one.
    private let selectionGlow = CAShapeLayer()
    private var animateSelection = false
    var onClipSelected: ((ClipView) -> Void)?
    /// A clip body dragged left out of the timeline (window point): the launcher puts a copy in a slot.
    var onDropToLauncher: ((DalnokClipId, CGPoint) -> Bool)?
    private var hoveredClip: DalnokClipId? { didSet { if hoveredClip != oldValue { needsDisplay = true } } }

    private let playheadLayer = CALayer()
    let hoverLine = CALayer()
    /// A selection made since the playhead was last placed: Play starts at it. A section dragged out with the marquee
    /// starts where the drag began; clicked clips start at the earliest selected clip.
    private enum PlayFrom { case range(Int64), clips }
    private var playFrom: PlayFrom?
    func clearPlayFromSelection() { playFrom = nil }
    var playStartForSelection: Int64? {
        guard let p = playFrom, !selectedClips.isEmpty else { return nil }
        switch p {
        case .range(let f): return f
        case .clips: return selectedClips.compactMap { session.clip($0) }.map(\.start).min()
        }
    }
    /// The timeline frame the hover line marks (nil: hidden). Snapped like a click (⌃ bypasses).
    private(set) var hoverFrame: Int64?
    func showHoverLine(atX x: CGFloat?, bypass: Bool = false) {
        CATransaction.begin(); CATransaction.setDisableActions(true); defer { CATransaction.commit() }
        guard let x, x >= 0, x <= bounds.width, drag == nil, marquee == nil, rulerDrag == nil, !scrubbing else {
            hoverFrame = nil; hoverLine.isHidden = true; return
        }
        let f = snap(max(0, frame(forX: x)), bypass: bypass)
        hoverFrame = f
        let px = xPos(forFrame: Double(f)).rounded() + 0.5
        hoverLine.frame = CGRect(x: px - 0.5, y: 0, width: 1, height: bounds.height)
        hoverLine.isHidden = false
    }
    private let playheadCap = CAShapeLayer()
    private let playheadHalo = CAGradientLayer()  // Prism: the column of light around the playhead
    /// Graphite and Warm Analog: the afterglow behind the playhead while it runs (a phosphor trace's persistence; a
    /// lamp's warmth), fading in when playing starts and out when it stops.
    private let playheadTrail = CAGradientLayer()
    private let spectrumFan = CAGradientLayer()   // Prism: light dispersed by the playhead's prism head
    private var mins: [Float] = [], maxs: [Float] = []

    private enum Zone: Equatable { case body, leftEdge, rightEdge, fadeIn, fadeOut, warp(Int) }
    /// What the pointer would do here, for the control bar's hint line (Settings ▸ Appearance ▸ Hints).
    private(set) var hoverHint: String?
    private func hint(_ p: CGPoint, _ h: (ClipView, Zone)?) -> String? {
        if p.y < Theme.rulerHeight / 2 { return "Ruler, top half: drag to set the cycle range; drag its ends to adjust it" }
        if p.y < Theme.rulerHeight { return "Ruler, bottom half: click or drag to move the playhead" }
        guard let (clip, zone) = h else { return "Arrangement: drag to select clips, drop audio files to import, ⌘-scroll to zoom" }
        switch zone {
        case .leftEdge: return "Clip start: drag to trim (hold ⌃ to ignore the grid)"
        case .rightEdge: return "Clip end: drag to trim, ⌥-drag to time-stretch (hold ⌃ to ignore the grid)"
        case .fadeIn, .fadeOut: return "Fade handle: drag to lengthen or shorten the fade"
        case .warp: return "Quantized hit: drag to move it (snaps to the grid; hold ⌃ to ignore it). The attack moves whole; the audio around it stretches"
        case .body: return clip.isMidi ? "MIDI clip: drag to move (hold ⌃ to ignore the grid), double-click to edit its notes"
                                       : "Audio clip: drag to move (hold ⌃ to ignore the grid), drag an edge to trim"
        }
    }
    private let titleH: CGFloat = 16
    private let fadeHandleZone: CGFloat = 14
    private struct Drag {
        let clip: ClipView
        let moving: [ClipView]
        let zone: Zone
        let startX: CGFloat
        var startY: CGFloat = 0
        var changed = false
        var stretch = false // ⌥-drag on the right edge: time-stretch instead of trim
    }
    private var drag: Drag?
    /// FL-style clip motion (ClipMotion.swift): the picture of the clips being moved, lifted off the lanes while they
    /// follow the pointer. `lifted` clips are drawn as a ghost (their landing place on the grid) meanwhile, and not at
    /// all while the picture settles onto them.
    private(set) var lift: ClipLift?
    private(set) var lifted: Set<DalnokClipId> = []
    private var landing = false
    /// The clips last drawn, for pop-in and poof (`noteClipChanges`).
    private var knownClips: [DalnokClipId: (clip: ClipView, track: TrackView, laneIndex: Int)] = [:]
    /// The tracks a solo silenced at the last model change (their clips fade back in, or out, when it changes).
    private var knownQuiet: Set<DalnokTrackId> = []
    static let soloSilencedAlpha: CGFloat = 0.38
    private struct Marquee { let start: CGPoint; var end: CGPoint; let initial: Set<DalnokClipId>; var moved = false }
    private var marquee: Marquee?
    /// Ruler gesture: a click seeks; a drag draws, moves or resizes the cycle region.
    private struct RulerDrag { enum Kind { case create, move, start, end }; var kind: Kind; let x: CGFloat; let start: Int64; let end: Int64; var moved = false }
    private var rulerDrag: RulerDrag?
    private var scrubbing = false
    // MARK: Automation view (A): curves over each lane; clips are not editable while it's on.
    var showAutomation = false { didSet { needsDisplay = true } }
    static var automationTarget: Int32 = 0 // 0 volume, 1 pan
    private struct AutoDrag { let track: DalnokTrackId; var points: [DalnokAutoPoint]; var index: Int; let lane: AutoLane }
    private var autoDrag: AutoDrag?
    private let autoMargin: CGFloat = 8

    /// What a track's automation lane shows: the global volume/pan choice, or a plug-in parameter picked
    /// for that track (plug-in window ▸ Automate).
    enum AutoLane: Equatable {
        case volume, pan
        case plugin(slot: Int32, param: UInt32, name: String)
    }
    var pluginLanes: [DalnokTrackId: AutoLane] = [:] { didSet { needsDisplay = true } }
    func lane(for t: TrackView) -> AutoLane { pluginLanes[t.id] ?? (Self.automationTarget == 1 ? .pan : .volume) }
    private var globalLane: AutoLane { Self.automationTarget == 1 ? .pan : .volume }
    func lanePoints(_ t: TrackView, _ lane: AutoLane) -> [DalnokAutoPoint] {
        switch lane {
        case .volume: return t.volumeAuto
        case .pan: return t.panAuto
        case let .plugin(slot, param, _): return session.pluginAutomation(t.id, slot, param)
        }
    }
    private func setLanePoints(_ id: DalnokTrackId, _ lane: AutoLane, _ pts: [DalnokAutoPoint]) {
        switch lane {
        case .volume: session.setAutomation(id, 0, pts)
        case .pan: session.setAutomation(id, 1, pts)
        case let .plugin(slot, param, _): session.setPluginAutomation(id, slot, param, pts)
        }
    }
    private func staticValue(_ t: TrackView, _ lane: AutoLane) -> Float {
        switch lane {
        case .volume: return t.gainDb
        case .pan: return t.pan
        case let .plugin(slot, param, _): return session.pluginParameterValue(slot, param) ?? 0.5
        }
    }
    private func format(_ v: Float, _ lane: AutoLane) -> String {
        switch lane {
        case .volume: return FaderControl.format(v)
        case .pan: return PanKnob.format(Double(v))
        case let .plugin(_, _, name): return "\(name) \(Int((v * 100).rounded()))%"
        }
    }
    private func undoName(_ lane: AutoLane) -> String {
        switch lane { case .volume: "Volume Automation"; case .pan: "Pan Automation"; case .plugin: "Plug-in Automation" }
    }

    /// Lane y for an automation value (volume: fader taper, top = +6 dB; pan: top = left; plug-in: top = 100%).
    func autoY(_ value: Float, laneY: CGFloat, lane: AutoLane? = nil) -> CGFloat {
        let l = lane ?? globalLane
        let f: Double
        switch l {
        case .volume: f = 1 - FaderControl.position(for: value)
        case .pan: f = Double(value + 1) / 2
        case .plugin: f = 1 - Double(value)
        }
        let top = laneY + autoMargin, h = laneHeight(atLaneY: laneY) - 2 * autoMargin
        return top + CGFloat(f) * h
    }
    func autoValue(atY y: CGFloat, laneY: CGFloat, lane: AutoLane? = nil) -> Float {
        let top = laneY + autoMargin, h = laneHeight(atLaneY: laneY) - 2 * autoMargin
        let f = Double(min(max((y - top) / h, 0), 1))
        switch lane ?? globalLane {
        case .volume: return max(-200, FaderControl.db(for: 1 - f))
        case .pan: return Float(f * 2 - 1)
        case .plugin: return Float(1 - f)
        }
    }

    private func drawAutomation(_ ctx: CGContext) {
        guard showAutomation else { return }
        for (i, track) in session.tracks.enumerated() {
            let y = laneY(i), lh = session.laneHeight(i)
            guard y + lh > Theme.rulerHeight, y < bounds.height else { continue }
            ctx.setFillColor(Theme.laneA.withAlphaComponent(0.55).cgColor) // clips recede
            ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: lh - 1))
            let lane = lane(for: track)
            let pts = lanePoints(track, lane)
            let color = TrackTint(base: track.color).waveform
            if case let .plugin(_, _, name) = lane { // which parameter this lane shows
                (name.uppercased() as NSString).draw(at: CGPoint(x: 8, y: y + 4), withAttributes: [.font: Theme.mono(9, .semibold), .foregroundColor: Theme.accent])
            }
            if pts.isEmpty { // the static value, dashed
                let v = staticValue(track, lane)
                let ly = autoY(v, laneY: y, lane: lane)
                ctx.setStrokeColor(color.withAlphaComponent(0.6).cgColor)
                ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [5, 4])
                ctx.move(to: CGPoint(x: 0, y: ly)); ctx.addLine(to: CGPoint(x: bounds.width, y: ly)); ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                continue
            }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: 0, y: autoY(pts[0].value, laneY: y, lane: lane)))
            for p in pts { ctx.addLine(to: CGPoint(x: xPos(forFrame: Double(p.frame)), y: autoY(p.value, laneY: y, lane: lane))) }
            ctx.addLine(to: CGPoint(x: bounds.width, y: autoY(pts[pts.count - 1].value, laneY: y, lane: lane)))
            ctx.strokePath()
            for p in pts {
                let c = CGPoint(x: xPos(forFrame: Double(p.frame)), y: autoY(p.value, laneY: y, lane: lane))
                guard c.x > -6, c.x < bounds.width + 6 else { continue }
                let r = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                ctx.setFillColor(Theme.panel.cgColor); ctx.fillEllipse(in: r)
                ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: r)
            }
        }
        let name = Self.automationTarget == 1 ? "PAN AUTOMATION" : "VOLUME AUTOMATION"
        (name as NSString).draw(at: CGPoint(x: bounds.width - 140, y: Theme.rulerHeight + 4),
                                withAttributes: [.font: Theme.mono(9, .semibold), .foregroundColor: Theme.accent])
    }

    /// Automation gestures: click empty lane space adds a point (and drags it), drag a point to move it,
    /// ⌥-click a point to delete it. Each gesture is one undo step.
    private func autoMouseDown(_ p: CGPoint, _ event: NSEvent) -> Bool {
        guard showAutomation, let i = trackIndex(atY: p.y), i < session.tracks.count else { return false }
        let track = session.tracks[i], y = laneY(i), lane = lane(for: track)
        var pts = lanePoints(track, lane)
        let hit = pts.firstIndex { abs(xPos(forFrame: Double($0.frame)) - p.x) <= 6 && abs(autoY($0.value, laneY: y, lane: lane) - p.y) <= 6 }
        session.engine.beginGroup(undoName(lane))
        if let h = hit, event.modifierFlags.contains(.option) {
            pts.remove(at: h)
            setLanePoints(track.id, lane, pts)
            session.engine.endGroup()
            return true
        }
        var index: Int
        if let h = hit { index = h } else {
            let frame = snap(frame(forX: p.x), bypass: event.modifierFlags.contains(.control))
            if pts.isEmpty { // start from the current static value so the rest of the song doesn't jump
                if frame > 0 { pts.append(DalnokAutoPoint(frame: 0, value: staticValue(track, lane))) }
            }
            pts.append(DalnokAutoPoint(frame: frame, value: autoValue(atY: p.y, laneY: y, lane: lane)))
            pts.sort { $0.frame < $1.frame }
            index = pts.lastIndex { $0.frame == frame } ?? pts.count - 1
            setLanePoints(track.id, lane, pts)
        }
        autoDrag = AutoDrag(track: track.id, points: pts, index: index, lane: lane)
        return true
    }
    private func autoMouseDragged(_ p: CGPoint, _ event: NSEvent) -> Bool {
        guard var d = autoDrag, let i = session.tracks.firstIndex(where: { $0.id == d.track }) else { return false }
        let y = laneY(i)
        var f = snap(frame(forX: p.x), bypass: event.modifierFlags.contains(.control))
        // A point stays between its neighbors.
        if d.index > 0 { f = max(f, d.points[d.index - 1].frame + 1) }
        if d.index + 1 < d.points.count { f = min(f, d.points[d.index + 1].frame - 1) }
        d.points[d.index] = DalnokAutoPoint(frame: max(0, f), value: autoValue(atY: p.y, laneY: y, lane: d.lane))
        setLanePoints(d.track, d.lane, d.points)
        autoDrag = d
        ValueBubble.show(format(d.points[d.index].value, d.lane), above: self, at: p.x)
        return true
    }
    /// Autopunch range (red, lower ruler); drawn while `showPunch`.
    var punchRange: (Int64, Int64)? { didSet { needsDisplay = true } }
    var showPunch = false { didSet { needsDisplay = true } }
    private let edgeWidth: CGFloat = 7

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true // macOS 14+ defaults to false; clips scrolled left of the view would cover the headers
        layer?.backgroundColor = Theme.look.arrangement == .glass ? nil : Theme.laneA.cgColor
        playheadLayer.backgroundColor = Theme.playhead.withAlphaComponent(0.9).cgColor
        playheadLayer.zPosition = 10
        if Theme.look.arrangement == .manuscript { // a paper casing either side, so the red line reads over red-ink clips
            playheadLayer.shadowColor = Theme.laneA.cgColor
            playheadLayer.shadowOpacity = 1
            playheadLayer.shadowRadius = 1.2
            playheadLayer.shadowOffset = .zero
        }
        layer?.addSublayer(playheadLayer)
        // The hover playhead: a faint line where a click would put the playhead (as video editors show), wherever
        // the real playhead is.
        hoverLine.backgroundColor = Theme.playhead.withAlphaComponent(0.38).cgColor
        hoverLine.zPosition = 9
        hoverLine.isHidden = true
        layer?.addSublayer(hoverLine)
        let cap = CGMutablePath() // pentagon pointing down (view is flipped)
        cap.move(to: CGPoint(x: -6, y: 0)); cap.addLine(to: CGPoint(x: 6, y: 0)); cap.addLine(to: CGPoint(x: 6, y: 6))
        cap.addLine(to: CGPoint(x: 0, y: 12)); cap.addLine(to: CGPoint(x: -6, y: 6)); cap.closeSubpath()
        playheadCap.path = cap
        playheadCap.fillColor = Theme.playhead.cgColor
        playheadCap.zPosition = 11
        playheadCap.shadowOpacity = 0.5
        playheadCap.shadowRadius = 2
        playheadCap.shadowOffset = .zero
        layer?.addSublayer(playheadCap)
        selectionGlow.fillColor = nil
        selectionGlow.lineWidth = 1.5
        selectionGlow.strokeColor = Theme.selection.withAlphaComponent(0.9).cgColor
        selectionGlow.shadowRadius = 7
        selectionGlow.shadowOpacity = 0.85
        selectionGlow.shadowOffset = .zero
        selectionGlow.opacity = 0
        selectionGlow.zPosition = 5
        layer?.addSublayer(selectionGlow)
        configureFamilyLayers()
    }

    /// The playhead glows while the transport runs (red while recording).
    func setTransportState(playing: Bool, recording: Bool) {
        Motion.layers(Motion.gentle) {
            let color = recording ? Theme.recordOn : Theme.playhead
            playheadCap.fillColor = color.cgColor
            playheadLayer.backgroundColor = color.withAlphaComponent(0.9).cgColor
            playheadCap.shadowColor = color.cgColor
            playheadCap.shadowRadius = playing ? 6 : 2
            playheadCap.shadowOpacity = playing ? 0.9 : 0.5
            switch Theme.look.arrangement {
            case .flat: playheadTrail.opacity = playing && !Motion.reduced ? 1 : 0
                if recording { playheadTrail.colors = [Theme.recordOn.withAlphaComponent(0).cgColor, Theme.recordOn.withAlphaComponent(0.06).cgColor, Theme.recordOn.withAlphaComponent(0.2).cgColor] }
                else { let glow = Theme.activeStyle == .warmAnalog ? Theme.hex(0xFFB866) : Theme.playhead
                    playheadTrail.colors = [glow.withAlphaComponent(0).cgColor, glow.withAlphaComponent(0.05).cgColor, glow.withAlphaComponent(0.16).cgColor] }
            case .glass: playheadHalo.opacity = playing || recording ? 1 : 0.55 // the guide brightens while light runs through it
                playheadHalo.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(recording ? 0.35 : 0.22).cgColor, color.withAlphaComponent(0).cgColor]
            case .manuscript: playheadCap.shadowOpacity = 0 // ink doesn't glow
            }
        }
    }

    private func updateSelectionGlow() {
        var target: (rect: CGRect, color: NSColor)?
        if let id = selectedClip {
            for (i, t) in session.tracks.enumerated() {
                if let c = t.clips.first(where: { $0.id == id }) {
                    target = (clipRect(c, laneY: laneY(i)).insetBy(dx: -0.5, dy: -0.5), t.color)
                    break
                }
            }
        }
        let animate = animateSelection && !Motion.reduced
        animateSelection = false
        guard let target, target.rect.maxY > Theme.rulerHeight else {
            Motion.layers(animate ? Motion.quick : 0) { selectionGlow.opacity = 0 }
            return
        }
        // Atelier selects with crop marks that glide to the next clip like a drafting square; the others with a glow.
        let path = Theme.look.arrangement == .manuscript ? Self.cropMarksPath(target.rect.insetBy(dx: -0.5, dy: -0.5))
            : CGPath(roundedRect: target.rect, cornerWidth: Theme.look.arrangement == .glass ? 5.5 : 3.5, cornerHeight: Theme.look.arrangement == .glass ? 5.5 : 3.5, transform: nil)
        if animate, selectionGlow.opacity > 0.5, let from = selectionGlow.path {
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = from
            a.toValue = path
            a.duration = Motion.gentle
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            selectionGlow.add(a, forKey: "glide")
        } else if animate {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.duration = Motion.standard
            selectionGlow.add(a, forKey: "appear")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionGlow.frame = bounds
        selectionGlow.path = path
        selectionGlow.opacity = 1
        selectionGlow.shadowColor = target.color.cgColor
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func xPos(forFrame f: Double) -> CGFloat { CGFloat((f - scrollFrame) / framesPerPoint) }
    func frame(forX x: CGFloat) -> Double { scrollFrame + Double(x) * framesPerPoint }
    func laneY(_ index: Int) -> CGFloat { Theme.rulerHeight + session.laneTop(index) - scrollY }

    /// Redraws only these tracks' lanes, and the lanes of the stacks that summarize them.
    func invalidateLanes(of ids: Set<DalnokTrackId>) {
        var all = ids
        for id in ids {
            var parent = session.track(id)?.stack ?? 0
            while parent != 0, all.insert(parent).inserted { parent = session.track(parent)?.stack ?? 0 }
        }
        for (i, t) in session.tracks.enumerated() where all.contains(t.id) {
            setNeedsDisplay(NSRect(x: 0, y: laneY(i), width: bounds.width, height: session.laneHeight(i)))
        }
    }
    /// The height of the lane whose top is at `laneY` (view coordinates).
    func laneHeight(atLaneY laneY: CGFloat) -> CGFloat { session.laneHeight(session.laneIndex(atY: laneY - Theme.rulerHeight + scrollY + 0.5)) }
    func trackIndex(atY y: CGFloat) -> Int? {
        guard y >= Theme.rulerHeight else { return nil }
        let i = session.laneIndex(atY: y - Theme.rulerHeight + scrollY)
        return i >= 0 && i < session.tracks.count ? i : nil
    }

    /// A fit asked for before the view had its real width (a window still being built) runs at the next layout.
    private var fitPending = false
    /// Shows exactly this view (a rebuilt window taking over an earlier one's zoom and scroll); cancels a pending fit.
    func keepView(framesPerPoint fpp: Double, scrollFrame sf: Double, scrollY sy: CGFloat) {
        fitPending = false
        stopGlide()
        framesPerPoint = fpp
        scrollFrame = sf
        scrollY = sy
    }
    func zoomToFit(animated: Bool = false) {
        // Fitting a not-yet-laid-out timeline used a 200 pt stand-in width, squeezing the song into the first 200 pt
        // (seen after switching between Graphite and Warm Analog, which rebuilds the window).
        guard bounds.width >= 200 else { fitPending = true; needsLayout = true; return }
        fitPending = false
        let len = Double(max(session.length, Int64(sampleRate * 10)))
        let fpp = max(1, len * 1.05 / Double(bounds.width))
        if animated { glide(framesPerPoint: fpp, scrollFrame: 0); return }
        stopGlide()
        framesPerPoint = fpp
        scrollFrame = 0
    }

    // MARK: Gliding view changes (menu and keyboard zoom, zoom to fit or selection, page turns while playing)

    private var glider: MotionDriver?
    /// Where the running glide ends, so a repeated zoom key builds on it rather than on a half-way view.
    private(set) var glideTarget: (fpp: Double, sf: Double)?
    var isGliding: Bool { glider?.running == true }
    func stopGlide() { glider?.cancel(); glider = nil; glideTarget = nil }
    /// Moves the view to a zoom and left edge as one continuous camera move: the zoom eases in log space around the
    /// one point that is at the same place on screen before and after (so a keyboard zoom keeps its anchor still).
    func glide(framesPerPoint fpp: Double, scrollFrame sf: Double, duration: Double = 0.26, curve: Motion.Curve = .easeOut) {
        let f1 = min(max(fpp, 0.25), sampleRate * 10), s1 = max(0, sf)
        stopGlide()
        let f0 = framesPerPoint, s0 = scrollFrame
        guard f0 != f1 || s0 != s1 else { return }
        glideTarget = (f1, s1)
        let sameZoom = abs(f0 - f1) < 1e-9 * f0
        let x = sameZoom ? 0 : (s1 - s0) / (f0 - f1), anchor = s0 + x * f0 // screen point x shows frame `anchor` throughout
        glider = Motion.drive(self, duration: duration, curve: curve, { [weak self] t in
            guard let self else { return }
            if sameZoom { self.scrollFrame = s0 + (s1 - s0) * t; return }
            let f = t >= 1 ? f1 : exp(log(f0) + (log(f1) - log(f0)) * t)
            self.framesPerPoint = f
            self.scrollFrame = t >= 1 ? s1 : anchor - x * f
        }, completion: { [weak self] in self?.glideTarget = nil })
    }
    /// Keyboard and menu zoom: a short glide around `x`, building on a glide already running.
    func zoomSmoothly(by factor: Double, around x: CGFloat) {
        let (f0, s0) = glideTarget ?? (framesPerPoint, scrollFrame)
        let anchor = s0 + Double(x) * f0
        let f1 = min(max(f0 * factor, 0.25), sampleRate * 10)
        glide(framesPerPoint: f1, scrollFrame: anchor - Double(x) * f1, duration: 0.22)
    }

    // MARK: Playhead

    func updatePlayhead() {
        let x = xPos(forFrame: Double(session.engine.position))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadLayer.frame = CGRect(x: x - 0.5, y: Theme.rulerHeight - 12, width: 1, height: bounds.height)
        playheadLayer.isHidden = x < -2 || x > bounds.width + 2
        playheadCap.position = CGPoint(x: x, y: Theme.rulerHeight - 12) // below the bar numbers, so "1" stays readable
        playheadCap.isHidden = playheadLayer.isHidden
        if Theme.look.arrangement == .flat {
            playheadTrail.frame = CGRect(x: x - 48, y: Theme.rulerHeight, width: 48, height: bounds.height)
            playheadTrail.isHidden = playheadLayer.isHidden
        }
        if Theme.look.arrangement == .glass {
            playheadHalo.frame = CGRect(x: x - 7, y: Theme.rulerHeight, width: 14, height: bounds.height)
            playheadHalo.isHidden = playheadLayer.isHidden
            spectrumFan.position = CGPoint(x: x, y: Theme.rulerHeight - 6)
            spectrumFan.isHidden = playheadLayer.isHidden
        }
        CATransaction.commit()
    }

    /// Page-follow while playing.
    func followPlayhead() {
        guard session.engine.isPlaying, drag == nil else { return }
        let x = xPos(forFrame: Double(session.engine.position))
        guard !isGliding else { return }
        if x > bounds.width - 24 || x < 0 {
            // A quick page turn (as Bitwig and Studio One do) rather than a jump, so the eye can follow the playhead.
            let target = Double(session.engine.position) - 24 * framesPerPoint
            if x < 0 || x > bounds.width + 4 { scrollFrame = target } else { glide(framesPerPoint: framesPerPoint, scrollFrame: target, duration: 0.2, curve: .easeInOut) }
        }
    }

    // MARK: Grid & snapping

    /// A "nice" ruler step in seconds so labels sit >= ~90 pt apart.
    func gridStep() -> Double {
        let target = framesPerPoint / sampleRate * 90
        let steps: [Double] = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { $0 >= target } ?? 600
    }

    // MARK: Bars and beats

    /// Ruler and grid in bars and beats (default, as in Logic) or minutes and seconds.
    static var barsAndBeats: Bool {
        get { UserDefaults.standard.object(forKey: "rulerBarsAndBeats") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "rulerBarsAndBeats") }
    }
    /// Frames per quarter note and quarter notes per bar where the view is centred (the map can vary).
    var framesPerBeat: Double { session.framesPerBeat(at: frame(forX: bounds.midX)) }
    var beatsPerBar: Double {
        let m = session.bar(atBeat: session.frameToBeat(frame(forX: bounds.midX)))
        return Double(m.num) * 4 / Double(m.den)
    }

    /// Grid spacing for the current zoom (lines about 90 points apart): whole bars, or quarter notes inside a bar.
    struct GridStep { var bars = 0; var beats = 1.0 }
    func gridStepBeats() -> GridStep {
        let target = framesPerPoint * 90 / framesPerBeat
        for q in [0.0625, 0.125, 0.25, 0.5, 1] where q >= target && q < beatsPerBar - 1e-9 { return GridStep(bars: 0, beats: q) }
        let bars = [1, 2, 4, 8, 16, 32, 64, 128, 256].first { Double($0) * beatsPerBar >= target } ?? 256
        return GridStep(bars: bars, beats: 0)
    }

    /// Ruler step in frames at the view centre (used for nudging and for minutes-and-seconds mode).
    func gridStepFrames() -> Double {
        guard Self.barsAndBeats else { return gridStep() * sampleRate }
        let g = gridStepBeats()
        return (g.bars > 0 ? Double(g.bars) * beatsPerBar : g.beats) * framesPerBeat
    }

    /// Snapping unit: a quarter of the ruler step (a 16th note when the ruler shows beats).
    func snapQuantum() -> Double { gridStepFrames() / 4 }

    struct GridLine { let frame: Double; let bar: Int; let beatInBar: Double; var isBar: Bool { beatInBar < 1e-9 } }

    /// Grid lines between two frames, walking bars through the meter and tempo maps.
    func gridLines(from f0: Double, to f1: Double) -> [GridLine] {
        let g = gridStepBeats()
        var bar = session.bar(atBeat: session.frameToBeat(f0)).bar
        if g.bars > 1 { bar = Int((Double(bar) / Double(g.bars)).rounded(.down)) * g.bars }
        var lines: [GridLine] = []
        while lines.count < 4_000 {
            let start = session.barToBeat(bar)
            if session.beatToFrame(start) > f1 { break }
            if g.bars > 0 {
                lines.append(GridLine(frame: session.beatToFrame(start), bar: bar, beatInBar: 0)); bar += g.bars
            } else {
                let end = session.barToBeat(bar + 1)
                var q = start
                while q < end - 1e-9 {
                    lines.append(GridLine(frame: session.beatToFrame(q), bar: bar, beatInBar: q - start)); q += g.beats
                }
                bar += 1
            }
        }
        return lines
    }

    /// "bar.beat.sixteenth" (1-based) for a frame, or the bar alone for whole-bar steps.
    func barsLabel(_ frame: Double, wholeBars: Bool) -> String {
        let beat = (session.frameToBeat(frame) * 4).rounded() / 4
        let b = session.bar(atBeat: beat + 1e-9)
        if wholeBars || b.beatInBar < 1e-6 { return "\(b.bar + 1)" }
        let whole = Int((b.beatInBar + 1e-6).rounded(.down))
        let perBeat = max(1, 16 / b.den)
        let sub = Int(((b.beatInBar - Double(whole)) * Double(perBeat)).rounded())
        return sub == 0 ? "\(b.bar + 1).\(whole + 1)" : "\(b.bar + 1).\(whole + 1).\(sub + 1)"
    }

    /// Snaps to the minor grid (a quarter of the ruler step) inside the bar, following the maps.
    /// Hold Control to bypass.
    func snap(_ frame: Double, bypass: Bool) -> Int64 {
        let f = max(0, frame)
        guard !bypass else { return Int64(f.rounded()) }
        guard Self.barsAndBeats else { let q = snapQuantum(); return Int64((f / q).rounded() * q) }
        let g = gridStepBeats()
        let beat = session.frameToBeat(f)
        let b = session.bar(atBeat: beat)
        let barStart = session.barToBeat(b.bar), barEnd = session.barToBeat(b.bar + 1)
        let q = g.bars > 0 ? Double(g.bars) * (barEnd - barStart) / 4 : g.beats / 4
        let snapped = min(barEnd, barStart + ((beat - barStart) / q).rounded() * q)
        return max(0, Int64(session.beatToFrame(snapped).rounded()))
    }

    // MARK: Drawing

    /// Lanes drawn by the last draw pass (self-test evidence for partial redraws).
    private(set) var lanesDrawn = 0
    /// Total time spent in draw (audit instrumentation).
    private(set) var drawSeconds = 0.0, drawCalls = 0
    override func draw(_ dirtyRect: NSRect) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { drawSeconds += Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9; drawCalls += 1 }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        lanesDrawn = 0
        let scale = window?.backingScaleFactor ?? 2
        drawLanes(ctx)
        let glassClip = Theme.look.arrangement == .glass
        if glassClip { ctx.saveGState(); ctx.addPath(CGPath(roundedRect: glassLanesRect, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.clip() }
        drawGrid(ctx, scale: scale)
        let quiet = session.soloSilenced() // a solo elsewhere silences these: their clips recede (the audit: W4)
        for (i, track) in session.tracks.enumerated() {
            let y = laneY(i)
            guard y + session.laneHeight(i) > Theme.rulerHeight, y < bounds.height else { continue }
            // Only lanes inside the area being redrawn (a structural edit redraws just its tracks' lanes).
            guard dirtyRect.intersects(CGRect(x: 0, y: y, width: bounds.width, height: session.laneHeight(i))) else { continue }
            lanesDrawn += 1
            if track.isStack { drawStackSummary(ctx, track, laneY: y) }
            let silenced = quiet.contains(track.id)
            if silenced { ctx.saveGState(); ctx.setAlpha(Self.soloSilencedAlpha) }
            for clip in track.clips {
                if lifted.contains(clip.id) { if !landing { drawGhost(ctx, clipRect(clip, laneY: y), color: track.color) }; continue }
                drawClip(ctx, clip, track: track, laneY: y, scale: scale)
            }
            if silenced { ctx.restoreGState() }
            if let rec = recording, rec.tracks.contains(track.id) { drawRecording(ctx, rec, laneY: y, track: track.id) }
        }
        if let m = marquee, m.moved {
            let r = CGRect(x: min(m.start.x, m.end.x), y: min(m.start.y, m.end.y),
                           width: abs(m.end.x - m.start.x), height: abs(m.end.y - m.start.y))
            ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: Theme.rulerHeight, width: bounds.width, height: max(0, bounds.height - Theme.rulerHeight)))
            switch Theme.look.arrangement {
            case .flat:
                ctx.setFillColor(Theme.selection.withAlphaComponent(0.18).cgColor); ctx.fill(r)
                ctx.setStrokeColor(Theme.selection.cgColor); ctx.setLineWidth(1); ctx.stroke(r)
            case .glass: // a pane of light
                Prism.slab(ctx, r, radius: 4, tint: Theme.accent, body: 0.08, lift: 0)
            case .manuscript: // a dashed drafting box with crop marks
                ctx.setFillColor(Theme.ink(0.03).cgColor); ctx.fill(r)
                ctx.setStrokeColor(Theme.text.cgColor); ctx.setLineWidth(Atelier.fine); ctx.setLineDash(phase: 0, lengths: [4, 3]); ctx.stroke(r)
                ctx.setLineDash(phase: 0, lengths: [])
                Atelier.cropMarks(ctx, r, length: 5, gap: 2, weight: Atelier.fine)
            }
            ctx.restoreGState()
        }
        drawAutomation(ctx)
        if glassClip { ctx.restoreGState() }
        // A fade at the foot while more tracks lie below (audit C5: a cut-off row gave no cue).
        if scrollY < maxScrollY - 1, Theme.look.arrangement != .glass {
            let h: CGFloat = 26, r = CGRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
            NSGradient(starting: Theme.laneA.withAlphaComponent(0), ending: Theme.laneA.withAlphaComponent(0.9))?.draw(in: r, angle: 90)
        }
        drawRuler(ctx, scale: scale)
        updateSelectionGlow()

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

    /// The take in progress: drawn as a growing red region on its armed tracks.
    struct RecordingRegion: Equatable {
        var start: Int64; var end: Int64; var tracks: Set<DalnokTrackId>
        /// Live waveform: one peak per DALNOK_LIVE_PEAK_FRAMES recorded frames, per recording audio track.
        var peaks: [DalnokTrackId: [Float]] = [:]
        /// A cycle take wraps here; only the current pass is drawn.
        var cycle: (start: Int64, end: Int64)? = nil
        static func == (a: Self, b: Self) -> Bool {
            a.start == b.start && a.end == b.end && a.tracks == b.tracks && a.peaks == b.peaks &&
                a.cycle?.start == b.cycle?.start && a.cycle?.end == b.cycle?.end
        }
    }
    var recording: RecordingRegion? {
        didSet {
            guard oldValue != recording else { return }
            // Only the recording lanes change (a take can run for an hour; the rest of the arrangement stays put).
            if let o = oldValue, let n = recording, o.tracks == n.tracks { invalidateLanes(of: n.tracks) } else { needsDisplay = true }
        }
    }

    private func drawRecording(_ ctx: CGContext, _ rec: RecordingRegion, laneY: CGFloat, track: DalnokTrackId) {
        let x0 = xPos(forFrame: Double(rec.start)), x1 = xPos(forFrame: Double(max(rec.start, rec.end)))
        let rect = CGRect(x: x0, y: laneY + 3, width: max(2, x1 - x0), height: laneHeight(atLaneY: laneY) - 7)
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(Theme.recordOn.withAlphaComponent(0.22).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(Theme.recordOn.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        if let peaks = rec.peaks[track], !peaks.isEmpty { drawLivePeaks(ctx, peaks, rec, in: rect) }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(10.5, .semibold), .foregroundColor: Theme.text]
        ("● Recording" as NSString).draw(at: CGPoint(x: max(rect.minX, 0) + 6, y: rect.minY + 1.5), withAttributes: attrs)
    }

    /// The take's waveform as it records: the loudest peak in each pixel column, mirrored about the lane's centre.
    private func drawLivePeaks(_ ctx: CGContext, _ peaks: [Float], _ rec: RecordingRegion, in rect: CGRect) {
        let step = Int64(DALNOK_LIVE_PEAK_FRAMES)
        let top = rect.minY + 16, bottom = rect.maxY - 3
        guard bottom - top > 4 else { return }
        let mid = (top + bottom) / 2, half = (bottom - top) / 2
        // A cycle take: positions wrap at the cycle end; only the pass in progress is shown.
        var first = 0
        var origin = rec.start // timeline frame of peak 0
        if let c = rec.cycle, c.end > c.start {
            let len = c.end - c.start, lead = rec.start - c.start
            let pass = (lead + Int64(peaks.count) * step) / len
            first = max(0, Int((pass * len - lead + step - 1) / step))
            origin = rec.start - pass * len
        }
        let visible = bounds.intersection(ctx.boundingBoxOfClipPath)
        var column = Int.min, colPeak: Float = 0
        ctx.setStrokeColor(Theme.text.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        func flush() {
            guard column != Int.min, colPeak > 0 else { return }
            let h = max(0.5, CGFloat(min(colPeak, 1)) * half)
            let x = CGFloat(column) + 0.5
            ctx.move(to: CGPoint(x: x, y: mid - h)); ctx.addLine(to: CGPoint(x: x, y: mid + h))
        }
        for i in first..<peaks.count {
            let x = xPos(forFrame: Double(origin + Int64(i) * step))
            if x < visible.minX - 1 { continue }
            if x > visible.maxX + 1 { break }
            let col = Int(x.rounded(.down))
            if col != column { flush(); column = col; colPeak = 0 }
            colPeak = max(colPeak, peaks[i])
        }
        flush()
        ctx.strokePath()
    }

    /// MIDI clips: notes as bars, vertical position by pitch within the clip's own range.
    private func drawNotes(_ ctx: CGContext, _ clip: ClipView, rect: CGRect, color: NSColor, dim: Bool) {
        let visible = clip.notes.filter { $0.start >= clip.offset && $0.start < clip.offset + clip.length }
        guard let lo = visible.map(\.pitch).min(), let hi = visible.map(\.pitch).max() else { return }
        let top = rect.minY + titleH + 4, height = rect.maxY - 4 - top
        let span = CGFloat(max(Int(hi) - Int(lo), 11)) + 1
        let row = max(1, min(6, height / span)) // short lanes: thinner rows rather than notes over the clip's title
        let base = max(top, top + (height - row * span) / 2)
        ctx.setFillColor(color.withAlphaComponent(dim ? 0.45 : 0.95).cgColor)
        for n in visible {
            let x0 = xPos(forFrame: Double(clip.start + n.start - clip.offset))
            let end = min(n.start + n.length, clip.offset + clip.length)
            let x1 = xPos(forFrame: Double(clip.start + end - clip.offset))
            let y = base + (CGFloat(hi) - CGFloat(n.pitch) + CGFloat(span - CGFloat(Int(hi) - Int(lo)) - 1) / 2) * row
            let r = CGRect(x: x0, y: y, width: max(1.5, x1 - x0 - 0.5), height: max(1.5, row - 1))
            switch Theme.look.arrangement {
            case .flat: ctx.fill(r)
            case .glass: // beads of light: rounded, so dense passages still read as separate notes
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(r.height, r.width) / 2, cornerHeight: min(r.height, r.width) / 2, transform: nil)); ctx.fillPath()
            case .manuscript: // a round head where the note starts and a fine duration line: phrases read as written
                let d = max(2.5, min(row + 0.5, 6))
                ctx.fill(CGRect(x: r.minX, y: r.midY - 0.5, width: r.width, height: max(1, row * 0.28)))
                ctx.fillEllipse(in: CGRect(x: r.minX - 0.5, y: r.midY - d / 2, width: d, height: d))
            }
        }
    }

    /// Double-click on a MIDI clip (opens the piano roll).
    var onOpenClip: ((ClipView) -> Void)?
    /// Any click in the arrangement (returns editing commands to it).
    var onActivate: (() -> Void)?

    var highlightedTrack: DalnokTrackId? { didSet { if oldValue != highlightedTrack { needsDisplay = true } } }

    /// New tracks (added by hand, a template, duplicate or undo) glow in the accent colour for a moment, as Bitwig and
    /// Studio One mark where a new lane landed. Not on project open: those tracks are all new.
    private func noteTrackChanges() {
        let ids = Set(session.tracks.map(\.id))
        defer { knownTracks = ids }
        guard let known = knownTracks, !Motion.reduced else { return }
        let added = ids.subtracting(known)
        guard !added.isEmpty, added.count <= 8, !known.isDisjoint(with: ids) || (known.isEmpty && session.projectURL == nil) else { return }
        let t0 = CACurrentMediaTime()
        for id in added { laneFlash[id] = t0 }
        flashDriver?.cancel()
        flashDriver = Motion.drive(self, duration: Self.laneFlashSeconds, curve: .easeOut, { [weak self] _ in
            self?.needsDisplay = true
        }, completion: { [weak self] in self?.laneFlash = [:]; self?.needsDisplay = true })
    }

    /// Muting a track or clip hatches and greys its clips: the old look fades out over the new one instead of
    /// switching in one frame.
    private func crossfadeMuteChanges(_ now: [DalnokClipId: (clip: ClipView, track: TrackView, laneIndex: Int)], quiet: Set<DalnokTrackId>,
                                      in host: CALayer) {
        let changed = now.compactMap { id, n -> (ClipView, TrackView, Int)? in
            guard let old = knownClips[id], old.laneIndex == n.laneIndex,
                  old.track.muted != n.track.muted || old.clip.muted != n.clip.muted
                    || knownQuiet.contains(n.track.id) != quiet.contains(n.track.id) else { return nil }
            return (old.clip, old.track, n.laneIndex)
        }
        guard !changed.isEmpty, changed.count <= 64 else { return }
        let scale = window?.backingScaleFactor ?? 2
        for (clip, track, lane) in changed {
            let y = laneY(lane)
            let area = clipRect(clip, laneY: y).intersection(visibleRect)
            let wasQuiet = knownQuiet.contains(track.id)
            guard !area.isEmpty, let image = render(area, scale: scale, { ctx in
                if wasQuiet { ctx.setAlpha(Self.soloSilencedAlpha) }
                self.drawClip(ctx, clip, track: track, laneY: y, scale: scale)
            }) else { continue }
            let l = CALayer()
            l.contents = image
            l.contentsScale = scale
            l.frame = area
            host.addSublayer(l)
            CATransaction.begin()
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.22
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            l.opacity = 0
            l.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }
    /// Draws into an offscreen image of `area` (view coordinates).
    private func render(_ area: CGRect, scale: CGFloat, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(ceil(area.width * scale)), height: Int(ceil(area.height * scale)), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: -scale); ctx.translateBy(x: -area.minX, y: -area.maxY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func drawLanes(_ ctx: CGContext) {
        let family = Theme.look.arrangement
        if family != .glass { ctx.setFillColor(Theme.laneA.cgColor); ctx.fill(bounds) }
        if family != .flat { drawSkinnedLanes(ctx, family); return }
        for (i, t) in session.tracks.enumerated() {
            let y = laneY(i)
            ctx.setFillColor((t.id == highlightedTrack ? Theme.laneHighlight : (i % 2 == 0 ? Theme.laneA : Theme.laneB)).cgColor)
            let lh = session.laneHeight(i)
            ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: lh))
            if let t0 = laneFlash[t.id] {
                let k = min(1, (CACurrentMediaTime() - t0) / Self.laneFlashSeconds)
                ctx.setFillColor(t.color.withAlphaComponent(0.28 * (1 - Motion.Curve.easeOut(k))).cgColor)
                ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: lh))
            }
            ctx.setFillColor(Theme.separator.cgColor)
            ctx.fill(CGRect(x: 0, y: y + lh - 1, width: bounds.width, height: 1))
        }
    }

    private func drawGrid(_ ctx: CGContext, scale: CGFloat) {
        let px = 1 / scale
        if Theme.look.arrangement == .manuscript && Self.barsAndBeats { drawManuscriptGrid(ctx, scale: scale); return }
        let f0 = frame(forX: 0), f1 = frame(forX: bounds.width)
        guard Self.barsAndBeats else {
            let step = gridStepFrames()
            var t = floor(f0 / step) * step
            while t <= f1 {
                let x = (xPos(forFrame: t) * scale).rounded() / scale
                ctx.setFillColor(Theme.gridMajor.cgColor)
                ctx.fill(CGRect(x: x, y: Theme.rulerHeight, width: px, height: bounds.height))
                let mx = xPos(forFrame: t + step / 2)
                ctx.setFillColor(Theme.gridMinor.cgColor)
                ctx.fill(CGRect(x: (mx * scale).rounded() / scale, y: Theme.rulerHeight, width: px, height: bounds.height))
                t += step
            }
            return
        }
        let lines = gridLines(from: f0, to: f1 + gridStepFrames())
        for (i, line) in lines.enumerated() {
            let x = (xPos(forFrame: line.frame) * scale).rounded() / scale
            // Bar lines are stronger than beat lines when the grid shows beats.
            ctx.setFillColor((line.isBar ? Theme.gridMajor : Theme.gridMinor.withAlphaComponent(0.06)).cgColor)
            ctx.fill(CGRect(x: x, y: Theme.rulerHeight, width: px, height: bounds.height))
            if i + 1 < lines.count {
                let mx = xPos(forFrame: (line.frame + lines[i + 1].frame) / 2)
                ctx.setFillColor(Theme.gridMinor.cgColor)
                ctx.fill(CGRect(x: (mx * scale).rounded() / scale, y: Theme.rulerHeight, width: px, height: bounds.height))
            }
        }
    }

    private func drawRuler(_ ctx: CGContext, scale: CGFloat) {
        let family = Theme.look.arrangement
        if family != .glass { ctx.setFillColor(Theme.panel.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: Theme.rulerHeight)) }
        switch family {
        case .flat:
            ctx.setFillColor(Theme.separator.cgColor)
            ctx.fill(CGRect(x: 0, y: Theme.rulerHeight - 1, width: bounds.width, height: 1))
        case .glass:
            // The ruler is its own floating strip of glass above the canvas pane.
            ctx.setFillColor(NSColor.clear.cgColor)
            Prism.drawField(in: self, frosted: false, clip: CGRect(x: 0, y: 0, width: bounds.width, height: Theme.rulerHeight))
            Prism.liquidPane(self, CGRect(x: 4, y: 3, width: bounds.width - 8, height: Theme.rulerHeight - 4), radius: (Theme.rulerHeight - 4) / 2)
        case .manuscript:
            // A drafting scale: a double rule closes the ruler (heavy below, hairline above).
            Atelier.rule(ctx, CGPoint(x: 0, y: Theme.rulerHeight - 0.75), CGPoint(x: bounds.width, y: Theme.rulerHeight - 0.75), weight: Atelier.medium)
            Atelier.rule(ctx, CGPoint(x: 0, y: Theme.rulerHeight - 3.5), CGPoint(x: bounds.width, y: Theme.rulerHeight - 3.5), weight: Atelier.hair, color: Theme.ink(0.45))
        }

        drawCycle(ctx)
        drawPunch(ctx)
        var attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(10), .foregroundColor: Theme.textDim]
        if family == .manuscript { attrs = [.font: Theme.title(10.5, .regular), .foregroundColor: Theme.text] }
        let px = 1 / scale
        let step = gridStepFrames()
        let f0 = frame(forX: 0), f1 = frame(forX: bounds.width)
        // Ticks: (frame, label) pairs; minor ticks interpolate between them.
        var marks: [(Double, String?)] = []
        if Self.barsAndBeats {
            let wholeBars = gridStepBeats().bars > 0
            let lines = gridLines(from: f0, to: f1 + step)
            marks = lines.map { ($0.frame, $0.frame >= 0 ? barsLabel($0.frame, wholeBars: wholeBars) : nil) }
        } else {
            var t = floor(f0 / step) * step
            while t <= f1 + step { marks.append((t, t >= 0 ? Self.formatTime(t / sampleRate, step: step / sampleRate) : nil)); t += step }
        }
        for (i, mark) in marks.enumerated() {
            let x = (xPos(forFrame: mark.0) * scale).rounded() / scale
            ctx.setFillColor((family == .manuscript ? Theme.ink(0.7) : family == .glass ? Theme.ink(0.22) : Theme.textFaint).cgColor)
            ctx.fill(CGRect(x: x, y: family == .manuscript ? 12 : 2, width: px, height: Theme.rulerHeight - (family == .manuscript ? 13 : 3)))
            let next = i + 1 < marks.count ? marks[i + 1].0 : mark.0 + step
            ctx.setFillColor(Theme.ink(family == .manuscript ? 0.3 : 0.12).cgColor)
            for k in 1..<4 {
                let tx = (xPos(forFrame: mark.0 + (next - mark.0) * Double(k) / 4) * scale).rounded() / scale
                ctx.fill(CGRect(x: tx, y: Theme.rulerHeight - (k == 2 ? 8 : 5), width: px, height: k == 2 ? 7 : 4))
            }
            if let label = mark.1 { (label as NSString).draw(at: CGPoint(x: x + 4, y: 2), withAttributes: attrs) }
        }
        drawTempoMarkers(ctx)
        drawMarkers(ctx)
    }

    // MARK: Markers: flags along the top of the ruler (click: go there; drag: move; double-click: rename)

    var onRenameMarker: ((Int32) -> Void)?
    private var markerDrag: (id: Int32, x: CGFloat, frame: Int64, moved: Bool, preview: Int64)?
    private static var markerColor: NSColor { Theme.look.arrangement == .glass ? Theme.accent : Theme.hex(0xE0A43A) }
    private func markerRect(_ m: DalnokMarker, frame: Int64? = nil) -> CGRect {
        let x = xPos(forFrame: Double(frame ?? m.frame))
        let w = (markerLabel(m) as NSString).size(withAttributes: [.font: Self.markerFont]).width + 8
        return CGRect(x: x, y: 1, width: min(140, w), height: 12)
    }
    static var markerFont: NSFont { Theme.look.arrangement == .manuscript ? Theme.note(10.5) : Theme.ui(9, .semibold) }
    /// Atelier letters its sections in order, like the parts of a plate ("A  Verse", "B  Chorus").
    func markerLabel(_ m: DalnokMarker) -> String {
        guard Theme.look.arrangement == .manuscript else { return fixedString(m.name) }
        return sectionLetter(m) + "  " + fixedString(m.name)
    }
    func sectionLetter(_ m: DalnokMarker) -> String {
        let i = session.markers.sorted { $0.frame < $1.frame }.firstIndex { $0.id == m.id } ?? 0
        return i < 26 ? String(UnicodeScalar(UInt8(65 + i))) : "\(i + 1)"
    }
    fileprivate func markerDragPreview(_ id: Int32) -> Int64? { markerDrag?.id == id ? markerDrag!.preview : nil }
    func marker(atPoint p: CGPoint) -> DalnokMarker? {
        session.markers.reversed().first { markerRect($0).insetBy(dx: -2, dy: -1).contains(p) }
    }
    private func drawMarkers(_ ctx: CGContext) {
        if Theme.look.arrangement == .manuscript { drawSectionHeadings(ctx); return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.ui(9, .semibold), .foregroundColor: Theme.hex(0x1A1400)]
        for m in session.markers {
            let f = markerDrag?.id == m.id ? markerDrag!.preview : m.frame
            let r = markerRect(m, frame: f)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            ctx.setFillColor(Self.markerColor.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.fillPath()
            ctx.fill(CGRect(x: r.minX, y: 1, width: 1.5, height: Theme.rulerHeight - 2))
            ctx.saveGState(); ctx.clip(to: r.insetBy(dx: 3, dy: 0))
            (markerLabel(m) as NSString).draw(at: CGPoint(x: r.minX + 4, y: r.minY), withAttributes: attrs)
            ctx.restoreGState()
            ctx.setFillColor(Self.markerColor.withAlphaComponent(0.16).cgColor) // a guide through the lanes
            ctx.fill(CGRect(x: r.minX, y: Theme.rulerHeight, width: 1, height: bounds.height - Theme.rulerHeight))
        }
    }

    /// A stack's lane: its members' clips as slim bars in their colours (a map of the stack), one row each.
    private func drawStackSummary(_ ctx: CGContext, _ stack: TrackView, laneY y: CGFloat) {
        let members = session.contents(of: stack.id).filter { !$0.isStack } // the audio inside, at any depth
        guard !members.isEmpty else { return }
        let top = y + 8, h = laneHeight(atLaneY: y) - 16, row = max(2, min(8, h / CGFloat(members.count)))
        for (k, m) in members.enumerated() {
            ctx.setFillColor(m.color.withAlphaComponent(stack.collapsed ? 0.75 : 0.4).cgColor)
            for c in m.clips {
                let x0 = xPos(forFrame: Double(c.start)), x1 = xPos(forFrame: Double(c.end))
                guard x1 > 0, x0 < bounds.width else { continue }
                ctx.fill(CGRect(x: x0, y: top + CGFloat(k) * row, width: max(1, x1 - x0), height: max(1.5, row - 1.5)))
            }
        }
    }

    /// The cycle region: a band in the ruler (bright when on) and, when on, a faint wash over the lanes.
    private func drawCycle(_ ctx: CGContext) {
        let c = session.cycle
        guard c.end > c.start else { return }
        let a = xPos(forFrame: Double(c.start)), b = xPos(forFrame: Double(c.end))
        guard b > 0, a < bounds.width else { return }
        let band = CGRect(x: a, y: 1, width: b - a, height: Theme.rulerHeight - 3)
        ctx.setFillColor(Theme.cycle.withAlphaComponent(c.on ? 0.32 : 0.10).cgColor)
        ctx.fill(band)
        ctx.setFillColor(Theme.cycle.withAlphaComponent(c.on ? 1 : 0.35).cgColor)
        ctx.fill(CGRect(x: a, y: 1, width: 2, height: band.height))
        ctx.fill(CGRect(x: b - 2, y: 1, width: 2, height: band.height))
        if c.on {
            ctx.setFillColor(Theme.cycle.withAlphaComponent(0.035).cgColor)
            ctx.fill(CGRect(x: a, y: Theme.rulerHeight, width: b - a, height: bounds.height - Theme.rulerHeight))
        }
    }

    /// Autopunch: a red bar along the bottom of the ruler with a faint wash over the lanes.
    private func drawPunch(_ ctx: CGContext) {
        guard showPunch, let p = punchRange else { return }
        let a = xPos(forFrame: Double(p.0)), b = xPos(forFrame: Double(p.1))
        guard b > 0, a < bounds.width else { return }
        ctx.setFillColor(Theme.recordOn.withAlphaComponent(0.85).cgColor)
        ctx.fill(CGRect(x: a, y: Theme.rulerHeight - 4, width: b - a, height: 3))
        ctx.setFillColor(Theme.recordOn.withAlphaComponent(0.05).cgColor)
        ctx.fill(CGRect(x: a, y: Theme.rulerHeight, width: b - a, height: bounds.height - Theme.rulerHeight))
    }

    /// Tempo and meter changes after the start, as small flags on the ruler (the first values live in the control bar).
    private func drawTempoMarkers(_ ctx: CGContext) {
        guard Self.barsAndBeats else { return }
        var flags: [(Double, String)] = session.tempoPoints.dropFirst().map {
            (session.beatToFrame($0.beat), String(format: "\u{2669}%g", $0.bpm))
        }
        flags += session.meterPoints.dropFirst().map {
            (session.beatToFrame(session.barToBeat(Int($0.bar))), "\($0.numerator)/\($0.denominator)")
        }
        // One flag per position: a tempo and a time signature change on the same downbeat share a label.
        var merged: [(Double, String)] = []
        for flag in flags.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, abs(last.0 - flag.0) < 1 { merged[merged.count - 1].1 += "  " + flag.1 } else { merged.append(flag) }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9, .semibold), .foregroundColor: Theme.panel]
        for (frame, text) in merged {
            let x = xPos(forFrame: frame)
            guard x > -60, x < bounds.width else { continue }
            let size = (text as NSString).size(withAttributes: attrs)
            let r = CGRect(x: x, y: Theme.rulerHeight - 12, width: size.width + 6, height: 11)
            ctx.setFillColor(Theme.accent.cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.fillPath()
            ctx.fill(CGRect(x: x, y: 2, width: 1, height: Theme.rulerHeight - 3))
            (text as NSString).draw(at: CGPoint(x: x + 3, y: r.minY), withAttributes: attrs)
        }
    }

    /// Position display text: "bar.beat.sixteenth.tick" (240 ticks per 16th) or minutes and seconds.
    // MARK: Accessibility: every visible clip is a pressable element (press selects it).

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Arrangement" }
    override func accessibilityChildren() -> [Any]? {
        var out: [Any] = []
        for (i, t) in session.tracks.enumerated() {
            let y = laneY(i)
            guard y + session.laneHeight(i) > Theme.rulerHeight, y < bounds.height else { continue }
            for c in t.clips {
                let r = clipRect(c, laneY: y).intersection(bounds)
                guard !r.isEmpty else { continue }
                let length = TimelineView.formatTime(Double(c.length) / sampleRate, step: 0.1)
                let label = "\(c.name.isEmpty ? "Clip" : c.name) on \(t.name), at \(positionText(c.start)), \(length) long"
                    + (c.isMidi ? ", MIDI" : "") + (c.offline ? ", audio missing" : "")
                let id = c.id
                out.append(AXItem.make(in: self, rect: r, role: .button, label: label,
                                       value: selectedClips.contains(id) ? "selected" : nil) { [weak self] in
                    guard let self else { return false }
                    self.select([id], primary: id)
                    if let clip = self.session.clip(id) { self.onClipSelected?(clip) }
                    return true
                })
            }
        }
        return out
    }

    func positionText(_ frame: Int64, barsAndBeats: Bool = TimelineView.barsAndBeats) -> String {
        guard barsAndBeats else { return Self.formatTime(Double(frame) / sampleRate) }
        // A frame stands for the interval [frame, frame + 1): show the tick at its middle, so a grid line that falls
        // inside it (at 44.1 kHz and 96 BPM a beat is 27,562.5 frames) reads as that line, not the tick before it.
        let b = session.bar(atBeat: session.frameToBeat(Double(frame) + 0.5))
        let sixteenths = b.beatInBar * 16 / Double(b.den) // 16ths since the bar start
        let whole = Int(sixteenths.rounded(.down)), ticks = min(239, Int((sixteenths - Double(whole)) * 240))
        let perBeat = max(1, 16 / b.den)
        return String(format: "%d.%d.%d.%03d", b.bar + 1, whole / perBeat + 1, whole % perBeat + 1, ticks)
    }

    static func formatTime(_ t: Double, step: Double = 0.001) -> String {
        let m = Int(t) / 60
        let s = t - Double(m * 60)
        if step >= 1 { return String(format: "%d:%02d", m, Int(s.rounded())) }
        if step >= 0.1 { return String(format: "%d:%04.1f", m, s) }
        if step >= 0.01 { return String(format: "%d:%05.2f", m, s) }
        return String(format: "%d:%06.3f", m, s)
    }

    // MARK: Clip motion (ClipMotion.swift)

    /// Where the clips with these ids are now (their union), if any is on screen.
    private func rect(of ids: Set<DalnokClipId>) -> CGRect? {
        var r: CGRect?
        for (i, t) in session.tracks.enumerated() {
            for c in t.clips where ids.contains(c.id) { let cr = clipRect(c, laneY: laneY(i)); r = r?.union(cr) ?? cr }
        }
        return r
    }

    /// A picture of just these clips (no lanes or grid behind them), in view coordinates.
    private func picture(of ids: Set<DalnokClipId>) -> (CGImage, CGRect)? {
        guard let area = rect(of: ids)?.insetBy(dx: -1, dy: -1), area.width >= 1, area.height >= 1 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        guard let ctx = CGContext(data: nil, width: Int(ceil(area.width * scale)), height: Int(ceil(area.height * scale)), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: -scale) // flipped, like the view
        ctx.translateBy(x: -area.minX, y: -area.maxY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for (i, t) in session.tracks.enumerated() {
            for c in t.clips where ids.contains(c.id) { drawClip(ctx, c, track: t, laneY: laneY(i), scale: scale) }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { ($0, area) }
    }

    /// The outline left where lifted clips will land: a dashed edge and a faint wash of the track colour.
    private func drawGhost(_ ctx: CGContext, _ rect: CGRect, color: NSColor) {
        let path = CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(color.withAlphaComponent(0.16).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(color.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
    }

    /// Body drags: after 3 pt the clips lift. From then on the picture springs from grid step to grid step and lane
    /// to lane, to wherever the clips would land (`snapLift`), rather than gliding under the pointer.
    private func liftClips(_ d: Drag, pointer p: CGPoint) {
        if lift != nil { return }
        guard !Motion.reduced, hypot(p.x - d.startX, p.y - d.startY) >= 3, let host = layer else { return }
        let ids = Set(d.moving.map(\.id))
        guard let (image, area) = picture(of: ids) else { return }
        let l = ClipLift(image: image, frame: area, in: host, scale: window?.backingScaleFactor ?? 2)
        lift = l
        lifted = ids
        landing = false
        needsDisplay = true
    }

    /// Points the lifted picture at where the clips now sit on the grid (after the drag moved them).
    private func snapLift() {
        guard let lift, let landing = rect(of: lifted)?.insetBy(dx: -1, dy: -1) else { return }
        lift.target = CGPoint(x: landing.midX, y: landing.midY)
    }

    /// Drops the lifted picture onto where the clips ended up (or ends it at once).
    func endLift(animated: Bool) {
        guard let l = lift else { return }
        lift = nil
        guard animated, !Motion.reduced, let target = rect(of: lifted)?.insetBy(dx: -1, dy: -1) else {
            l.cancel(); lifted = []; landing = false; needsDisplay = true
            return
        }
        landing = true
        needsDisplay = true
        l.drop(onto: target) { [weak self] in
            guard let self, self.lift == nil else { return }
            self.lifted = []; self.landing = false; self.needsDisplay = true
        }
    }

    /// Clips that appeared since the last call pop in; clips that went away shrink and fade where they were. Called
    /// after each model change; large changes (opening a project, switching tracks wholesale) are not animated.
    /// Tracks seen at the last model change, and when each new one arrived (its lane glows, then settles).
    private var knownTracks: Set<DalnokTrackId>?
    private(set) var laneFlash: [DalnokTrackId: CFTimeInterval] = [:]
    private var flashDriver: MotionDriver?
    static let laneFlashSeconds = 0.8

    func noteClipChanges() {
        var now: [DalnokClipId: (clip: ClipView, track: TrackView, laneIndex: Int)] = [:]
        for (i, t) in session.tracks.enumerated() { for c in t.clips { now[c.id] = (c, t, i) } }
        let quietNow = session.soloSilenced()
        defer { knownClips = now; knownQuiet = quietNow }
        noteTrackChanges()
        guard !Motion.reduced, drag == nil, let host = layer else { return }
        crossfadeMuteChanges(now, quiet: quietNow, in: host)
        guard !knownClips.isEmpty else { return }
        let added = now.keys.filter { knownClips[$0] == nil }, removed = knownClips.keys.filter { now[$0] == nil }
        guard !(added.isEmpty && removed.isEmpty), added.count + removed.count <= 16,
              Set(knownClips.values.map(\.track.id)).intersection(session.tracks.map(\.id)).count > 0 else { return } // another project
        let scale = window?.backingScaleFactor ?? 2
        for id in added {
            guard let (image, area) = picture(of: [id]), area.intersects(visibleRect) else { continue }
            ClipFlourish.pop(image, frame: area, in: host, scale: scale)
        }
        for id in removed {
            guard let old = knownClips[id], old.laneIndex < session.tracks.count else { continue }
            let y = laneY(old.laneIndex)
            let area = clipRect(old.clip, laneY: y).insetBy(dx: -1, dy: -1)
            guard area.intersects(visibleRect),
                  let ctx = CGContext(data: nil, width: Int(ceil(area.width * scale)), height: Int(ceil(area.height * scale)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.scaleBy(x: scale, y: -scale); ctx.translateBy(x: -area.minX, y: -area.maxY)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            drawClip(ctx, old.clip, track: old.track, laneY: y, scale: scale)
            NSGraphicsContext.restoreGraphicsState()
            if let image = ctx.makeImage() { ClipFlourish.poof(image, frame: area, in: host, scale: scale) }
        }
    }

    func clipRect(_ clip: ClipView, laneY: CGFloat) -> CGRect {
        let x0 = xPos(forFrame: Double(clip.start)), x1 = xPos(forFrame: Double(clip.end))
        return CGRect(x: x0, y: laneY + 3, width: max(2, x1 - x0), height: laneHeight(atLaneY: laneY) - 7)
    }

    private func drawClip(_ ctx: CGContext, _ clip: ClipView, track: TrackView, laneY: CGFloat, scale: CGFloat) {
        let rect = clipRect(clip, laneY: laneY)
        guard rect.maxX > 0, rect.minX < bounds.width else { return }
        if Theme.look.arrangement != .flat { drawSkinnedClip(ctx, clip, track: track, rect: rect, scale: scale); return }
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        let tint = TrackTint(base: clip.offline ? Theme.textFaint : (track.muted ? TrackTint(base: track.color).muted : track.color))
        let selected = selectedClips.contains(clip.id)
        let dim = track.muted || clip.muted || clip.offline

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor((selected ? tint.bodySelected : tint.body).cgColor)
        ctx.fill(rect)
        let titleBg = selected ? tint.titleSelected : tint.title
        ctx.setFillColor(titleBg.cgColor)
        ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleH))
        if dim { drawHatch(ctx, rect) }

        if clip.isMidi {
            drawNotes(ctx, clip, rect: rect, color: tint.waveform, dim: dim)
        } else if let media = session.engine.poolMedia(clip.media) {
            drawWaveform(ctx, media: media, clip: clip, rect: rect, top: rect.minY + titleH + 2, color: tint.waveform,
                         dim: dim || clip.processing, scale: scale)
        }
        drawFades(ctx, clip, rect: rect)

        // Title: name in a contrast-picked color; tags (speed, pitch, gain, state) quieter.
        let fg = TrackTint.textColor(on: titleBg)
        var tags: [String] = []
        if clip.offline { tags.append("offline") }
        if clip.muted || track.muted { tags.append("muted") } // in words as well as hatching, in every look (audit L1)
        if clip.isMidi { tags.append(clip.notes.count == 1 ? "1 note" : "\(clip.notes.count) notes") }
        if clip.folder != 0 { tags.append("⧉ takes \(session.takes(clip.folder).count)") }
        if abs(clip.rate - 1) > 1e-9 { tags.append(String(format: "%.0f%% speed", clip.rate * 100)) }
        if clip.pitch != 0 { tags.append(String(format: "%+g st", Double(clip.pitch))) }
        if !clip.preservePitch && abs(clip.rate - 1) > 1e-9 { tags.append("varispeed") }
        if clip.processing { tags.append("rendering…") }
        if clip.gainDb != 0 { tags.append(clip.gainDb.isFinite ? String(format: "%+.1f dB", clip.gainDb) : "−∞ dB") }
        // Older projects named every MIDI clip "MIDI"; show the track's name instead, as new clips are named.
        let name = clip.isMidi && clip.name == "MIDI" ? track.name : clip.name
        drawTitle(ctx, name, tags: tags.isEmpty ? "" : "   " + tags.joined(separator: "   "), fg: fg,
                  at: CGPoint(x: max(rect.minX, 0) + 6, y: rect.minY + 1.5))
        ctx.restoreGState()
        if selected || clip.id == hoveredClip { drawFadeHandles(ctx, clip, rect: rect) }
        drawWarpMarkers(ctx, clip, rect: rect)

        ctx.addPath(path)
        ctx.setStrokeColor((selected ? Theme.selection : tint.border).cgColor)
        ctx.setLineWidth(selected ? 1.5 : 1)
        ctx.strokePath()
    }

    /// Typeset clip titles, kept across redraws: shaping the same names again was about a third of drawing a lane.
    private var titleLines: [String: (line: CTLine, ascent: CGFloat)] = [:]

    /// Draws a clip title (name semibold, tags quieter) with its line box's top-left at `p`, like NSAttributedString.draw(at:).
    private func drawTitle(_ ctx: CGContext, _ name: String, tags: String, fg: NSColor, at p: CGPoint) {
        let rgb = fg.usingColorSpace(.sRGB) ?? fg
        let key = String(format: "%.4f %.4f %.4f %.4f|", rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent) + name + "|" + tags
        let entry: (line: CTLine, ascent: CGFloat)
        if let cached = titleLines[key] {
            entry = cached
        } else {
            let title = NSMutableAttributedString(string: name, attributes: [
                .font: Theme.ui(10.5, .semibold), NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg.cgColor])
            if !tags.isEmpty {
                title.append(NSAttributedString(string: tags, attributes: [
                    .font: Theme.ui(10, .regular),
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): fg.withAlphaComponent(0.7).cgColor]))
            }
            let line = CTLineCreateWithAttributedString(title)
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
            entry = (line, ascent)
            if titleLines.count > 4_096 { titleLines.removeAll(keepingCapacity: true) }
            titleLines[key] = entry
        }
        let matrix = ctx.textMatrix
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: isFlipped ? -1 : 1)
        ctx.textPosition = CGPoint(x: p.x, y: isFlipped ? p.y + entry.ascent : p.y - entry.ascent)
        CTLineDraw(entry.line, ctx)
        ctx.textMatrix = matrix
    }

    /// Diagonal hatch for muted/offline clips (state shown by form, not only color).
    private func drawHatch(_ ctx: CGContext, _ rect: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(Theme.ink(0.05).cgColor)
        ctx.setLineWidth(1)
        var x = rect.minX - rect.height
        while x < rect.maxX {
            ctx.move(to: CGPoint(x: x, y: rect.maxY)); ctx.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 6
        }
        ctx.strokePath()
        ctx.restoreGState()
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
            // The faded-out part: darkened on dark canvases, washed back to paper on light ones.
            ctx.setFillColor((Theme.isLight ? Theme.laneA.withAlphaComponent(0.72) : NSColor.black.withAlphaComponent(0.38)).cgColor)
            ctx.fillPath()
            ctx.addLines(between: pts)
            ctx.setStrokeColor((Theme.isLight ? Theme.text.withAlphaComponent(0.8) : Theme.ink(0.75)).cgColor)
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

    /// A quantized clip's hits: a short tick at the top and bottom of the waveform, with a grip triangle (drag to move).
    private func drawWarpMarkers(_ ctx: CGContext, _ clip: ClipView, rect: CGRect) {
        guard clip.warp.count > 2, rect.height > titleH + 10 else { return }
        let color = Theme.text.withAlphaComponent(0.7)
        ctx.saveGState()
        ctx.setFillColor(color.cgColor)
        let hit = clip.warpHitOffset(sampleRate: sampleRate)
        for i in clip.warpMarkers(sampleRate: sampleRate) {
            let x = xPos(forFrame: Double(clip.start + clip.warp[i].time + hit)).rounded() + 0.5
            guard x > rect.minX + 2, x < rect.maxX - 2 else { continue }
            ctx.fill(CGRect(x: x - 0.5, y: rect.minY + titleH, width: 1, height: 5))
            ctx.fill(CGRect(x: x - 0.5, y: rect.maxY - 6, width: 1, height: 5))
            ctx.move(to: CGPoint(x: x - 3, y: rect.maxY - 1)); ctx.addLine(to: CGPoint(x: x + 3, y: rect.maxY - 1))
            ctx.addLine(to: CGPoint(x: x, y: rect.maxY - 5)); ctx.closePath(); ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// Window-coordinate point of a quantized clip's hit marker (self-test).
    func windowPoint(ofWarp i: Int, in id: DalnokClipId) -> CGPoint? {
        guard let ti = session.tracks.firstIndex(where: { $0.clips.contains { $0.id == id } }),
              let c = session.clip(id), c.warp.indices.contains(i) else { return nil }
        let r = clipRect(c, laneY: laneY(ti))
        return convert(CGPoint(x: xPos(forFrame: Double(c.start + c.warp[i].time + c.warpHitOffset(sampleRate: sampleRate))), y: r.maxY - 8), to: nil)
    }

    /// One min/max column per device pixel across the visible span.
    private func drawWaveform(_ ctx: CGContext, media: OpaquePointer, clip: ClipView, rect: CGRect, top: CGFloat,
                              color: NSColor, dim: Bool, scale: CGFloat) {
        let visX0 = max(rect.minX, 0), visX1 = min(rect.maxX, bounds.width)
        let columns = Int(((visX1 - visX0) * scale).rounded(.up))
        guard columns > 0 else { return }
        if clip.warp.count >= 2 { // a quantized clip: each warp segment drawn at its own speed
            for i in 1..<clip.warp.count {
                let a = clip.warp[i - 1], b = clip.warp[i]
                let x0 = max(visX0, xPos(forFrame: Double(clip.start + a.time))), x1 = min(visX1, xPos(forFrame: Double(clip.start + b.time)))
                guard x1 > x0 else { continue }
                var part = clip
                part.warp = []
                part.fields.start = clip.start + a.time
                part.fields.offset = a.source
                part.fields.length = b.time - a.time
                part.fields.rate = Double(b.source - a.source) / Double(b.time - a.time)
                drawWaveform(ctx, media: media, clip: part, rect: CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height),
                             top: top, color: color, dim: dim, scale: scale)
            }
            return
        }
        if mins.count < columns { mins = [Float](repeating: 0, count: columns); maxs = mins }
        // Stretched clips draw their source at `rate` source frames per timeline frame.
        let fpc = framesPerPoint / Double(scale) * clip.rate
        let sourceStart = Int64((frame(forX: visX0) - Double(clip.start)) * clip.rate) + clip.offset
        let waveH = rect.maxY - top - 3
        let chans = min(Int(dalnok_media_channels(media)), 2)
        let laneH = waveH / CGFloat(chans)
        ctx.setStrokeColor(color.withAlphaComponent(dim ? 0.35 : 0.95).cgColor)
        ctx.setLineWidth(1 / scale)
        let pen = Theme.look.arrangement == .manuscript // Atelier: drawn with a pen, not filled pixel by pixel
        for ch in 0..<chans {
            dalnok_media_peaks(media, Int32(ch), sourceStart, fpc, &mins, &maxs, Int64(columns))
            let mid = top + laneH * (CGFloat(ch) + 0.5)
            let half = laneH * 0.48
            if pen {
                // Shading strokes every 1.8 pt, and the envelope traced above and below in one quick line each.
                let step = max(1, Int((1.8 * scale).rounded()))
                ctx.setLineWidth(0.7)
                ctx.setStrokeColor(color.withAlphaComponent(dim ? 0.3 : 0.7).cgColor)
                for i in stride(from: 0, to: columns, by: step) {
                    let px = visX0 + (CGFloat(i) + 0.5) / scale
                    ctx.move(to: CGPoint(x: px, y: mid - CGFloat(maxs[i]) * half)); ctx.addLine(to: CGPoint(x: px, y: mid - CGFloat(mins[i]) * half))
                }
                ctx.strokePath()
                ctx.setStrokeColor(color.withAlphaComponent(dim ? 0.4 : 0.95).cgColor); ctx.setLineWidth(0.9); ctx.setLineJoin(.round)
                for edge in [maxs, mins] {
                    var pts: [CGPoint] = []
                    pts.reserveCapacity(columns / step + 1)
                    for i in stride(from: 0, to: columns, by: step) { pts.append(CGPoint(x: visX0 + (CGFloat(i) + 0.5) / scale, y: mid - CGFloat(edge[i]) * half)) }
                    ctx.addLines(between: pts); ctx.strokePath()
                }
                continue
            }
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
            if clip.warp.count > 2, p.y > r.minY + titleH + 4 {
                let hit = clip.warpHitOffset(sampleRate: sampleRate)
                for i in clip.warpMarkers(sampleRate: sampleRate) where abs(xPos(forFrame: Double(clip.start + clip.warp[i].time + hit)) - p.x) <= 4 {
                    return (clip, .warp(i))
                }
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
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) { showHoverLine(atX: nil) }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        showHoverLine(atX: p.x, bypass: event.modifierFlags.contains(.control))
        let h = hit(p)
        hoveredClip = h?.0.id
        hoverHint = hint(p, h)
        switch h?.1 {
        case .leftEdge?, .rightEdge?: NSCursor.resizeLeftRight.set()
        case .fadeIn?, .fadeOut?: NSCursor.crosshair.set()
        case .body?: NSCursor.openHand.set()
        case .warp?: NSCursor.resizeLeftRight.set()
        case nil: NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder is KeyOwner { window?.makeFirstResponder(nil) } // the arrangement keys come back
        onActivate?()
        let p = convert(event.locationInWindow, from: nil)
        hoverLine.isHidden = true
        if p.y < Theme.rulerHeight, let m = marker(atPoint: p) {
            if event.clickCount == 2 { onRenameMarker?(m.id); return }
            markerDrag = (m.id, p.x, m.frame, false, m.frame)
            return
        }
        if p.y >= Theme.rulerHeight / 2 && p.y < Theme.rulerHeight { seek(toX: p.x); scrubbing = true; return } // lower half: playhead
        if p.y >= Theme.rulerHeight && autoMouseDown(p, event) { return }
        if p.y < Theme.rulerHeight { // upper half: cycle
            let c = session.cycle
            let a = xPos(forFrame: Double(c.start)), b = xPos(forFrame: Double(c.end))
            let kind: RulerDrag.Kind = c.end <= c.start ? .create
                : abs(p.x - a) <= 5 ? .start : abs(p.x - b) <= 5 ? .end : (p.x > a && p.x < b ? .move : .create)
            rulerDrag = RulerDrag(kind: kind, x: p.x, start: c.start, end: c.end)
            return
        }
        guard let (clip, zone) = hit(p) else {
            if event.clickCount == 2, let i = trackIndex(atY: p.y), createMidiClip(onTrackAt: i, atX: p.x) { return }
            let initial = event.modifierFlags.contains(.shift) ? selectedClips : []
            if initial.isEmpty { selectedClip = nil }
            marquee = Marquee(start: p, end: p, initial: initial)
            return
        }
        if event.modifierFlags.contains(.shift) {
            var ids = selectedClips
            if ids.remove(clip.id) != nil {
                select(ids, primary: selectedClip == clip.id ? ids.sorted().first : selectedClip)
                if let id = selectedClip, let remaining = session.clip(id) { onClipSelected?(remaining) }
                return
            }
            ids.insert(clip.id); select(ids, primary: clip.id)
        } else if selectedClips.contains(clip.id) {
            select(selectedClips, primary: clip.id)
        } else {
            selectedClip = clip.id
        }
        onClipSelected?(clip)
        playFrom = .clips
        if event.clickCount == 2 { onOpenClip?(clip); return }
        let stretch = zone == .rightEdge && event.modifierFlags.contains(.option) && !clip.isMidi
        let moving = zone == .body ? selectedClips.compactMap { session.clip($0) } : [clip]
        drag = Drag(clip: clip, moving: moving, zone: zone, startX: p.x, startY: p.y, stretch: stretch)
        if case .warp = zone { session.engine.beginGroup("Move Quantized Hit") } else {
        session.engine.beginGroup(stretch ? "Time Stretch" : zone == .body ? "Move Clip"
                                  : (zone == .fadeIn || zone == .fadeOut) ? "Fade" : "Trim Clip") }
        if zone == .body { NSCursor.closedHand.set() }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if var d = markerDrag {
            d.moved = d.moved || abs(p.x - d.x) >= 3
            if d.moved { d.preview = snap(max(0, Double(d.frame) + Double(p.x - d.x) * framesPerPoint), bypass: event.modifierFlags.contains(.control)) }
            markerDrag = d; needsDisplay = true
            return
        }
        if var m = marquee {
            m.end = CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, Theme.rulerHeight), bounds.height))
            m.moved = m.moved || hypot(m.end.x - m.start.x, m.end.y - m.start.y) >= 3
            if m.moved {
                let r = CGRect(x: min(m.start.x, m.end.x), y: min(m.start.y, m.end.y),
                               width: abs(m.end.x - m.start.x), height: abs(m.end.y - m.start.y))
                var ids = m.initial
                for (i, track) in session.tracks.enumerated() {
                    for clip in track.clips where clipRect(clip, laneY: laneY(i)).intersects(r) { ids.insert(clip.id) }
                }
                let primary = selectedClip.flatMap { ids.contains($0) ? $0 : nil } ?? ids.sorted().first
                select(ids, primary: primary)
            }
            marquee = m; needsDisplay = true
            return
        }
        if var r = rulerDrag {
            r.moved = r.moved || abs(p.x - r.x) >= 3
            rulerDrag = r
            guard r.moved else { return }
            let bypass = event.modifierFlags.contains(.control)
            let at = snap(frame(forX: p.x), bypass: bypass), from = snap(frame(forX: r.x), bypass: bypass)
            var range: (Int64, Int64)
            switch r.kind {
            case .create: range = (min(at, from), max(at, from))
            case .move:
                let delta = max(-r.start, at - from)
                range = (r.start + delta, r.end + delta)
            case .start: range = (min(at, r.end - 1), r.end)
            case .end: range = (r.start, max(at, r.start + 1))
            }
            if range.1 - range.0 >= 64 { session.setCycle(true, range.0, range.1) }
            needsDisplay = true
            return
        }
        if scrubbing { seek(toX: p.x); return }
        if autoMouseDragged(p, event) { return }
        guard var d = drag else { return }
        let bypass = event.modifierFlags.contains(.control)
        let delta = Double(p.x - d.startX) * framesPerPoint
        let c = d.clip
        guard let current = session.clip(c.id) else { return }
        switch d.zone {
        case .warp(let i):
            // The hit plays where the pointer is (on the grid unless ⌃): its anchor's clip time follows.
            guard c.warp.indices.contains(i) else { break }
            let hit = c.warpHitOffset(sampleRate: sampleRate)
            let at = snap(Double(c.start + c.warp[i].time + hit) + delta, bypass: bypass) - current.start - hit
            if let w = current.warpMoving(i, toTime: at, sampleRate: sampleRate),
               w.map(\.time) != current.warp.map(\.time), session.setWarp(c.id, w) { d.changed = true }
        case .body:
            liftClips(d, pointer: p)
            let start = snap(Double(c.start) + delta, bypass: bypass)
            if d.moving.count > 1 {
                let earliest = d.moving.map(\.start).min() ?? 0
                let wanted = max(-earliest, start - c.start)
                let applied = current.start - c.start
                if wanted != applied && session.nudgeClips(d.moving.map(\.id), by: wanted - applied) { d.changed = true }
                snapLift()
                break
            }
            let track = trackIndex(atY: p.y).map { session.tracks[$0].id } ?? current.track
            if start != current.start || track != current.track {
                session.moveClip(c.id, track: track, start: start)
                d.changed = true
            }
            snapLift()
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
            if !c.isMidi { end = min(end, c.start + (c.mediaFrames - c.offset)) } // audio can't extend past its media; MIDI can
            end = max(end, c.start + 1)
            if end != current.end {
                session.setRegion(c.id, start: c.start, offset: c.offset, length: end - c.start)
                d.changed = true
            }
        }
        drag = d
    }

    override func mouseUp(with event: NSEvent) {
        if let d = markerDrag {
            markerDrag = nil
            if d.moved, d.preview != d.frame { session.moveMarker(d.id, to: d.preview) }
            else { playFrom = nil; session.engine.seek(d.frame); updatePlayhead(); onSeek?() }
            needsDisplay = true
            return
        }
        if scrubbing { scrubbing = false; return }
        if autoDrag != nil { autoDrag = nil; session.engine.endGroup(); ValueBubble.hide(); return }
        if let r = rulerDrag {
            rulerDrag = nil
            if !r.moved { seek(toX: r.x) }
            return
        }
        if let m = marquee {
            marquee = nil; needsDisplay = true
            if !m.moved { seek(toX: m.start.x) }
            else {
                playFrom = .range(snap(max(0, frame(forX: min(m.start.x, m.end.x))), bypass: event.modifierFlags.contains(.control)))
                if let id = selectedClip, let clip = session.clip(id) { onClipSelected?(clip) }
            }
            return
        }
        guard let d = drag else { return }
        session.engine.endGroup()
        drag = nil
        if d.zone == .body, convert(event.locationInWindow, from: nil).x < 0, let drop = onDropToLauncher {
            if d.changed { session.undo() } // the clip stays where it was; the slot gets a copy
            endLift(animated: false)
            _ = drop(d.clip.id, event.locationInWindow)
            needsDisplay = true
            return
        }
        endLift(animated: true)
        mouseMoved(with: event)
        onSelectionChange?()
    }

    /// Double-clicking empty space in a lane adds a one-bar MIDI clip at that bar (instrument tracks, and empty audio
    /// tracks, which become instrument tracks) and opens it in the clip editor.
    @discardableResult func createMidiClip(onTrackAt index: Int, atX x: CGFloat) -> Bool {
        guard session.tracks.indices.contains(index) else { return false }
        let t = session.tracks[index]
        guard t.isInstrument || (!t.isBus && t.clips.isEmpty && t.stack == 0) else { return false }
        let bar = session.bar(atBeat: session.frameToBeat(max(0, frame(forX: x)))).bar
        let start = Int64(session.beatToFrame(session.barToBeat(bar)).rounded())
        let end = Int64(session.beatToFrame(session.barToBeat(bar + 1)).rounded())
        let id = session.addMidiClip(t.id, start: max(0, start), length: max(1, end - start))
        guard id != 0, let clip = session.clip(id) else { return false }
        selectedClip = id
        onClipSelected?(clip)
        onOpenClip?(clip)
        return true
    }

    /// Clicks place the playhead on the snap grid (hold Control for an exact position).
    private func seek(toX x: CGFloat) {
        playFrom = nil
        let bypass = NSApp.currentEvent?.modifierFlags.contains(.control) ?? false
        session.engine.seek(snap(max(0, frame(forX: x)), bypass: bypass))
        updatePlayhead()
        onSeek?()
    }

    override func scrollWheel(with event: NSEvent) {
        scroll(with: event, zoomAnchorX: convert(event.locationInWindow, from: nil).x)
    }

    /// One handler for wheel and trackpad scrolling over the arrangement, the track headers and the launcher, so
    /// they share one vertical viewport and never drift apart. ⌘ zooms around `zoomAnchorX`; ⌥ makes every track
    /// taller or shorter.
    var onAllTracksHeight: ((CGFloat) -> Void)?
    func scroll(with event: NSEvent, zoomAnchorX: CGFloat) {
        if event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            if dy != 0 { onAllTracksHeight?(Theme.trackHeight * exp(dy * 0.01)) }
            return
        }
        if event.modifierFlags.contains(.command) {
            zoom(by: exp(-event.scrollingDeltaY * 0.01), around: max(0, zoomAnchorX))
            return
        }
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        if dx != 0 || event.modifierFlags.contains(.shift) { stopGlide() }
        scrollFrame -= Double(dx) * framesPerPoint
        if event.modifierFlags.contains(.shift) && dx == 0 {
            scrollFrame -= Double(dy) * framesPerPoint
        } else {
            scrollY = min(max(0, scrollY - dy), maxScrollY)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 / (1 + event.magnification), around: convert(event.locationInWindow, from: nil).x)
    }

    func zoom(by factor: Double, around x: CGFloat) {
        stopGlide() // a gesture takes over from a running glide
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
        if fitPending && bounds.width >= 200 { zoomToFit() }
        clampScrollY()
        removeAllToolTips()
        addToolTip(CGRect(x: 0, y: 0, width: bounds.width, height: Theme.rulerHeight / 2),
                   owner: "Drag here to set the cycle (loop) region; drag it to move, drag its edges to resize. C turns cycle on or off." as NSString, userData: nil)
        addToolTip(CGRect(x: 0, y: Theme.rulerHeight / 2, width: bounds.width, height: Theme.rulerHeight / 2),
                   owner: "Click or drag to move the playhead (snaps to the grid; hold ⌃ for an exact position)." as NSString, userData: nil)
        updatePlayhead()
    }
}


// MARK: - Theme families: glass (Prism) and manuscript (Atelier) arrangements

extension TimelineView {
    /// The crop marks around a clip (Atelier's selection), as one path so it can glide between clips.
    static func cropMarksPath(_ r: CGRect, length: CGFloat = 7, gap: CGFloat = 3) -> CGPath {
        let p = CGMutablePath()
        for (x, sx) in [(r.minX, -1.0), (r.maxX, 1.0)] as [(CGFloat, CGFloat)] {
            for (y, sy) in [(r.minY, -1.0), (r.maxY, 1.0)] as [(CGFloat, CGFloat)] {
                p.move(to: CGPoint(x: x + sx * gap, y: y)); p.addLine(to: CGPoint(x: x + sx * (gap + length), y: y))
                p.move(to: CGPoint(x: x, y: y + sy * gap)); p.addLine(to: CGPoint(x: x, y: y + sy * (gap + length)))
            }
        }
        return p
    }

    /// Playhead and selection layers for the theme's family (set up once; the window is rebuilt on a theme switch).
    func configureFamilyLayers() {
        switch Theme.look.arrangement {
        case .flat:
            let glow = Theme.activeStyle == .warmAnalog ? Theme.hex(0xFFB866) : Theme.playhead
            playheadTrail.startPoint = CGPoint(x: 0, y: 0.5); playheadTrail.endPoint = CGPoint(x: 1, y: 0.5)
            playheadTrail.colors = [glow.withAlphaComponent(0).cgColor, glow.withAlphaComponent(0.05).cgColor, glow.withAlphaComponent(0.16).cgColor]
            playheadTrail.locations = [0, 0.7, 1]
            playheadTrail.zPosition = 8
            playheadTrail.opacity = 0
            layer?.addSublayer(playheadTrail)
        case .glass:
            // An optical guide: a fine bright core inside a soft column of light, and a prism head that splits the light
            // into a small spectrum fan over the ruler (it marks the position without covering bar numbers).
            playheadHalo.startPoint = CGPoint(x: 0, y: 0.5); playheadHalo.endPoint = CGPoint(x: 1, y: 0.5)
            playheadHalo.colors = [Theme.playhead.withAlphaComponent(0).cgColor, Theme.playhead.withAlphaComponent(0.22).cgColor, Theme.playhead.withAlphaComponent(0).cgColor]
            playheadHalo.zPosition = 9
            playheadHalo.opacity = 0.55
            layer?.addSublayer(playheadHalo)
            let head = CGMutablePath() // a triangular prism pointing down
            head.move(to: CGPoint(x: -6, y: 0)); head.addLine(to: CGPoint(x: 6, y: 0)); head.addLine(to: CGPoint(x: 0, y: 10)); head.closeSubpath()
            playheadCap.path = head
            spectrumFan.bounds = CGRect(x: 0, y: 0, width: 22, height: 6)
            spectrumFan.startPoint = CGPoint(x: 0, y: 0.5); spectrumFan.endPoint = CGPoint(x: 1, y: 0.5)
            spectrumFan.colors = Prism.spectrum.map { $0.withAlphaComponent(0.75).cgColor }
            spectrumFan.zPosition = 10
            let fan = CAShapeLayer() // the fan widens away from the prism
            let fp = CGMutablePath(); fp.move(to: CGPoint(x: 9, y: 0)); fp.addLine(to: CGPoint(x: 13, y: 0)); fp.addLine(to: CGPoint(x: 22, y: 6)); fp.addLine(to: CGPoint(x: 0, y: 6)); fp.closeSubpath()
            fan.path = fp
            spectrumFan.mask = fan
            layer?.addSublayer(spectrumFan)
            selectionGlow.shadowRadius = 10
        case .manuscript:
            let caret = CGMutablePath() // a red-pen arrowhead, drawn quickly (a little lopsided)
            caret.move(to: CGPoint(x: -5.5, y: 1.5)); caret.addQuadCurve(to: CGPoint(x: 0.3, y: 11), control: CGPoint(x: -2.2, y: 5.5))
            caret.addQuadCurve(to: CGPoint(x: 4.6, y: 2.4), control: CGPoint(x: 2.6, y: 6.2))
            caret.addQuadCurve(to: CGPoint(x: -5.5, y: 1.5), control: CGPoint(x: -0.4, y: 3.2))
            playheadCap.path = caret
            playheadCap.shadowOpacity = 0
            selectionGlow.lineWidth = 1.25
            selectionGlow.strokeColor = Theme.text.cgColor
            selectionGlow.shadowOpacity = 0
        }
    }

    /// Prism: the canvas is one large pane of glass, floating with a gutter where the light field shows.
    var glassLanesRect: CGRect { CGRect(x: 4, y: Theme.rulerHeight + 4, width: max(0, bounds.width - 8), height: max(0, bounds.height - Theme.rulerHeight - 8)) }

    func drawSkinnedLanes(_ ctx: CGContext, _ family: Theme.Look.Arrangement) {
        if family == .glass {
            Prism.drawField(in: self, frosted: false)
            Prism.liquidPane(self, glassLanesRect, radius: 14)
            ctx.saveGState(); ctx.addPath(CGPath(roundedRect: glassLanesRect, cornerWidth: 14, cornerHeight: 14, transform: nil)); ctx.clip()
            defer { ctx.restoreGState() }
            drawLaneMarks(ctx, family)
            return
        }
        drawLaneMarks(ctx, family)
    }

    private func drawLaneMarks(_ ctx: CGContext, _ family: Theme.Look.Arrangement) {
        for (i, t) in session.tracks.enumerated() {
            let y = laneY(i), lh = session.laneHeight(i)
            guard y + lh > 0, y < bounds.height else { continue }
            let lane = CGRect(x: 0, y: y, width: bounds.width, height: lh)
            if t.id == highlightedTrack {
                if family == .glass {
                    // The focused lane: a beam of the track's light from the left, fading across the canvas.
                    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [t.color.withAlphaComponent(0.13).cgColor, t.color.withAlphaComponent(0.035).cgColor] as CFArray, locations: [0, 1])!
                    ctx.saveGState(); ctx.clip(to: lane); ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y), end: CGPoint(x: bounds.width, y: y), options: []); ctx.restoreGState()
                } else {
                    ctx.setFillColor(Theme.laneHighlight.cgColor); ctx.fill(lane)
                }
            } else if family == .manuscript {
                ctx.setFillColor((i % 2 == 0 ? Theme.laneA : Theme.laneB).cgColor); ctx.fill(lane)
            }
            if let t0 = laneFlash[t.id] {
                let k = min(1, (CACurrentMediaTime() - t0) / Self.laneFlashSeconds)
                ctx.setFillColor(t.color.withAlphaComponent(0.28 * (1 - Motion.Curve.easeOut(k))).cgColor)
                ctx.fill(lane)
            }
            if family == .glass {
                ctx.setFillColor(Theme.ink(0.07).cgColor); ctx.fill(CGRect(x: 0, y: y + lh - 0.5, width: bounds.width, height: 0.5))
            } else {
                Atelier.rule(ctx, CGPoint(x: 0, y: y + lh - 0.25), CGPoint(x: bounds.width, y: y + lh - 0.25), weight: Atelier.hair, color: Theme.ink(0.3),
                             seed: Int(truncatingIfNeeded: t.id) &* 131)
            }
        }
    }

    /// Atelier's grid: bar lines are fine rules, heavier every four bars (phrases); beats are ticks at the top and
    /// bottom of each lane, as on a drafting scale, and become dotted lines only when zoomed in far enough to need them.
    func drawManuscriptGrid(_ ctx: CGContext, scale: CGFloat) {
        let f0 = frame(forX: 0), f1 = frame(forX: bounds.width)
        let lines = gridLines(from: f0, to: f1 + gridStepFrames())
        let px = 1 / scale
        let top = Theme.rulerHeight
        let lanes = session.tracks.indices.map { (laneY($0), session.laneHeight($0)) }.filter { $0.0 + $0.1 > top && $0.0 < bounds.height }
        for (i, line) in lines.enumerated() {
            let x = (xPos(forFrame: line.frame) * scale).rounded() / scale
            if line.isBar { // ruled by hand: each bar line keeps its own wobble (seeded by its bar) as the view scrolls
                let phrase = (line.bar - 1) % 4 == 0
                Atelier.rule(ctx, CGPoint(x: x, y: top), CGPoint(x: x, y: bounds.height), weight: phrase ? 0.9 : 0.5,
                             color: Theme.ink(phrase ? 0.22 : 0.11), seed: line.bar &* 7_919)
            } else {
                let spacing = i + 1 < lines.count ? xPos(forFrame: lines[i + 1].frame) - x : 100
                for (k, (y, h)) in lanes.enumerated() { // quick pen ticks, slightly uneven
                    let s = Int(line.frame / 97) &+ k
                    let lean = CGFloat(Atelier.hash(s) - 0.5) * 1.2
                    Atelier.rule(ctx, CGPoint(x: x, y: y), CGPoint(x: x + lean, y: y + 4), weight: 0.6, color: Theme.ink(0.32), seed: s)
                    Atelier.rule(ctx, CGPoint(x: x - lean, y: y + h - 4), CGPoint(x: x, y: y + h), weight: 0.6, color: Theme.ink(0.32), seed: s &+ 1)
                }
                if spacing > 28 {
                    Atelier.rule(ctx, CGPoint(x: x + px / 2, y: top), CGPoint(x: x + px / 2, y: bounds.height), weight: px, color: Theme.ink(0.07), dash: [1, 3])
                }
            }
        }
    }

    /// Glass slabs (Prism) and ink plates (Atelier). Same geometry, hit areas and information as the flat clip.
    func drawSkinnedClip(_ ctx: CGContext, _ clip: ClipView, track: TrackView, rect: CGRect, scale: CGFloat) {
        let family = Theme.look.arrangement
        let tint = TrackTint(base: clip.offline ? Theme.textFaint : (track.muted ? TrackTint(base: track.color).muted : track.color))
        let selected = selectedClips.contains(clip.id)
        let hovered = clip.id == hoveredClip
        let dim = track.muted || clip.muted || clip.offline
        let glass = family == .glass
        let radius: CGFloat = glass ? 5 : 0.5

        ctx.saveGState()
        if glass {
            Prism.slab(ctx, rect, radius: radius, tint: tint.base, body: dim ? 0.06 : 0.13, lift: selected ? 1 : hovered ? 0.35 : 0)
            // A frosted band carries the name: the glass is a little denser at the top.
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
            let band = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: titleH + 2)
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [tint.base.withAlphaComponent(selected ? 0.5 : 0.32).cgColor, tint.base.withAlphaComponent(0.0).cgColor] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: band.minY), end: CGPoint(x: 0, y: band.maxY + 4), options: [])
            ctx.restoreGState()
        } else {
            // Atelier: an ink wash in the track's ink, brushed by hand (its edge keeps the clip's own hand).
            ctx.setFillColor(Theme.laneA.withAlphaComponent(0.55).cgColor); ctx.fill(rect)
            Atelier.wash(ctx, rect.insetBy(dx: 0.5, dy: 0.5), color: tint.base, alpha: selected ? 0.3 : dim ? 0.1 : 0.19, seed: Int(truncatingIfNeeded: clip.id))
        }
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        if dim {
            if glass { // frosted: a fine dotted grain over the glass, plus the "muted" tag
                ctx.setFillColor(Theme.ink(0.08).cgColor)
                var yy = rect.minY + titleH + 2
                while yy < rect.maxY { var xx = rect.minX + (Int(yy) % 6 == 0 ? 0 : 3); while xx < rect.maxX { ctx.fill(CGRect(x: xx, y: yy, width: 1, height: 1)); xx += 6 }; yy += 3 }
            } else {
                Atelier.hatch(ctx, CGRect(x: rect.minX, y: rect.minY + titleH, width: rect.width, height: rect.height - titleH),
                              spacing: 6, color: Theme.ink(0.2), weight: 0.6, cross: true, seed: Int(truncatingIfNeeded: clip.id))
            }
        }
        if clip.isMidi {
            drawNotes(ctx, clip, rect: rect, color: tint.waveform, dim: dim)
        } else if let media = session.engine.poolMedia(clip.media) {
            drawWaveform(ctx, media: media, clip: clip, rect: rect, top: rect.minY + titleH + 2, color: tint.waveform, dim: dim || clip.processing, scale: scale)
        }
        drawFades(ctx, clip, rect: rect)

        var tags: [String] = []
        if clip.offline { tags.append("offline") }
        if clip.muted || track.muted { tags.append("muted") }
        if clip.isMidi { tags.append(clip.notes.count == 1 ? "1 note" : "\(clip.notes.count) notes") }
        if clip.folder != 0 { tags.append("⧉ takes \(session.takes(clip.folder).count)") }
        if abs(clip.rate - 1) > 1e-9 { tags.append(String(format: "%.0f%% speed", clip.rate * 100)) }
        if clip.pitch != 0 { tags.append(String(format: "%+g st", Double(clip.pitch))) }
        if !clip.preservePitch && abs(clip.rate - 1) > 1e-9 { tags.append("varispeed") }
        if clip.processing { tags.append("rendering…") }
        if clip.gainDb != 0 { tags.append(clip.gainDb.isFinite ? String(format: "%+.1f dB", clip.gainDb) : "−∞ dB") }
        let name = clip.isMidi && clip.name == "MIDI" ? track.name : clip.name
        if glass {
            drawTitle(ctx, name, tags: tags.isEmpty ? "" : "   " + tags.joined(separator: "   "), fg: Theme.isLight ? (Theme.text.blended(withFraction: 0.3, of: tint.base) ?? Theme.text) // dark ink on pale glass (audit: low contrast)
                                                                                     : OKLCH.adjust(tint.base, dl: 0.2, chromaScale: 0.5),
                      at: CGPoint(x: max(rect.minX, 0) + 7, y: rect.minY + 2))
        } else {
            // A typeset label on the paper: the name in the track's ink, a fine rule under it, notes in italic.
            let x0 = max(rect.minX, 0) + 6
            let nameAttrs: [NSAttributedString.Key: Any] = [.font: Theme.title(10.5, .semibold), .foregroundColor: OKLCH.adjust(tint.base, dl: Theme.isLight ? -0.16 : 0.12, chromaScale: 1)]
            let tagAttrs: [NSAttributedString.Key: Any] = [.font: Theme.note(10), .foregroundColor: Theme.textDim]
            let n = name as NSString, size = n.size(withAttributes: nameAttrs)
            n.draw(at: CGPoint(x: x0, y: rect.minY + 1), withAttributes: nameAttrs)
            if !tags.isEmpty { (tags.joined(separator: " · ") as NSString).draw(at: CGPoint(x: x0 + size.width + 8, y: rect.minY + 1.5), withAttributes: tagAttrs) }
            Atelier.rule(ctx, CGPoint(x: rect.minX + 3, y: rect.minY + titleH), CGPoint(x: min(rect.maxX - 3, rect.minX + 6 + size.width + 40), y: rect.minY + titleH),
                         weight: Atelier.hair, color: tint.base.withAlphaComponent(0.7), seed: Int(truncatingIfNeeded: clip.id) &+ 3)
        }
        ctx.restoreGState()
        if selected || hovered { drawFadeHandles(ctx, clip, rect: rect) }
        drawWarpMarkers(ctx, clip, rect: rect)
        if !glass {
            // The outline: four pen strokes in the track's ink that overshoot the corners; a selected clip is gone over
            // again in black ink, with corner ticks.
            let s = Int(truncatingIfNeeded: clip.id)
            Atelier.box(ctx, rect.insetBy(dx: 0.5, dy: 0.5), weight: Atelier.fine, color: tint.base.withAlphaComponent(dim ? 0.5 : 0.95), seed: s, overshoot: 3)
            if selected {
                Atelier.box(ctx, rect.insetBy(dx: 1, dy: 1), weight: Atelier.medium, color: Theme.text, seed: s &+ 1, overshoot: 4)
                Atelier.cropMarks(ctx, rect, weight: Atelier.fine, seed: s)
            }
            // A broad pen stroke down the start: the clip's start reads at any zoom.
            Atelier.pen(ctx, Atelier.handPoints(CGPoint(x: rect.minX + 1.2, y: rect.minY + 1), CGPoint(x: rect.minX + 1.2, y: rect.maxY - 1), seed: s &+ 2, wobble: 0.3),
                        weight: 2.6, color: tint.base, seed: s &+ 2)
        }
    }

    /// Atelier's markers are section headings: "§ Verse" set in italic over a fine vertical rule through the lanes.
    func drawSectionHeadings(_ ctx: CGContext) {
        for m in session.markers {
            let f = markerDragPreview(m.id) ?? m.frame
            let r = markerRect(m, frame: f)
            guard r.maxX > 0, r.minX < bounds.width else { continue }
            ctx.setFillColor(Theme.panel.cgColor); ctx.fill(r)
            Atelier.rule(ctx, CGPoint(x: r.minX + 0.5, y: 0), CGPoint(x: r.minX + 0.5, y: bounds.height), weight: Atelier.fine, color: Theme.ink(0.45))
            Atelier.rule(ctx, CGPoint(x: r.minX + 0.5, y: Theme.rulerHeight), CGPoint(x: r.minX + 0.5, y: bounds.height), weight: Atelier.hair, color: Theme.ink(0.18))
            ctx.saveGState(); ctx.clip(to: r)
            let letter = sectionLetter(m) + "  " as NSString
            letter.draw(at: CGPoint(x: r.minX + 4, y: r.minY - 1), withAttributes: [.font: Self.markerFont, .foregroundColor: Atelier.gold])
            let lw = letter.size(withAttributes: [.font: Self.markerFont]).width
            (fixedString(m.name) as NSString).draw(at: CGPoint(x: r.minX + 4 + lw, y: r.minY - 1), withAttributes: [.font: Theme.title(10.5, .regular), .foregroundColor: Theme.text])
            ctx.restoreGState()
        }
    }
}
