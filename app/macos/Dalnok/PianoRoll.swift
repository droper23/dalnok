// Piano roll: edit the notes of one MIDI clip. Every gesture is one undo step through the
// engine's midi.setNotes command; the view never caches notes beyond the current gesture.
//   Double-click empty grid: add a note (grid length). Drag empty grid: select notes (⇧ adds).
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
        window.appearance = NSAppearance(named: .darkAqua)
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
        window?.title = "Piano Roll — \(t.name): \(c.name)"
    }
    /// Called after any model change: the clip may have been edited elsewhere, undone or deleted.
    func modelChanged() {
        guard window?.isVisible == true else { return }
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
    var selection: Set<NoteKey> = [] { didSet { needsDisplay = true } }
    struct NoteKey: Hashable { let start: Int64, pitch: UInt8 }
    var entryFrame: Double? { didSet { needsDisplay = true } }
    var entryPitch = 60 { didSet { needsDisplay = true } }

    // Layout
    static let keyWidth: CGFloat = 48, rulerHeight: CGFloat = 22, velocityHeight: CGFloat = 72, edge: CGFloat = 6
    var rowHeight: CGFloat = 12
    var framesPerPoint: Double = 200 { didSet { needsDisplay = true } }
    var scrollX: Double = 0 { didSet { needsDisplay = true } }   // timeline frame at the grid's left edge
    var scrollY: CGFloat = 0 { didSet { needsDisplay = true } }  // points from the top (pitch 127)

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "Drag empty space to select notes. Option-arrow keys move the entry cursor; Return inserts a note."
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var clip: ClipView? { session.clip(clipId).flatMap { $0.isMidi ? $0 : nil } }
    var track: TrackView? { clip.flatMap { session.track($0.track) } }
    var grid: CGRect {
        CGRect(x: Self.keyWidth, y: Self.rulerHeight, width: max(0, bounds.width - Self.keyWidth),
               height: max(0, bounds.height - Self.rulerHeight - Self.velocityHeight))
    }
    var velocityLane: CGRect { CGRect(x: Self.keyWidth, y: bounds.height - Self.velocityHeight, width: grid.width, height: Self.velocityHeight) }

    // MARK: Coordinates (timeline frames and MIDI pitch)

    func x(_ frame: Double) -> CGFloat { grid.minX + CGFloat((frame - scrollX) / framesPerPoint) }
    func frame(atX x: CGFloat) -> Double { scrollX + Double(x - grid.minX) * framesPerPoint }
    func y(_ pitch: Int) -> CGFloat { grid.minY + CGFloat(127 - pitch) * rowHeight - scrollY }
    func pitch(atY y: CGFloat) -> Int { max(0, min(127, 127 - Int(floor((y - grid.minY + scrollY) / rowHeight)))) }
    var framesPerBeat: Double { session.engine.sampleRate * 60 / session.bpm }
    var beatsPerBar: Double { let m = session.meter; return Double(m.0) * 4 / Double(m.1) }
    /// Snap unit: a 16th note, or an 8th / beat when zoomed out.
    var snapFrames: Double {
        let sixteenth = framesPerBeat / 4
        for k in [1.0, 2, 4, 8, 16] where sixteenth * k / framesPerPoint >= 10 { return sixteenth * k }
        return sixteenth * 16
    }
    func snap(_ f: Double, bypass: Bool) -> Double { bypass ? f.rounded() : (f / snapFrames).rounded() * snapFrames }

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
            ctx.setFillColor((black ? Theme.laneB.blended(withFraction: 0.35, of: .black) ?? Theme.laneB : Theme.laneB).cgColor)
            ctx.fill(CGRect(x: g.minX, y: ry, width: g.width, height: rowHeight))
            if p % 12 == 0 { ctx.setFillColor(Theme.gridMajor.cgColor); ctx.fill(CGRect(x: g.minX, y: ry + rowHeight - 1, width: g.width, height: 1)) }
        }
        // Outside the clip window is dimmed.
        ctx.setFillColor(Theme.hex(0x000000, 0.35).cgColor)
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
            let path = CGPath(roundedRect: r, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(tint.base.withAlphaComponent(0.35 + 0.65 * v).cgColor)
            ctx.fillPath()
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

    private func drawBeatLines(_ ctx: CGContext, from top: CGFloat, height: CGFloat) {
        let beat = framesPerBeat, bar = beat * beatsPerBar
        let step = beat / 4 / framesPerPoint >= 8 ? beat / 4 : (beat / framesPerPoint >= 8 ? beat : bar)
        var f = (frame(atX: grid.minX) / step).rounded(.down) * step
        while x(f) <= grid.maxX {
            let isBar = abs((f / bar).rounded() * bar - f) < 1, isBeat = abs((f / beat).rounded() * beat - f) < 1
            ctx.setFillColor((isBar ? Theme.hex(0xFFFFFF, 0.14) : isBeat ? Theme.gridMajor : Theme.gridMinor).cgColor)
            ctx.fill(CGRect(x: x(f).rounded(), y: top, width: 1, height: height))
            f += step
        }
    }

    private func drawKeyboard(_ ctx: CGContext, _ g: CGRect) {
        ctx.saveGState()
        let column = CGRect(x: 0, y: g.minY, width: Self.keyWidth - 1, height: g.height)
        ctx.clip(to: column)
        // Ivory keys with hairlines where white keys meet (between E–F and B–C, and around black keys),
        // then black keys inset from the left like a real keyboard seen from above.
        ctx.setFillColor(Theme.hex(0xE9E4DA).cgColor)
        ctx.fill(column)
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        for p in 0...127 {
            let ry = y(p)
            guard ry + rowHeight >= g.minY, ry <= g.maxY else { continue }
            let black = [1, 3, 6, 8, 10].contains(p % 12)
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
        let bar = framesPerBeat * beatsPerBar
        var f = (frame(atX: g.minX) / bar).rounded(.down) * bar
        let attrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(10), .foregroundColor: Theme.textDim]
        let every = max(1, Int((70 * framesPerPoint / bar).rounded(.up)))
        while x(f) <= g.maxX {
            let index = Int((f / bar).rounded())
            if x(f) >= g.minX && index % every == 0 {
                Theme.textFaint.setFill(); CGRect(x: x(f).rounded(), y: 5, width: 1, height: Self.rulerHeight - 6).fill()
                ("\(index + 1)" as NSString).draw(at: CGPoint(x: x(f) + 4, y: 4), withAttributes: attrs)
            }
            f += bar
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
        for n in visibleNotes(c) {
            let sx = x(timeline(n, c))
            guard sx >= lane.minX - 4, sx <= lane.maxX + 4 else { continue }
            let h = (lane.height - 12) * CGFloat(n.velocity) / 127
            let sel = selection.contains(NoteKey(start: n.start, pitch: n.pitch))
            ctx.setFillColor((sel ? Theme.selection : tint.waveform).cgColor)
            ctx.fill(CGRect(x: sx, y: lane.maxY - 4 - h, width: 2, height: h))
            ctx.fillEllipse(in: CGRect(x: sx - 2, y: lane.maxY - 4 - h - 2.5, width: 6, height: 6))
        }
        ctx.restoreGState()
    }

    // MARK: Editing

    private struct Drag {
        enum Kind { case move, resize, velocity }
        let kind: Kind
        let start: CGPoint
        let original: [DalnokNote] // all notes at gesture start
        let moving: Set<NoteKey>
        var changed = false
        var previewed: UInt8?
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
        return visibleNotes(c).min { abs(x(timeline($0, c)) - p.x) < abs(x(timeline($1, c)) - p.x) }
            .flatMap { abs(x(timeline($0, c)) - p.x) <= 6 ? $0 : nil }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        (window?.windowController as? PianoRollController)?.focused = true
        guard let c = clip else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let n = hitStem(p) {
            let k = key(n)
            if !selection.contains(k) { selection = [k] }
            drag = Drag(kind: .velocity, start: p, original: c.notes, moving: selection)
            session.engine.beginGroup("Note Velocity")
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
            drag = Drag(kind: edge ? .resize : .move, start: p, original: c.notes, moving: selection)
            session.engine.beginGroup(edge ? "Resize Notes" : "Move Notes")
            (edge ? NSCursor.resizeLeftRight : NSCursor.closedHand).set()
            return
        }
        if event.clickCount == 2 {
            addNote(at: p, bypass: event.modifierFlags.contains(.control))
        } else {
            let initial = event.modifierFlags.contains(.shift) ? selection : []
            selection = initial
            marquee = Marquee(start: p, end: p, initial: initial)
        }
    }

    func addNote(at p: CGPoint, bypass: Bool = false) {
        guard let c = clip else { return }
        let start = snap(frame(atX: p.x), bypass: bypass)
        let length = Int64(snapFrames)
        let rel = Int64(start) - c.start + c.offset
        guard rel >= c.offset, rel < c.offset + c.length else { return }
        let n = DalnokNote(start: rel, length: length, pitch: UInt8(pitch(atY: p.y)), velocity: 100)
        commit(c.notes.filter { key($0) != key(n) } + [n], select: [key(n)])
        previewNote(n.pitch, n.velocity)
    }

    override func mouseDragged(with event: NSEvent) {
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
            let dt = Int64(bypass ? dxFrames.rounded() : (dxFrames / snapFrames).rounded() * snapFrames)
            let dp = -Int(((p.y - d.start.y) / rowHeight).rounded())
            for n in d.original {
                guard d.moving.contains(key(n)) else { result.append(n); continue }
                let m = DalnokNote(start: max(0, n.start + dt), length: n.length,
                                   pitch: UInt8(max(0, min(127, Int(n.pitch) + dp))), velocity: n.velocity)
                result.append(m)
                moved.insert(key(m))
            }
            if let first = result.first(where: { moved.contains(key($0)) }), first.pitch != (d.previewed ?? d.original.first { d.moving.contains(key($0)) }?.pitch) {
                previewNote(first.pitch, first.velocity)
                d.previewed = first.pitch
            }
        case .resize:
            let dl = Int64(bypass ? dxFrames.rounded() : (dxFrames / snapFrames).rounded() * snapFrames)
            for n in d.original {
                guard d.moving.contains(key(n)) else { result.append(n); continue }
                result.append(DalnokNote(start: n.start, length: max(Int64(snapFrames / 4), n.length + dl), pitch: n.pitch, velocity: n.velocity))
                moved.insert(key(n))
            }
        case .velocity:
            let dv = Int(((d.start.y - p.y) / (Self.velocityHeight - 12) * 127).rounded())
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
        if drag != nil { session.engine.endGroup() }
        drag = nil
        marquee = nil
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func keyDown(with event: NSEvent) {
        guard let c = clip else { return super.keyDown(with: event) }
        let chars = event.charactersIgnoringModifiers ?? ""
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
        switch event.keyCode {
        case 36, 76: // Return / keypad Enter: step entry inside the clip
            let f = entryFrame ?? Double(c.start)
            let rel = Int64(f.rounded()) - c.start + c.offset
            guard rel >= c.offset, rel < c.offset + c.length else { return }
            let n = DalnokNote(start: rel, length: min(Int64(snapFrames), c.offset + c.length - rel), pitch: UInt8(entryPitch), velocity: 100)
            commit(c.notes.filter { key($0) != key(n) } + [n], select: [key(n)])
            previewNote(n.pitch, n.velocity)
            entryFrame = min(Double(c.end), f + snapFrames)
        case 51, 117: // delete, forward delete (usually arrives through Edit ▸ Delete)
            deleteSelection()
        case 126, 125: // up, down
            transpose(by: (event.keyCode == 126 ? 1 : -1) * (shift ? 12 : 1))
        case 123, 124: // left, right
            nudge(by: Int64((event.keyCode == 124 ? 1 : -1) * snapFrames))
        default:
            if chars == "a" && event.modifierFlags.contains(.command) {
                selection = Set(visibleNotes(c).map(key))
            } else if chars == "q" {
                quantizeSelection()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    func deleteSelection() {
        guard let c = clip, !selection.isEmpty else { return }
        commit(c.notes.filter { !selection.contains(key($0)) }, select: [])
    }

    func transpose(by semitones: Int) {
        guard let c = clip, !selection.isEmpty else { return }
        var sel: Set<NoteKey> = []
        let notes = c.notes.map { n -> DalnokNote in
            guard selection.contains(key(n)) else { return n }
            let m = DalnokNote(start: n.start, length: n.length, pitch: UInt8(max(0, min(127, Int(n.pitch) + semitones))), velocity: n.velocity)
            sel.insert(key(m)); return m
        }
        commit(notes, select: sel)
        if let first = notes.first(where: { sel.contains(key($0)) }) { previewNote(first.pitch, first.velocity) }
    }

    func nudge(by frames: Int64) {
        guard let c = clip, !selection.isEmpty else { return }
        var sel: Set<NoteKey> = []
        let notes = c.notes.map { n -> DalnokNote in
            guard selection.contains(key(n)) else { return n }
            let m = DalnokNote(start: max(0, n.start + frames), length: n.length, pitch: n.pitch, velocity: n.velocity)
            sel.insert(key(m)); return m
        }
        commit(notes, select: sel)
    }

    /// Quantizes the selected notes (or all) to the current snap grid.
    func quantizeSelection() {
        guard let c = clip else { return }
        let all = selection.isEmpty
        var sel: Set<NoteKey> = []
        let q = snapFrames
        let notes = c.notes.map { n -> DalnokNote in
            guard all || selection.contains(key(n)) else { return n }
            let t = timeline(n, c), snapped = (t / q).rounded() * q
            let m = DalnokNote(start: max(0, n.start + Int64(snapped - t)), length: n.length, pitch: n.pitch, velocity: n.velocity)
            if !all { sel.insert(key(m)) }
            return m
        }
        commit(notes, select: sel)
    }

    /// Plays the note on the instrument when this clip's track is the armed (live) one.
    func previewNote(_ pitch: UInt8, _ velocity: UInt8) {
        guard track?.armed == true else { return }
        let h = session.engine.handle
        dalnok_midi_inject(h, 0x90, pitch, velocity)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { dalnok_midi_inject(h, 0x80, pitch, 0) }
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
