// Phase invert (API 46): the source flips before the inserts; sends carry it; undo, save and the catalog.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct PhaseInvert {
    private func info(_ e: OpaquePointer, _ t: DalnokTrackId) -> DalnokTrackInfo {
        var i = DalnokTrackInfo(); _ = dalnok_track_info(e, t, &i); return i
    }

    @Test func invertsTheTrackAndItsSendsInOneUndoStep() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Audio")
        let src = ramp(4_800)
        let m = makeMedia([src]); defer { dalnok_media_release(m) }
        _ = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, m, ""), 0, 0, 0)
        let (l0, r0) = render(e, frames: 4_800)
        #expect(!info(e, t).phase_invert)
        #expect(dalnok_track_set_phase_invert(e, t, true) == DALNOK_OK && info(e, t).phase_invert)
        #expect(undoName(e).contains("Invert Phase"))
        let (l1, r1) = render(e, frames: 4_800)
        expectClose(l1, l0.map { -$0 }, tol: 1e-6, "left is the exact negative")
        expectClose(r1, r0.map { -$0 }, tol: 1e-6, "right is the exact negative")
        #expect(dalnok_track_set_phase_invert(e, t, true) != DALNOK_OK, "no step when nothing changes")

        // A pre-fader send at 0 dB doubles the track on the master; inverted, both paths flip together.
        let bus = dalnok_track_add_bus(e, "Bus")
        #expect(dalnok_track_set_send(e, t, bus, 0, true) == DALNOK_OK)
        let (ls, _) = render(e, frames: 4_800)
        expectClose(ls, l0.map { -2 * $0 }, tol: 1e-5, "the send carries the inverted signal")
        #expect(dalnok_track_remove_send(e, t, bus) == DALNOK_OK)

        #expect(dalnok_undo(e) && dalnok_undo(e) && dalnok_undo(e) && dalnok_undo(e)) // remove send, send, bus, invert
        #expect(!info(e, t).phase_invert)
        expectClose(render(e, frames: 4_800).0, l0, tol: 1e-6, "undo restores the original polarity")
        #expect(dalnok_redo(e) && info(e, t).phase_invert)
    }

    @Test func savesAndRunsFromTheCatalog() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Audio")
        #expect(runCommand(e, "track.setPhaseInvert", "{\"track\":\(t),\"on\":true}").0 == DALNOK_OK)
        let path = tempDir().appendingPathComponent("phase.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, path.path, &err, err.count) == DALNOK_OK)
        let doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(doc["version"] as? Int == 14)
        #expect(((doc["tracks"] as? [[String: Any]])?.first?["phaseInvert"] as? Bool) == true)
        let back = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(back) }
        #expect(dalnok_project_load(back, path.path, nil, &err, err.count) == DALNOK_OK)
        #expect(info(back, dalnok_track_at(back, 0)).phase_invert)
        #expect(runCommand(back, "track.setPhaseInvert", "{\"track\":\(dalnok_track_at(back, 0)),\"on\":false}").0 == DALNOK_OK)
        #expect(!info(back, dalnok_track_at(back, 0)).phase_invert)
    }
}
