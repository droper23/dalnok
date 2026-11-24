// The clip editor docked at the bottom of the main window, sharing that space with the device chain (as Ableton's
// Clip and Device views do): double-clicking a clip opens it here, the Clip / Devices switch flips between the two.
// MIDI clips edit in a piano roll; audio clips show their whole source with the clip's region, whose edges trim it.
// The bar along the top holds Logic's quantize value and strength (Q quantizes with them).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

/// The quantize value and strength used by Q in the arrangement and the piano roll (remembered).
enum QuantizeSetting {
    /// (menu title, grid in quarter notes)
    static let grids: [(String, Double)] = [("1/4", 1), ("1/8", 0.5), ("1/8 Triplet", 1.0 / 3), ("1/16", 0.25),
                                            ("1/16 Triplet", 1.0 / 6), ("1/32", 0.125)]
    static let strengths: [Double] = [1, 0.75, 0.5, 0.25]
    static var grid: Double {
        get { let g = UserDefaults.standard.double(forKey: "quantizeGrid"); return g > 0 ? g : 0.25 }
        set { UserDefaults.standard.set(newValue, forKey: "quantizeGrid") }
    }
    static var strength: Double {
        get { let s = UserDefaults.standard.object(forKey: "quantizeStrength") as? Double; return min(max(s ?? 1, 0.01), 1) }
        set { UserDefaults.standard.set(min(max(newValue, 0.01), 1), forKey: "quantizeStrength") }
    }
    /// How readily audio quantize hears a transient (0-1).
    static var sensitivity: Double {
        get { let s = UserDefaults.standard.object(forKey: "quantizeSensitivity") as? Double; return min(max(s ?? 0.5, 0), 1) }
        set { UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: "quantizeSensitivity") }
    }
    static var name: String { grids.first { abs($0.1 - grid) < 1e-9 }?.0 ?? "1/\(Int((4 / grid).rounded()))" }
}

@MainActor
final class ClipEditorPanel: NSView {
    let session: Session
    let roll: PianoRollView
    let audio: AudioClipView
    private let bar = NSView()
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let placeholder = NSTextField(labelWithString: "Double-click a clip to edit it here.")
    let gridPopup = RuledPopUpButton(frame: .zero, pullsDown: false)
    let strengthPopup = RuledPopUpButton(frame: .zero, pullsDown: false)
    let quantizeButton = LookButton(frame: .zero)
    let resizeEdge = HeightResizeEdge()
    static let barHeight: CGFloat = 28
    /// The editor's height (its top edge resizes it; remembered apart from the device chain's).
    static var height: CGFloat {
        get { let h = UserDefaults.standard.double(forKey: "clipEditorHeight"); return h > 0 ? min(max(CGFloat(h), 200), 720) : 320 }
        set { UserDefaults.standard.set(Double(min(max(newValue, 200), 720)), forKey: "clipEditorHeight") }
    }
    private(set) var clipId: DalnokClipId?
    /// True while the editor is where the owner is working (clicked last): editing keys, Delete and ⌘C/⌘V act here.
    var focused = false
    var onFocus: (() -> Void)?
    /// Quantizes the shown audio clip (the main window's Q, so audio follows the same path as the arrangement).
    var onQuantizeAudio: (() -> Void)?
    var clip: ClipView? { clipId.flatMap { session.clip($0) } }

    init(session: Session) {
        self.session = session
        roll = PianoRollView(session: session)
        audio = AudioClipView(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        roll.velocityHeight = 60
        roll.onStatus = { [weak self] s in self?.status.stringValue = s }
        roll.onFocus = { [weak self] in self?.focus() }
        audio.onFocus = { [weak self] in self?.focus() }
        audio.onStatus = { [weak self] s in self?.status.stringValue = s }
        title.font = Theme.ui(12, .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        status.font = Theme.ui(11)
        status.textColor = Theme.textDim
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholder.font = Theme.ui(12)
        placeholder.textColor = Theme.textDim
        for (name, g) in QuantizeSetting.grids { gridPopup.addItem(withTitle: name); gridPopup.lastItem?.representedObject = g }
        for s in QuantizeSetting.strengths { strengthPopup.addItem(withTitle: "\(Int(s * 100))%"); strengthPopup.lastItem?.representedObject = s }
        for p in [gridPopup, strengthPopup] { p.controlSize = .small; p.font = Theme.ui(11); p.target = self; p.action = #selector(quantizeChanged(_:)) }
        gridPopup.toolTip = "Quantize value: the grid Q moves note starts to"
        strengthPopup.toolTip = "Quantize strength: how far toward the grid Q moves each note"
        gridPopup.setAccessibilityLabel("Quantize value")
        strengthPopup.setAccessibilityLabel("Quantize strength")
        quantizeButton.title = "Quantize"
        quantizeButton.target = self
        quantizeButton.action = #selector(quantizeTapped)
        quantizeButton.toolTip = "Quantize: the selected notes (or every note) of a MIDI clip; an audio clip's transients (Q)"
        let q = NSTextField(labelWithString: "Q")
        q.font = Theme.ui(11, .semibold); q.textColor = Theme.textDim
        for v in [bar, roll, audio, placeholder] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for v in [title, q, gridPopup, strengthPopup, quantizeButton, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(v)
        }
        self.quantizeLabel = q
        addSubview(resizeEdge)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor), bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            title.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            q.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 16), q.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            gridPopup.leadingAnchor.constraint(equalTo: q.trailingAnchor, constant: 6), gridPopup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            gridPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 112), strengthPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
            strengthPopup.leadingAnchor.constraint(equalTo: gridPopup.trailingAnchor, constant: 6), strengthPopup.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            quantizeButton.leadingAnchor.constraint(equalTo: strengthPopup.trailingAnchor, constant: 6), quantizeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: quantizeButton.trailingAnchor, constant: 14), status.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            status.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -170), // the Clip / Devices switch sits there
            roll.leadingAnchor.constraint(equalTo: leadingAnchor), roll.trailingAnchor.constraint(equalTo: trailingAnchor),
            roll.topAnchor.constraint(equalTo: bar.bottomAnchor), roll.bottomAnchor.constraint(equalTo: bottomAnchor),
            audio.leadingAnchor.constraint(equalTo: leadingAnchor), audio.trailingAnchor.constraint(equalTo: trailingAnchor),
            audio.topAnchor.constraint(equalTo: bar.bottomAnchor), audio.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            resizeEdge.leadingAnchor.constraint(equalTo: leadingAnchor), resizeEdge.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeEdge.topAnchor.constraint(equalTo: topAnchor), resizeEdge.heightAnchor.constraint(equalToConstant: 5),
        ])
        resizeEdge.toolTip = "Drag to resize the clip editor"
        setAccessibilityLabel("Clip editor")
        syncQuantizeControls()
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    private var quantizeLabel: NSTextField?

    override func draw(_ dirtyRect: NSRect) {
        Theme.panel.setFill(); bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: bounds.height - Self.barHeight, width: bounds.width, height: 1).fill()
    }
    override var isFlipped: Bool { false }

    func focus() { focused = true; onFocus?() }

    /// Shows a clip (MIDI in the piano roll, audio in the sample view).
    func show(clip id: DalnokClipId) {
        clipId = id
        if let c = session.clip(id), c.isMidi {
            roll.clipId = id
            roll.selection = []
            roll.entryFrame = nil
            roll.warmInstrument()
            layoutSubtreeIfNeeded()
            roll.fitToClip()
            roll.updateSubtitle()
        } else {
            audio.clipId = id
            layoutSubtreeIfNeeded()
            audio.fit()
        }
        update()
    }

    func syncQuantizeControls() {
        gridPopup.selectItem(at: QuantizeSetting.grids.firstIndex { abs($0.1 - QuantizeSetting.grid) < 1e-9 } ?? 3)
        strengthPopup.selectItem(at: QuantizeSetting.strengths.firstIndex { abs($0 - QuantizeSetting.strength) < 1e-9 } ?? 0)
    }
    @objc private func quantizeChanged(_ sender: NSPopUpButton) {
        if let g = gridPopup.selectedItem?.representedObject as? Double { QuantizeSetting.grid = g }
        if let s = strengthPopup.selectedItem?.representedObject as? Double { QuantizeSetting.strength = s }
    }
    @objc private func quantizeTapped() {
        guard let c = clip else { return }
        if c.isMidi { roll.quantizeSelection() } else { focus(); onQuantizeAudio?() }
    }

    /// Every display tick: the playhead of whichever editor is showing.
    func tick() {
        if !roll.isHidden { roll.updatePlayhead() } else if !audio.isHidden { audio.updatePlayhead() }
    }
    /// After any model change: the clip may have been edited, undone or deleted.
    func modelChanged() { update() }

    private func update() {
        let c = clip
        if c == nil { clipId = nil }
        let midi = c?.isMidi == true
        roll.isHidden = !midi
        audio.isHidden = c == nil || midi
        placeholder.isHidden = c != nil
        for v in [gridPopup, strengthPopup, quantizeButton, quantizeLabel].compactMap({ $0 }) as [NSView] { v.isHidden = c == nil }
        if let c, let t = session.track(c.track) {
            let name = c.name
            title.stringValue = name.isEmpty || name == t.name ? t.name : "\(t.name): \(name)"
            if midi { roll.updateSubtitle(); roll.needsDisplay = true } else { audio.updateStatus(); audio.needsDisplay = true }
        } else {
            title.stringValue = "Clip"
            status.stringValue = ""
        }
    }
}

/// Ableton's sample view, simply: the clip's whole source file, the part the clip plays bright and the rest dimmed.
/// Drag the region's edges to trim the clip (the same edit as trimming it in the arrangement).
@MainActor
final class AudioClipView: NSView {
    let session: Session
    var clipId: DalnokClipId = 0 { didSet { needsDisplay = true } }
    var onFocus: (() -> Void)?
    var onStatus: ((String) -> Void)?
    /// Source frames per point and the source frame at the left edge.
    var framesPerPoint: Double = 100 { didSet { needsDisplay = true; shownPlayhead = .nan; updatePlayhead() } }
    var scrollFrame: Double = 0 { didSet { needsDisplay = true; shownPlayhead = .nan; updatePlayhead() } }
    private var mins: [Float] = [], maxs: [Float] = []
    /// The clip's transients (source frames), as audio quantize hears them; recomputed when the clip's region changes.
    private var transients: [Int64] = []
    private var transientKey: (DalnokClipId, Int64, Int64, Double)?
    private func refreshTransients(_ c: ClipView) {
        let key = (c.id, c.offset, c.sourceSpan, QuantizeSetting.sensitivity)
        if let k = transientKey, k == key { return }
        transientKey = key
        let n = Int(dalnok_audio_transients(session.engine.handle, c.id, QuantizeSetting.sensitivity, nil, 0))
        guard n > 0 else { transients = []; return }
        var out = [Int64](repeating: 0, count: n)
        let got = Int(dalnok_audio_transients(session.engine.handle, c.id, QuantizeSetting.sensitivity, &out, Int32(n)))
        transients = Array(out.prefix(max(0, min(n, got))))
    }
    private enum Edge: Equatable { case left, right, anchor(Int) }
    private var drag: (edge: Edge, startX: CGFloat, clip: ClipView, changed: Bool)?
    static let ruler: CGFloat = 20

    /// The playhead (a layer moved every display tick): where the clip's audio is playing, through any warp. Before or
    /// after the clip it waits at the region's edge, dimmed.
    let playheadLayer = CALayer()
    private var shownPlayhead: CGFloat = .nan
    func updatePlayhead() {
        guard let c = clip else { playheadLayer.isHidden = true; return }
        let pos = session.engine.position
        let inside = pos >= c.start && pos < c.end
        let t = Double(min(max(pos, c.start), c.end) - c.start)
        let px = x(c.sourceFrame(atClipTime: t)).rounded()
        guard px != shownPlayhead || playheadLayer.opacity != (inside ? 1 : 0.35) else { return }
        shownPlayhead = px
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playheadLayer.frame = CGRect(x: px - 0.5, y: 0, width: 1.5, height: bounds.height)
        playheadLayer.opacity = inside ? 1 : 0.35
        playheadLayer.isHidden = px < 0 || px > bounds.width
        CATransaction.commit()
    }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        playheadLayer.backgroundColor = Theme.playhead.cgColor
        playheadLayer.zPosition = 10
        layer?.addSublayer(playheadLayer)
        setAccessibilityLabel("Audio clip")
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); shownPlayhead = .nan; updatePlayhead() }

    var clip: ClipView? { session.clip(clipId).flatMap { $0.isMidi ? nil : $0 } }
    func x(_ source: Double) -> CGFloat { CGFloat((source - scrollFrame) / framesPerPoint) }
    func source(atX x: CGFloat) -> Double { scrollFrame + Double(x) * framesPerPoint }
    /// The region the clip plays, in source frames.
    func region(_ c: ClipView) -> (Double, Double) {
        if let last = c.warp.last { return (Double(c.offset), Double(last.source)) }
        return (Double(c.offset), Double(c.offset) + Double(c.sourceSpan))
    }

    /// Shows the whole source with a little room either side.
    func fit() {
        guard let c = clip, bounds.width > 20 else { return }
        let total = Double(max(c.mediaFrames, c.offset + c.sourceSpan, 1))
        framesPerPoint = total * 1.04 / Double(bounds.width)
        scrollFrame = -total * 0.02
        updateStatus()
    }

    func updateStatus() {
        guard let c = clip else { return }
        let rate = session.engine.sampleRate
        func t(_ f: Int64) -> String { String(format: "%.3f s", Double(f) / rate) }
        var parts = ["Plays \(t(c.offset))–\(t(c.offset + c.sourceSpan)) of \(t(c.mediaFrames))"]
        if c.gainDb != 0 { parts.append(c.gainDb.isFinite ? String(format: "gain %+.1f dB", c.gainDb).replacingOccurrences(of: "-", with: "−") : "gain −∞") }
        if c.warp.count > 2 { parts.append("quantized (\(c.warp.count - 2) anchors)") }
        else if c.isStretched { parts.append(String(format: "speed %.2f×", 1 / c.rate)) }
        if c.offline { parts.append("source missing") }
        refreshTransients(c)
        parts.append(transients.count == 1 ? "1 transient" : "\(transients.count) transients")
        parts.append(c.isStretched ? "trim stretched clips in the arrangement" : "drag the clip's edges to trim")
        onStatus?(parts.joined(separator: "  ·  "))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.laneA.setFill(); bounds.fill()
        guard let c = clip else { return }
        let tint = TrackTint(base: session.track(c.track)?.color ?? Theme.accent)
        let (a, b) = region(c)
        let ra = x(a), rb = x(b)
        let wave = CGRect(x: 0, y: Self.ruler, width: bounds.width, height: bounds.height - Self.ruler)
        // The region the clip plays.
        ctx.setFillColor(tint.base.withAlphaComponent(0.16).cgColor)
        ctx.fill(CGRect(x: ra, y: wave.minY, width: max(1, rb - ra), height: wave.height))
        // Waveform: one min/max column per point, per channel.
        if let media = dalnok_pool_media(session.engine.handle, c.media) {
            let columns = Int(bounds.width.rounded(.up))
            if mins.count < columns { mins = [Float](repeating: 0, count: columns); maxs = mins }
            let chans = max(1, min(Int(dalnok_media_channels(media)), 2))
            let laneH = (wave.height - 8) / CGFloat(chans)
            for ch in 0..<chans {
                _ = dalnok_media_peaks(media, Int32(ch), Int64(scrollFrame.rounded()), framesPerPoint, &mins, &maxs, Int64(columns))
                let mid = wave.minY + 4 + laneH * (CGFloat(ch) + 0.5), half = laneH * 0.46
                for i in 0..<columns {
                    let px = CGFloat(i) + 0.5
                    let inside = px >= ra && px <= rb
                    ctx.setStrokeColor((inside ? tint.waveform : Theme.textFaint).withAlphaComponent(inside ? 0.95 : 0.5).cgColor)
                    var t = mid - CGFloat(maxs[i]) * half, bo = mid - CGFloat(mins[i]) * half
                    if bo - t < 1 { t = mid - 0.5; bo = mid + 0.5 }
                    ctx.move(to: CGPoint(x: px, y: t)); ctx.addLine(to: CGPoint(x: px, y: bo)); ctx.strokePath()
                }
            }
        }
        // Transients (where Q cuts and aligns): small markers along the top of the waveform.
        refreshTransients(c)
        ctx.setFillColor(Theme.accent.withAlphaComponent(0.85).cgColor)
        for t in transients {
            let px = x(Double(t)).rounded() + 0.5
            guard px >= 0, px <= bounds.width else { continue }
            ctx.fill(CGRect(x: px - 0.5, y: wave.minY, width: 1, height: 10))
            ctx.move(to: CGPoint(x: px - 3, y: wave.minY)); ctx.addLine(to: CGPoint(x: px + 3, y: wave.minY))
            ctx.addLine(to: CGPoint(x: px, y: wave.minY + 5)); ctx.closePath(); ctx.fillPath()
        }
        // Outside the region, washed back.
        ctx.setFillColor(Theme.hex(0x000000, Theme.isLight ? 0.08 : 0.3).cgColor)
        ctx.fill(CGRect(x: 0, y: wave.minY, width: max(0, ra), height: wave.height))
        ctx.fill(CGRect(x: rb, y: wave.minY, width: max(0, bounds.width - rb), height: wave.height))
        // Region edges with grab tabs.
        for ex in [ra, rb] {
            ctx.setFillColor(tint.border.cgColor)
            ctx.fill(CGRect(x: ex - 1, y: wave.minY, width: 2, height: wave.height))
            ctx.fill(CGRect(x: ex - 5, y: wave.minY, width: 10, height: 8))
        }
        // A quantized clip's hits (the audio pinned to each moved time): a line with a grip at the bottom; drag one to
        // pin that time to another moment of the audio (when a hit was found in the wrong place).
        if c.warp.count > 2 {
            let pre = Double(pinOffset)
            ctx.setFillColor(Theme.text.withAlphaComponent(0.55).cgColor)
            for i in c.warpMarkers(sampleRate: session.engine.sampleRate) {
                let px = x(Double(c.warp[i].source) + pre).rounded() + 0.5
                ctx.fill(CGRect(x: px - 0.5, y: wave.minY + 12, width: 1, height: wave.height - 12))
                ctx.move(to: CGPoint(x: px - 4, y: bounds.maxY)); ctx.addLine(to: CGPoint(x: px + 4, y: bounds.maxY))
                ctx.addLine(to: CGPoint(x: px, y: bounds.maxY - 6)); ctx.closePath(); ctx.fillPath()
            }
        }
        // Ruler: seconds of the source.
        Theme.panel.setFill(); CGRect(x: 0, y: 0, width: bounds.width, height: Self.ruler).fill()
        Theme.separator.setFill(); CGRect(x: 0, y: Self.ruler - 1, width: bounds.width, height: 1).fill()
        let rate = session.engine.sampleRate
        let steps: [Double] = [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { $0 * rate / framesPerPoint >= 70 } ?? 600
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9.5), .foregroundColor: Theme.textDim]
        var sec = (max(0, scrollFrame) / rate / step).rounded(.down) * step
        while x(sec * rate) < bounds.width {
            let px = x(sec * rate).rounded()
            Theme.textFaint.setFill(); CGRect(x: px, y: 6, width: 1, height: Self.ruler - 7).fill()
            let label = step < 1 ? String(format: "%.2f s", sec) : sec >= 60 ? String(format: "%d:%02d", Int(sec) / 60, Int(sec) % 60) : "\(Int(sec)) s"
            (label as NSString).draw(at: CGPoint(x: px + 3, y: 3), withAttributes: attrs)
            sec += step
        }
    }

    /// Source frames from an anchor to the attack it pins (audio quantize places anchors 6 ms before the attack).
    private var pinOffset: Int64 { Int64((session.engine.sampleRate * 0.006).rounded()) }
    private func edge(at p: CGPoint) -> Edge? {
        guard let c = clip, p.y >= Self.ruler else { return nil }
        for i in c.warpMarkers(sampleRate: session.engine.sampleRate) where abs(x(Double(c.warp[i].source + pinOffset)) - p.x) <= 4 {
            return .anchor(i)
        }
        let (a, b) = region(c)
        if abs(p.x - x(a)) <= 6 { return .left }
        if abs(p.x - x(b)) <= 6 { return .right }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let e = edge(at: p)
        let movable = e.map { if case .anchor = $0 { return true }; return clip?.isStretched == false } ?? false
        (movable ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        let p = convert(event.locationInWindow, from: nil)
        guard let c = clip else { return }
        if let e = edge(at: p), !c.isStretched || { if case .anchor = e { return true }; return false }() {
            drag = (e, p.x, c, false)
            if case .anchor = e { session.engine.beginGroup("Move Quantized Hit") } else { session.engine.beginGroup("Trim Clip") }
            return
        }
        // A click elsewhere puts the playhead there (inside the clip's region).
        let (a, b) = region(c)
        let s = min(max(source(atX: p.x), a), b - 1)
        // Through the warp: the clip time whose source is the clicked frame (search, the map is monotonic).
        var lo = 0.0, hi = Double(c.length)
        for _ in 0..<40 { let mid = (lo + hi) / 2; if c.sourceFrame(atClipTime: mid) < s { lo = mid } else { hi = mid } }
        session.engine.seek(c.start + Int64(lo.rounded()))
        shownPlayhead = .nan
        updatePlayhead()
    }
    override func mouseDragged(with event: NSEvent) {
        guard var d = drag, let current = clip else { return }
        let p = convert(event.locationInWindow, from: nil)
        let c = d.clip
        let delta = Int64((Double(p.x - d.startX) * framesPerPoint).rounded())
        switch d.edge {
        case .anchor(let i):
            if let w = c.warpMoving(i, toSource: c.warp[i].source + delta, sampleRate: session.engine.sampleRate),
               w.map(\.source) != current.warp.map(\.source), session.setWarp(c.id, w) { d.changed = true }
        case .left: // keeps the clip's end in place on the timeline
            let offset = min(max(0, c.offset + delta), c.offset + c.length - 1)
            let start = c.start + (offset - c.offset)
            if start >= 0, offset != current.offset {
                session.setRegion(c.id, start: start, offset: offset, length: c.end - start)
                d.changed = true
            }
        case .right:
            let length = min(max(1, c.length + delta), c.mediaFrames - c.offset)
            if length != current.length {
                session.setRegion(c.id, start: c.start, offset: c.offset, length: length)
                d.changed = true
            }
        }
        drag = d
        updateStatus()
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        if drag != nil { session.engine.endGroup() }
        drag = nil
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let px = convert(event.locationInWindow, from: nil).x, anchor = source(atX: px)
            framesPerPoint = min(max(framesPerPoint * exp(-event.scrollingDeltaY * 0.01), 0.5), 1e6)
            scrollFrame = anchor - Double(px) * framesPerPoint
            return
        }
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        scrollFrame -= Double(dx != 0 ? dx : dy) * framesPerPoint
    }
    override func magnify(with event: NSEvent) {
        let px = convert(event.locationInWindow, from: nil).x, anchor = source(atX: px)
        framesPerPoint = min(max(framesPerPoint / (1 + event.magnification), 0.5), 1e6)
        scrollFrame = anchor - Double(px) * framesPerPoint
    }
}

/// The clip editor's Clip / Devices switch in the look: Atelier's ruled cells (RuledTabs), elsewhere a small pill
/// whose chosen side is filled with the look's colour (Graphite's gold, Warm Analog's amber, Prism's light).
@MainActor
final class LookTabs: RuledTabs {
    override func draw(_ dirtyRect: NSRect) {
        guard Theme.activeStyle != .atelier, let ctx = NSGraphicsContext.current?.cgContext else { return super.draw(dirtyRect) }
        LookChrome.pill(ctx, bounds, segments: (0..<segmentCount).map { (label(forSegment: $0) ?? "", selectedSegment == $0) },
                        focused: window?.firstResponder === self)
    }
}

/// A small text button in the look (Quantize): a ruled box in Atelier, a pill elsewhere; lit while pressed.
@MainActor
final class LookButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        setButtonType(.momentaryPushIn)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: LookChrome.font]).width
        return NSSize(width: ceil(w) + 22, height: 20)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        LookChrome.pill(ctx, bounds, segments: [(title, isHighlighted)], focused: window?.firstResponder === self, button: true)
    }
}

@MainActor
enum LookChrome {
    static var font: NSFont { Theme.activeStyle == .atelier ? Theme.title(12) : Theme.ui(11, .semibold) }
    /// Cells side by side in one rounded (or, in Atelier, ruled) frame; `on` cells are filled with the look's colour.
    static func pill(_ ctx: CGContext, _ bounds: CGRect, segments: [(String, Bool)], focused: Bool, button: Bool = false) {
        let r = bounds.insetBy(dx: 0.5, dy: 1.5)
        let style = Theme.activeStyle
        let radius: CGFloat = style == .prism ? r.height / 2 : style == .atelier ? 0 : 4
        let frame = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let tint = Theme.controlTint
        ctx.saveGState()
        ctx.addPath(frame); ctx.clip()
        ctx.setFillColor((style == .atelier ? Theme.panelRaised.withAlphaComponent(0.6) : Theme.ink(style == .prism ? 0.07 : 0.05)).cgColor)
        ctx.fill(r)
        let w = r.width / CGFloat(max(1, segments.count))
        for (i, (label, on)) in segments.enumerated() {
            let cell = CGRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: w, height: r.height)
            if on {
                if style == .atelier { Theme.laneHighlight.setFill(); cell.fill() }
                else {
                    ctx.setFillColor((style == .prism ? tint.withAlphaComponent(button ? 0.35 : 0.55) : tint.withAlphaComponent(button ? 0.6 : 0.9)).cgColor)
                    ctx.fill(cell)
                }
            }
            if i > 0 {
                ctx.setFillColor(Theme.ink(0.18).cgColor)
                ctx.fill(CGRect(x: cell.minX - 0.5, y: cell.minY + 3, width: 1, height: cell.height - 6))
            }
            let dark = on && style != .atelier && style != .prism && Theme.isLight(tint)
            let color: NSColor = dark ? NSColor.black.withAlphaComponent(0.82) : (on || button ? Theme.text : Theme.textDim)
            let attrs: [NSAttributedString.Key: Any] = [.font: on && style == .atelier ? Theme.title(12, .semibold) : font, .foregroundColor: color]
            let s = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: CGPoint(x: cell.midX - s.width / 2, y: cell.midY - s.height / 2), withAttributes: attrs)
            if on && style == .atelier && !button {
                Atelier.rule(ctx, CGPoint(x: cell.minX + 6, y: cell.maxY - 1.5), CGPoint(x: cell.maxX - 6, y: cell.maxY - 1.5), weight: Atelier.heavy, color: Atelier.vermilion)
            }
        }
        ctx.restoreGState()
        if style == .atelier { Atelier.box(ctx, r, weight: Atelier.hair, color: Theme.ink(0.7)) }
        else {
            ctx.addPath(frame)
            ctx.setStrokeColor((style == .prism ? Theme.ink(0.22) : Theme.ink(0.16)).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        }
        if focused {
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), cornerWidth: radius + 1.5, cornerHeight: radius + 1.5, transform: nil))
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(1); ctx.strokePath()
        }
    }
}
