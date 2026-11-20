// A-03: snapshot undo steps below the top are stored as clip deltas against the state they will be applied to.
// Random structural, clip, parameter and grouped edits, with undo and redo walks and a branch, must reproduce every
// recorded state exactly (compared as serialized projects).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct UndoDeltas {
    func snapshot(_ e: OpaquePointer) -> NSDictionary {
        let url = tempDir().appendingPathComponent("undo-\(UUID().uuidString).dalnok")
        #expect(dalnok_project_save_snapshot(e, url.path, nil, 0) == DALNOK_OK)
        let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        try? FileManager.default.removeItem(at: url)
        return NSDictionary(dictionary: json)
    }

    @Test(arguments: [UInt64(0x51), 0xA03, 0xBEEF])
    func randomHistoryReproducesEveryState(seed start: UInt64) throws {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(200_000)]); defer { dalnok_media_release(m) }
        var tracks = [dalnok_track_add(e, "A"), dalnok_track_add(e, "B")]
        var clips: [DalnokClipId] = []
        for t in tracks { for k in 0..<8 { clips.append(dalnok_clip_add(e, t, m, Int64(k) * 20_000, 0, 10_000)) } }
        var seed = start
        var lastOp: UInt64 = 0
        var undoNames: [String] = []
        func cstrUndo(_ e: OpaquePointer) -> String { undoName(e) }
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
        func live() -> [DalnokClipId] { clips.filter { var i = DalnokClipInfo(); return dalnok_clip_info(e, $0, &i) == DALNOK_OK } }
        /// One random undoable edit; false if it was refused (no undo step).
        func randomEdit(_ i: Int) -> Bool {
            let alive = live()
            guard let c = alive.isEmpty ? nil : alive[Int(next()) % alive.count] else { return dalnok_track_add(e, "T\(i)") != 0 }
            let op = next() % 11
            lastOp = op
            switch op {
            case 0: return dalnok_clips_nudge(e, [c], 1, Int64(next() % 2000) - 1000) == DALNOK_OK
            case 1: return dalnok_clip_move(e, c, tracks[Int(next()) % tracks.count], Int64(next() % 300_000)) == DALNOK_OK
            case 2:
                var info = DalnokClipInfo(); _ = dalnok_clip_info(e, c, &info)
                var right: DalnokClipId = 0
                guard info.length > 4 else { return false }
                let ok = dalnok_clip_split(e, c, info.start + 1 + Int64(next() % UInt64(info.length - 2)), &right) == DALNOK_OK
                if ok { clips.append(right) }
                return ok
            case 3: return dalnok_clip_remove(e, c) == DALNOK_OK
            case 4: let n = dalnok_clip_add(e, tracks[Int(next()) % tracks.count], m, Int64(next() % 300_000), 0, 5_000); clips.append(n); return n != 0
            case 5: return dalnok_clip_set_gain_db(e, c, Float(Int(next() % 24)) - 12) == DALNOK_OK
            case 6: return dalnok_track_set_gain_db(e, tracks[0], Float(Int(next() % 40)) - 30) == DALNOK_OK
            case 7: let t = dalnok_track_add(e, "T\(i)"); tracks.append(t); return t != 0
            case 8:
                dalnok_undo_begin_group(e, "Group \(i)")
                _ = dalnok_track_set_pan(e, tracks[0], Float(Int(next() % 200) - 100) / 100)
                _ = dalnok_clips_nudge(e, [c], 1, 480)
                _ = dalnok_clip_set_muted(e, c, next() & 1 == 0)
                dalnok_undo_end_group(e)
                return true
            case 9: return dalnok_track_rename(e, tracks[Int(next()) % tracks.count], "R\(i)") == DALNOK_OK
            default:
                let n = dalnok_clips_copy(e, Array(alive.prefix(3)), Int32(min(3, alive.count)), Int64(next() % 200_000), 0, nil, 0)
                return n > 0
            }
        }
        var states = [snapshot(e)], ops: [UInt64] = [99]
        var i = 0
        // An accepted edit that changes nothing (a nudge clamped at zero) records no step: count only revision changes.
        func recorded(_ i: Int) -> Bool { let r = dalnok_model_revision(e); return randomEdit(i) && dalnok_model_revision(e) != r }
        while states.count < 121 { i += 1; if recorded(i) { states.append(snapshot(e)); ops.append(lastOp); undoNames.append(cstrUndo(e)) } }
        // Undo all the way, then redo all the way: every state comes back exactly.
        for k in stride(from: 119, through: 0, by: -1) {
            #expect(dalnok_undo(e))
            #expect(snapshot(e).isEqual(to: states[k] as! [AnyHashable: Any]), "undo to state \(k) (seed \(start)) after undoing op \(ops[k + 1]) '\(undoNames[k])'")
        }
        for k in 1...120 {
            #expect(dalnok_redo(e))
            #expect(snapshot(e).isEqual(to: states[k] as! [AnyHashable: Any]), "redo to state \(k) (seed \(start))")
        }
        // Undo 40, branch with 15 new edits, then undo everything back to the start.
        for _ in 0..<40 { #expect(dalnok_undo(e)) }
        var branch = Array(states.prefix(81))
        while branch.count < 96 { i += 1; if recorded(i) { branch.append(snapshot(e)) } }
        #expect(!dalnok_redo(e), "a new edit clears redo")
        for k in stride(from: 94, through: 0, by: -1) {
            #expect(dalnok_undo(e))
            #expect(snapshot(e).isEqual(to: branch[k] as! [AnyHashable: Any]), "undo through the branch to state \(k) (seed \(start))")
        }
    }
}
