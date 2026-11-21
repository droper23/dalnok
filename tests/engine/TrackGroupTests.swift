// Track groups: linked volume (relative), pan, mute, solo, record enable and Input Monitoring; one undo step; clutch.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct TrackGroups {
    func info(_ e: OpaquePointer, _ t: DalnokTrackId) -> DalnokTrackInfo { var i = DalnokTrackInfo(); _ = dalnok_track_info(e, t, &i); return i }

    @Test func linkedSettingsFollowAndUndoTogether() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let kick = dalnok_track_add(e, "Kick"), snare = dalnok_track_add(e, "Snare"), bass = dalnok_track_add(e, "Bass")
        let keys = dalnok_track_add_instrument(e, "Keys")
        _ = dalnok_track_set_gain_db(e, snare, -6)
        let members = [kick, snare, keys]
        let g = dalnok_group_create(e, "Drums", members, 3)
        #expect(g > 0 && info(e, kick).group == g && info(e, snare).group == g && info(e, bass).group == 0)
        var gi = [DalnokGroupInfo](repeating: DalnokGroupInfo(), count: 4)
        #expect(dalnok_groups(e, &gi, 4) == 1 && name(gi[0].name) == "Drums" && gi[0].members == 3 && gi[0].volume && !gi[0].pan)

        // Volume: relative, one undo step.
        #expect(dalnok_track_set_gain_db(e, kick, -3) == DALNOK_OK)
        #expect(info(e, kick).gain_db == -3 && info(e, snare).gain_db == -9 && info(e, keys).gain_db == -3 && info(e, bass).gain_db == 0)
        #expect(dalnok_undo(e) && info(e, kick).gain_db == 0 && info(e, snare).gain_db == -6, "one undo restores every member")
        // Mute and solo copy.
        #expect(dalnok_track_set_mute(e, snare, true) == DALNOK_OK)
        #expect(info(e, kick).muted && info(e, keys).muted && !info(e, bass).muted)
        _ = dalnok_track_set_mute(e, snare, false)
        _ = dalnok_track_set_solo(e, kick, true)
        #expect(info(e, snare).solo && !info(e, bass).solo)
        _ = dalnok_track_set_solo(e, kick, false)
        // Record enable: audio members follow; the instrument track (one takes MIDI at a time) does not.
        _ = dalnok_track_set_armed(e, keys, false) // a new instrument track starts armed
        #expect(dalnok_track_set_armed(e, kick, true) == DALNOK_OK)
        #expect(info(e, snare).armed && !info(e, keys).armed && !info(e, bass).armed)
        // Input Monitoring: audio members.
        #expect(dalnok_track_set_input_monitor(e, snare, true) == DALNOK_OK)
        #expect(info(e, kick).input_monitor && !info(e, bass).input_monitor)

        // Clutch: nothing follows.
        dalnok_groups_set_clutch(e, true)
        #expect(dalnok_track_set_gain_db(e, kick, -10) == DALNOK_OK && info(e, snare).gain_db == -6)
        dalnok_groups_set_clutch(e, false)
        // A link turned off.
        gi[0].mute = false
        #expect(dalnok_group_set(e, &gi[0]) == DALNOK_OK)
        _ = dalnok_track_set_mute(e, kick, true)
        #expect(!info(e, snare).muted)
        // A fader at -inf stays there; pulling the group to -inf takes everyone.
        dalnok_groups_set_clutch(e, true)
        _ = dalnok_track_set_gain_db(e, keys, -.infinity)
        dalnok_groups_set_clutch(e, false)
        _ = dalnok_track_set_gain_db(e, snare, -3)
        #expect(info(e, keys).gain_db == -.infinity)
        _ = dalnok_track_set_gain_db(e, kick, -.infinity)
        #expect(info(e, snare).gain_db == -.infinity)
        // Leaving and deleting.
        #expect(dalnok_track_set_group(e, snare, 0) == DALNOK_OK && info(e, snare).group == 0)
        #expect(dalnok_group_remove(e, g) == DALNOK_OK && info(e, kick).group == 0 && dalnok_groups(e, nil, 0) == 0)
        #expect(dalnok_undo(e) && dalnok_groups(e, nil, 0) == 1 && info(e, kick).group == g, "deleting a group is undoable")
    }

    @Test func groupsAreSavedAndIgnorableByOlderBuilds() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B")
        let g = dalnok_group_create(e, "Vox", [a, b], 2)
        var gi = DalnokGroupInfo(); _ = dalnok_groups(e, &gi, 1); gi.pan = true
        _ = dalnok_group_set(e, &gi)
        let path = tempDir().appendingPathComponent("g.dalnok").path
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, path, &err, 256) == DALNOK_OK)
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        #expect(doc["version"] as? Int == 3, "groups alone don't raise the format version (older builds ignore them)")
        let f = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(f) }
        #expect(dalnok_project_load(f, path, nil, &err, 256) == DALNOK_OK)
        var back = DalnokGroupInfo()
        #expect(dalnok_groups(f, &back, 1) == 1 && back.id == g && name(back.name) == "Vox" && back.pan && back.members == 2)
        _ = dalnok_track_set_pan(f, dalnok_track_at(f, 0), 0.5)
        #expect(info(f, dalnok_track_at(f, 1)).pan == 0.5)
    }
}
