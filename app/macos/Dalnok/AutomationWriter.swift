// Automation writing (Track ▸ Automation Mode): in Touch, moving a track's volume or pan while the transport
// plays writes those moves into its lane until you let go; in Latch, it keeps writing the last value until the
// transport stops. While writing, the engine plays the control instead of the lane (dalnok_track_automation_hold).
// Each written range replaces the lane's points in that range as one undo step ("Write Automation").
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class AutomationWriter {
    enum Mode: Int { case read = 0, touch = 1, latch = 2 }
    static weak var shared: AutomationWriter?
    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.integer(forKey: "automationMode")) ?? .read }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "automationMode") }
    }
    let session: Session
    private struct Pass { var points: [DalnokAutoPoint] = []; var released = false }
    private var passes: [String: Pass] = [:]
    var onWritten: ((String) -> Void)?
    var isWriting: Bool { !passes.isEmpty }

    init(session: Session) { self.session = session; Self.shared = self }

    private func key(_ t: DalnokTrackId, _ target: Int32) -> String { "\(t):\(target)" }

    /// A control was grabbed (begin) or let go (end).
    func touch(_ track: DalnokTrackId, _ target: Int32, _ begin: Bool) {
        guard Self.mode != .read, session.engine.isPlaying else { return }
        let k = key(track, target)
        if begin {
            dalnok_track_automation_hold(session.engine.handle, track, target, true)
            if passes[k] == nil { passes[k] = Pass() }
            passes[k]?.released = false
            sample(track, target)
        } else if Self.mode == .touch {
            commit(k)
        } else {
            passes[k]?.released = true // latch: keep writing until the transport stops
        }
    }

    /// Called every UI tick: records the current values; commits everything when the transport stops.
    func tick() {
        guard !passes.isEmpty else { return }
        guard session.engine.isPlaying else { commitAll(); return }
        for k in passes.keys {
            let parts = k.split(separator: ":").compactMap { Int32($0) }
            if parts.count == 2 { sample(DalnokTrackId(parts[0]), parts[1]) }
        }
    }

    private func sample(_ track: DalnokTrackId, _ target: Int32) {
        guard let t = session.track(track) else { return }
        let k = key(track, target), frame = session.engine.position
        let value = target == 1 ? t.pan : max(-200, t.gainDb.isFinite ? t.gainDb : -200)
        guard var p = passes[k] else { return }
        if let last = p.points.last {
            if frame < last.frame { commit(k); passes[k] = Pass(); p = Pass() } // the playhead jumped back (cycle): start a new pass
            else if abs(last.value - value) < 0.01 && frame - last.frame < Int64(session.engine.sampleRate / 10) { return } // thin
        }
        p.points.append(DalnokAutoPoint(frame: frame, value: value))
        passes[k] = p
    }

    func commitAll() { for k in Array(passes.keys) { commit(k) } }

    private func commit(_ k: String) {
        guard let pass = passes.removeValue(forKey: k) else { return }
        let parts = k.split(separator: ":").compactMap { Int32($0) }
        guard parts.count == 2, let t = session.track(DalnokTrackId(parts[0])) else { return }
        let target = parts[1]
        dalnok_track_automation_hold(session.engine.handle, t.id, target, false)
        guard let first = pass.points.first, let last = pass.points.last else { return }
        // Replace the lane inside the written range; keep it elsewhere.
        var merged = t.automation(target).filter { $0.frame < first.frame || $0.frame > last.frame }
        merged += pass.points
        merged.sort { $0.frame < $1.frame }
        session.engine.beginGroup("Write Automation")
        session.setAutomation(t.id, target, merged)
        session.engine.endGroup()
        onWritten?("Wrote \(target == 1 ? "pan" : "volume") automation on \(t.name) (\(pass.points.count) points)")
    }
}
