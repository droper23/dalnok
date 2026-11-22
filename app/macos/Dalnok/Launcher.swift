// Clip launcher (View ▸ Clip Launcher): a grid of slots on the same rows as the track lanes, between the
// headers and the timeline (one track model: each track has a timeline lane and launcher slots).
// Click a clip to launch it (it starts on the next bar and loops); click an empty slot on a playing track to
// stop it; with a clip selected on a track, click one of its empty slots to put a copy there. On a record-enabled
// track every empty slot carries a record mark: click it to record straight into that slot (the take keeps the
// whole bars it covers), click it again to stop. Drag clips between slots and the arrangement (a copy each way, one
// undo step). The top row launches scenes (whole columns). Launches, queued launches and clips arriving in a slot
// animate through Motion (Reduce Motion: instant, and a queued launch is a steady dashed outline).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class LauncherView: NSView, TrackScrollHost, KeyOwner {
    var onScroll: ((NSEvent) -> Void)?
    func scrollTracks(with event: NSEvent) { onScroll?(event) }
    override func scrollWheel(with event: NSEvent) { scrollTracks(with: event) }
    static let slotWidth: CGFloat = 70
    let session: Session
    var scrollY: CGFloat = 0 { didSet { needsDisplay = true } }
    /// The selected timeline clip (copied into an empty slot on its track when clicked).
    var selectedClip: () -> DalnokClipId? = { nil }
    var onMessage: ((String) -> Void)?
    /// Click on an empty slot's record mark (record-enabled tracks): record into that slot, or stop that take.
    var onRecordInto: ((Int) -> Void)?
    /// Motion state: launch sweeps per (track, slot) and arrivals per slot clip, 0…1 while running.
    struct SlotKey: Hashable { let track: DalnokTrackId; let slot: Int32 }
    private(set) var launchSweep: [SlotKey: Double] = [:]
    private(set) var arrival: [DalnokClipId: Double] = [:]
    private var lastPlaying: [DalnokTrackId: Int32] = [:]
    private var knownSlotClips: Set<DalnokClipId>?
    private var drivers: [MotionDriver] = []

    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        setAccessibilityLabel("Clip launcher")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    var width: CGFloat { CGFloat(session.scenes) * Self.slotWidth + 8 }
    /// Places a slot clip on the timeline (track, frame) when a slot is dragged out of the launcher.
    var onDropToTimeline: ((DalnokClipId, CGPoint) -> Bool)?
    private var dragFrom: (clip: DalnokClipId, at: CGPoint)?

    func laneY(_ i: Int) -> CGFloat { Theme.rulerHeight + session.laneTop(i) - scrollY }
    func slotRect(row: Int, slot: Int) -> CGRect {
        CGRect(x: 4 + CGFloat(slot) * Self.slotWidth, y: laneY(row) + 6, width: Self.slotWidth - 6, height: session.laneHeight(row) - 12)
    }
    /// The record mark of an empty slot on a record-enabled track (a circle in the middle of the slot).
    func recordMarkRect(row: Int, slot: Int) -> CGRect {
        let r = slotRect(row: row, slot: slot)
        let d = min(18, r.height - 6)
        return CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
    }
    func sceneRect(_ slot: Int) -> CGRect { CGRect(x: 4 + CGFloat(slot) * Self.slotWidth, y: 4, width: Self.slotWidth - 6, height: Theme.rulerHeight - 8) }

    /// The (track row, slot) under a window point, if any.
    func slot(atWindow point: CGPoint) -> (row: Int, slot: Int)? {
        let p = convert(point, from: nil)
        guard bounds.contains(p), p.y >= Theme.rulerHeight else { return nil }
        let row = session.laneIndex(atY: p.y + scrollY - Theme.rulerHeight)
        let k = Int(((p.x - 4) / Self.slotWidth).rounded(.down))
        return row >= 0 && row < session.tracks.count && k >= 0 && k < Int(session.scenes) ? (row, k) : nil
    }

    // MARK: Keyboard (Tab to the grid, arrows move between slots, Space or Return presses one, Esc stops every clip)

    private(set) var cursor = (row: 0, slot: 0)
    /// Tab reaches the grid; a click doesn't take the keyboard (Space keeps playing and stopping the transport).
    override var acceptsFirstResponder: Bool { !session.tracks.isEmpty && CommittingWindow.navigating }
    override var canBecomeKeyView: Bool { !isHiddenOrHasHiddenAncestor && bounds.width > 1 && !session.tracks.isEmpty }
    override func becomeFirstResponder() -> Bool {
        cursor = (min(cursor.row, max(0, session.tracks.count - 1)), min(cursor.slot, Int(session.scenes) - 1))
        needsDisplay = true
        return true
    }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    func ownsKey(_ event: NSEvent) -> Bool { window?.firstResponder === self && [123, 124, 125, 126, 36, 76, 49, 53].contains(event.keyCode) }
    override func keyDown(with event: NSEvent) {
        let rows = session.tracks.count, slots = Int(session.scenes)
        guard rows > 0 else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123: cursor.slot = max(0, cursor.slot - 1)
        case 124: cursor.slot = min(slots - 1, cursor.slot + 1)
        case 126: cursor.row = max(0, cursor.row - 1)
        case 125: cursor.row = min(rows - 1, cursor.row + 1)
        case 36, 76, 49: press(row: cursor.row, slot: cursor.slot, keyboard: true)
        case 53: dalnok_launcher_stop_all(session.engine.handle)
        default: return super.keyDown(with: event)
        }
        if (123...126).contains(event.keyCode) { announceCursor() }
        needsDisplay = true
    }
    /// VoiceOver reads the slot under the keyboard cursor as it moves.
    private func announceCursor() {
        guard cursor.row < session.tracks.count else { return }
        let track = session.tracks[cursor.row]
        let text = session.slotClip(track.id, Int32(cursor.slot)).map { "Slot \(cursor.slot + 1) on \(track.name): \($0.name)" }
            ?? "Slot \(cursor.slot + 1) on \(track.name), empty"
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// What a click (or Space/Return on the keyboard cursor) does to a slot.
    func press(row i: Int, slot k: Int, keyboard: Bool) {
        guard i < session.tracks.count else { return }
        let track = session.tracks[i], h = session.engine.handle
        if let clip = session.slotClip(track.id, Int32(k)) {
            let playing = dalnok_launcher_playing(h, track.id) == Int32(k) && dalnok_launcher_queued(h, track.id, nil) != -1
            dalnok_launcher_launch(h, track.id, playing ? -1 : Int32(k))
            if keyboard { onMessage?(playing ? "\(clip.name) stops on the next bar" : "\(clip.name) starts on the next bar") }
        } else if track.armed && keyboard {
            onRecordInto?(k)
        } else if let sel = selectedClip(), session.clip(sel)?.track == track.id {
            session.copyToSlot(sel, Int32(k))
            onMessage?("Copied to slot \(k + 1): \(keyboard ? "press Space" : "click it") to launch")
            animateChanges()
        } else if dalnok_launcher_playing(h, track.id) >= 0 {
            dalnok_launcher_launch(h, track.id, -1)
        } else {
            onMessage?("Select a clip on \(track.name), then \(keyboard ? "press Space on" : "click") an empty slot to put it there")
        }
        needsDisplay = true
    }

    /// Called from the window's tick: progress, queued launches and the record mark breathe.
    func tick() {
        animateChanges()
        needsDisplay = true
    }

    /// Starts Motion for what changed since the last look: a launch sweeps light across the slot as it starts,
    /// and a clip that arrives in a slot (copied, dropped or recorded) settles into it.
    func animateChanges() {
        let h = session.engine.handle
        let ids = Set(session.slotClips.map(\.id))
        if let known = knownSlotClips {
            for clip in session.slotClips where !known.contains(clip.id) {
                let id = clip.id
                arrival[id] = 0
                drivers.append(Motion.drive(self, duration: Motion.gentle, curve: .spring, { [weak self] t in
                    self?.arrival[id] = t; self?.needsDisplay = true
                }, completion: { [weak self] in self?.arrival[id] = nil; self?.needsDisplay = true }))
            }
        }
        knownSlotClips = ids
        for track in session.tracks {
            let p = dalnok_launcher_playing(h, track.id)
            defer { lastPlaying[track.id] = p }
            guard let was = lastPlaying[track.id], was != p, p >= 0 else { continue }
            let key = SlotKey(track: track.id, slot: p)
            launchSweep[key] = 0
            drivers.append(Motion.drive(self, duration: Motion.gentle * 1.5, { [weak self] t in
                self?.launchSweep[key] = t; self?.needsDisplay = true
            }, completion: { [weak self] in self?.launchSweep[key] = nil; self?.needsDisplay = true }))
        }
        drivers.removeAll { !$0.running }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.hex(Theme.palette.launcher).setFill(); bounds.fill()
        // Scene row: launch a column; the last control stops everything.
        let sceneAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9.5, .semibold), .foregroundColor: Theme.textDim]
        for k in 0..<Int(session.scenes) {
            let r = sceneRect(k)
            ctx.setFillColor(Theme.shade(0.25).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
            ("▶ \(k + 1)" as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: sceneAttrs)
        }
        Theme.separator.setFill(); CGRect(x: 0, y: Theme.rulerHeight - 1, width: bounds.width, height: 1).fill()
        if dalnok_launcher_recording(session.engine.handle) { // recording the performance: a red edge
            Theme.recordOn.setFill(); CGRect(x: 0, y: Theme.rulerHeight - 3, width: bounds.width, height: 2).fill()
        }
        let pos = session.engine.position, rate = session.engine.sampleRate
        let recordSlot = Int(dalnok_record_slot(session.engine.handle))
        if recordSlot >= 0 && recordSlot < Int(session.scenes) { // scene-row mark on the record column
            let r = sceneRect(recordSlot)
            ctx.setFillColor(Theme.recordOn.cgColor)
            ctx.fillEllipse(in: CGRect(x: r.maxX - 12, y: r.midY - 3.5, width: 7, height: 7))
        }
        var queued: [DalnokTrackId: Int32] = [:]
        for track in session.tracks { queued[track.id] = dalnok_launcher_queued(session.engine.handle, track.id, nil) }
        for (i, track) in session.tracks.enumerated() {
            let y = laneY(i)
            guard y + session.laneHeight(i) > Theme.rulerHeight, y < bounds.height else { continue }
            (i % 2 == 0 ? Theme.laneA : Theme.laneB).setFill()
            CGRect(x: 0, y: y, width: bounds.width, height: session.laneHeight(i)).fill()
            let playing = dalnok_launcher_playing(session.engine.handle, track.id)
            for k in 0..<Int(session.scenes) {
                let r = slotRect(row: i, slot: k)
                let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
                guard let clip = session.slotClip(track.id, Int32(k)) else {
                    let target = recordSlot == k && track.armed
                    ctx.setStrokeColor(target ? Theme.recordOn.withAlphaComponent(0.85).cgColor : Theme.hairline.cgColor)
                    ctx.setLineWidth(target ? 1.5 : 1)
                    ctx.addPath(path); ctx.strokePath()
                    if track.armed { // the record mark: hollow, solid where takes go, breathing while one comes in
                        let m = recordMarkRect(row: i, slot: k)
                        let live = target && session.engine.isRecording
                        let level = live ? 0.45 + 0.55 * Motion.breathe(period: 1.2) : 1
                        ctx.setStrokeColor(Theme.recordOn.withAlphaComponent(0.9).cgColor); ctx.setLineWidth(1.5)
                        ctx.strokeEllipse(in: m.insetBy(dx: 1, dy: 1))
                        if target {
                            ctx.setFillColor(Theme.recordOn.withAlphaComponent(CGFloat(level)).cgColor)
                            ctx.fillEllipse(in: m.insetBy(dx: 4, dy: 4))
                        }
                    }
                    continue
                }
                if recordSlot == k && track.armed { // will be replaced by the next take
                    ctx.setStrokeColor(Theme.recordOn.cgColor); ctx.setLineWidth(2)
                    ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -1, dy: -1), cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.strokePath()
                }
                let tint = TrackTint(base: track.color)
                let isPlaying = playing == Int32(k)
                ctx.saveGState()
                if let a = arrival[clip.id] { // settling into the slot
                    let sc = 0.6 + 0.4 * CGFloat(a)
                    ctx.translateBy(x: r.midX, y: r.midY); ctx.scaleBy(x: sc, y: sc); ctx.translateBy(x: -r.midX, y: -r.midY)
                    ctx.setAlpha(0.35 + 0.65 * CGFloat(min(1, a)))
                }
                ctx.setFillColor((isPlaying ? tint.base : tint.base.withAlphaComponent(0.45)).cgColor)
                ctx.addPath(path); ctx.fillPath()
                if let t = launchSweep[SlotKey(track: track.id, slot: Int32(k))], t < 1 { // light sweeps across as it starts
                    ctx.saveGState(); ctx.addPath(path); ctx.clip()
                    let x = r.minX + (r.width + 24) * CGFloat(t) - 24
                    ctx.setFillColor(Theme.ink(0.35 * (1 - CGFloat(t))).cgColor)
                    ctx.fill(CGRect(x: x, y: r.minY, width: 24, height: r.height))
                    ctx.restoreGState()
                }
                if queued[track.id] == Int32(k) || (queued[track.id] == -1 && isPlaying) { // waiting for its bar
                    let level = CGFloat(Motion.breathe(period: 0.5))
                    ctx.setStrokeColor(Theme.ink(0.35 + 0.55 * level).cgColor); ctx.setLineWidth(1.5)
                    ctx.setLineDash(phase: 0, lengths: [4, 3])
                    ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -2, dy: -2), cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
                if isPlaying { // loop progress along the bottom
                    let len = Double(max(1, clip.length))
                    let start = Double(dalnok_launcher_slot_start(session.engine.handle, track.id))
                    let rel = (Double(pos) - start).truncatingRemainder(dividingBy: len)
                    let f = CGFloat((rel < 0 ? rel + len : rel) / len)
                    ctx.setFillColor(Theme.ink(0.8).cgColor)
                    ctx.fill(CGRect(x: r.minX + 3, y: r.maxY - 4, width: (r.width - 6) * f, height: 2))
                }
                let fg = TrackTint.textColor(on: tint.base)
                let symbol = isPlaying ? "■" : "▶"
                if clip.follow != 0 { // follow action badge
                    ((clip.follow == 1 ? "→" : "■") + "\(clip.followLoops)" as NSString)
                        .draw(at: CGPoint(x: r.maxX - 22, y: r.minY + 4), withAttributes: [.font: Theme.mono(8.5, .bold), .foregroundColor: fg.withAlphaComponent(0.8)])
                }
                (symbol as NSString).draw(at: CGPoint(x: r.minX + 5, y: r.minY + 4),
                                          withAttributes: [.font: Theme.ui(9, .bold), .foregroundColor: fg])
                (clip.name as NSString).draw(in: CGRect(x: r.minX + 5, y: r.minY + 17, width: r.width - 10, height: 14),
                                             withAttributes: [.font: Theme.ui(10, .semibold), .foregroundColor: fg])
                (TimelineView.formatTime(Double(clip.length) / rate, step: 0.1) as NSString)
                    .draw(at: CGPoint(x: r.minX + 5, y: r.minY + 31), withAttributes: [.font: Theme.mono(8.5), .foregroundColor: fg.withAlphaComponent(0.7)])
                ctx.restoreGState()
            }
        }
        if window?.firstResponder === self, cursor.row < session.tracks.count { // the keyboard cursor
            let r = slotRect(row: cursor.row, slot: cursor.slot).insetBy(dx: -3, dy: -3)
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(2.5)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.strokePath()
        }
        Theme.separator.setFill(); CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    // MARK: Accessibility: scenes and filled slots are buttons (press launches or stops, as a click does).

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? {
        let h = session.engine.handle
        var out: [Any] = (0..<Int(session.scenes)).map { k in
            AXItem.make(in: self, rect: sceneRect(k), role: .button, label: "Launch scene \(k + 1)") { [weak self] in
                guard let self else { return false }
                return dalnok_launcher_launch_scene(self.session.engine.handle, Int32(k)) == DALNOK_OK
            }
        }
        for (i, track) in session.tracks.enumerated() {
            let playing = dalnok_launcher_playing(h, track.id)
            let queued = dalnok_launcher_queued(h, track.id, nil)
            for k in 0..<Int(session.scenes) {
                let r = slotRect(row: i, slot: k).intersection(bounds)
                guard !r.isEmpty else { continue }
                guard let clip = session.slotClip(track.id, Int32(k)) else {
                    guard track.armed else { continue }
                    let recording = session.engine.isRecording && dalnok_record_slot(h) == Int32(k)
                    out.append(AXItem.make(in: self, rect: r, role: .button,
                                           label: recording ? "Stop recording into slot \(k + 1) on \(track.name)" : "Record into slot \(k + 1) on \(track.name)",
                                           value: recording ? "recording" : "empty") { [weak self] in
                        self?.onRecordInto?(k); self?.needsDisplay = true; return true
                    })
                    continue
                }
                let id = track.id, isPlaying = playing == Int32(k)
                let state = queued == Int32(k) ? "starts on the next bar" : isPlaying && queued == -1 ? "playing, stops on the next bar" : isPlaying ? "playing" : "stopped"
                out.append(AXItem.make(in: self, rect: r, role: .button,
                                       label: "Slot \(k + 1) on \(track.name): \(clip.name)", value: state) { [weak self] in
                    guard let self else { return false }
                    dalnok_launcher_launch(self.session.engine.handle, id, isPlaying ? -1 : Int32(k))
                    self.needsDisplay = true
                    return true
                })
            }
        }
        return out
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        for (i, track) in session.tracks.enumerated() {
            for k in 0..<Int(session.scenes) where slotRect(row: i, slot: k).contains(p) {
                let m = NSMenu()
                let target = dalnok_record_slot(session.engine.handle) == Int32(k)
                let rec = NSMenuItem(title: target ? "Record Takes into the Arrangement" : "Record Takes into Slot \(k + 1)",
                                     action: #selector(recordSlotChosen(_:)), keyEquivalent: "")
                rec.target = self; rec.representedObject = target ? -1 : k
                guard let clip = session.slotClip(track.id, Int32(k)) else { m.addItem(rec); return m }
                m.addItem(rec)
                m.addItem(.separator())
                let header = NSMenuItem(title: "Follow Action", action: nil, keyEquivalent: ""); header.isEnabled = false
                m.addItem(header)
                for (title, action, loops) in [("None", 0, 1), ("Next Slot After 1 Loop", 1, 1), ("Next Slot After 2 Loops", 1, 2),
                                               ("Next Slot After 4 Loops", 1, 4), ("Stop After 1 Loop", 2, 1), ("Stop After 4 Loops", 2, 4)] {
                    let it = NSMenuItem(title: title, action: #selector(followChosen(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = [Int(clip.id), action, loops]
                    it.state = clip.follow == Int32(action) && (action == 0 || clip.followLoops == Int32(loops)) ? .on : .off
                    it.indentationLevel = 1
                    m.addItem(it)
                }
                m.addItem(.separator())
                let remove = NSMenuItem(title: "Remove Clip from Slot", action: #selector(removeChosen(_:)), keyEquivalent: "")
                remove.target = self; remove.representedObject = Int(clip.id)
                m.addItem(remove)
                return m
            }
        }
        return nil
    }
    @objc func followChosen(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? [Int], v.count == 3 else { return }
        dalnok_launcher_set_follow(session.engine.handle, DalnokClipId(v[0]), Int32(v[1]), Int32(v[2]))
        session.refresh(); needsDisplay = true
    }
    @objc func recordSlotChosen(_ sender: NSMenuItem) {
        guard let k = sender.representedObject as? Int else { return }
        dalnok_record_set_slot(session.engine.handle, Int32(k))
        onMessage?(k < 0 ? "Takes go into the arrangement" : "Takes on armed tracks go into slot \(k + 1), trimmed to whole bars")
        needsDisplay = true
    }
    @objc func removeChosen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        session.removeClip(DalnokClipId(id)); needsDisplay = true
    }

    /// The scene row's record control: logs launches and writes them into the arrangement when turned off.
    override func mouseDragged(with event: NSEvent) {
        guard dragFrom != nil else { return }
        NSCursor.closedHand.set()
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragFrom = nil; NSCursor.arrow.set() }
        guard let d = dragFrom else { return }
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { // a click, not a drag out: launch / stop
            if hypot(p.x - d.at.x, p.y - d.at.y) < 4, let clip = session.slotClips.first(where: { $0.id == d.clip }) {
                let h = session.engine.handle
                let playing = dalnok_launcher_playing(h, clip.track) == clip.slot
                dalnok_launcher_launch(h, clip.track, playing ? -1 : clip.slot)
                needsDisplay = true
            }
            return
        }
        if onDropToTimeline?(d.clip, event.locationInWindow) != true { onMessage?("Drop a launcher clip on a lane in the arrangement") }
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) } // a click hands the keyboard back
        let p = convert(event.locationInWindow, from: nil)
        let h = session.engine.handle
        if p.y < Theme.rulerHeight {
            for k in 0..<Int(session.scenes) where sceneRect(k).contains(p) {
                if dalnok_launcher_launch_scene(h, Int32(k)) != DALNOK_OK { onMessage?("Scene \(k + 1) is empty") }
                needsDisplay = true
                return
            }
            return
        }
        for (i, track) in session.tracks.enumerated() {
            for k in 0..<Int(session.scenes) where slotRect(row: i, slot: k).contains(p) {
                if let clip = session.slotClip(track.id, Int32(k)) {
                    // Launch (or stop) on mouse-up, unless the clip is dragged out onto the timeline.
                    dragFrom = (clip.id, p)
                    return
                } else if track.armed && recordMarkRect(row: i, slot: k).insetBy(dx: -4, dy: -4).contains(p) {
                    onRecordInto?(k)
                } else {
                    press(row: i, slot: k, keyboard: false) // copy the selection here, or stop a playing track
                }
                cursor = (i, k)
                needsDisplay = true
                return
            }
        }
    }
}
