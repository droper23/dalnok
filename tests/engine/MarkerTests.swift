// Markers (API 26, project format 11).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

struct Markers {
    func list(_ e: OpaquePointer) -> [(Int32, Int64, String)] {
        (0..<dalnok_marker_count(e)).map { i in
            var m = DalnokMarker(); dalnok_marker_at(e, i, &m); return (m.id, m.frame, name(m.name))
        }
    }

    @Test func markersStaySortedAndEditsUndo() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let b = dalnok_marker_add(e, 96_000, "Chorus"), a = dalnok_marker_add(e, 48_000, "Verse")
        #expect(a > 0 && b > 0 && list(e).map(\.2) == ["Verse", "Chorus"] && undoName(e) == "Add Marker")
        #expect(dalnok_marker_add(e, -1, "x") == 0, "negative positions are refused")
        #expect(dalnok_marker_move(e, a, 144_000) == DALNOK_OK && list(e).map(\.2) == ["Chorus", "Verse"])
        #expect(dalnok_marker_rename(e, b, "Hook") == DALNOK_OK && list(e)[0].2 == "Hook")
        #expect(dalnok_marker_rename(e, b, "") != DALNOK_OK, "a marker needs a name")
        #expect(dalnok_marker_remove(e, b) == DALNOK_OK && list(e).count == 1)
        #expect(dalnok_undo(e) && list(e).map(\.2) == ["Hook", "Verse"], "undo restores a deleted marker")
        #expect(dalnok_undo(e) && list(e)[0].2 == "Chorus", "undo a rename")
        let unnamed = dalnok_marker_add(e, 0, nil)
        #expect(list(e).first { $0.0 == unnamed }?.2.hasPrefix("Marker") == true, "an unnamed marker gets a name")
    }

    @Test func markersSaveAndReopen() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        dalnok_marker_add(e, 48_000, "Intro"); dalnok_marker_add(e, 480_000, "Bridge")
        let url = tempDir().appendingPathComponent("m.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, url.path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"markers\"") && (text.contains("\"version\": 11") || text.contains("\"version\":11")))
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, url.path, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        #expect(list(e2).map(\.1) == [48_000, 480_000] && list(e2).map(\.2) == ["Intro", "Bridge"])
        let next = dalnok_marker_add(e2, 0, "New")
        #expect(!list(e2).filter { $0.2 != "New" }.map(\.0).contains(next), "new ids don't collide with loaded ones")
        // A damaged marker list is an error, not a silent drop.
        try text.replacingOccurrences(of: "\"frame\": 48000", with: "\"frame\": -5").replacingOccurrences(of: "\"frame\":48000", with: "\"frame\":-5")
            .write(to: url, atomically: true, encoding: .utf8)
        let e3 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e3) }
        #expect(dalnok_project_load(e3, url.path, nil, &err, 256) != DALNOK_OK)
    }
}

struct HiddenTracks {
    @Test func hiddenTracksKeepPlayingAndSave() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let a = dalnok_track_add(e, "A")
        let url = tempDir().appendingPathComponent("h.wav")
        _ = try writeTestWav(url, frames: 2_400)
        var media: OpaquePointer?
        dalnok_media_load(url.path, 48_000, &media, nil, 0)
        DalnokEngine.dalnok_clip_add(e, a, dalnok_pool_add(e, media!, url.path), 0, 0, 2_400)
        dalnok_media_release(media)
        var before = [Float](repeating: 0, count: 2_400), r = before
        _ = dalnok_render_offline(e, 0, 2_400, &before, &r)
        #expect(dalnok_track_set_hidden(e, a, true) == DALNOK_OK && dalnok_track_hidden(e, a) && undoName(e) == "Hide Track")
        var after = [Float](repeating: 0, count: 2_400)
        _ = dalnok_render_offline(e, 0, 2_400, &after, &r)
        #expect(after == before, "a hidden track still plays")
        let p = tempDir().appendingPathComponent("h.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        dalnok_project_save(e, p.path, &err, 256)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, p.path, nil, &err, 256) == DALNOK_OK && dalnok_track_hidden(e2, dalnok_track_at(e2, 0)))
        #expect(dalnok_track_set_hidden(e, 0, false) == DALNOK_OK && !dalnok_track_hidden(e, a) && undoName(e) == "Show All Tracks")
        #expect(dalnok_track_set_hidden(e, 0, false) != DALNOK_OK, "nothing to show is not an undo step")
    }
}
