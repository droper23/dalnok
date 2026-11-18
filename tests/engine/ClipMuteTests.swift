// Clip mute: audio, MIDI, launcher, undo, and project persistence.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct ClipMute {
    @Test func mutedAudioRevealsUnderlyingClipAndSurvivesUndoAndSave() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Audio")
        let bed = makeMedia([[Float](repeating: 0.25, count: 4_800)])
        let top = makeMedia([[Float](repeating: 0.75, count: 4_800)])
        defer { dalnok_media_release(bed); dalnok_media_release(top) }
        _ = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, bed, ""), 0, 0, 0)
        let clip = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, top, ""), 0, 0, 0)
        #expect(abs(render(e, 0, 1_000)[500] - 0.75) < 1e-6)
        #expect(dalnok_clip_set_muted(e, clip, true) == DALNOK_OK && dalnok_clip_muted(e, clip))
        #expect(abs(render(e, 0, 1_000)[500] - 0.25) < 1e-6, "muted top clip does not cover the audio underneath")
        #expect(dalnok_undo(e) && !dalnok_clip_muted(e, clip))
        #expect(abs(render(e, 0, 1_000)[500] - 0.75) < 1e-6)
        #expect(dalnok_redo(e) && dalnok_clip_muted(e, clip))
        let path = tempDir().appendingPathComponent("muted.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, path.path, &err, err.count) == DALNOK_OK)
        let doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect(doc["version"] as? Int == 12)
        let reopened = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(reopened) }
        #expect(dalnok_project_load(reopened, path.path, nil, &err, err.count) == DALNOK_OK)
        #expect(dalnok_clip_muted(reopened, clip))
        #expect(runCommand(reopened, "clip.setMuted", "{\"clip\":\(clip),\"muted\":false}").0 == DALNOK_OK)
        #expect(!dalnok_clip_muted(reopened, clip))
    }

    @Test func mutedMidiRemainsSilentAfterTheTrackIsUnmuted() {
        let (e, track, clip) = oneNoteSession(); defer { dalnok_engine_destroy(e) }
        #expect(render(e, 0, 24_000).contains { abs($0) > 0.001 })
        #expect(dalnok_track_set_mute(e, track, true) == DALNOK_OK)
        #expect(dalnok_clip_set_muted(e, clip, true) == DALNOK_OK)
        #expect(dalnok_track_set_mute(e, track, false) == DALNOK_OK)
        #expect(render(e, 0, 24_000).allSatisfy { abs($0) < 1e-7 })
        #expect(dalnok_clip_set_muted(e, clip, false) == DALNOK_OK)
        #expect(render(e, 0, 24_000).contains { abs($0) > 0.001 })
    }

    @Test func mutedLauncherSlotDoesNotPlayTheTimelineInstead() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Audio")
        let media = makeMedia([[Float](repeating: 0.5, count: 48_000)]); defer { dalnok_media_release(media) }
        let clip = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, media, ""), 0, 0, 0)
        let slot = dalnok_launcher_copy_clip(e, clip, 0)
        #expect(slot != 0 && dalnok_clip_set_muted(e, slot, true) == DALNOK_OK)
        #expect(dalnok_launcher_launch(e, t, 0) == DALNOK_OK)
        let out = pump(e, 4_096).0
        #expect(out.allSatisfy { abs($0) < 1e-7 }, "a muted playing slot remains silent instead of falling back to the timeline")
    }
}
