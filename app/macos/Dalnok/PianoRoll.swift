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
    static let keyWidth: CGFloat = 48, rulerHeight: CGFloat = 22, velocityHeight: CGFloat = 72, edge: CGFloat = 6
    var rowHeight: CGFloat = 12
    var framesPerPoint: Double = 200 { didSet { needsDisplay = true; if snapBeats != shownSnap { updateSubtitle() } } }
    private var shownSnap = 0.0

    /// Window subtitle: the snap value and what's selected, so state isn't hidden.
    func updateSubtitle() {
        shownSnap = snapBeats
        let snap = snapBeats > 1 ? "\(Int(snapBeats)) quarter notes" : "1/\(Int((4 / snapBeats).rounded())) note"
        var parts = ["Snap \(snap) (⌃ to bypass)"]
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
        window?.subtitle = parts.joined(separator: "  ·  ")
    }
    var scrollX: Double = 0 { didSet { needsDisplay = true } }   // timeline frame at the grid's left edge
    var scrollY: CGFloat = 0 { didSet { needsDisplay = true } }  // points from the top (pitch 127)

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        clipsToBounds = true
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
                let ink = OKLCH.adjust(tint.base, dl: Theme.isLight ? -0.12 : 0.1, chromaScale: 1)
                let weight = 1 + 4 * v, mid = r.midY
                ctx.setFillColor(ink.cgColor)
                ctx.fill(CGRect(x: r.minX, y: mid - weight / 2, width: r.width, height: weight))
                Atelier.rule(ctx, CGPoint(x: r.maxX - 0.5, y: r.minY + 1), CGPoint(x: r.maxX - 0.5, y: r.maxY - 1), weight: Atelier.fine, color: ink)
                let d = min(rowHeight - 1, 10)
                let head = CGRect(x: r.minX - 0.5, y: mid - d / 2, width: d * 1.25, height: d)
                ctx.saveGState(); ctx.translateBy(x: head.midX, y: head.midY); ctx.rotate(by: -0.35)
                ctx.fillEllipse(in: CGRect(x: -head.width / 2, y: -head.height / 2, width: head.width, height: head.height))
                ctx.restoreGState()
                if sel {
                    ctx.setStrokeColor(Theme.text.cgColor); ctx.setLineWidth(Atelier.fine); ctx.stroke(r.insetBy(dx: -2, dy: -1))
                    Atelier.cropMarks(ctx, r.insetBy(dx: -2, dy: -1), length: 4, gap: 1.5, weight: Atelier.hair)
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
        ctx.setFillColor((family == .glass ? Theme.hex(0x3A4366) : family == .engraved ? Theme.panelRaised : Theme.hex(0xE9E4DA)).cgColor)
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
        for n in visibleNotes(c) {
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
                let ink = OKLCH.adjust(tint.base, dl: Theme.isLight ? -0.12 : 0.1, chromaScale: 1)
                Atelier.rule(ctx, CGPoint(x: sx + 1, y: lane.maxY - 4), CGPoint(x: sx + 1, y: lane.maxY - 4 - h), weight: Atelier.fine, color: sel ? Theme.text : ink)
                let head = CGRect(x: sx - 2, y: lane.maxY - 4 - h - 3, width: 6, height: 6)
                ctx.setFillColor(Theme.panel.cgColor); ctx.fillEllipse(in: head)
                ctx.setStrokeColor((sel ? Theme.text : ink).cgColor); ctx.setLineWidth(Atelier.fine); ctx.strokeEllipse(in: head)
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
        enum Kind { case move, resize, velocity }
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
            let dt = max(-earliest, Int64(bypass ? dxFrames.rounded() : snap(t0 + dxFrames, bypass: false) - t0))
            let dp = max(-Int(low), min(127 - Int(high), -Int(((p.y - d.start.y) / rowHeight).rounded())))
            for n in d.original {
                guard d.moving.contains(key(n)) else { result.append(n); continue }
                let m = DalnokNote(start: n.start + dt, length: n.length,
                                   pitch: UInt8(Int(n.pitch) + dp), velocity: n.velocity)
                result.append(m)
                moved.insert(key(m))
            }
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
        case "midi.quantize": quantizeSelection()
        default:
            if action?.item != nil, ShortcutRegistry.shared.perform(action!) { return } // a global command (e.g. Play)
            super.keyDown(with: event)
        }
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
        let notes = c.notes.map { n -> DalnokNote in
            guard selection.contains(key(n)) else { return n }
            let m = DalnokNote(start: n.start, length: n.length, pitch: UInt8(Int(n.pitch) + delta), velocity: n.velocity)
            sel.insert(key(m)); return m
        }
        commit(notes, select: sel)
        if let first = notes.first(where: { sel.contains(key($0)) }) { previewNote(first.pitch, first.velocity) }
    }

    func nudge(by frames: Int64) {
        guard let c = clip, !selection.isEmpty else { return }
        guard let earliest = c.notes.filter({ selection.contains(key($0)) }).map(\.start).min() else { return }
        let delta = max(-earliest, frames)
        guard delta != 0 else { return }
        var sel: Set<NoteKey> = []
        let notes = c.notes.map { n -> DalnokNote in
            guard selection.contains(key(n)) else { return n }
            let m = DalnokNote(start: n.start + delta, length: n.length, pitch: n.pitch, velocity: n.velocity)
            sel.insert(key(m)); return m
        }
        commit(notes, select: sel)
    }

    /// Quantizes the selected notes (or all) to the current snap grid.
    func quantizeSelection() {
        guard let c = clip else { return }
        let all = selection.isEmpty
        var sel: Set<NoteKey> = []
        let notes = c.notes.map { n -> DalnokNote in
            guard all || selection.contains(key(n)) else { return n }
            let t = timeline(n, c), snapped = snap(t, bypass: false)
            let m = DalnokNote(start: max(0, n.start + Int64(snapped - t)), length: n.length, pitch: n.pitch, velocity: n.velocity)
            if !all { sel.insert(key(m)) }
            return m
        }
        commit(notes, select: sel)
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
