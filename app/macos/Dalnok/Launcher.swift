// Clip launcher (View ▸ Clip Launcher): a grid of slots on the same rows as the track lanes, between the
// headers and the timeline (one track model: each track has a timeline lane and launcher slots).
// Click a clip to launch it (it starts on the next bar and loops); click an empty slot on a playing track to
// stop it; with a clip selected on a track, click one of its empty slots to put a copy there. The top row
// launches scenes (whole columns) and stops everything.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class LauncherView: NSView {
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

    func laneY(_ i: Int) -> CGFloat { Theme.rulerHeight + CGFloat(i) * Theme.trackHeight - scrollY }
    func slotRect(row: Int, slot: Int) -> CGRect {
        CGRect(x: 4 + CGFloat(slot) * Self.slotWidth, y: laneY(row) + 6, width: Self.slotWidth - 6, height: Theme.trackHeight - 12)
    }
    func sceneRect(_ slot: Int) -> CGRect { CGRect(x: 4 + CGFloat(slot) * Self.slotWidth, y: 4, width: Self.slotWidth - 6, height: Theme.rulerHeight - 8) }

    /// Called from the window's tick: progress and queued blinking.
    func tick() {
        blink.toggle()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        (Analog.on ? Theme.hex(0x15100C) : Theme.panel).setFill(); bounds.fill()
        // Scene row: launch a column; the last control stops everything.
        let sceneAttrs: [NSAttributedString.Key: Any] = [.font: Theme.mono(9.5, .semibold), .foregroundColor: Theme.textDim]
        for k in 0..<Int(session.scenes) {
            let r = sceneRect(k)
            ctx.setFillColor(Theme.hex(0x000000, 0.25).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
            ("▶ \(k + 1)" as NSString).draw(at: CGPoint(x: r.minX + 6, y: r.minY + 3), withAttributes: sceneAttrs)
        }
        Theme.separator.setFill(); CGRect(x: 0, y: Theme.rulerHeight - 1, width: bounds.width, height: 1).fill()
        let pos = session.engine.position, rate = session.engine.sampleRate
        for (i, track) in session.tracks.enumerated() {
            let y = laneY(i)
            guard y + Theme.trackHeight > Theme.rulerHeight, y < bounds.height else { continue }
            (i % 2 == 0 ? Theme.laneA : Theme.laneB).setFill()
            CGRect(x: 0, y: y, width: bounds.width, height: Theme.trackHeight).fill()
            let playing = dalnok_launcher_playing(session.engine.handle, track.id)
            for k in 0..<Int(session.scenes) {
                let r = slotRect(row: i, slot: k)
                let path = CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil)
                guard let clip = session.slotClip(track.id, Int32(k)) else {
                    ctx.setStrokeColor(Theme.hairline.cgColor); ctx.setLineWidth(1)
                    ctx.addPath(path); ctx.strokePath()
                    continue
                }
                let tint = TrackTint(base: track.color)
                let isPlaying = playing == Int32(k)
                ctx.setFillColor((isPlaying ? tint.base : tint.base.withAlphaComponent(0.45)).cgColor)
                ctx.addPath(path); ctx.fillPath()
                if isPlaying { // loop progress along the bottom
                    let len = Double(max(1, clip.length))
                    let f = CGFloat(Double(pos).truncatingRemainder(dividingBy: len) / len)
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
                    ctx.fill(CGRect(x: r.minX + 3, y: r.maxY - 4, width: (r.width - 6) * f, height: 2))
                }
                let fg = TrackTint.textColor(on: tint.base)
                let symbol = isPlaying ? "■" : "▶"
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
                if session.slotClip(track.id, Int32(k)) != nil {
                    // A playing slot clicked again goes back to the arrangement.
                    let playing = dalnok_launcher_playing(h, track.id) == Int32(k)
                    dalnok_launcher_launch(h, track.id, playing ? -1 : Int32(k))
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
