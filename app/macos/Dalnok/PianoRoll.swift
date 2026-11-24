// Piano roll: edit the notes of one MIDI clip. Every gesture is one undo step through the
// engine's midi.setNotes command; the view never caches notes beyond the current gesture.
//   Double-click empty grid: add a note (grid length; keep dragging to set its length). Drag empty grid: select
//   notes (⇧ adds). ⌘C / ⌘X / ⌘V / ⌘D copy, cut, paste (at the playhead) and duplicate notes.
//   Drag a note: move in time and pitch (snapped; ⌃ bypasses). Drag its right edge: resize.
//   Velocity lane: drag a stem. Delete removes, ↑/↓ transpose (⇧ = octave), ←/→ move by the grid,
//   ⌘A selects all, Q quantizes the selection. Scroll to pan, ⌘-scroll or pinch to zoom.
//   ⌥ arrows move the step-entry cursor; Return inserts a note at the cursor and advances it.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class PianoRollController: NSWindowController, NSWindowDelegate {
    let roll: PianoRollView
    /// The piano roll owns editing commands (Delete) until the main window becomes key again.
    var focused = false
    func windowDidBecomeKey(_ notification: Notification) { focused = true }
    func windowWillClose(_ notification: Notification) { focused = false }
    init(session: Session) {
        roll = PianoRollView(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.autorecalculatesKeyViewLoop = true // Tab follows the layout (keyboard-only use)
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.window
        window.minSize = NSSize(width: 480, height: 300)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("DalnokPianoRoll")
        window.contentView = roll
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(clip: DalnokClipId) {
        focused = true
        roll.clipId = clip
        roll.warmInstrument()
        roll.selection = []
        roll.entryFrame = nil
        roll.entryPitch = 60
        roll.fitToClip()
        updateTitle()
        if window?.isVisible != true { window?.center() }
        if !Motion.reduced && window?.isVisible != true {
            window?.alphaValue = 0
            window?.makeKeyAndOrderFront(nil)
            Motion.views(Motion.standard) { window?.animator().alphaValue = 1 }
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        window?.makeFirstResponder(roll)
    }
    func updateTitle() {
        guard let c = roll.clip, let t = roll.session.track(c.track) else { return }
        window?.title = c.name == "MIDI" || c.name == t.name ? "Piano Roll — \(t.name)" : "Piano Roll — \(t.name): \(c.name)"
        roll.updateSubtitle()
    }
    /// Called after any model change: the clip may have been edited elsewhere, undone or deleted.
    func modelChanged() {
        guard window?.isVisible == true else { return }
        roll.updateSubtitle()
        if roll.clip == nil { window?.orderOut(nil); return }
        updateTitle()
        roll.needsDisplay = true
    }
}

@MainActor
final class PianoRollView: NSView {
    let session: Session
    var clipId: DalnokClipId = 0
    /// Selected notes, identified by their values (notes have no ids; values are unique in practice).
    var selection: Set<NoteKey> = [] { didSet { needsDisplay = true; updateSubtitle() } }
    struct NoteKey: Hashable { let start: Int64, pitch: UInt8 }
    var entryFrame: Double? { didSet { needsDisplay = true } }
    var entryPitch = 60 { didSet { needsDisplay = true } }

    // Layout
    static let keyWidth: CGFloat = 48, rulerHeight: CGFloat = 22, edge: CGFloat = 6
    /// The velocity lane's height (shorter when the editor is docked in the main window).
    var velocityHeight: CGFloat = 72 { didSet { needsDisplay = true } }
    /// Docked in the main window's clip editor: status text goes here instead of the window's subtitle, and a click
    /// reports focus (so editing keys and Delete act on notes).
    var onStatus: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var rowHeight: CGFloat = 12
    var framesPerPoint: Double = 200 { didSet { needsDisplay = true; shownPlayhead = .nan; updatePlayhead(); if snapBeats != shownSnap { updateSubtitle() } } }
    private var shownSnap = 0.0

    /// Window subtitle: the snap value and what's selected, so state isn't hidden.
    func updateSubtitle() {
        shownSnap = snapBeats
        let snap = snapBeats > 1 ? "\(Int(snapBeats)) quarter notes" : "1/\(Int((4 / snapBeats).rounded())) note"
        var parts = ["Drag snap \(snap) (⌃ bypasses)"]
        if let c = clip {
            let sel = c.notes.filter { selection.contains(NoteKey(start: $0.start, pitch: $0.pitch)) }
            if sel.isEmpty {
                parts.append(c.notes.count == 1 ? "1 note" : "\(c.notes.count) notes")
            } else {
                parts.append("\(sel.count) of \(c.notes.count) selected")
                let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
                let pitches = Set(sel.map(\.pitch)), vels = sel.map { Int($0.velocity) }
                if pitches.count == 1, let p = pitches.first { parts.append("\(names[Int(p) % 12])\(Int(p) / 12 - 1)") }
                if let lo = vels.min(), let hi = vels.max() { parts.append(lo == hi ? "velocity \(lo)" : "velocity \(lo)–\(hi)") }
            }
        }
        setAccessibilityValue(parts.joined(separator: ", "))
        if let onStatus { onStatus(parts.joined(separator: "  ·  ")) } else { window?.subtitle = parts.joined(separator: "  ·  ") }
    }
    var scrollX: Double = 0 { didSet { needsDisplay = true; shownPlayhead = .nan; updatePlayhead() } }   // timeline frame at the grid's left edge
    var scrollY: CGFloat = 0 { didSet { needsDisplay = true } }  // points from the top (pitch 127)

    /// The playhead: a layer moved every display tick (no redraw of the notes).
    let playheadLayer = CALayer()
    private var shownPlayhead: CGFloat = .nan
    /// Moves the playhead line to the engine's position; hidden outside the grid.
    func updatePlayhead() {
        let g = grid
        let px = x(Double(session.engine.position)).rounded()
        guard px != shownPlayhead || playheadLayer.frame.height != g.height + Self.rulerHeight else { return }
        shownPlayhead = px
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playheadLayer.frame = CGRect(x: px - 0.5, y: 0, width: 1.5, height: g.maxY)
        playheadLayer.isHidden = clip == nil || px < g.minX || px > g.maxX
        CATransaction.commit()
    }

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        playheadLayer.backgroundColor = Theme.playhead.cgColor
        playheadLayer.zPosition = 10
        playheadLayer.isHidden = true
        layer?.addSublayer(playheadLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Piano roll")
        setAccessibilityHelp("] and [ select the next and previous note, Return inserts a note at the entry cursor, Option-arrows move the cursor.")
        toolTip = "Drag empty space to select notes. Option-arrow keys move the entry cursor; Return inserts a note."
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func layout() { super.layout(); shownPlayhead = .nan; updatePlayhead() }

    var clip: ClipView? { session.clip(clipId).flatMap { $0.isMidi ? $0 : nil } }
    var track: TrackView? { clip.flatMap { session.track($0.track) } }
    var grid: CGRect {
        CGRect(x: Self.keyWidth, y: Self.rulerHeight, width: max(0, bounds.width - Self.keyWidth),
               height: max(0, bounds.height - Self.rulerHeight - velocityHeight))
    }
    var velocityLane: CGRect { CGRect(x: Self.keyWidth, y: bounds.height - velocityHeight, width: grid.width, height: velocityHeight) }

    // MARK: Coordinates (timeline frames and MIDI pitch)

    func x(_ frame: Double) -> CGFloat { grid.minX + CGFloat((frame - scrollX) / framesPerPoint) }
    func frame(atX x: CGFloat) -> Double { scrollX + Double(x - grid.minX) * framesPerPoint }
    func y(_ pitch: Int) -> CGFloat { grid.minY + CGFloat(127 - pitch) * rowHeight - scrollY }
    func pitch(atY y: CGFloat) -> Int { max(0, min(127, 127 - Int(floor((y - grid.minY + scrollY) / rowHeight)))) }
    /// Frames per quarter note where the view is centred (the tempo map can vary).
    var framesPerBeat: Double { session.framesPerBeat(at: frame(atX: grid.midX)) }
    /// Snap unit in quarter notes: a 16th note, or longer when zoomed out.
    var snapBeats: Double {
        for k in [1.0, 2, 4, 8, 16] where framesPerBeat / 4 * k / framesPerPoint >= 10 { return k / 4 }
        return 4
    }
    /// Snap unit in frames at the view centre (keyboard moves and default note lengths).
    var snapFrames: Double { snapBeats * framesPerBeat }
    /// Snaps on the beat grid, which follows tempo changes.
    func snap(_ f: Double, bypass: Bool) -> Double {
        guard !bypass else { return f.rounded() }
        let q = snapBeats
        return session.beatToFrame((session.frameToBeat(f) / q).rounded() * q).rounded()
    }

    func timeline(_ n: DalnokNote, _ c: ClipView) -> Double { Double(c.start + n.start - c.offset) }
    func rect(_ n: DalnokNote, _ c: ClipView) -> CGRect {
        let x0 = x(timeline(n, c)), x1 = x(timeline(n, c) + Double(n.length))
        return CGRect(x: x0, y: y(Int(n.pitch)) + 1, width: max(3, x1 - x0 - 1), height: rowHeight - 2)
    }
    func visibleNotes(_ c: ClipView) -> [DalnokNote] {
        c.notes.filter { $0.start >= c.offset && $0.start < c.offset + c.length }
    }

    func fitToClip() {
        guard let c = clip else { return }
        layoutSubtreeIfNeeded()
        let width = max(200, Double(bounds.width > 0 ? grid.width : 900))
        framesPerPoint = max(20, Double(c.length) * 1.08 / width)
        scrollX = Double(c.start) - Double(c.length) * 0.02
        let pitches = visibleNotes(c).map { Int($0.pitch) }
        let mid = pitches.isEmpty ? 60 : (pitches.min()! + pitches.max()!) / 2
        let gridH = bounds.height > 0 ? grid.height : 400
        scrollY = max(0, CGFloat(127 - mid) * rowHeight - gridH / 2)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.laneA.setFill(); bounds.fill()
        guard let c = clip else { return }
        let tint = TrackTint(base: track?.color ?? Theme.accent)
        let g = grid

        ctx.saveGState()
        ctx.clip(to: g)
        // Rows: black keys darker, C rows marked.
        for p in 0...127 {
            let ry = y(p)
            guard ry + rowHeight >= g.minY, ry <= g.maxY else { continue }
            let black = [1, 3, 6, 8, 10].contains(p % 12)
            if Theme.look.tapeEditors { // ledger paper: warm rows with a faint rule under each, a red-brown rule under each C
                ctx.setFillColor(Theme.hex(black ? 0x17120E : 0x1F1913).cgColor)
                ctx.fill(CGRect(x: g.minX, y: ry, width: g.width, height: rowHeight))
                ctx.setFillColor((p % 12 == 0 ? Theme.hex(0xB0603E, 0.45) : Theme.hex(0xE8D8C0, 0.05)).cgColor)
                ctx.fill(CGRect(x: g.minX, y: ry + rowHeight - 1, width: g.width, height: 1))
                continue
            }
            switch Theme.look.editors {
            case .glass: // the canvas shows through; black-key rows are a breath darker, each C a thin line of light
                ctx.setFillColor((black ? Theme.shade(0.22) : Theme.ink(0.012)).cgColor)
                ctx.fill(CGRect(x: g.minX, y: ry, width: g.width, height: rowHeight))
                if p % 12 == 0 { ctx.setFillColor(Theme.accent.withAlphaComponent(0.22).cgColor); ctx.fill(CGRect(x: g.minX, y: ry + rowHeight - 1, width: g.width, height: 1)) }
                continue
            case .engraved: // paper rows; black-key rows a faint tint; a fine ink rule under every C, a hairline at E|F
                if black { ctx.setFillColor(Theme.ink(0.022).cgColor); ctx.fill(CGRect(x: g.minX, y: ry, width: g.width, height: rowHeight)) }
                if p % 12 == 0 { Atelier.rule(ctx, CGPoint(x: g.minX, y: ry + rowHeight - 0.25), CGPoint(x: g.maxX, y: ry + rowHeight - 0.25), weight: Atelier.fine, color: Theme.ink(0.45)) }
                else if p % 12 == 5 { Atelier.rule(ctx, CGPoint(x: g.minX, y: ry + rowHeight - 0.25), CGPoint(x: g.maxX, y: ry + rowHeight - 0.25), weight: Atelier.hair, color: Theme.ink(0.18)) }
                continue
            case .grid, .tape: break
            }
            ctx.setFillColor((black ? Theme.laneB.blended(withFraction: 0.35, of: .black) ?? Theme.laneB : Theme.laneB).cgColor)
            ctx.fill(CGRect(x: g.minX, y: ry, width: g.width, height: rowHeight))
            if p % 12 == 0 { ctx.setFillColor(Theme.gridMajor.cgColor); ctx.fill(CGRect(x: g.minX, y: ry + rowHeight - 1, width: g.width, height: 1)) }
        }
        if Theme.look.editors == .engraved {
            // Outside the clip: washed back and hatched, as an unused area of the sheet.
            let outside = [CGRect(x: g.minX, y: g.minY, width: max(0, x(Double(c.start)) - g.minX), height: g.height),
                           CGRect(x: x(Double(c.end)), y: g.minY, width: max(0, g.maxX - x(Double(c.end))), height: g.height)]
            for r in outside where r.width > 0 { ctx.setFillColor(Theme.panel.withAlphaComponent(0.7).cgColor); ctx.fill(r); Atelier.hatch(ctx, r, spacing: 7, color: Theme.ink(0.08)) }
        }
        // Outside the clip window is dimmed.
        ctx.setFillColor(Theme.hex(0x000000, Theme.look.editors == .engraved ? 0 : 0.35).cgColor)
        ctx.fill(CGRect(x: g.minX, y: g.minY, width: max(0, x(Double(c.start)) - g.minX), height: g.height))
        ctx.fill(CGRect(x: x(Double(c.end)), y: g.minY, width: max(0, g.maxX - x(Double(c.end))), height: g.height))
        // Beat and bar lines.
        drawBeatLines(ctx, from: g.minY, height: g.height)
        // Notes, colored by the track and shaded by velocity.
        for n in visibleNotes(c) {
            let r = rect(n, c)
            guard r.maxX >= g.minX, r.minX <= g.maxX, r.maxY >= g.minY, r.minY <= g.maxY else { continue }
            let sel = selection.contains(NoteKey(start: n.start, pitch: n.pitch))
            let v = CGFloat(n.velocity) / 127
            if Theme.look.tapeEditors { drawPin(ctx, r, velocity: v, tint: tint, selected: sel); continue }
            if Theme.look.editors == .glass {
                // Glass: a capsule whose body thickens with velocity; selected notes rise and brighten.
                Prism.slab(ctx, r, radius: min(r.height / 2, 4), tint: tint.base, body: 0.18 + 0.32 * v, lift: sel ? 1 : 0)
                ctx.setFillColor(tint.waveform.withAlphaComponent(0.95).cgColor)
                ctx.fill(CGRect(x: r.minX + 1, y: r.minY + 2, width: min(2, r.width), height: max(1, r.height - 4)))
                continue
            }
            if Theme.look.editors == .engraved {
                // Engraved: a round head where the note starts and a duration line whose weight is its velocity; a fine
                // end tick marks where it stops (and where to grab it). Selected notes are boxed in ink.
                let ink = OKLCH.adjust(tint.base, dl: Theme.isLight ? -0.12 : 0.05, chromaScale: Theme.isLight ? 1 : 0.8)
                let weight = 1 + 4 * v, mid = r.midY
                let ns = Atelier.seed(CGPoint(x: CGFloat(n.start % 100_000), y: CGFloat(n.pitch)))
                // The duration as one pen stroke whose pressure (weight) is the velocity.
                Atelier.pen(ctx, Atelier.handPoints(CGPoint(x: r.minX, y: mid), CGPoint(x: r.maxX, y: mid), seed: ns, wobble: 0.5), weight: max(1, weight), color: ink, seed: ns)
                Atelier.rule(ctx, CGPoint(x: r.maxX - 0.5, y: r.minY + 1), CGPoint(x: r.maxX - 0.5, y: r.maxY - 1), weight: Atelier.fine, color: ink, seed: ns &+ 1)
                ctx.setFillColor(ink.cgColor)
                let d = min(rowHeight - 1, 10)
                let head = CGRect(x: r.minX - 0.5, y: mid - d / 2, width: d * 1.25, height: d)
                ctx.saveGState(); ctx.translateBy(x: head.midX, y: head.midY); ctx.rotate(by: -0.35)
                ctx.fillEllipse(in: CGRect(x: -head.width / 2, y: -head.height / 2, width: head.width, height: head.height))
                ctx.restoreGState()
                if sel {
                    Atelier.box(ctx, r.insetBy(dx: -2, dy: -1), weight: Atelier.fine, color: Theme.text, seed: ns &+ 2, overshoot: 2)
                }
                continue
            }
            let path = CGPath(roundedRect: r, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(tint.base.withAlphaComponent(0.35 + 0.65 * v).cgColor)
            ctx.fillPath()
            // A bright start cap and top edge keep quiet (dim) notes readable against the grid in both themes.
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            ctx.setFillColor(tint.waveform.withAlphaComponent(0.95).cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: min(3, r.width), height: r.height))
            ctx.setFillColor(tint.waveform.withAlphaComponent(0.5).cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1))
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor((sel ? Theme.selection : tint.border).cgColor)
            ctx.setLineWidth(sel ? 1.5 : 1)
            ctx.strokePath()
        }
        if let f = entryFrame {
            let cursor = CGRect(x: x(f), y: y(entryPitch) + 1, width: max(3, CGFloat(snapFrames / framesPerPoint)), height: rowHeight - 2)
            ctx.setStrokeColor(Theme.selection.cgColor); ctx.setLineWidth(1.5); ctx.stroke(cursor)
        }
        if let m = marquee {
            let r = CGRect(x: min(m.start.x, m.end.x), y: min(m.start.y, m.end.y),
                           width: abs(m.end.x - m.start.x), height: abs(m.end.y - m.start.y))
            ctx.setFillColor(Theme.selection.withAlphaComponent(0.18).cgColor); ctx.fill(r)
            ctx.setStrokeColor(Theme.selection.cgColor); ctx.setLineWidth(1); ctx.stroke(r)
        }
        ctx.restoreGState()

        drawKeyboard(ctx, g)
        drawRuler(ctx, g)
        drawVelocity(ctx, c, tint)
    }

    /// Warm Analog: a note is a lit pin, a glass tube in a dark housing whose brightness follows velocity,
    /// with a round lamp at the note's start.
    private func drawPin(_ ctx: CGContext, _ r: CGRect, velocity v: CGFloat, tint: TrackTint, selected: Bool) {
        let housing = CGPath(roundedRect: r.insetBy(dx: 0, dy: 0.5), cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        ctx.addPath(housing); ctx.setFillColor(Theme.hex(0x0E0A08).cgColor); ctx.fillPath()
        let lamp = OKLCH.adjust(tint.base, dl: 0.08, chromaScale: 1.1)
        let tube = r.insetBy(dx: min(2, r.width / 4), dy: max(1.5, r.height * 0.28))
        if tube.width > 0, tube.height > 0 {
            ctx.setFillColor(lamp.withAlphaComponent(0.12 + 0.3 * v).cgColor) // bloom
            ctx.fill(tube.insetBy(dx: -1, dy: -1))
            ctx.setFillColor(lamp.withAlphaComponent(0.4 + 0.6 * v).cgColor)
            ctx.addPath(CGPath(roundedRect: tube, cornerWidth: tube.height / 2, cornerHeight: tube.height / 2, transform: nil)); ctx.fillPath()
        }
        let d = max(3, r.height - 3)
        let head = CGRect(x: r.minX + 1, y: r.midY - d / 2, width: d, height: d)
        ctx.setFillColor(lamp.withAlphaComponent(0.35 * v + 0.15).cgColor); ctx.fillEllipse(in: head.insetBy(dx: -1.5, dy: -1.5))
        ctx.setFillColor(NSColor(white: 1, alpha: 0.55 + 0.4 * v).blended(withFraction: 0.5, of: lamp)?.cgColor ?? lamp.cgColor)
        ctx.fillEllipse(in: head)
        ctx.addPath(housing)
        ctx.setStrokeColor((selected ? Theme.selection : Theme.hex(0x000000, 0.6)).cgColor)
        ctx.setLineWidth(selected ? 1.5 : 0.75)
        ctx.strokePath()
    }

    private func drawBeatLines(_ ctx: CGContext, from top: CGFloat, height: CGFloat) {
        // Walk bars through the meter map; inside each bar, 16ths, meter beats, or nothing when zoomed out.
        var bar = session.bar(atBeat: session.frameToBeat(frame(atX: grid.minX))).bar
        var guardCount = 0
        while guardCount < 2_000 {
            guardCount += 1
            let start = session.barToBeat(bar), end = session.barToBeat(bar + 1)
            if x(session.beatToFrame(start)) > grid.maxX { break }
            let meterBeat = 4.0 / Double(session.bar(atBeat: start).den)
            let sixteenthPts = session.beatToFrame(start + 0.25) - session.beatToFrame(start)
            let beatPts = session.beatToFrame(start + meterBeat) - session.beatToFrame(start)
            let step = sixteenthPts / framesPerPoint >= 8 ? 0.25 : (beatPts / framesPerPoint >= 8 ? meterBeat : end - start)
            var q = start
            while q < end - 1e-9 {
                let rel = q - start
                let isBar = rel < 1e-9, isBeat = abs((rel / meterBeat).rounded() * meterBeat - rel) < 1e-9
                if Theme.look.editors == .engraved {
                    // Bar lines are rules, heavier every fourth bar; beats fine, sixteenths dotted.
                    let lx = x(session.beatToFrame(q)).rounded() + 0.5
                    if isBar { Atelier.rule(ctx, CGPoint(x: lx, y: top), CGPoint(x: lx, y: top + height), weight: bar % 4 == 0 ? Atelier.medium : Atelier.fine, color: Theme.ink(0.5)) }
                    else if isBeat { Atelier.rule(ctx, CGPoint(x: lx, y: top), CGPoint(x: lx, y: top + height), weight: Atelier.hair, color: Theme.ink(0.2)) }
                    else { Atelier.rule(ctx, CGPoint(x: lx, y: top), CGPoint(x: lx, y: top + height), weight: Atelier.hair, color: Theme.ink(0.12), dash: [1, 3]) }
                    q += step; continue
                }
                ctx.setFillColor((isBar ? Theme.ink(0.14) : isBeat ? Theme.gridMajor : Theme.gridMinor).cgColor)
                ctx.fill(CGRect(x: x(session.beatToFrame(q)).rounded(), y: top, width: 1, height: height))
                q += step
            }
            bar += 1
        }
    }

    private func drawKeyboard(_ ctx: CGContext, _ g: CGRect) {
        ctx.saveGState()
        let column = CGRect(x: 0, y: g.minY, width: Self.keyWidth - 1, height: g.height)
        ctx.clip(to: column)
        // Ivory keys with hairlines where white keys meet (between E–F and B–C, and around black keys),
        // then black keys inset from the left like a real keyboard seen from above.
        let family = Theme.look.editors
        ctx.setFillColor((family == .glass ? (Theme.isLight ? Theme.panelRaised : Theme.hex(0x3A4366)) : family == .engraved ? Theme.panelRaised : Theme.hex(0xE9E4DA)).cgColor)
        ctx.fill(column)
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        // Pitch classes this clip uses (from its notes): marked in the keyboard's margin, to see the material at a glance.
        let used = Set((clip?.notes ?? []).map { Int($0.pitch) % 12 })
        for p in 0...127 {
            let ry = y(p)
            guard ry + rowHeight >= g.minY, ry <= g.maxY else { continue }
            let black = [1, 3, 6, 8, 10].contains(p % 12)
            if family == .glass || family == .engraved {
                if black {
                    let r = CGRect(x: 0, y: ry + 1, width: Self.keyWidth * 0.55, height: rowHeight - 2)
                    if family == .glass { ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.setFillColor(Theme.hex(0x080A14).cgColor); ctx.fillPath() }
                    else { ctx.setFillColor(Theme.text.cgColor); ctx.fill(r) }
                } else if p % 12 == 0 || p % 12 == 5 {
                    ctx.setFillColor(Theme.ink(0.25).cgColor); ctx.fill(CGRect(x: 0, y: ry + rowHeight - 0.5, width: Self.keyWidth, height: 0.5))
                }
                if used.contains(p % 12) {
                    let dot = CGRect(x: Self.keyWidth - 6, y: ry + rowHeight / 2 - 1.5, width: 3, height: 3)
                    ctx.setFillColor((family == .glass ? Theme.accent : Atelier.vermilion).cgColor); ctx.fillEllipse(in: dot)
                }
                if p % 12 == 0 {
                    let font = family == .engraved ? Theme.title(9, .regular) : Theme.mono(8.5, .medium)
                    ("\(names[p % 12])\(p / 12 - 1)" as NSString).draw(at: CGPoint(x: Self.keyWidth - 28, y: ry + (rowHeight - 11) / 2), withAttributes: [.font: font, .foregroundColor: Theme.textDim])
                }
                continue
            }
            if black {
                ctx.setFillColor(Theme.hex(0x121315).cgColor)
                let r = CGRect(x: 0, y: ry + 0.5, width: Self.keyWidth * 0.6, height: rowHeight - 1)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                ctx.fillPath()
            } else if p % 12 == 0 || p % 12 == 5 {
                ctx.setFillColor(Theme.hex(0x000000, 0.28).cgColor) // B|C and E|F boundaries
                ctx.fill(CGRect(x: 0, y: ry + rowHeight - 0.5, width: Self.keyWidth, height: 1))
            }
            if p % 12 == 0 {
                let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(8.5, .semibold), .foregroundColor: Theme.hex(0x55575C)]
                ("\(names[p % 12])\(p / 12 - 1)" as NSString).draw(at: CGPoint(x: Self.keyWidth - 24, y: ry + (rowHeight - 11) / 2), withAttributes: attrs)
            }
        }
        ctx.restoreGState()
        Theme.separator.setFill(); CGRect(x: Self.keyWidth - 1, y: g.minY, width: 1, height: g.height).fill()
    }

    private func drawRuler(_ ctx: CGContext, _ g: CGRect) {
        Theme.panel.setFill(); CGRect(x: 0, y: 0, width: bounds.width, height: Self.rulerHeight).fill()
        Theme.separator.setFill(); CGRect(x: 0, y: Self.rulerHeight - 1, width: bounds.width, height: 1).fill()
        if Theme.look.editors == .engraved {
            Atelier.rule(ctx, CGPoint(x: 0, y: Self.rulerHeight - 0.75), CGPoint(x: bounds.width, y: Self.rulerHeight - 0.75), weight: Atelier.medium)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(10, Theme.look.editors == .engraved ? .medium : .regular), .foregroundColor: Theme.look.editors == .engraved ? Theme.text : Theme.textDim]
        let center = session.frameToBeat(frame(atX: g.midX))
        let c = session.bar(atBeat: center)
        let barFrames = session.beatToFrame(session.barToBeat(c.bar + 1)) - session.beatToFrame(session.barToBeat(c.bar))
        let every = max(1, Int((70 * framesPerPoint / max(1, barFrames)).rounded(.up)))
        var index = session.bar(atBeat: session.frameToBeat(frame(atX: g.minX))).bar
        index = Int((Double(index) / Double(every)).rounded(.down)) * every
        while index < 1_000_000 {
            let f = session.beatToFrame(session.barToBeat(index))
            if x(f) > g.maxX { break }
            if x(f) >= g.minX && index >= 0 {
                Theme.textFaint.setFill(); CGRect(x: x(f).rounded(), y: 5, width: 1, height: Self.rulerHeight - 6).fill()
                ("\(index + 1)" as NSString).draw(at: CGPoint(x: x(f) + 4, y: 4), withAttributes: attrs)
            }
            index += every
        }
    }

    private func drawVelocity(_ ctx: CGContext, _ c: ClipView, _ tint: TrackTint) {
        let lane = velocityLane
        Theme.panel.setFill(); CGRect(x: 0, y: lane.minY, width: bounds.width, height: lane.height).fill()
        Theme.separator.setFill(); CGRect(x: 0, y: lane.minY, width: bounds.width, height: 1).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9, .medium), .foregroundColor: Theme.textDim]
        ("VELOCITY" as NSString).draw(at: CGPoint(x: 6, y: lane.minY + 6), withAttributes: attrs)
        ctx.saveGState()
        ctx.clip(to: lane)
        // A chord's stems share one x: the loudest is drawn first and selected ones last, so every head stays visible
        // above the stems in front of it.
        let order = visibleNotes(c).sorted { a, b in
            let sa = selection.contains(key(a)), sb = selection.contains(key(b))
            return sa != sb ? !sa : a.velocity > b.velocity
        }
        for n in order {
            let sx = x(timeline(n, c))
            guard sx >= lane.minX - 4, sx <= lane.maxX + 4 else { continue }
            let h = (lane.height - 12) * CGFloat(n.velocity) / 127
            let sel = selection.contains(NoteKey(start: n.start, pitch: n.pitch))
            switch Theme.look.editors {
            case .glass: // pillars of light with a bright bead on top
                let bar = CGRect(x: sx - 1, y: lane.maxY - 4 - h, width: 4, height: h)
                let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [tint.waveform.withAlphaComponent(0.9).cgColor, tint.base.withAlphaComponent(0.1).cgColor] as CFArray, locations: [0, 1])!
                ctx.saveGState(); ctx.clip(to: bar); ctx.drawLinearGradient(gr, start: CGPoint(x: 0, y: bar.minY), end: CGPoint(x: 0, y: bar.maxY), options: []); ctx.restoreGState()
                ctx.setFillColor((sel ? NSColor.white : tint.waveform).cgColor)
                ctx.fillEllipse(in: CGRect(x: sx - 2, y: bar.minY - 2.5, width: 6, height: 6))
            case .engraved: // a stem with an open head (a filled one when selected), like a printed plot
                let ink = OKLCH.adjust(tint.base, dl: Theme.isLight ? -0.12 : 0.05, chromaScale: Theme.isLight ? 1 : 0.8)
                Atelier.rule(ctx, CGPoint(x: sx + 1, y: lane.maxY - 4), CGPoint(x: sx + 1, y: lane.maxY - 4 - h), weight: Atelier.fine, color: sel ? Theme.text : ink)
                let head = CGRect(x: sx - 2, y: lane.maxY - 4 - h - 3, width: 6, height: 6)
                ctx.setFillColor(Theme.panel.cgColor); ctx.fillEllipse(in: head)
                Atelier.loop(ctx, head, weight: Atelier.fine, color: sel ? Theme.text : ink)
                if sel { ctx.setFillColor(Theme.text.cgColor); ctx.fillEllipse(in: head.insetBy(dx: 1.5, dy: 1.5)) }
            case .grid, .tape:
                ctx.setFillColor((sel ? Theme.selection : tint.waveform).cgColor)
                ctx.fill(CGRect(x: sx, y: lane.maxY - 4 - h, width: 2, height: h))
                ctx.fillEllipse(in: CGRect(x: sx - 2, y: lane.maxY - 4 - h - 2.5, width: 6, height: 6))
            }
        }
        ctx.restoreGState()
    }

    // MARK: Editing

    private struct Drag {
        enum Kind { case move, resize, velocity, create }
        let kind: Kind
        let start: CGPoint
        let original: [DalnokNote] // all notes at gesture start
        let moving: Set<NoteKey>
        var changed = false
        var previewed: UInt8? = nil
    }
    private var drag: Drag?
    private struct Marquee { let start: CGPoint; var end: CGPoint; let initial: Set<NoteKey> }
    private var marquee: Marquee?

    func key(_ n: DalnokNote) -> NoteKey { NoteKey(start: n.start, pitch: n.pitch) }

    /// Replaces the clip's notes (one undo step, or part of the current gesture's group).
    func commit(_ notes: [DalnokNote], select: Set<NoteKey>? = nil) {
        session.setNotes(clipId, notes)
        if let select { selection = select }
        needsDisplay = true
    }

    func hitNote(_ p: CGPoint) -> (DalnokNote, edge: Bool)? {
        guard let c = clip else { return nil }
        for n in visibleNotes(c).reversed() {
            let r = rect(n, c)
            if r.insetBy(dx: -1, dy: 0).contains(p) { return (n, p.x >= r.maxX - Self.edge) }
        }
        return nil
    }
    func hitStem(_ p: CGPoint) -> DalnokNote? {
        guard let c = clip, velocityLane.contains(p) else { return nil }
        // Notes of a chord share one x: the closest stem top to the pointer wins, so each can be picked.
        let near = visibleNotes(c).filter { abs(x(timeline($0, c)) - p.x) <= 6 }
        let lane = velocityLane
        func top(_ n: DalnokNote) -> CGFloat { lane.maxY - 4 - (lane.height - 12) * CGFloat(n.velocity) / 127 }
        return near.min { (abs(x(timeline($0, c)) - p.x), abs(top($0) - p.y)) < (abs(x(timeline($1, c)) - p.x), abs(top($1) - p.y)) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        (window?.windowController as? PianoRollController)?.focused = true
        onFocus?()
        guard let c = clip else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let n = hitStem(p) {
            let k = key(n)
            if !selection.contains(k) { selection = [k] }
            drag = Drag(kind: .velocity, start: p, original: c.notes, moving: selection)
            session.engine.beginGroup("Note Velocity")
            holdPreview(n.pitch, n.velocity)
            return
        }
        // The keyboard on the left plays its keys (held while the mouse is down; dragging glides).
        if p.x < Self.keyWidth, p.y >= grid.minY, p.y <= grid.maxY {
            playingKeys = true
            holdPreview(UInt8(pitch(atY: p.y)), 100)
            return
        }
        guard grid.contains(p) else { return }
        if let (n, edge) = hitNote(p) {
            let k = key(n)
            if event.modifierFlags.contains(.shift) {
                if selection.contains(k) { selection.remove(k) } else { selection.insert(k) }
            } else if !selection.contains(k) {
                selection = [k]
            }
            drag = Drag(kind: edge ? .resize : .move, start: p, original: c.notes, moving: selection, previewed: n.pitch)
            session.engine.beginGroup(edge ? "Resize Notes" : "Move Notes")
            holdPreview(n.pitch, n.velocity) // clicking a note plays it
            (edge ? NSCursor.resizeLeftRight : NSCursor.closedHand).set()
            return
        }
        if event.clickCount == 2 {
            // Double-click adds a note; dragging on stretches it to where the mouse is (one undo step).
            session.engine.beginGroup("Add Note")
            if let n = addNote(at: p, bypass: event.modifierFlags.contains(.control)), let cur = clip {
                drag = Drag(kind: .create, start: p, original: cur.notes, moving: [key(n)], previewed: n.pitch)
                holdPreview(n.pitch, n.velocity)
                NSCursor.resizeLeftRight.set()
            } else {
                session.engine.endGroup()
            }
        } else {
            let initial = event.modifierFlags.contains(.shift) ? selection : []
            selection = initial
            marquee = Marquee(start: p, end: p, initial: initial)
        }
    }

    /// Snaps down to the grid (the cell the point is in), so a double-click lands a note where it was clicked.
    func snapDown(_ f: Double, bypass: Bool) -> Double {
        guard !bypass else { return f.rounded() }
        let q = snapBeats
        return session.beatToFrame((session.frameToBeat(f) / q + 1e-9).rounded(.down) * q).rounded()
    }

    @discardableResult func addNote(at p: CGPoint, bypass: Bool = false) -> DalnokNote? {
        guard let c = clip else { return nil }
        let start = snap(frame(atX: p.x), bypass: bypass)
        let length = Int64(snapFrames)
        let rel = Int64(start) - c.start + c.offset
        guard rel >= c.offset, rel < c.offset + c.length else { return nil }
        let n = DalnokNote(start: rel, length: length, pitch: UInt8(pitch(atY: p.y)), velocity: 100)
        commit(c.notes.filter { key($0) != key(n) } + [n], select: [key(n)])
        if drag == nil { previewNote(n.pitch, n.velocity) }
        return n
    }

    override func mouseDragged(with event: NSEvent) {
        if playingKeys {
            let p = convert(event.locationInWindow, from: nil)
            holdPreview(UInt8(max(0, min(127, pitch(atY: min(max(p.y, grid.minY), grid.maxY))))), 100)
            return
        }
        if var m = marquee, let c = clip {
            let p = convert(event.locationInWindow, from: nil)
            m.end = CGPoint(x: min(max(p.x, grid.minX), grid.maxX), y: min(max(p.y, grid.minY), grid.maxY))
            let r = CGRect(x: min(m.start.x, m.end.x), y: min(m.start.y, m.end.y),
                           width: abs(m.end.x - m.start.x), height: abs(m.end.y - m.start.y))
            selection = m.initial.union(visibleNotes(c).filter { rect($0, c).intersects(r) }.map(key))
            marquee = m
            needsDisplay = true
            return
        }
        guard var d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        let bypass = event.modifierFlags.contains(.control)
        let dxFrames = Double(p.x - d.start.x) * framesPerPoint
        var result: [DalnokNote] = [], moved: Set<NoteKey> = []
        switch d.kind {
        case .move:
            // Snap the gesture so the grabbed note lands on the grid; keep relative timing.
            let moving = d.original.filter { d.moving.contains(key($0)) }
            guard let earliest = moving.map(\.start).min(), let low = moving.map(\.pitch).min(), let high = moving.map(\.pitch).max() else { return }
            // The beat grid follows tempo changes: snap the earliest note's landing point, then move all by that delta.
            let origin = Double((clip?.start ?? 0) - (clip?.offset ?? 0)), t0 = origin + Double(earliest)
            // Stay inside the clip's window: a note moved past its end (or before a trimmed start) is neither shown nor played.
            let lo = Int64(clip?.offset ?? 0), hi = lo + Int64((clip?.length ?? 1) - 1)
            let latest = moving.map(\.start).max() ?? earliest
            let dt = max(lo - earliest, min(hi - latest, Int64(bypass ? dxFrames.rounded() : snap(t0 + dxFrames, bypass: false) - t0)))
            let dp = max(-Int(low), min(127 - Int(high), -Int(((p.y - d.start.y) / rowHeight).rounded())))
            var landed: [DalnokNote] = [] // after the others, so a note dropped on an identical one replaces it
            for n in d.original {
                guard d.moving.contains(key(n)) else { result.append(n); continue }
                let m = DalnokNote(start: n.start + dt, length: n.length,
                                   pitch: UInt8(Int(n.pitch) + dp), velocity: n.velocity)
                landed.append(m)
                moved.insert(key(m))
            }
            result += landed
            // The grabbed note sounds at its new pitch as it moves.
            if let grabbed = d.previewed, let now = UInt8(exactly: Int(grabbed) + dp), heldPreview?.pitch != now,
               let n = result.first(where: { moved.contains(key($0)) }) {
                holdPreview(now, n.velocity)
            }
        case .resize:
            let dl = Int64(bypass ? dxFrames.rounded() : (dxFrames / snapFrames).rounded() * snapFrames)
            for n in d.original {
                guard d.moving.contains(key(n)) else { result.append(n); continue }
                result.append(DalnokNote(start: n.start, length: max(Int64(snapFrames / 4), n.length + dl), pitch: n.pitch, velocity: n.velocity))
                moved.insert(key(n))
            }
        case .create:
            // The new note runs from its start to the grid line nearest the mouse (at least one grid step).
            guard let n = d.original.first(where: { d.moving.contains(key($0)) }), let c = clip else { return }
            let startFrame = timeline(n, c), at = frame(atX: p.x)
            let end = bypass ? at.rounded() : snap(at, bypass: false)
            let minLen = bypass ? max(1, snapFrames / 4) : snapFrames
            let len = Int64(max(minLen, end - startFrame).rounded())
            for o in d.original {
                guard d.moving.contains(key(o)) else { result.append(o); continue }
                result.append(DalnokNote(start: o.start, length: len, pitch: o.pitch, velocity: o.velocity))
                moved.insert(key(o))
            }
            if result.first(where: { moved.contains(key($0)) })?.length == clip?.notes.first(where: { moved.contains(key($0)) })?.length {
                drag = d; return
            }
        case .velocity:
            let dv = Int(((d.start.y - p.y) / (velocityHeight - 12) * 127).rounded())
            for n in d.original {
                guard d.moving.contains(key(n)) else { result.append(n); continue }
                result.append(DalnokNote(start: n.start, length: n.length, pitch: n.pitch, velocity: UInt8(max(1, min(127, Int(n.velocity) + dv)))))
                moved.insert(key(n))
            }
        }
        if Set(result.map(key)) != Set(clip?.notes.map(key) ?? []) || d.kind != .move {
            commit(result, select: moved)
            d.changed = true
        }
        drag = d
    }

    override func mouseUp(with event: NSEvent) {
        releasePreview()
        playingKeys = false
        if drag != nil { session.engine.endGroup() }
        drag = nil
        marquee = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
        guard let c = clip else { return super.keyDown(with: event) }
        let shift = event.modifierFlags.contains(.shift)
        if event.modifierFlags.contains(.option), (123...126).contains(event.keyCode) {
            let f = entryFrame ?? Double(c.start)
            if event.keyCode == 123 || event.keyCode == 124 {
                let direction = event.keyCode == 124 ? 1.0 : -1.0
                entryFrame = min(Double(c.end - 1), max(Double(c.start), f + direction * snapFrames))
            } else {
                entryFrame = f
                entryPitch = max(0, min(127, entryPitch + (event.keyCode == 126 ? 1 : -1) * (shift ? 12 : 1)))
            }
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { deleteSelection(); return } // usually arrives through Edit ▸ Delete
        // Editing keys come from the shortcut registry (piano-roll context), so they can be reassigned.
        let action = KeyCombo(event: event).flatMap { ShortcutRegistry.shared.resolve($0, context: .pianoRoll) }
        switch action?.id {
        case "midi.step_insert":
            let f = entryFrame ?? Double(c.start)
            let rel = Int64(f.rounded()) - c.start + c.offset
            guard rel >= c.offset, rel < c.offset + c.length else { return }
            let n = DalnokNote(start: rel, length: min(Int64(snapFrames.rounded()), c.offset + c.length - rel), pitch: UInt8(entryPitch), velocity: 100)
            commit(c.notes.filter { key($0) != key(n) } + [n], select: [key(n)])
            previewNote(n.pitch, n.velocity)
            entryFrame = min(Double(c.end), f + snapFrames)
        case "midi.transpose_up": transpose(by: 1)
        case "midi.transpose_down": transpose(by: -1)
        case "midi.transpose_octave_up": transpose(by: 12)
        case "midi.transpose_octave_down": transpose(by: -12)
        case "midi.nudge_left": nudge(by: -Int64(snapFrames))
        case "midi.nudge_right": nudge(by: Int64(snapFrames))
        case "midi.select_all": selection = Set(visibleNotes(c).map(key))
        case "midi.select_next": moveNoteSelection(forward: true)
        case "midi.select_previous": moveNoteSelection(forward: false)
        case "midi.quantize": quantizeSelection()
        default:
            if action?.item != nil, ShortcutRegistry.shared.perform(action!) { return } // a global command (e.g. Play)
            super.keyDown(with: event)
        }
    }

    /// ] and [ walk the notes in time order without a mouse (the arrows edit the selection: transpose and nudge).
    func moveNoteSelection(forward: Bool) {
        guard let c = clip else { return }
        let notes = visibleNotes(c).sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        guard !notes.isEmpty else { return }
        let chosen = notes.filter { selection.contains(key($0)) }
        let target: DalnokNote?
        if forward {
            target = chosen.last.map { a in notes.first { ($0.start, $0.pitch) > (a.start, a.pitch) } ?? a } ?? notes.first
        } else {
            target = chosen.first.map { a in notes.last { ($0.start, $0.pitch) < (a.start, a.pitch) } ?? a } ?? notes.last
        }
        guard let t = target else { return }
        selection = [key(t)]
        // Scroll the note into view.
        let f = Double(c.start + t.start - c.offset), g = grid
        if x(f) < g.minX || x(f) > g.maxX - 8 { scrollX = max(0, f - Double(g.width / 3) * framesPerPoint) }
        if y(Int(t.pitch)) < g.minY { scrollY = CGFloat(127 - Int(t.pitch)) * rowHeight }
        else if y(Int(t.pitch)) + rowHeight > g.maxY { scrollY += y(Int(t.pitch)) + rowHeight - g.maxY }
        previewNote(t.pitch, t.velocity)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    func deleteSelection() {
        guard let c = clip, !selection.isEmpty else { return }
        commit(c.notes.filter { !selection.contains(key($0)) }, select: [])
    }

    func transpose(by semitones: Int) {
        guard let c = clip, !selection.isEmpty else { return }
        let selected = c.notes.filter { selection.contains(key($0)) }
        guard let low = selected.map(\.pitch).min(), let high = selected.map(\.pitch).max() else { return }
        let delta = max(-Int(low), min(127 - Int(high), semitones))
        guard delta != 0 else { return }
        var sel: Set<NoteKey> = []
        let notes = c.notes.filter { !selection.contains(key($0)) } + c.notes.filter { selection.contains(key($0)) }.map { n -> DalnokNote in
            let m = DalnokNote(start: n.start, length: n.length, pitch: UInt8(Int(n.pitch) + delta), velocity: n.velocity)
            sel.insert(key(m)); return m
        }
        commit(notes, select: sel)
        if let first = notes.first(where: { sel.contains(key($0)) }) { previewNote(first.pitch, first.velocity) }
    }

    func nudge(by frames: Int64) {
        guard let c = clip, !selection.isEmpty else { return }
        let starts = c.notes.filter { selection.contains(key($0)) }.map(\.start)
        guard let earliest = starts.min(), let latest = starts.max() else { return }
        let delta = max(c.offset - earliest, min(c.offset + c.length - 1 - latest, frames))
        guard delta != 0 else { return }
        var sel: Set<NoteKey> = []
        let notes = c.notes.filter { !selection.contains(key($0)) } + c.notes.filter { selection.contains(key($0)) }.map { n -> DalnokNote in
            let m = DalnokNote(start: n.start + delta, length: n.length, pitch: n.pitch, velocity: n.velocity)
            sel.insert(key(m)); return m
        }
        commit(notes, select: sel)
    }

    /// Quantizes the selected notes (or all) to the quantize value and strength (Clip ▸ Quantize, the editor's bar).
    func quantizeSelection() {
        guard let c = clip else { return }
        let all = selection.isEmpty
        let grid = QuantizeSetting.grid, strength = QuantizeSetting.strength
        var sel: Set<NoteKey> = []
        let picked = { (n: DalnokNote) in all || self.selection.contains(self.key(n)) } // quantized notes go last (they win a collision)
        let notes = c.notes.filter { !picked($0) } + c.notes.filter(picked).map { n -> DalnokNote in
            guard n.start >= c.offset, n.start < c.offset + c.length else { return n } // outside the window: not shown, not touched
            let t = timeline(n, c), target = session.beatToFrame((session.frameToBeat(t) / grid).rounded() * grid)
            let at = min(max(n.start + Int64(((target - t) * strength).rounded()), c.offset), c.offset + c.length - 1)
            let m = DalnokNote(start: at, length: n.length, pitch: n.pitch, velocity: n.velocity)
            if !all { sel.insert(key(m)) }
            return m
        }
        session.engine.beginGroup("Quantize")
        commit(notes, select: sel)
        session.engine.endGroup()
        session.onMessage?("Quantized \(all ? "every note" : sel.count == 1 ? "1 note" : "\(sel.count) notes") to \(QuantizeSetting.name)\(strength < 1 ? " at \(Int((strength * 100).rounded()))%" : "")")
    }

    // MARK: Copy and paste

    /// Copied notes, relative to the earliest (start 0); shared by every piano roll.
    static var clipboard: [DalnokNote] = []
    var selectedNotes: [DalnokNote] { clip.map { c in c.notes.filter { selection.contains(key($0)) } } ?? [] }
    /// The timeline frame where the selection starts (Play starts there).
    var selectionStartFrame: Int64? {
        guard let c = clip, let first = selectedNotes.map(\.start).min() else { return nil }
        return c.start + first - c.offset
    }
    @discardableResult func copySelection() -> Int {
        let notes = selectedNotes
        guard let first = notes.map(\.start).min() else { return 0 }
        Self.clipboard = notes.map { DalnokNote(start: $0.start - first, length: $0.length, pitch: $0.pitch, velocity: $0.velocity) }
        return notes.count
    }
    func cutSelection() {
        guard copySelection() > 0 else { return }
        session.engine.beginGroup("Cut Notes")
        deleteSelection()
        session.engine.endGroup()
    }
    /// Pastes at the playhead when it is inside the clip, else right after the selection (or at the clip's start).
    func paste() {
        guard let c = clip, !Self.clipboard.isEmpty else { NSSound.beep(); return }
        let pos = session.engine.position
        let at: Int64 = pos >= c.start && pos < c.end ? pos - c.start + c.offset
            : selectedNotes.map { $0.start + $0.length }.max() ?? c.offset
        place(Self.clipboard, at: at, name: "Paste Notes")
    }
    /// A copy of the selection right after it (rounded up to the grid), selected.
    func duplicateSelection() {
        let notes = selectedNotes
        guard let first = notes.map(\.start).min(), let last = notes.map({ $0.start + $0.length }).max() else { NSSound.beep(); return }
        let span = Double(last - first), step = max(snapFrames, (span / snapFrames).rounded(.up) * snapFrames)
        place(notes.map { DalnokNote(start: $0.start - first, length: $0.length, pitch: $0.pitch, velocity: $0.velocity) },
              at: first + Int64(step.rounded()), name: "Duplicate Notes")
    }
    /// Places relative notes at source frame `at` (one undo step), lengthening the clip when they run past its end.
    private func place(_ relative: [DalnokNote], at: Int64, name: String) {
        guard let c = clip else { return }
        let placed = relative.map { DalnokNote(start: at + $0.start, length: $0.length, pitch: $0.pitch, velocity: $0.velocity) }
        let keys = Set(placed.map(key))
        session.engine.beginGroup(name)
        commit(c.notes.filter { !keys.contains(key($0)) } + placed, select: keys)
        if let end = placed.map({ $0.start + $0.length }).max(), end > c.offset + c.length {
            session.setRegion(c.id, start: c.start, offset: c.offset, length: end - c.offset)
        }
        session.engine.endGroup()
    }

    /// Plays the note on the instrument when this clip's track is the armed (live) one.
    // Auditioning, as in other DAWs: notes sound through the clip's track instrument while you click, hold, move or
    // resize them, armed or not, playing or stopped, and are never recorded (dalnok_track_preview_note).
    private var heldPreview: (track: DalnokTrackId, pitch: UInt8)?
    private var playingKeys = false

    /// Sample-based instruments finish loading during their first processing calls, so the first note heard after
    /// opening a project came late or not at all. A release of no note makes the track's instrument process for a
    /// moment (2 s) without a sound, before anything is clicked.
    func warmInstrument() {
        if let t = track?.id { _ = dalnok_track_preview_note(session.engine.handle, t, 0, 0, false) }
    }
    /// A short note: created, transposed or step-entered notes.
    func previewNote(_ pitch: UInt8, _ velocity: UInt8) {
        guard let t = track?.id else { return }
        let h = session.engine.handle
        guard dalnok_track_preview_note(h, t, pitch, velocity, true) == DALNOK_OK else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { _ = dalnok_track_preview_note(h, t, pitch, 0, false) }
    }
    /// A note held for as long as the mouse is down on it; moving it to another pitch plays the new one.
    func holdPreview(_ pitch: UInt8, _ velocity: UInt8) {
        if heldPreview?.pitch == pitch { return }
        releasePreview()
        guard let t = track?.id, dalnok_track_preview_note(session.engine.handle, t, pitch, max(1, velocity), true) == DALNOK_OK else { return }
        heldPreview = (t, pitch)
    }
    func releasePreview() {
        if let held = heldPreview { _ = dalnok_track_preview_note(session.engine.handle, held.track, held.pitch, 0, false) }
        heldPreview = nil
    }

    // MARK: Navigation

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            zoom(by: event.scrollingDeltaY > 0 ? 0.9 : 1.1, around: convert(event.locationInWindow, from: nil).x)
            return
        }
        scrollX = max(-Double(grid.width) * framesPerPoint * 0.1, scrollX - Double(event.scrollingDeltaX) * framesPerPoint)
        let maxY = max(0, 128 * rowHeight - grid.height)
        scrollY = max(0, min(maxY, scrollY - event.scrollingDeltaY))
    }
    override func magnify(with event: NSEvent) { zoom(by: 1 / (1 + event.magnification), around: convert(event.locationInWindow, from: nil).x) }
    func zoom(by factor: Double, around px: CGFloat) {
        let anchor = frame(atX: px)
        framesPerPoint = max(5, min(20_000, framesPerPoint * factor))
        scrollX = anchor - Double(px - grid.minX) * framesPerPoint
    }
}
