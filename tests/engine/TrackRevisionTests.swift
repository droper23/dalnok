// Per-track revisions (A-05): an edit stamps only the tracks it changed, so a view re-reads only those.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct TrackRevisions {
    /// Everything the app reads for one track, as text (so "unchanged" can be compared exactly).
    func viewOf(_ e: OpaquePointer, _ t: DalnokTrackId) -> String {
        var ti = DalnokTrackInfo()
        guard dalnok_track_info(e, t, &ti) == DALNOK_OK else { return "gone" }
        var out = "\(name(ti.name)) \(ti.gain_db) \(ti.pan) \(ti.muted) \(ti.solo) \(ti.kind) \(ti.clip_count) \(ti.height) \(dalnok_track_output(e, t))"
        for k in 0..<ti.clip_count {
            var ci = DalnokClipInfo()
            _ = dalnok_clip_info(e, dalnok_track_clip_at(e, t, k), &ci)
            out += " | \(ci.id) \(ci.start) \(ci.offset) \(ci.length) \(ci.fade_in) \(ci.fade_out) \(ci.gain_db) \(dalnok_clip_muted(e, ci.id))"
        }
        for k in 0..<dalnok_track_plugin_count(e, t) {
            var pi = DalnokPluginSlotInfo()
            _ = dalnok_track_plugin_info(e, t, k, &pi)
            out += " # \(pi.id) \(pi.loaded) \(dalnok_plugin_bypassed(e, t, pi.id))"
        }
        return out
    }

    @Test func editsStampOnlyTheTracksTheyChange() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(20_000)]); defer { dalnok_media_release(m) }
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B")
        let ca = dalnok_clip_add(e, a, m, 0, 0, 5_000)
        _ = dalnok_clip_add(e, b, m, 0, 0, 5_000)
        let before = dalnok_model_revision(e), rb = dalnok_track_revision(e, b)
        var ids = [ca]
        #expect(dalnok_clips_nudge(e, &ids, 1, 100) == DALNOK_OK)
        #expect(dalnok_track_revision(e, a) == dalnok_model_revision(e) && dalnok_model_revision(e) > before)
        #expect(dalnok_track_revision(e, b) == rb, "an unrelated track keeps its revision")
        #expect(dalnok_undo(e))
        #expect(dalnok_track_revision(e, a) == dalnok_model_revision(e) && dalnok_track_revision(e, b) == rb)
        #expect(dalnok_track_set_gain_db(e, b, -6) == DALNOK_OK)
        let ra = dalnok_track_revision(e, a)
        #expect(dalnok_track_revision(e, b) == dalnok_model_revision(e) && ra < dalnok_model_revision(e))
        #expect(dalnok_undo(e) && dalnok_track_revision(e, b) == dalnok_model_revision(e) && dalnok_track_revision(e, a) == ra)
        // A failed edit stamps nothing; moving a clip between tracks stamps both.
        #expect(dalnok_clip_move(e, ca, 9_999, 0) != DALNOK_OK && dalnok_track_revision(e, a) == ra)
        #expect(dalnok_clip_move(e, ca, b, 7_000) == DALNOK_OK)
        #expect(dalnok_track_revision(e, a) == dalnok_model_revision(e) && dalnok_track_revision(e, b) == dalnok_model_revision(e))
        // Master gain is not a track.
        let r2 = dalnok_track_revision(e, a)
        #expect(dalnok_master_set_gain_db(e, -3) == DALNOK_OK && dalnok_track_revision(e, a) == r2)
    }

    /// Tracks that came from a project load were never stamped by an edit; they must still keep their revision
    /// when another track is edited (the first version reported every loaded track as changed).
    @Test func loadedTracksKeepTheirRevisionWhenAnotherTrackChanges() throws {
        let dir = tempDir()
        let wav = dir.appendingPathComponent("a.wav")
        _ = try writeTestWav(wav, frames: 4_000)
        let src = dalnok_engine_create(sr)!
        var m: OpaquePointer?
        #expect(dalnok_media_load(wav.path, sr, &m, nil, 0) == DALNOK_OK)
        let pool = dalnok_pool_add(src, m, wav.path); dalnok_media_release(m)
        for i in 0..<3 { _ = DalnokEngine.dalnok_clip_add(src, dalnok_track_add(src, "T\(i)"), pool, 0, 0, 1_000) }
        let path = dir.appendingPathComponent("p.dalnok").path
        #expect(dalnok_project_save(src, path, nil, 0) == DALNOK_OK)
        dalnok_engine_destroy(src)
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        #expect(dalnok_project_load(e, path, nil, nil, 0) == DALNOK_OK)
        let ids = (0..<dalnok_track_count(e)).map { dalnok_track_at(e, $0) }
        let loaded = ids.map { dalnok_track_revision(e, $0) }
        #expect(loaded.allSatisfy { $0 <= dalnok_model_revision(e) })
        var clip = [dalnok_track_clip_at(e, ids[0], 0)]
        #expect(dalnok_clips_nudge(e, &clip, 1, 100) == DALNOK_OK)
        #expect(dalnok_track_revision(e, ids[0]) == dalnok_model_revision(e))
        #expect(dalnok_track_revision(e, ids[1]) == loaded[1] && dalnok_track_revision(e, ids[2]) == loaded[2])
    }

    /// The property the UI relies on: if a track's revision did not move, everything it reads for that track is
    /// unchanged. Random structural edits, parameter edits, plug-in changes, undo and redo.
    @Test(arguments: [11, 12, 13] as [UInt64])
    func unchangedRevisionMeansUnchangedView(seed: UInt64) {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(40_000)]); defer { dalnok_media_release(m) }
        var tracks = (0..<4).map { dalnok_track_add(e, "T\($0)") }
        let bus = dalnok_track_add_bus(e, "Bus"); tracks.append(bus)
        var clips: [DalnokClipId] = []
        for t in tracks.dropLast() { for k in 0..<3 { clips.append(dalnok_clip_add(e, t, m, Int64(k) * 8_000, 0, 5_000)) } }
        var rng = SeededRandom(state: seed)
        var views = Dictionary(uniqueKeysWithValues: tracks.map { ($0, (dalnok_track_revision(e, $0), viewOf(e, $0))) })
        for step in 0..<400 {
            let c = clips[Int.random(in: 0..<clips.count, using: &rng)]
            let t = tracks[Int.random(in: 0..<tracks.count, using: &rng)]
            switch Int.random(in: 0..<12, using: &rng) {
            case 0: var ids = [c]; _ = dalnok_clips_nudge(e, &ids, 1, Int64.random(in: -2_000...2_000, using: &rng))
            case 1: _ = dalnok_clip_move(e, c, tracks[Int.random(in: 0..<4, using: &rng)], Int64.random(in: 0...50_000, using: &rng))
            case 2:
                var right: DalnokClipId = 0
                let info = clipInfo(e, c)
                if info.length > 2, dalnok_clip_split(e, c, info.start + info.length / 2, &right) == DALNOK_OK { clips.append(right) }
            case 3: _ = dalnok_clip_set_muted(e, c, Bool.random(using: &rng))
            case 4: _ = dalnok_clip_set_gain_db(e, c, Float.random(in: -12...6, using: &rng))
            case 5: _ = dalnok_track_set_gain_db(e, t, Float.random(in: -30...6, using: &rng))
            case 6: _ = dalnok_track_set_mute(e, t, Bool.random(using: &rng))
            case 7: _ = dalnok_track_set_output(e, tracks[Int.random(in: 0..<4, using: &rng)], Bool.random(using: &rng) ? bus : 0)
            case 8: _ = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
            case 9: _ = dalnok_undo(e)
            case 10: _ = dalnok_redo(e)
            default: _ = dalnok_track_rename(e, t, "R\(step)")
            }
            for id in tracks {
                let r = dalnok_track_revision(e, id), v = viewOf(e, id)
                if let (oldR, oldV) = views[id], r == oldR {
                    #expect(v == oldV, "seed \(seed) step \(step): track \(id) changed without a new revision")
                    if v != oldV { return }
                }
                views[id] = (r, v)
            }
        }
    }
}
