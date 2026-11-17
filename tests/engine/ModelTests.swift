// Project model, undo, persistence and command catalog tests.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct UndoAndEditing {
    @Test func everyEditIsUndoableAndRedoable() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(10_000)]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A")
        let c = dalnok_clip_add(e, t, m, 0, 0, 0)
        let base = render(e, frames: 20_000)
        #expect(dalnok_clip_move(e, c, t, 5_000) == DALNOK_OK)
        #expect(undoName(e) == "Move Clip")
        #expect(dalnok_clip_set_region(e, c, 5_000, 100, 4_000) == DALNOK_OK)
        #expect(undoName(e) == "Trim Clip")
        #expect(clipInfo(e, c).offset == 100 && clipInfo(e, c).length == 4_000)

        #expect(dalnok_undo(e)); #expect(dalnok_undo(e))
        #expect(clipInfo(e, c).start == 0)
        expectClose(render(e, frames: 20_000).0, base.0, tol: 0, "undo restores audio exactly")
        #expect(dalnok_redo(e)); #expect(dalnok_redo(e))
        #expect(clipInfo(e, c).start == 5_000 && clipInfo(e, c).length == 4_000)
        #expect(!dalnok_can_redo(e))
        // Undo all the way back to empty.
        while dalnok_undo(e) {}
        #expect(dalnok_track_count(e) == 0)
    }

    @Test func groupsCollapseIntoOneStep() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(1_000)]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A")
        let c = dalnok_clip_add(e, t, m, 0, 0, 0)
        dalnok_undo_begin_group(e, "Drag")
        for x in 1...25 { dalnok_clip_move(e, c, t, Int64(x * 100)) }
        dalnok_undo_end_group(e)
        #expect(undoName(e) == "Drag")
        #expect(clipInfo(e, c).start == 2_500)
        #expect(dalnok_undo(e))
        #expect(clipInfo(e, c).start == 0, "one undo reverts the whole drag")
        #expect(undoName(e) == "Add Clip")
    }

    @Test func failedEditsChangeNothing() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(1_000)]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A")
        let c = dalnok_clip_add(e, t, m, 0, 0, 0)
        let rev = dalnok_model_revision(e)
        #expect(dalnok_clip_set_region(e, c, 0, 900, 200) == DALNOK_ERR_INVALID_ARG, "past media end")
        #expect(dalnok_clip_move(e, c, 99, 0) == DALNOK_ERR_NOT_FOUND)
        #expect(dalnok_clip_split(e, c, 0, nil) == DALNOK_ERR_INVALID_ARG, "split at edge")
        #expect(dalnok_model_revision(e) == rev)
        #expect(undoName(e) == "Add Clip")
    }

    @Test func gainUndoRestoresAudio() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let src = ramp(2_000); let m = makeMedia([src]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A"); dalnok_clip_add(e, t, m, 0, 0, 0)
        dalnok_track_set_gain_db(e, t, -6.0206)
        expectClose(render(e, frames: 2_000).0, src.map { $0 * 0.5 }, tol: 1e-5, "gain applied")
        dalnok_undo(e)
        expectClose(render(e, frames: 2_000).0, src, tol: 1e-6, "gain undone")
        var info = DalnokTrackInfo(); dalnok_track_info(e, t, &info)
        #expect(info.gain_db == 0)
    }

    @Test func splitIsSeamless() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(30_000)]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A")
        let c = dalnok_clip_add(e, t, m, 1_000, 500, 20_000)
        let before = render(e, frames: 25_000)
        var right: DalnokClipId = 0
        #expect(dalnok_clip_split(e, c, 7_777, &right) == DALNOK_OK)
        #expect(clipInfo(e, c).length == 6_777)
        #expect(clipInfo(e, right).start == 7_777 && clipInfo(e, right).offset == 7_277)
        expectClose(render(e, frames: 25_000).0, before.0, tol: 0, "split renders identically")
    }

    @Test func topClipWinsWhenOverlapping() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let a = [Float](repeating: 0.25, count: 1_000), b = [Float](repeating: -0.5, count: 1_000)
        let ma = makeMedia([a]), mb = makeMedia([b]); defer { dalnok_media_release(ma); dalnok_media_release(mb) }
        let t = dalnok_track_add(e, "A")
        let ca = dalnok_clip_add(e, t, ma, 0, 0, 0)
        dalnok_clip_add(e, t, mb, 500, 0, 0)
        func near(_ x: Float, _ y: Float) -> Bool { abs(x - y) < 1e-4 } // mono center pan ~unity
        var (l, _) = render(e, frames: 1_500)
        #expect(near(l[499], 0.25) && near(l[500], -0.5) && near(l[999], -0.5), "later clip on top")
        dalnok_clip_move(e, ca, t, 0) // moving brings A to the top
        (l, _) = render(e, frames: 1_500)
        #expect(near(l[999], 0.25) && near(l[1_000], -0.5))
    }

    @Test func removingTrackRemovesItsClipsAndUndoRestoresThem() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(500)]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A"); dalnok_clip_add(e, t, m, 0, 0, 0)
        dalnok_track_remove(e, t)
        #expect(dalnok_track_count(e) == 0 && dalnok_session_length(e) == 0)
        dalnok_undo(e)
        #expect(dalnok_track_count(e) == 1 && dalnok_session_length(e) == 500)
    }
}

@Suite struct Persistence {
    let dir = tempDir()

    @discardableResult
    func makeProject(_ e: OpaquePointer, audio: URL) throws -> [Float] {
        let samples = try writeTestWav(audio, frames: 24_000)
        var m: OpaquePointer?
        #expect(dalnok_media_load(audio.path, sr, &m, nil, 0) == DALNOK_OK)
        let id = dalnok_pool_add(e, m, audio.path)
        dalnok_media_release(m)
        let t1 = dalnok_track_add(e, "Drums ü 🥁"), t2 = dalnok_track_add(e, "Quiet")
        DalnokEngine.dalnok_clip_add(e, t1, id, 1_000, 2_000, 10_000)
        DalnokEngine.dalnok_clip_add(e, t2, id, 0, 0, 0)
        dalnok_track_set_gain_db(e, t2, -200) // -inf
        dalnok_track_set_pan(e, t1, -0.3)
        return samples
    }

    @Test func snapshotDoesNotFollowPredictableTemporarySymlink() throws {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        _ = dalnok_track_add(e, "Recovery")
        let snapshot = dir.appendingPathComponent("snapshot.dalnok")
        let victim = dir.appendingPathComponent("untouched.txt")
        try "keep this".write(to: victim, atomically: true, encoding: .utf8)
        let legacyTemp = snapshot.path + ".tmp-\(ProcessInfo.processInfo.processIdentifier)"
        try FileManager.default.createSymbolicLink(atPath: legacyTemp, withDestinationPath: victim.path)
        #expect(dalnok_project_save_snapshot(e, snapshot.path, nil, 0) == DALNOK_OK)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep this")
        #expect(dalnok_project_dirty(e))
    }

    @Test func recoverySnapshotKeepsDirtyStateAndAudio() throws {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        try makeProject(e, audio: dir.appendingPathComponent("snapshot-audio.wav"))
        let expected = render(e, frames: 30_000)
        let revision = dalnok_model_revision(e)
        let snapshot = dir.appendingPathComponent("recovery.dalnok").path
        #expect(dalnok_project_dirty(e))
        #expect(dalnok_project_save_snapshot(e, snapshot, nil, 0) == DALNOK_OK)
        #expect(dalnok_project_dirty(e) && dalnok_model_revision(e) == revision)
        let loaded = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(loaded) }
        var missing: Int32 = -1
        var prepared: OpaquePointer?
        #expect(dalnok_project_prepare(snapshot, sr, &prepared, &missing, nil, 0) == DALNOK_OK && missing == 0)
        #expect(dalnok_project_apply_recovery(loaded, prepared) == DALNOK_OK)
        #expect(dalnok_project_dirty(loaded))
        let actual = render(loaded, frames: 30_000)
        expectClose(actual.0, expected.0, tol: 0, "snapshot left")
        expectClose(actual.1, expected.1, tol: 0, "snapshot right")
        #expect(dalnok_project_save_snapshot(e, dir.appendingPathComponent("missing/recovery.dalnok").path, nil, 0) == DALNOK_ERR_IO)
        #expect(dalnok_project_dirty(e) && dalnok_model_revision(e) == revision)
    }

    @Test func saveLoadRoundTripsExactly() throws {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        try makeProject(e, audio: dir.appendingPathComponent("a.wav"))
        let project = dir.appendingPathComponent("p.dalnok").path
        #expect(dalnok_project_dirty(e))
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project, &err, 256) == DALNOK_OK, "\(cstr(err))")
        #expect(!dalnok_project_dirty(e))
        let before = render(e, frames: 30_000)

        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        var missing: Int32 = -1
        #expect(dalnok_project_load(e2, project, &missing, &err, 256) == DALNOK_OK, "\(cstr(err))")
        #expect(missing == 0)
        let after = render(e2, frames: 30_000)
        expectClose(after.0, before.0, tol: 0, "left identical after reload")
        expectClose(after.1, before.1, tol: 0, "right identical after reload")
        var info = DalnokTrackInfo()
        dalnok_track_info(e2, dalnok_track_at(e2, 0), &info)
        #expect(name(info.name) == "Drums ü 🥁")
        dalnok_track_info(e2, dalnok_track_at(e2, 1), &info)
        #expect(info.gain_db == -.infinity)
        #expect(!dalnok_project_dirty(e2) && !dalnok_can_undo(e2))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty, "atomic save leaves no temp files")
    }

    @Test func relocatedProjectFindsMediaByRelativePath() throws {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let orig = dir.appendingPathComponent("orig"), moved = dir.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: orig.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        try makeProject(e, audio: orig.appendingPathComponent("Audio/a.wav"))
        dalnok_project_save(e, orig.appendingPathComponent("p.dalnok").path, nil, 0)
        try FileManager.default.moveItem(at: orig, to: moved)

        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        var missing: Int32 = -1
        #expect(dalnok_project_load(e2, moved.appendingPathComponent("p.dalnok").path, &missing, nil, 0) == DALNOK_OK)
        #expect(missing == 0, "found via relativePath")
        var p = [CChar](repeating: 0, count: 1024)
        dalnok_pool_path(e2, clipInfo(e2, dalnok_track_clip_at(e2, dalnok_track_at(e2, 0), 0)).media, &p, 1024)
        #expect(cstr(p).hasSuffix("moved/Audio/a.wav"))
    }

    @Test func missingMediaLoadsOfflineAndSilent() throws {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let audio = dir.appendingPathComponent("gone.wav")
        try makeProject(e, audio: audio)
        let project = dir.appendingPathComponent("m.dalnok").path
        dalnok_project_save(e, project, nil, 0)
        try FileManager.default.removeItem(at: audio)

        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        var missing: Int32 = 0
        #expect(dalnok_project_load(e2, project, &missing, nil, 0) == DALNOK_OK)
        #expect(missing == 1)
        let c = dalnok_track_clip_at(e2, dalnok_track_at(e2, 0), 0)
        #expect(clipInfo(e2, c).offline && clipInfo(e2, c).length == 10_000, "clip kept, marked offline")
        #expect(dalnok_pool_media(e2, clipInfo(e2, c).media) == nil)
        #expect(render(e2, frames: 30_000).0.allSatisfy { $0 == 0 })
        // Saving again keeps the offline reference.
        #expect(dalnok_project_save(e2, project, nil, 0) == DALNOK_OK)
        let text = try String(contentsOfFile: project, encoding: .utf8)
        #expect(text.contains("gone.wav"))
    }

    @Test func badFilesAreRejectedWithoutTouchingCurrentProject() throws {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        try makeProject(e, audio: dir.appendingPathComponent("a.wav"))
        let rev = dalnok_model_revision(e)
        let cases = [
            "not json",
            "{\"format\":\"something-else\",\"version\":1}",
            "{\"format\":\"dalnok-project\",\"version\":99}",
            "{\"format\":\"dalnok-project\",\"version\":1,\"tracks\":[{\"id\":1,\"clips\":[{\"id\":1,\"media\":7,\"start\":0,\"offset\":0,\"length\":5}]}]}",
            String(repeating: "[", count: 5_000),
        ]
        for (i, text) in cases.enumerated() {
            let path = dir.appendingPathComponent("bad\(i).dalnok")
            try text.write(to: path, atomically: true, encoding: .utf8)
            var err = [CChar](repeating: 0, count: 256)
            let st = dalnok_project_load(e, path.path, nil, &err, 256)
            #expect(st != DALNOK_OK, "case \(i) rejected")
            #expect(!cstr(err).isEmpty)
        }
        #expect(dalnok_model_revision(e) == rev && dalnok_track_count(e) == 2, "current project untouched")
        #expect(dalnok_project_load(e, "/nonexistent/x.dalnok", nil, nil, 0) == DALNOK_ERR_IO)
    }

    @Test func loadingAtAnotherSampleRateRescalesPositions() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        try makeProject(e, audio: dir.appendingPathComponent("a.wav"))
        let project = dir.appendingPathComponent("sr.dalnok").path
        dalnok_project_save(e, project, nil, 0)
        let e2 = dalnok_engine_create(44_100)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project, nil, nil, 0) == DALNOK_OK)
        let c = clipInfo(e2, dalnok_track_clip_at(e2, dalnok_track_at(e2, 0), 0))
        #expect(c.start == 919 && c.offset == 1_838 && c.length == 9_188) // x 44100/48000, rounded
    }

    @Test func newProjectClearsEverything() throws {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        try makeProject(e, audio: dir.appendingPathComponent("a.wav"))
        dalnok_project_new(e)
        #expect(dalnok_track_count(e) == 0 && !dalnok_can_undo(e) && !dalnok_project_dirty(e))
    }
}

@Suite struct CommandCatalog {
    @Test func namesAreUniqueAndDocumented() {
        var names = Set<String>()
        for i in 0..<dalnok_command_count() {
            var n: UnsafePointer<CChar>?, t: UnsafePointer<CChar>?, a: UnsafePointer<CChar>?
            #expect(dalnok_command_info(i, &n, &t, &a))
            let name = String(cString: n!)
            #expect(names.insert(name).inserted, "duplicate \(name)")
            #expect(!String(cString: t!).isEmpty)
        }
        #expect(names.count >= 15)
        #expect(!dalnok_command_info(dalnok_command_count(), nil, nil, nil))
    }

    @Test func commandsDriveTheModel() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(4_000)]); defer { dalnok_media_release(m) }
        let media = dalnok_pool_add(e, m, nil)
        let (s1, r1) = runCommand(e, "track.add", #"{"name": "Café 🎵"}"#)
        #expect(s1 == DALNOK_OK)
        let track = r1["id"] as! Int
        let (s2, r2) = runCommand(e, "clip.add", "{\"track\": \(track), \"media\": \(media), \"start\": 100}")
        #expect(s2 == DALNOK_OK)
        let clip = r2["id"] as! Int
        #expect(runCommand(e, "clip.move", "{\"clip\": \(clip), \"start\": 2000}").0 == DALNOK_OK)
        #expect(clipInfo(e, DalnokClipId(clip)).start == 2_000)
        #expect(runCommand(e, "edit.undo").1["done"] as? Bool == true)
        #expect(clipInfo(e, DalnokClipId(clip)).start == 100)

        let (s3, d) = runCommand(e, "session.describe")
        #expect(s3 == DALNOK_OK)
        let tracks = d["tracks"] as! [[String: Any]]
        #expect(tracks.first?["name"] as? String == "Café 🎵", "unicode escapes decoded")
    }

    @Test func errorsAreReportedAsJSON() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let (s1, r1) = runCommand(e, "no.such.command")
        #expect(s1 == DALNOK_ERR_NOT_FOUND && (r1["error"] as? String)?.contains("unknown") == true)
        #expect(runCommand(e, "clip.move", "{\"clip\": 1}").0 == DALNOK_ERR_INVALID_ARG)
        #expect(runCommand(e, "clip.move", "{\"clip\": 1, \"start\": 0}").0 == DALNOK_ERR_NOT_FOUND)
        #expect(runCommand(e, "track.add", "{bad json").0 == DALNOK_ERR_FORMAT)
        #expect(runCommand(e, "track.add", "[1]").0 == DALNOK_ERR_FORMAT)
        #expect(runCommand(e, "track.setVolume", "{\"track\": 1.5, \"db\": 0}").0 == DALNOK_ERR_INVALID_ARG)
    }
}

@Suite struct TrackColors {
    func info(_ e: OpaquePointer, _ t: DalnokTrackId) -> DalnokTrackInfo { var i = DalnokTrackInfo(); dalnok_track_info(e, t, &i); return i }

    @Test func newTracksContinueTheGradientFromTheTrackAbove() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let t = (0..<4).map { dalnok_track_add(e, "T\($0)") }
        #expect(t.map { info(e, $0).color } == [0, 1, 2, 3])
        dalnok_track_remove(e, t[3])
        dalnok_track_remove(e, t[1])
        let n = dalnok_track_add(e, "new")
        #expect(info(e, n).color == 3, "continues after the last track (2), never duplicating a neighbor")
        #expect(info(e, n).custom_color == -1)
    }

    @Test func customColorsPinAndRecolorRestoresTheSpectrum() throws {
        let dir = tempDir()
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let t = (0..<3).map { dalnok_track_add(e, "T\($0)") }
        #expect(dalnok_track_set_color(e, t[1], 0x112233) == DALNOK_OK)
        #expect(dalnok_track_set_color(e, t[1], 0x1000000) == DALNOK_ERR_INVALID_ARG)
        dalnok_track_move(e, t[2], 0)
        #expect(info(e, t[2]).color == 2, "moving keeps a track's color (identity)")
        #expect(dalnok_tracks_recolor_gradient(e) == DALNOK_OK)
        #expect((0..<3).map { info(e, dalnok_track_at(e, Int32($0))).color } == [0, 1, 2], "gradient re-applied in display order")
        #expect(info(e, t[1]).custom_color == 0x112233, "custom color survives recolor")
        #expect(undoName(e) == "Recolor Tracks")
        let p = dir.appendingPathComponent("c.dalnok").path
        dalnok_project_save(e, p, nil, 0)
        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        dalnok_project_load(e2, p, nil, nil, 0)
        #expect(info(e2, dalnok_track_at(e2, 2)).custom_color == 0x112233 && info(e2, dalnok_track_at(e2, 0)).custom_color == -1)
        #expect(runCommand(e, "track.setColor", "{\"track\": \(t[0]), \"color\": \"#ff8800\"}").0 == DALNOK_OK)
        #expect(info(e, t[0]).custom_color == 0xff8800)
        #expect(runCommand(e, "track.setColor", "{\"track\": \(t[0]), \"color\": \"auto\"}").0 == DALNOK_OK)
        #expect(info(e, t[0]).custom_color == -1)
    }
}
