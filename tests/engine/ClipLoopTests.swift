// Clip loops: a looped clip repeats its window for its whole length (audio and MIDI); split, trim, save and unloop.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct ClipLoops {
    /// A 1,000-frame ramp saved as a 32-bit float WAV, on one track: sample k is (k + 1) / 1,000.
    func session() -> (OpaquePointer, DalnokClipId, URL) {
        let e = dalnok_engine_create(48_000)!
        let ramp = (0..<1_000).map { Float($0 + 1) / 1_000 }
        let dir = tempDir()
        let url = dir.appendingPathComponent("ramp.wav")
        var err = [CChar](repeating: 0, count: 256)
        let src = dalnok_engine_create(48_000)!
        let m = makeMedia([ramp, ramp]); defer { dalnok_media_release(m) }
        DalnokEngine.dalnok_clip_add(src, dalnok_track_add(src, "S"), dalnok_pool_add(src, m, ""), 0, 0, 0)
        _ = dalnok_render_to_wav(src, url.path, 0, 1_000, 32, &err, 256)
        dalnok_engine_destroy(src)
        var media: OpaquePointer?
        _ = dalnok_media_load(url.path, 48_000, &media, nil, 0)
        let c = DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "Loop"), dalnok_pool_add(e, media, url.path), 2_000, 0, 1_000)
        dalnok_media_release(media)
        return (e, c, dir)
    }
    func expectRamp(_ l: [Float], from: Int, frames: Int, phase: Int = 0, _ what: String) {
        var worst: Float = 0
        for k in 0..<frames { worst = max(worst, abs(l[from + k] - Float((phase + k) % 1_000 + 1) / 1_000)) }
        #expect(worst < 1e-6, "\(what): worst \(worst)")
    }

    @Test func audioLoopRepeatsSplitsTrimsAndSaves() throws {
        let (e, c, dir) = session(); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_clip_set_loop(e, c, true) == DALNOK_OK && undoName(e) == "Loop")
        #expect(dalnok_clip_set_region(e, c, 2_000, 0, 3_500) == DALNOK_OK, "a looped clip extends past its audio")
        var (l, _) = render(e, frames: 6_000)
        expectRamp(l, from: 2_000, frames: 3_500, "3.5 passes of the ramp")
        #expect(l[1_999] == 0 && l[5_500] == 0, "silent outside the clip")
        // Split mid-pass: the sound doesn't change.
        var right: DalnokClipId = 0
        #expect(dalnok_clip_split(e, c, 3_700, &right) == DALNOK_OK)
        #expect(right != 0 && clipInfo(e, right).loop_phase == 700 && clipInfo(e, right).loop_length == 1_000)
        (l, _) = render(e, frames: 6_000)
        expectRamp(l, from: 2_000, frames: 3_500, "after the split")
        // Save and reopen.
        let path = dir.appendingPathComponent("loop.dalnok").path
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let r = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(r) }
        var missing: Int32 = 0
        #expect(dalnok_project_load(r, path, &missing, &err, 256) == DALNOK_OK && missing == 0, "\(cstr(err))")
        (l, _) = render(r, frames: 6_000)
        expectRamp(l, from: 2_000, frames: 3_500, "reopened")
        // Trim the right piece's left edge by 250 frames: it keeps playing the loop where it was.
        #expect(dalnok_clip_set_region(e, right, 3_950, 0, 1_550) == DALNOK_OK && clipInfo(e, right).loop_phase == 950)
        (l, _) = render(e, frames: 6_000)
        expectRamp(l, from: 3_950, frames: 1_550, phase: 950, "trimmed left edge")
        #expect(l[3_800] == 0, "the trimmed part is silent")
        // Loop off: the piece plays its window once from its phase.
        #expect(dalnok_clip_set_loop(e, right, false) == DALNOK_OK)
        let info = clipInfo(e, right)
        #expect(info.loop_length == 0 && info.offset == 950 && info.length == 50, "\(info.offset) \(info.length)")
        #expect(dalnok_undo(e) && clipInfo(e, right).loop_length == 1_000, "undo turns the loop back on")
    }

    @Test func midiLoopRepeatsItsNotes() {
        // One quarter-note A4 at the start of a one-beat clip, looped to four beats: four onsets a beat apart.
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let c = dalnok_midi_clip_add(e, dalnok_track_add_instrument(e, nil), 0, 24_000)
        var note = DalnokNote(start: 0, length: 6_000, pitch: 69, velocity: 100)
        _ = dalnok_midi_clip_set_notes(e, c, &note, 1)
        #expect(dalnok_clip_set_loop(e, c, true) == DALNOK_OK)
        #expect(dalnok_clip_set_region(e, c, 0, 0, 96_000) == DALNOK_OK)
        let l = render(e, 0, 100_000)
        // An onset: the first sample above 0.01 after at least 100 ms below it.
        var onsets: [Int] = [], quietSince = -4_800
        for (i, v) in l.enumerated() {
            if abs(v) > 0.01 {
                if i - quietSince >= 4_800 { onsets.append(i) }
                quietSince = i
            }
        }
        let onTime = onsets.enumerated().allSatisfy { abs($0.element - $0.offset * 24_000) <= 240 }
        #expect(onsets.count == 4 && onTime, "onsets \(onsets)")
    }

    @Test func stretchedAudioAndSlotsRefuse() {
        let (e, c, _) = session(); defer { dalnok_engine_destroy(e) }
        _ = runCommand(e, "clip.setStretch", "{\"clip\":\(c),\"pitch\":2}")
        #expect(dalnok_clip_set_loop(e, c, true) != DALNOK_OK)
        #expect(runCommand(e, "clip.setLoop", "{\"clip\":\(c)}").0 == DALNOK_ERR_INVALID_ARG)
    }
}
