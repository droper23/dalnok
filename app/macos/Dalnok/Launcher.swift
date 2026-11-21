// Clip launcher (View ▸ Clip Launcher): a grid of slots on the same rows as the track lanes, between the
// headers and the timeline (one track model: each track has a timeline lane and launcher slots).
// Click a clip to launch it (it starts on the next bar and loops); click an empty slot on a playing track to
// stop it; with a clip selected on a track, click one of its empty slots to put a copy there. The top row
// launches scenes (whole columns) and stops everything.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class LauncherView: NSView, TrackScrollHost {
    var onScroll: ((NSEvent) -> Void)?
    func scrollTracks(with event: NSEvent) { onScroll?(event) }
    override func scrollWheel(with event: NSEvent) { scrollTracks(with: event) }
    static let slotWidth: CGFloat = 70
    let session: Session
    var scrollY: CGFloat = 0 { didSet { needsDisplay = true } }
    /// The selected timeline clip (copied into an empty slot on its track when clicked).
    var selectedClip: () -> DalnokClipId? = { nil }
    var onMessage: ((String) -> Void)?
    private var blink = false

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
    func sceneRect(_ slot: Int) -> CGRect { CGRect(x: 4 + CGFloat(slot) * Self.slotWidth, y: 4, width: Self.slotWidth - 6, height: Theme.rulerHeight - 8) }

    /// The (track row, slot) under a window point, if any.
    func slot(atWindow point: CGPoint) -> (row: Int, slot: Int)? {
        let p = convert(point, from: nil)
        guard bounds.contains(p), p.y >= Theme.rulerHeight else { return nil }
        let row = session.laneIndex(atY: p.y + scrollY - Theme.rulerHeight)
        let k = Int(((p.x - 4) / Self.slotWidth).rounded(.down))
        return row >= 0 && row < session.tracks.count && k >= 0 && k < Int(session.scenes) ? (row, k) : nil
    }

    /// Called from the window's tick: progress and queued blinking.
    func tick() {
        blink.toggle()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        Theme.hex(Theme.palette.launcher).setFill(); bounds.fill()
        // Scene row: launch a column; the last control stops everything.
        let sceneAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9.5, .semibold), .foregroundColor: Theme.textDim]
        for k in 0..<Int(session.scenes) {
            let r = sceneRect(k)
            ctx.setFillColor(Theme.hex(0x000000, 0.25).cgColor)
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
                    if recordSlot == k && track.armed { // the take lands here: a red ring and dot
                        ctx.setStrokeColor(Theme.recordOn.withAlphaComponent(0.85).cgColor); ctx.setLineWidth(1.5)
                        ctx.addPath(path); ctx.strokePath()
                        ctx.setFillColor(Theme.recordOn.cgColor)
                        ctx.fillEllipse(in: CGRect(x: r.midX - 4, y: r.midY - 4, width: 8, height: 8))
                    } else {
                        ctx.setStrokeColor(Theme.hairline.cgColor); ctx.setLineWidth(1)
                        ctx.addPath(path); ctx.strokePath()
                    }
                    continue
                }
                if recordSlot == k && track.armed { // will be replaced by the next take
                    ctx.setStrokeColor(Theme.recordOn.cgColor); ctx.setLineWidth(2)
                    ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -1, dy: -1), cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.strokePath()
                }
                let tint = TrackTint(base: track.color)
                let isPlaying = playing == Int32(k)
                ctx.setFillColor((isPlaying ? tint.base : tint.base.withAlphaComponent(0.45)).cgColor)
                ctx.addPath(path); ctx.fillPath()
                if isPlaying { // loop progress along the bottom
                    let len = Double(max(1, clip.length))
                    let start = Double(dalnok_launcher_slot_start(session.engine.handle, track.id))
                    let rel = (Double(pos) - start).truncatingRemainder(dividingBy: len)
                    let f = CGFloat((rel < 0 ? rel + len : rel) / len)
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
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
            }
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
            for k in 0..<Int(session.scenes) {
                guard let clip = session.slotClip(track.id, Int32(k)) else { continue }
                let r = slotRect(row: i, slot: k).intersection(bounds)
                guard !r.isEmpty else { continue }
                let id = track.id, isPlaying = playing == Int32(k)
                out.append(AXItem.make(in: self, rect: r, role: .button,
                                       label: "Slot \(k + 1) on \(track.name): \(clip.name)", value: isPlaying ? "playing" : "stopped") { [weak self] in
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
                } else if let sel = selectedClip(), session.clip(sel)?.track == track.id {
                    session.copyToSlot(sel, Int32(k))
                    onMessage?("Copied to slot \(k + 1): click it to launch")
                } else if dalnok_launcher_playing(h, track.id) >= 0 {
                    dalnok_launcher_launch(h, track.id, -1) // empty slot on a playing track: stop
                } else {
                    onMessage?("Select a clip on \(track.name), then click an empty slot to put it there")
                }
                needsDisplay = true
                return
            }
        }
    }
}
