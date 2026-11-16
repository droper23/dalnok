// Project model, undo, persistence and command catalog tests.
// SPDX-License-Identifier: GPL-3.0-or-later
import AtriumEngine
import Foundation
import Testing

@Suite struct UndoAndEditing {
    @Test func everyEditIsUndoableAndRedoable() {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let m = makeMedia([ramp(10_000)]); defer { atrium_media_release(m) }
        let t = atrium_track_add(e, "A")
        let c = atrium_clip_add(e, t, m, 0, 0, 0)
        let base = render(e, frames: 20_000)
        #expect(atrium_clip_move(e, c, t, 5_000) == ATRIUM_OK)
        #expect(undoName(e) == "Move Clip")
        #expect(atrium_clip_set_region(e, c, 5_000, 100, 4_000) == ATRIUM_OK)
        #expect(undoName(e) == "Trim Clip")
        #expect(clipInfo(e, c).offset == 100 && clipInfo(e, c).length == 4_000)

        #expect(atrium_undo(e)); #expect(atrium_undo(e))
        #expect(clipInfo(e, c).start == 0)
        expectClose(render(e, frames: 20_000).0, base.0, tol: 0, "undo restores audio exactly")
        #expect(atrium_redo(e)); #expect(atrium_redo(e))
        #expect(clipInfo(e, c).start == 5_000 && clipInfo(e, c).length == 4_000)
        #expect(!atrium_can_redo(e))
        // Undo all the way back to empty.
        while atrium_undo(e) {}
        #expect(atrium_track_count(e) == 0)
    }

    @Test func groupsCollapseIntoOneStep() {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let m = makeMedia([ramp(1_000)]); defer { atrium_media_release(m) }
        let t = atrium_track_add(e, "A")
        let c = atrium_clip_add(e, t, m, 0, 0, 0)
        atrium_undo_begin_group(e, "Drag")
        for x in 1...25 { atrium_clip_move(e, c, t, Int64(x * 100)) }
        atrium_undo_end_group(e)
        #expect(undoName(e) == "Drag")
        #expect(clipInfo(e, c).start == 2_500)
        #expect(atrium_undo(e))
        #expect(clipInfo(e, c).start == 0, "one undo reverts the whole drag")
        #expect(undoName(e) == "Add Clip")
    }

    @Test func failedEditsChangeNothing() {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let m = makeMedia([ramp(1_000)]); defer { atrium_media_release(m) }
        let t = atrium_track_add(e, "A")
        let c = atrium_clip_add(e, t, m, 0, 0, 0)
        let rev = atrium_model_revision(e)
        #expect(atrium_clip_set_region(e, c, 0, 900, 200) == ATRIUM_ERR_INVALID_ARG, "past media end")
        #expect(atrium_clip_move(e, c, 99, 0) == ATRIUM_ERR_NOT_FOUND)
        #expect(atrium_clip_split(e, c, 0, nil) == ATRIUM_ERR_INVALID_ARG, "split at edge")
        #expect(atrium_model_revision(e) == rev)
        #expect(undoName(e) == "Add Clip")
    }

    @Test func gainUndoRestoresAudio() {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let src = ramp(2_000); let m = makeMedia([src]); defer { atrium_media_release(m) }
        let t = atrium_track_add(e, "A"); atrium_clip_add(e, t, m, 0, 0, 0)
        atrium_track_set_gain_db(e, t, -6.0206)
        expectClose(render(e, frames: 2_000).0, src.map { $0 * 0.5 }, tol: 1e-5, "gain applied")
        atrium_undo(e)
        expectClose(render(e, frames: 2_000).0, src, tol: 1e-6, "gain undone")
        var info = AtriumTrackInfo(); atrium_track_info(e, t, &info)
        #expect(info.gain_db == 0)
    }

    @Test func splitIsSeamless() {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let m = makeMedia([ramp(30_000)]); defer { atrium_media_release(m) }
        let t = atrium_track_add(e, "A")
        let c = atrium_clip_add(e, t, m, 1_000, 500, 20_000)
        let before = render(e, frames: 25_000)
        var right: AtriumClipId = 0
        #expect(atrium_clip_split(e, c, 7_777, &right) == ATRIUM_OK)
        #expect(clipInfo(e, c).length == 6_777)
        #expect(clipInfo(e, right).start == 7_777 && clipInfo(e, right).offset == 7_277)
        expectClose(render(e, frames: 25_000).0, before.0, tol: 0, "split renders identically")
    }

    @Test func topClipWinsWhenOverlapping() {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let a = [Float](repeating: 0.25, count: 1_000), b = [Float](repeating: -0.5, count: 1_000)
        let ma = makeMedia([a]), mb = makeMedia([b]); defer { atrium_media_release(ma); atrium_media_release(mb) }
        let t = atrium_track_add(e, "A")
        let ca = atrium_clip_add(e, t, ma, 0, 0, 0)
        atrium_clip_add(e, t, mb, 500, 0, 0)
        func near(_ x: Float, _ y: Float) -> Bool { abs(x - y) < 1e-4 } // mono center pan ~unity
        var (l, _) = render(e, frames: 1_500)
        #expect(near(l[499], 0.25) && near(l[500], -0.5) && near(l[999], -0.5), "later clip on top")
        atrium_clip_move(e, ca, t, 0) // moving brings A to the top
        (l, _) = render(e, frames: 1_500)
        #expect(near(l[999], 0.25) && near(l[1_000], -0.5))
    }

    @Test func removingTrackRemovesItsClipsAndUndoRestoresThem() {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let m = makeMedia([ramp(500)]); defer { atrium_media_release(m) }
        let t = atrium_track_add(e, "A"); atrium_clip_add(e, t, m, 0, 0, 0)
        atrium_track_remove(e, t)
        #expect(atrium_track_count(e) == 0 && atrium_session_length(e) == 0)
        atrium_undo(e)
        #expect(atrium_track_count(e) == 1 && atrium_session_length(e) == 500)
    }
}

@Suite struct Persistence {
    let dir = tempDir()

    func makeProject(_ e: OpaquePointer, audio: URL) throws -> [Float] {
        let samples = try writeTestWav(audio, frames: 24_000)
        var m: OpaquePointer?
        #expect(atrium_media_load(audio.path, sr, &m, nil, 0) == ATRIUM_OK)
        let id = atrium_pool_add(e, m, audio.path)
        atrium_media_release(m)
        let t1 = atrium_track_add(e, "Drums ü 🥁"), t2 = atrium_track_add(e, "Quiet")
        AtriumEngine.atrium_clip_add(e, t1, id, 1_000, 2_000, 10_000)
        AtriumEngine.atrium_clip_add(e, t2, id, 0, 0, 0)
        atrium_track_set_gain_db(e, t2, -200) // -inf
        atrium_track_set_pan(e, t1, -0.3)
        return samples
    }

    @Test func saveLoadRoundTripsExactly() throws {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        try makeProject(e, audio: dir.appendingPathComponent("a.wav"))
        let project = dir.appendingPathComponent("p.atrium").path
        #expect(atrium_project_dirty(e))
        var err = [CChar](repeating: 0, count: 256)
        #expect(atrium_project_save(e, project, &err, 256) == ATRIUM_OK, "\(cstr(err))")
        #expect(!atrium_project_dirty(e))
        let before = render(e, frames: 30_000)

        let e2 = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e2) }
        var missing: Int32 = -1
        #expect(atrium_project_load(e2, project, &missing, &err, 256) == ATRIUM_OK, "\(cstr(err))")
        #expect(missing == 0)
        let after = render(e2, frames: 30_000)
        expectClose(after.0, before.0, tol: 0, "left identical after reload")
        expectClose(after.1, before.1, tol: 0, "right identical after reload")
        var info = AtriumTrackInfo()
        atrium_track_info(e2, atrium_track_at(e2, 0), &info)
        #expect(name(info.name) == "Drums ü 🥁")
        atrium_track_info(e2, atrium_track_at(e2, 1), &info)
        #expect(info.gain_db == -.infinity)
        #expect(!atrium_project_dirty(e2) && !atrium_can_undo(e2))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty, "atomic save leaves no temp files")
    }

    @Test func relocatedProjectFindsMediaByRelativePath() throws {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let orig = dir.appendingPathComponent("orig"), moved = dir.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: orig.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        try makeProject(e, audio: orig.appendingPathComponent("Audio/a.wav"))
        atrium_project_save(e, orig.appendingPathComponent("p.atrium").path, nil, 0)
        try FileManager.default.moveItem(at: orig, to: moved)

        let e2 = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e2) }
        var missing: Int32 = -1
        #expect(atrium_project_load(e2, moved.appendingPathComponent("p.atrium").path, &missing, nil, 0) == ATRIUM_OK)
        #expect(missing == 0, "found via relativePath")
        var p = [CChar](repeating: 0, count: 1024)
        atrium_pool_path(e2, clipInfo(e2, atrium_track_clip_at(e2, atrium_track_at(e2, 0), 0)).media, &p, 1024)
        #expect(cstr(p).hasSuffix("moved/Audio/a.wav"))
    }

    @Test func missingMediaLoadsOfflineAndSilent() throws {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let audio = dir.appendingPathComponent("gone.wav")
        try makeProject(e, audio: audio)
        let project = dir.appendingPathComponent("m.atrium").path
        atrium_project_save(e, project, nil, 0)
        try FileManager.default.removeItem(at: audio)

        let e2 = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e2) }
        var missing: Int32 = 0
        #expect(atrium_project_load(e2, project, &missing, nil, 0) == ATRIUM_OK)
        #expect(missing == 1)
        let c = atrium_track_clip_at(e2, atrium_track_at(e2, 0), 0)
        #expect(clipInfo(e2, c).offline && clipInfo(e2, c).length == 10_000, "clip kept, marked offline")
        #expect(atrium_pool_media(e2, clipInfo(e2, c).media) == nil)
        #expect(render(e2, frames: 30_000).0.allSatisfy { $0 == 0 })
        // Saving again keeps the offline reference.
        #expect(atrium_project_save(e2, project, nil, 0) == ATRIUM_OK)
        let text = try String(contentsOfFile: project, encoding: .utf8)
        #expect(text.contains("gone.wav"))
    }

    @Test func badFilesAreRejectedWithoutTouchingCurrentProject() throws {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        try makeProject(e, audio: dir.appendingPathComponent("a.wav"))
        let rev = atrium_model_revision(e)
        let cases = [
            "not json",
            "{\"format\":\"something-else\",\"version\":1}",
            "{\"format\":\"atrium-project\",\"version\":99}",
            "{\"format\":\"atrium-project\",\"version\":1,\"tracks\":[{\"id\":1,\"clips\":[{\"id\":1,\"media\":7,\"start\":0,\"offset\":0,\"length\":5}]}]}",
            String(repeating: "[", count: 5_000),
        ]
        for (i, text) in cases.enumerated() {
            let path = dir.appendingPathComponent("bad\(i).atrium")
            try text.write(to: path, atomically: true, encoding: .utf8)
            var err = [CChar](repeating: 0, count: 256)
            let st = atrium_project_load(e, path.path, nil, &err, 256)
            #expect(st != ATRIUM_OK, "case \(i) rejected")
            #expect(!cstr(err).isEmpty)
        }
        #expect(atrium_model_revision(e) == rev && atrium_track_count(e) == 2, "current project untouched")
        #expect(atrium_project_load(e, "/nonexistent/x.atrium", nil, nil, 0) == ATRIUM_ERR_IO)
    }

    @Test func loadingAtAnotherSampleRateRescalesPositions() throws {
        let e = atrium_engine_create(48_000)!; defer { atrium_engine_destroy(e) }
        try makeProject(e, audio: dir.appendingPathComponent("a.wav"))
        let project = dir.appendingPathComponent("sr.atrium").path
        atrium_project_save(e, project, nil, 0)
        let e2 = atrium_engine_create(44_100)!; defer { atrium_engine_destroy(e2) }
        #expect(atrium_project_load(e2, project, nil, nil, 0) == ATRIUM_OK)
        let c = clipInfo(e2, atrium_track_clip_at(e2, atrium_track_at(e2, 0), 0))
        #expect(c.start == 919 && c.offset == 1_838 && c.length == 9_188) // x 44100/48000, rounded
    }

    @Test func newProjectClearsEverything() throws {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        try makeProject(e, audio: dir.appendingPathComponent("a.wav"))
        atrium_project_new(e)
        #expect(atrium_track_count(e) == 0 && !atrium_can_undo(e) && !atrium_project_dirty(e))
    }
}

@Suite struct CommandCatalog {
    @Test func namesAreUniqueAndDocumented() {
        var names = Set<String>()
        for i in 0..<atrium_command_count() {
            var n: UnsafePointer<CChar>?, t: UnsafePointer<CChar>?, a: UnsafePointer<CChar>?
            #expect(atrium_command_info(i, &n, &t, &a))
            let name = String(cString: n!)
            #expect(names.insert(name).inserted, "duplicate \(name)")
            #expect(!String(cString: t!).isEmpty)
        }
        #expect(names.count >= 15)
        #expect(!atrium_command_info(atrium_command_count(), nil, nil, nil))
    }

    @Test func commandsDriveTheModel() {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let m = makeMedia([ramp(4_000)]); defer { atrium_media_release(m) }
        let media = atrium_pool_add(e, m, nil)
        let (s1, r1) = runCommand(e, "track.add", #"{"name": "Café 🎵"}"#)
        #expect(s1 == ATRIUM_OK)
        let track = r1["id"] as! Int
        let (s2, r2) = runCommand(e, "clip.add", "{\"track\": \(track), \"media\": \(media), \"start\": 100}")
        #expect(s2 == ATRIUM_OK)
        let clip = r2["id"] as! Int
        #expect(runCommand(e, "clip.move", "{\"clip\": \(clip), \"start\": 2000}").0 == ATRIUM_OK)
        #expect(clipInfo(e, AtriumClipId(clip)).start == 2_000)
        #expect(runCommand(e, "edit.undo").1["done"] as? Bool == true)
        #expect(clipInfo(e, AtriumClipId(clip)).start == 100)

        let (s3, d) = runCommand(e, "session.describe")
        #expect(s3 == ATRIUM_OK)
        let tracks = d["tracks"] as! [[String: Any]]
        #expect(tracks.first?["name"] as? String == "Café 🎵", "unicode escapes decoded")
    }

    @Test func errorsAreReportedAsJSON() {
        let e = atrium_engine_create(sr)!; defer { atrium_engine_destroy(e) }
        let (s1, r1) = runCommand(e, "no.such.command")
        #expect(s1 == ATRIUM_ERR_NOT_FOUND && (r1["error"] as? String)?.contains("unknown") == true)
        #expect(runCommand(e, "clip.move", "{\"clip\": 1}").0 == ATRIUM_ERR_INVALID_ARG)
        #expect(runCommand(e, "clip.move", "{\"clip\": 1, \"start\": 0}").0 == ATRIUM_ERR_NOT_FOUND)
        #expect(runCommand(e, "track.add", "{bad json").0 == ATRIUM_ERR_FORMAT)
        #expect(runCommand(e, "track.add", "[1]").0 == ATRIUM_ERR_FORMAT)
        #expect(runCommand(e, "track.setVolume", "{\"track\": 1.5, \"db\": 0}").0 == ATRIUM_ERR_INVALID_ARG)
    }
}
