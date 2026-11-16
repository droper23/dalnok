// Fades and crossfades, solo, track order, relink, copy-media-on-save.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Mono DC media; center pan on a mono track is unity within ~1e-4.
func dc(_ v: Float, _ n: Int) -> [Float] { [Float](repeating: v, count: n) }

@Suite struct Fades {
    @Test func linearFadeInAndOutShapes() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([dc(1, 10_000)]); defer { dalnok_media_release(m) }
        let c = dalnok_clip_add(e, dalnok_track_add(e, "A"), m, 0, 0, 0)
        #expect(dalnok_clip_set_fades(e, c, 1_000, 2_000, DALNOK_FADE_LINEAR) == DALNOK_OK)
        let (l, _) = render(e, frames: 10_000)
        for i in [0, 250, 500, 999] { #expect(abs(l[i] - (Float(i) + 0.5) / 1_000) < 2e-4, "fade-in at \(i): \(l[i])") }
        #expect(abs(l[5_000] - 1) < 2e-4, "body untouched")
        for i in [8_000, 9_000, 9_999] {
            let expected = (Float(10_000 - i) - 0.5) / 2_000
            #expect(abs(l[i] - expected) < 2e-4, "fade-out at \(i): \(l[i]) vs \(expected)")
        }
        #expect(clipInfo(e, c).fade_in == 1_000 && clipInfo(e, c).fade_out == 2_000)
    }

    @Test func linearCrossfadeOfIdenticalSignalsHasNoDip() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let a = makeMedia([dc(0.5, 10_000)]), b = makeMedia([dc(0.5, 10_000)])
        defer { dalnok_media_release(a); dalnok_media_release(b) }
        let t = dalnok_track_add(e, "A")
        dalnok_clip_add(e, t, a, 0, 0, 0)
        let top = dalnok_clip_add(e, t, b, 8_000, 0, 0) // overlaps 8000..10000
        dalnok_clip_set_fades(e, top, 2_000, 0, DALNOK_FADE_LINEAR)
        let (l, _) = render(e, frames: 18_000)
        #expect(l[7_000..<12_000].allSatisfy { abs($0 - 0.5) < 2e-4 }, "constant level through the crossfade")
    }

    @Test func equalPowerCrossfadeWeights() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let low = makeMedia([dc(0.6, 10_000)]), high = makeMedia([dc(-0.3, 10_000)])
        defer { dalnok_media_release(low); dalnok_media_release(high) }
        let t = dalnok_track_add(e, "A")
        dalnok_clip_add(e, t, low, 0, 0, 0)
        let top = dalnok_clip_add(e, t, high, 5_000, 0, 0)
        dalnok_clip_set_fades(e, top, 1_000, 0, DALNOK_FADE_EQUAL_POWER)
        let (l, _) = render(e, frames: 7_000)
        for i in [0, 100, 500, 900, 999] {
            let x = (Double(i) + 0.5) / 1_000
            let env = sin(x * .pi / 2), under = (1 - env * env).squareRoot()
            let expected = Float(0.6 * under - 0.3 * env)
            #expect(abs(l[5_000 + i] - expected) < 5e-4, "equal-power at \(i): \(l[5_000 + i]) vs \(expected)")
        }
        #expect(abs(l[6_500] + 0.3) < 2e-4, "top clip wins after the fade")
    }

    @Test func oversizedFadesAreScaledAndSplitKeepsOuterFades() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([dc(1, 1_000)]); defer { dalnok_media_release(m) }
        let c = dalnok_clip_add(e, dalnok_track_add(e, "A"), m, 0, 0, 0)
        dalnok_clip_set_fades(e, c, 3_000, 1_000, DALNOK_FADE_LINEAR) // 4000 > 1000 frames
        let (l, _) = render(e, frames: 1_000)
        #expect(l.allSatisfy { $0 <= 1.0001 && $0 >= 0 } && l.max()! < 1, "fades fit inside the clip")
        dalnok_clip_set_fades(e, c, 100, 200, DALNOK_FADE_LINEAR)
        var right: DalnokClipId = 0
        dalnok_clip_split(e, c, 500, &right)
        #expect(clipInfo(e, c).fade_in == 100 && clipInfo(e, c).fade_out == 0)
        #expect(clipInfo(e, right).fade_in == 0 && clipInfo(e, right).fade_out == 200)
        #expect(dalnok_clip_set_fades(e, c, -1, 0, DALNOK_FADE_LINEAR) == DALNOK_ERR_INVALID_ARG)
    }

    @Test func fadesAreUndoableAndPersist() throws {
        let dir = tempDir()
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let audio = dir.appendingPathComponent("a.wav")
        try writeTestWav(audio, frames: 20_000)
        var m: OpaquePointer?
        dalnok_media_load(audio.path, sr, &m, nil, 0)
        let id = dalnok_pool_add(e, m, audio.path); dalnok_media_release(m)
        let c = DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "A"), id, 0, 0, 0)
        dalnok_clip_set_fades(e, c, 480, 960, DALNOK_FADE_EQUAL_POWER)
        #expect(undoName(e) == "Fade")
        let project = dir.appendingPathComponent("f.dalnok").path
        dalnok_project_save(e, project, nil, 0)
        let before = render(e, frames: 20_000)
        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        dalnok_project_load(e2, project, nil, nil, 0)
        let c2 = clipInfo(e2, dalnok_track_clip_at(e2, dalnok_track_at(e2, 0), 0))
        #expect(c2.fade_in == 480 && c2.fade_out == 960 && c2.fade_curve == Int32(DALNOK_FADE_EQUAL_POWER.rawValue))
        expectClose(render(e2, frames: 20_000).0, before.0, tol: 0, "fades persist exactly")
        dalnok_undo(e)
        #expect(clipInfo(e, c).fade_in == 0)
    }
}

@Suite struct TracksSoloOrder {
    @Test func soloSilencesOthersAndUndoes() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let a = makeMedia([dc(0.25, 1_000)]), b = makeMedia([dc(0.5, 1_000)])
        defer { dalnok_media_release(a); dalnok_media_release(b) }
        let ta = dalnok_track_add(e, "A"), tb = dalnok_track_add(e, "B")
        dalnok_clip_add(e, ta, a, 0, 0, 0); dalnok_clip_add(e, tb, b, 0, 0, 0)
        #expect(abs(render(e, frames: 100).0[50] - 0.75) < 2e-4)
        dalnok_track_set_solo(e, tb, true)
        #expect(abs(render(e, frames: 100).0[50] - 0.5) < 2e-4, "only B")
        dalnok_track_set_solo(e, ta, true)
        #expect(abs(render(e, frames: 100).0[50] - 0.75) < 2e-4, "both soloed")
        dalnok_track_set_mute(e, ta, true)
        #expect(abs(render(e, frames: 100).0[50] - 0.5) < 2e-4, "mute beats solo")
        dalnok_undo(e); dalnok_undo(e); dalnok_undo(e)
        var info = DalnokTrackInfo(); dalnok_track_info(e, tb, &info)
        #expect(!info.solo && abs(render(e, frames: 100).0[50] - 0.75) < 2e-4, "undo clears solo")
        dalnok_track_set_solo(e, tb, true)
        dalnok_track_remove(e, tb)
        #expect(abs(render(e, frames: 100).0[50] - 0.25) < 2e-4, "removing the soloed track un-solos the rest")
    }

    @Test func soloOnTheLivePathIsSmoothed() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let a = makeMedia([dc(0.5, 48_000)]), b = makeMedia([dc(0.5, 48_000)])
        defer { dalnok_media_release(a); dalnok_media_release(b) }
        let ta = dalnok_track_add(e, "A"), tb = dalnok_track_add(e, "B")
        dalnok_clip_add(e, ta, a, 0, 0, 0); dalnok_clip_add(e, tb, b, 0, 0, 0)
        dalnok_transport_play(e)
        let before = pump(e, 2_048).0
        dalnok_track_set_solo(e, ta, true)
        let after = pump(e, 2_048).0
        #expect(maxStep([before.last!] + after) <= 0.5 / 256 * 1.05, "solo ramps, no click")
        #expect(abs(after.last! - 0.5) < 1e-3)
    }

    @Test func moveTrackReordersAndUndoes() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let ids = (1...4).map { dalnok_track_add(e, "T\($0)") }
        #expect(dalnok_track_move(e, ids[3], 0) == DALNOK_OK)
        #expect((0..<4).map { dalnok_track_at(e, Int32($0)) } == [ids[3], ids[0], ids[1], ids[2]])
        #expect(dalnok_track_move(e, ids[0], 9) == DALNOK_ERR_INVALID_ARG)
        dalnok_undo(e)
        #expect((0..<4).map { dalnok_track_at(e, Int32($0)) } == ids)
    }
}

@Suite struct MediaManagement {
    @Test func relinkBringsOfflineClipsBack() throws {
        let dir = tempDir()
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let audio = dir.appendingPathComponent("take.wav")
        let samples = try writeTestWav(audio, frames: 10_000)
        var m: OpaquePointer?
        dalnok_media_load(audio.path, sr, &m, nil, 0)
        let id = dalnok_pool_add(e, m, audio.path); dalnok_media_release(m)
        DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "A"), id, 0, 0, 0)
        let project = dir.appendingPathComponent("r.dalnok").path
        dalnok_project_save(e, project, nil, 0)
        let moved = dir.appendingPathComponent("elsewhere/take.wav")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: audio, to: moved)

        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        var missing: Int32 = 0
        dalnok_project_load(e2, project, &missing, nil, 0)
        #expect(missing == 1)
        let clip = clipInfo(e2, dalnok_track_clip_at(e2, dalnok_track_at(e2, 0), 0))
        var fresh: OpaquePointer?
        dalnok_media_load(moved.path, sr, &fresh, nil, 0)
        #expect(dalnok_pool_relink(e2, clip.media, fresh, moved.path, nil, 0) == DALNOK_OK)
        dalnok_media_release(fresh)
        #expect(!clipInfo(e2, clip.id).offline)
        expectClose(render(e2, frames: 10_000).0, samples, tol: 2e-4, "relinked audio plays")
        #expect(dalnok_pool_relink(e2, 999, fresh, "x", nil, 0) != DALNOK_OK)
    }

    @Test func saveCopyingMediaMakesProjectSelfContained() throws {
        let dir = tempDir()
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let lib = dir.appendingPathComponent("Library"), proj = dir.appendingPathComponent("Song")
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        // Two different files with the same name -> second gets " 2".
        let f1 = lib.appendingPathComponent("vox.wav"), f2 = lib.appendingPathComponent("x/vox.wav")
        try writeTestWav(f1, frames: 5_000, seed: 1)
        try writeTestWav(f2, frames: 5_000, seed: 2)
        for f in [f1, f2] {
            var m: OpaquePointer?
            dalnok_media_load(f.path, sr, &m, nil, 0)
            DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "T"), dalnok_pool_add(e, m, f.path), 0, 0, 0)
            dalnok_media_release(m)
        }
        let before = render(e, frames: 5_000)
        let project = proj.appendingPathComponent("Song.dalnok").path
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save_copying(e, project, true, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let copied = try FileManager.default.contentsOfDirectory(atPath: proj.appendingPathComponent("Audio Files").path).sorted()
        #expect(copied == ["vox 2.wav", "vox.wav"], "copied: \(copied)")
        // Saving again reuses the identical copies instead of duplicating.
        #expect(dalnok_project_save_copying(e, project, true, &err, 256) == DALNOK_OK)
        #expect(try FileManager.default.contentsOfDirectory(atPath: proj.appendingPathComponent("Audio Files").path).count == 2)
        // The project no longer depends on the library.
        try FileManager.default.removeItem(at: lib)
        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        var missing: Int32 = -1
        #expect(dalnok_project_load(e2, project, &missing, nil, 0) == DALNOK_OK && missing == 0)
        expectClose(render(e2, frames: 5_000).0, before.0, tol: 0, "identical after copying")
    }
}
