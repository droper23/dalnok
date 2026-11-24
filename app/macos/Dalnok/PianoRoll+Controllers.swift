// The piano roll's lower lane can show a MIDI controller instead of velocity (Logic's MIDI Draw, Ableton's envelope
// lane): mod wheel, volume, pan, expression, sustain or pitch bend, drawn as a stepped line. Click to set a value at a
// grid position, drag to draw across the grid, ⌥-click to delete the nearest point; ⌃ ignores the grid.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

extension PianoRollView {
    /// Lanes offered by the lane menu: (title, controller; -1 = velocity, 128 = pitch bend).
    static let controllerLanes: [(String, Int)] = [("Velocity", -1), ("Mod Wheel (CC 1)", 1), ("Breath (CC 2)", 2), ("Volume (CC 7)", 7),
                                                    ("Pan (CC 10)", 10), ("Expression (CC 11)", 11), ("Sustain (CC 64)", 64),
                                                    ("Pitch Bend", Int(DALNOK_PITCH_BEND))]
    var laneTitle: String {
        laneController < 0 ? "VELOCITY" : (Self.controllerLanes.first { $0.1 == laneController }?.0 ?? "CC \(laneController)").uppercased()
    }
    var laneMax: Int32 { laneController == Int(DALNOK_PITCH_BEND) ? 16_383 : 127 }

    func controllerEvents() -> [DalnokMidiCC] {
        guard let id = clip?.id else { return [] }
        let n = Int(dalnok_midi_clip_controllers(session.engine.handle, id, nil, 0))
        var out = [DalnokMidiCC](repeating: DalnokMidiCC(), count: n)
        if n > 0 { _ = dalnok_midi_clip_controllers(session.engine.handle, id, &out, Int32(n)) }
        return out
    }
    func setControllerEvents(_ events: [DalnokMidiCC]) {
        guard let id = clip?.id else { return }
        var list = events
        _ = dalnok_midi_clip_set_controllers(session.engine.handle, id, &list, Int32(list.count))
        session.refresh()
        needsDisplay = true
    }

    /// The lane's title is a menu of lanes.
    func showLaneMenu(at p: CGPoint) {
        let menu = NSMenu(title: "Lane")
        for (title, cc) in Self.controllerLanes {
            let it = NSMenuItem(title: title, action: #selector(chooseLane(_:)), keyEquivalent: "")
            it.tag = cc
            it.target = self
            it.state = cc == laneController ? .on : .off
            menu.addItem(it)
        }
        menu.popUp(positioning: nil, at: p, in: self)
    }
    @objc func chooseLane(_ sender: NSMenuItem) { laneController = sender.tag; needsDisplay = true; updateSubtitle() }

    func laneY(_ value: Int32) -> CGFloat {
        let lane = velocityLane
        return lane.maxY - 4 - (lane.height - 12) * CGFloat(value) / CGFloat(laneMax)
    }
    func laneValue(atY y: CGFloat) -> Int32 {
        let lane = velocityLane
        let v = (lane.maxY - 4 - y) / max(1, lane.height - 12) * CGFloat(laneMax)
        return Int32(min(max(0, v.rounded()), CGFloat(laneMax)))
    }

    func drawControllerLane(_ ctx: CGContext, _ c: ClipView, _ tint: TrackTint) {
        let lane = velocityLane
        let mine = controllerEvents().filter { Int($0.controller) == laneController && $0.start >= c.offset && $0.start < c.offset + c.length }
        ctx.saveGState()
        ctx.clip(to: lane)
        if laneController == Int(DALNOK_PITCH_BEND) { // the centre line
            Theme.separator.setFill(); CGRect(x: lane.minX, y: laneY(8_192).rounded(), width: lane.width, height: 1).fill()
        }
        // A stepped line: each value holds until the next point.
        let color = tint.waveform
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(1.5)
        var last: CGPoint?
        for e in mine {
            let px = x(Double(c.start + e.start - c.offset)), py = laneY(e.value)
            if let l = last { ctx.move(to: l); ctx.addLine(to: CGPoint(x: px, y: l.y)); ctx.addLine(to: CGPoint(x: px, y: py)) }
            last = CGPoint(x: px, y: py)
        }
        if let l = last { ctx.move(to: l); ctx.addLine(to: CGPoint(x: x(Double(c.start + c.length)), y: l.y)) }
        ctx.strokePath()
        ctx.setFillColor(color.cgColor)
        for e in mine { ctx.fillEllipse(in: CGRect(x: x(Double(c.start + e.start - c.offset)) - 2.5, y: laneY(e.value) - 2.5, width: 5, height: 5)) }
        ctx.restoreGState()
    }

    /// Sets the value at the snapped position under `p` (replacing a point already there). Returns false outside the clip.
    @discardableResult
    func drawController(at p: CGPoint, bypass: Bool) -> Bool {
        guard let c = clip else { return false }
        let t = bypass ? frame(atX: p.x).rounded() : snap(frame(atX: p.x), bypass: false)
        let start = Int64(t) - c.start + c.offset
        guard start >= c.offset, start < c.offset + c.length else { return false }
        var events = controllerEvents().filter { !(Int($0.controller) == laneController && $0.start == start) }
        events.append(DalnokMidiCC(start: start, controller: Int32(laneController), value: laneValue(atY: p.y)))
        setControllerEvents(events)
        return true
    }
    func deleteController(near p: CGPoint) {
        guard let c = clip else { return }
        let events = controllerEvents()
        let mine = events.enumerated().filter { Int($0.element.controller) == laneController }
        guard let nearest = mine.min(by: { abs(x(Double(c.start + $0.element.start - c.offset)) - p.x) < abs(x(Double(c.start + $1.element.start - c.offset)) - p.x) }),
              abs(x(Double(c.start + nearest.element.start - c.offset)) - p.x) <= 8 else { return }
        var rest = events
        rest.remove(at: nearest.offset)
        setControllerEvents(rest)
    }
}
