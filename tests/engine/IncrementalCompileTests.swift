// Incremental snapshot compilation (A-04): reused per-track content equals a fresh build.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import DalnokEngine

/// Deterministic generator so a failing seed reproduces.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct IncrementalCompile {
    /// A-04: the live snapshot reuses each track's clip content when its clips are unchanged. After every random
    /// edit, undo and redo, the reused content must equal a fresh build for every track.
    @Test(arguments: [1, 2, 3, 4] as [UInt64])
    func reusedContentMatchesFreshBuild(seed: UInt64) {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let mono = makeMedia([ramp(40_000)]); defer { dalnok_media_release(mono) }
        let stereo = makeMedia([ramp(40_000), ramp(40_000, scale: 0.5)]); defer { dalnok_media_release(stereo) }
        let audio = [dalnok_track_add(e, "A"), dalnok_track_add(e, "B"), dalnok_track_add(e, "C")]
        let keys = dalnok_track_add_instrument(e, "Keys")
        var clips: [DalnokClipId] = []
        for (i, t) in audio.enumerated() {
            for k in 0..<4 { clips.append(dalnok_clip_add(e, t, i == 1 ? stereo : mono, Int64(k) * 9_000, Int64(k) * 500, 6_000)) }
        }
        var midi: [DalnokClipId] = []
        for k in 0..<3 {
            let c = dalnok_midi_clip_add(e, keys, Int64(k) * 8_000, 8_000)
            var notes = (0..<6).map { DalnokNote(start: Int64($0) * 1_500, length: 2_500, pitch: UInt8(48 + $0), velocity: 90) }
            #expect(dalnok_midi_clip_set_notes(e, c, &notes, Int32(notes.count)) == DALNOK_OK)
            midi.append(c)
        }
        _ = dalnok_launcher_copy_clip(e, midi[0], 0)
        _ = dalnok_launcher_copy_clip(e, clips[0], 1)
        #expect(dalnok_engine_snapshot_mismatches(e) == 0)

        var rng = SplitMix(state: seed)
        let tracks = audio
        for step in 0..<300 {
            let all = clips + midi
            let c = all[Int.random(in: 0..<all.count, using: &rng)]
            switch Int.random(in: 0..<11, using: &rng) {
            case 0: var ids = [c]; _ = dalnok_clips_nudge(e, &ids, 1, Int64.random(in: -3_000...3_000, using: &rng))
            case 1:
                if !midi.contains(c) { _ = dalnok_clip_move(e, c, tracks[Int.random(in: 0..<tracks.count, using: &rng)], Int64.random(in: 0...60_000, using: &rng)) }
            case 2:
                var right: DalnokClipId = 0
                let info = clipInfo(e, c)
                if info.length > 2, dalnok_clip_split(e, c, info.start + info.length / 2, &right) == DALNOK_OK {
                    if midi.contains(c) { midi.append(right) } else { clips.append(right) }
                }
            case 3: _ = dalnok_clip_set_muted(e, c, Bool.random(using: &rng))
            case 4: _ = dalnok_clip_set_gain_db(e, c, Float.random(in: -12...6, using: &rng))
            case 5: _ = dalnok_clip_set_fades(e, c, Int64.random(in: 0...4_000, using: &rng), Int64.random(in: 0...4_000, using: &rng), DalnokFadeCurve(UInt32.random(in: 0...1, using: &rng)))
            case 6:
                let info = clipInfo(e, c)
                _ = dalnok_clip_set_region(e, c, info.start, Int64.random(in: 0...2_000, using: &rng), Int64.random(in: 1_000...8_000, using: &rng))
            case 7:
                if !midi.contains(c) { _ = dalnok_clip_set_stretch(e, c, 5_000, 1.25, 0, true); _ = dalnok_engine_poll_jobs(e) }
            case 8: _ = dalnok_undo(e)
            case 9: _ = dalnok_redo(e)
            default: _ = dalnok_track_set_gain_db(e, tracks[0], Float.random(in: -12...0, using: &rng)) // non-structural
            }
            let mismatches = dalnok_engine_snapshot_mismatches(e)
            #expect(mismatches == 0, "seed \(seed) step \(step): \(mismatches) tracks differ")
            if mismatches != 0 { return }
        }
        // Finished stretches change the snapshot without a model edit.
        while dalnok_engine_poll_jobs(e) > 0 { usleep(1_000) }
        #expect(dalnok_engine_snapshot_mismatches(e) == 0)
    }
}
