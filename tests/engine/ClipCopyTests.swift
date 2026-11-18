// Copy / paste / duplicate of clips (API 26).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

struct ClipCopy {
    @Test func copiesKeepEveryAttributeAndRenderIdentically() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B"), inst = dalnok_track_add_instrument(e, "Keys")
        let url = tempDir().appendingPathComponent("src.wav")
        _ = try writeTestWav(url, frames: 9_600)
        var media: OpaquePointer?
        #expect(dalnok_media_load(url.path, 48_000, &media, nil, 0) == DALNOK_OK)
        let clip = DalnokEngine.dalnok_clip_add(e, a, dalnok_pool_add(e, media!, url.path), 1_000, 200, 4_800)
        dalnok_media_release(media)
        dalnok_clip_set_fades(e, clip, 300, 500, DALNOK_FADE_EQUAL_POWER)
        dalnok_clip_set_gain_db(e, clip, -6)
        let midi = dalnok_midi_clip_add(e, inst, 50_000, 9_600) // clear of the audio comparison window
        var notes = [DalnokNote(start: 0, length: 2_400, pitch: 60, velocity: 100), DalnokNote(start: 4_800, length: 2_400, pitch: 64, velocity: 90)]
        dalnok_midi_clip_set_notes(e, midi, &notes, 2)

        // Duplicate right after itself on the same track: same audio, shifted by the clip's length.
        var out = [DalnokClipId](repeating: 0, count: 2)
        #expect(dalnok_clips_copy(e, [clip], 1, 5_800, 0, &out, 2) == 1)
        let copy = clipInfo(e, out[0]), orig = clipInfo(e, clip)
        #expect(undoName(e) == "Paste Clip")
        #expect(copy.track == a && copy.start == 5_800 && copy.offset == orig.offset && copy.length == orig.length && copy.media == orig.media)
        #expect(copy.fade_in == 300 && copy.fade_out == 500 && copy.fade_curve == 1 && abs(copy.gain_db - -6) < 1e-6)
        var l = [Float](repeating: 0, count: 12_000), r = l
        _ = dalnok_render_offline(e, 0, 12_000, &l, &r)
        for i in 0..<4_800 { #expect(abs(l[1_000 + i] - l[5_800 + i]) < 1e-6) } // tolerance: bit-identical render expected
        // Paste one track down; a MIDI clip pasted onto an audio track is refused and nothing changes.
        #expect(dalnok_clips_copy(e, [clip], 1, 0, 1, &out, 2) == 1 && clipInfo(e, out[0]).track == b)
        let before = dalnok_track_clip_at(e, b, 1)
        #expect(dalnok_clips_copy(e, [midi], 1, 0, -1, &out, 2) == 0 && dalnok_track_clip_at(e, b, 1) == before)
        // MIDI copy keeps its notes; editing the copy leaves the original alone.
        #expect(dalnok_clips_copy(e, [midi], 1, 60_000, 0, &out, 2) == 1)
        var got = [DalnokNote](repeating: DalnokNote(), count: 4)
        #expect(dalnok_midi_clip_notes(e, out[0], &got, 4) == 2 && got[1].pitch == 64)
        var one = [DalnokNote(start: 0, length: 100, pitch: 72, velocity: 100)]
        dalnok_midi_clip_set_notes(e, out[0], &one, 1)
        #expect(dalnok_midi_clip_notes(e, midi, &got, 4) == 2)
        #expect(dalnok_undo(e) && dalnok_midi_clip_notes(e, out[0], &got, 4) == 2, "undo restores the copy's notes")
    }

    @Test func multiClipPasteKeepsSpacingAndIsOneUndoStep() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let a = dalnok_track_add(e, "A")
        let url = tempDir().appendingPathComponent("s.wav")
        _ = try writeTestWav(url, frames: 4_800)
        var media: OpaquePointer?
        dalnok_media_load(url.path, 48_000, &media, nil, 0)
        let pool = dalnok_pool_add(e, media!, url.path)
        dalnok_media_release(media)
        let c1 = DalnokEngine.dalnok_clip_add(e, a, pool, 1_000, 0, 1_000)
        let c2 = DalnokEngine.dalnok_clip_add(e, a, pool, 3_500, 0, 1_000)
        var out = [DalnokClipId](repeating: 0, count: 2)
        #expect(dalnok_clips_copy(e, [c1, c2], 2, 10_000, 0, &out, 2) == 2 && undoName(e) == "Paste Clips")
        #expect(clipInfo(e, out[0]).start == 10_000 && clipInfo(e, out[1]).start == 12_500)
        #expect(dalnok_clips_copy(e, [c1, c1], 2, 0, 0, nil, 0) == 0, "duplicate ids are refused")
        #expect(dalnok_undo(e))
        #expect(clipInfo(e, out[0]).id == 0 && clipInfo(e, out[1]).id == 0, "one undo removes both copies")
        #expect(clipInfo(e, c1).start == 1_000)
    }
}

struct Clipboard {
    @Test func cutThenPasteWorksAfterTheSourceIsGoneAndKeepsLayout() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B"), c = dalnok_track_add(e, "C")
        let url = tempDir().appendingPathComponent("s.wav")
        _ = try writeTestWav(url, frames: 4_800)
        var media: OpaquePointer?
        dalnok_media_load(url.path, 48_000, &media, nil, 0)
        let pool = dalnok_pool_add(e, media!, url.path)
        dalnok_media_release(media)
        let c1 = DalnokEngine.dalnok_clip_add(e, a, pool, 2_000, 0, 1_000)
        let c2 = DalnokEngine.dalnok_clip_add(e, b, pool, 2_600, 100, 1_000)
        #expect(dalnok_clipboard_copy(e, [c1, c2], 2) == DALNOK_OK && dalnok_clipboard_count(e) == 2)
        #expect(dalnok_clips_remove(e, [c1, c2], 2) == DALNOK_OK) // cut
        var out = [DalnokClipId](repeating: 0, count: 2)
        #expect(dalnok_clipboard_paste(e, b, 10_000, &out, 2) == 2 && undoName(e) == "Paste Clips")
        let p1 = clipInfo(e, out[0]), p2 = clipInfo(e, out[1])
        #expect(p1.track == b && p1.start == 10_000 && p2.track == c && p2.start == 10_600 && p2.offset == 100, "spacing and rows kept")
        #expect(dalnok_clipboard_paste(e, c, 0, nil, 0) == 0, "no track below C: refused")
        #expect(dalnok_clipboard_count(e) == 2, "the clipboard is not consumed by pasting")
        #expect(dalnok_undo(e) && clipInfo(e, out[0]).id == 0)
    }
}

struct DuplicateTrack {
    @Test func duplicateCopiesSettingsAndClipsAndRendersTheSame() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let a = dalnok_track_add(e, "Gtr")
        let url = tempDir().appendingPathComponent("g.wav")
        _ = try writeTestWav(url, frames: 4_800)
        var media: OpaquePointer?
        dalnok_media_load(url.path, 48_000, &media, nil, 0)
        let clip = DalnokEngine.dalnok_clip_add(e, a, dalnok_pool_add(e, media!, url.path), 100, 0, 4_000)
        dalnok_media_release(media)
        dalnok_clip_set_gain_db(e, clip, -3)
        dalnok_track_set_gain_db(e, a, -6)
        dalnok_track_set_pan(e, a, -0.5)
        var single = [Float](repeating: 0, count: 4_800), sr = single
        _ = dalnok_render_offline(e, 0, 4_800, &single, &sr)
        let b = dalnok_track_duplicate(e, a)
        #expect(b != 0 && undoName(e) == "Duplicate Track" && dalnok_track_count(e) == 2 && dalnok_track_at(e, 1) == b)
        var info = DalnokTrackInfo()
        dalnok_track_info(e, b, &info)
        #expect(name(info.name) == "Gtr copy" && abs(info.gain_db - -6) < 1e-6 && abs(info.pan - -0.5) < 1e-6)
        let copy = clipInfo(e, dalnok_track_clip_at(e, b, 0))
        #expect(copy.id != clip && copy.start == 100 && copy.length == 4_000 && abs(copy.gain_db - -3) < 1e-6)
        var both = [Float](repeating: 0, count: 4_800), br = both
        _ = dalnok_render_offline(e, 0, 4_800, &both, &br)
        let worst = zip(both, single).map { abs($0 - 2 * $1) }.max() ?? 1
        #expect(worst < 1e-5, "two identical tracks sum to exactly twice one (worst \(worst))")
        #expect(dalnok_undo(e) && dalnok_track_count(e) == 1)
        _ = dalnok_render_offline(e, 0, 4_800, &both, &br)
        #expect(both == single, "undo removes the copy and its clips")
    }
}
