// Dalnok Sampler and Dalnok Drums: pitch, level, envelope, pads, state round trip (offline renders, numeric tolerances).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Writes mono samples as a 32-bit float WAV through the engine's own exporter and returns its path.
private func wav(_ x: [Float], _ name: String) -> String {
    let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
    let m = makeMedia([x, x]); defer { dalnok_media_release(m) }
    DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "S"), dalnok_pool_add(e, m, ""), 0, 0, 0)
    let path = tempDir().appendingPathComponent(name).path
    _ = dalnok_render_to_wav(e, path, 0, Int64(x.count), 32, nil, 0)
    return path
}

@Suite struct SamplerInstruments {
    func instrument(_ id: String) -> (OpaquePointer, DalnokTrackId, Int32, DalnokClipId) {
        let e = dalnok_engine_create(48_000)!
        let t = dalnok_track_add_instrument(e, "Inst")
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, "dalnok:\(id)", nil, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        let c = dalnok_midi_clip_add(e, t, 0, 96_000)
        return (e, t, slot, c)
    }

    @Test func samplerPlaysItsSampleAcrossTheKeyboard() throws {
        let sine = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let path = wav(sine, "a440.wav")
        let (e, _, slot, c) = instrument("sampler"); defer { dalnok_engine_destroy(e) }
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_set_sample(e, slot, 0, path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var out = [CChar](repeating: 0, count: 1_024)
        #expect(dalnok_plugin_sample_path(e, slot, 0, &out, 1_024) > 0 && cstr(out) == path)
        // Root 60: note 60 plays the sample at its pitch, 72 an octave up, at velocity 127 its level.
        var notes = [DalnokNote(start: 0, length: 12_000, pitch: 60, velocity: 127),
                     DalnokNote(start: 48_000, length: 12_000, pitch: 72, velocity: 127)]
        _ = dalnok_midi_clip_set_notes(e, c, &notes, 2)
        let l = render(e, 0, 96_000)
        #expect(abs(frequency(l[1_000..<11_000]) - 440) < 1, "root key: \(frequency(l[1_000..<11_000])) Hz")
        #expect(abs(frequency(l[49_000..<59_000]) - 880) < 2, "an octave up: \(frequency(l[49_000..<59_000])) Hz")
        let peak = l[2_000..<10_000].map { abs($0) }.max()!
        #expect(abs(peak - 0.5) < 0.01, "level \(peak)")
        // Note-off releases (50 ms default): silent 0.1 s after the note ends.
        #expect(l[17_000..<40_000].allSatisfy { abs($0) < 1e-6 })
        #expect(dalnok_plugin_set_sample(e, slot, 0, "/nonexistent/x.wav", &err, 256) != DALNOK_OK)
        #expect(dalnok_plugin_set_sample(e, slot, 1, path, &err, 256) != DALNOK_OK, "the Sampler has one zone")
    }

    @Test func drumPadsPlayTheirSamplesOnTheSample() throws {
        // Two "drums": a decaying click and a noise burst, on pads 0 (note 36) and 2 (note 38).
        let kick = (0..<4_800).map { Float(0.8 * exp(-Double($0) / 600) * sin(2 * Double.pi * 60 * Double($0) / 48_000)) }
        var seed: UInt32 = 1
        let snare = (0..<4_800).map { _ -> Float in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.3 }
        let (e, t, slot, c) = instrument("drums"); defer { dalnok_engine_destroy(e) }
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_set_sample(e, slot, 0, wav(kick, "kick.wav"), &err, 256) == DALNOK_OK)
        #expect(dalnok_plugin_set_sample(e, slot, 2, wav(snare, "snare.wav"), &err, 256) == DALNOK_OK)
        var notes = [DalnokNote(start: 1_000, length: 100, pitch: 36, velocity: 127),
                     DalnokNote(start: 13_000, length: 100, pitch: 38, velocity: 127),
                     DalnokNote(start: 25_000, length: 100, pitch: 37, velocity: 127)] // pad 1: empty
        _ = dalnok_midi_clip_set_notes(e, c, &notes, 3)
        let l = render(e, 0, 40_000)
        // One-shot from the exact frame: the rendered hit is the sample itself.
        #expect(l[0..<1_000].allSatisfy { $0 == 0 })
        let kickErr = (0..<4_800).map { abs(l[1_000 + $0] - kick[$0]) }.max()!, snareErr = (0..<4_800).map { abs(l[13_000 + $0] - snare[$0]) }.max()!
        let firstBad = (0..<4_800).first { abs(l[13_000 + $0] - snare[$0]) > 1e-4 } ?? -1
        #expect(kickErr < 1e-5 && snareErr < 1e-5, "kick \(kickErr), snare \(snareErr) from \(firstBad): \(firstBad >= 0 ? "\(l[13_000 + firstBad]) vs \(snare[firstBad]) next \(l[13_001 + firstBad]) vs \(firstBad + 1 < snare.count ? snare[firstBad + 1] : 0)" : "")")
        #expect(l[25_000..<30_000].allSatisfy { $0 == 0 }, "an empty pad is silent")
        // Saved and reopened: the kit comes back from the files it names.
        let dir = tempDir()
        let project = dir.appendingPathComponent("kit.dalnok").path
        #expect(dalnok_project_save(e, project, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let r = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(r) }
        var missing: Int32 = 0
        #expect(dalnok_project_load(r, project, &missing, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let again = render(r, 0, 40_000)
        #expect(zip(again, l).map { abs($0 - $1) }.max()! < 1e-6, "reopened kit renders the same")
        _ = t
    }
}

@Suite struct SliceToDrums {
    @Test func slicesReplayTheClipSampleForSample() throws {
        // Four decaying noise bursts at known frames, on an audio track at 10,000.
        var seed: UInt32 = 3
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
        var x = [Float](repeating: 0, count: 48_000)
        for at in [2_000, 14_000, 26_000, 38_000] { for k in 0..<6_000 { x[at + k] = 0.6 * noise() * Float(exp(-Double(k) / 800)) } }
        let path = tempDir().appendingPathComponent("loop.wav").path
        do {
            let w = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(w) }
            let m = makeMedia([x, x]); defer { dalnok_media_release(m) }
            DalnokEngine.dalnok_clip_add(w, dalnok_track_add(w, "S"), dalnok_pool_add(w, m, ""), 0, 0, 0)
            _ = dalnok_render_to_wav(w, path, 0, 48_000, 32, nil, 0)
        }
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var media: OpaquePointer?
        _ = dalnok_media_load(path, 48_000, &media, nil, 0)
        let t = dalnok_track_add(e, "Loop")
        let c = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, media, path), 10_000, 0, 0)
        dalnok_media_release(media)
        let (before, _) = render(e, frames: 60_000)
        var err = [CChar](repeating: 0, count: 256)
        let drums = dalnok_clip_slice_to_drums(e, c, &err, 256)
        #expect(drums != 0, "\(cstr(err))")
        #expect(dalnok_track_count(e) == 2 && dalnok_track_at(e, 1) == drums && clipInfo(e, c).muted && undoName(e) == "Slice to Drums")
        let mc = dalnok_track_clip_at(e, drums, 0)
        var notes = [DalnokNote](repeating: DalnokNote(), count: 16)
        let n = Int(dalnok_midi_clip_notes(e, mc, &notes, 16))
        #expect(n == 5, "a slice from the start, then one per hit (\(n): \(notes.prefix(n).map(\.start)))")
        #expect(notes.prefix(n).map(\.pitch) == (0..<n).map { UInt8(36 + $0) })
        let (after, _) = render(e, frames: 60_000)
        let worst = zip(before, after).map { abs($0 - $1) }.max()!
        #expect(worst < 1e-5, "the slices replay the clip (worst \(worst))")
        #expect(dalnok_undo(e) && dalnok_track_count(e) == 1 && !clipInfo(e, c).muted, "one undo")
    }
}
