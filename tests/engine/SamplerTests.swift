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

/// Dalnok Sampler's loop, low-pass, glide and mono mode (the 808 workflow).
@Suite struct SamplerShaping {
    /// A Sampler holding `sample` (root 60) with parameters by plain value (choices and toggles by normalized value).
    func sampler(_ sample: [Float], _ name: String, _ values: [UInt32: Double] = [:], normalized: [UInt32: Double] = [:],
                 notes: [DalnokNote]) -> OpaquePointer {
        let e = dalnok_engine_create(48_000)!
        let t = dalnok_track_add_instrument(e, "S")
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, "dalnok:sampler", nil, &err, 256)
        #expect(slot != 0 && dalnok_plugin_set_sample(e, slot, 0, wav(sample, name), &err, 256) == DALNOK_OK, "\(cstr(err))")
        for (pid, plain) in values {
            var lo = 0.0, hi = 1.0
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                var buf = [CChar](repeating: 0, count: 64)
                _ = dalnok_plugin_parameter_text(e, slot, pid, mid, &buf, 64)
                if (Double(cstr(buf)) ?? 0) < plain { lo = mid } else { hi = mid }
            }
            _ = dalnok_plugin_set_parameter(e, slot, pid, hi)
        }
        for (pid, v) in normalized { _ = dalnok_plugin_set_parameter(e, slot, pid, v) }
        let c = dalnok_midi_clip_add(e, t, 0, 192_000)
        var n = notes
        _ = dalnok_midi_clip_set_notes(e, c, &n, Int32(n.count))
        return e
    }
    let held = [DalnokNote(start: 0, length: 48_000, pitch: 60, velocity: 127)]
    func power(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)) }

    @Test func loopSustainsWhileTheNoteIsHeld() {
        let short = (0..<4_800).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) } // 44 whole cycles
        let plain = sampler(short, "loop0.wav", notes: held); defer { dalnok_engine_destroy(plain) }
        let a = render(plain, 0, 60_000)
        #expect(a[10_000..<40_000].allSatisfy { abs($0) < 1e-6 }, "without a loop the 0.1 s sample ends")
        let looped = sampler(short, "loop1.wav", normalized: [10: 1], notes: held); defer { dalnok_engine_destroy(looped) }
        let b = render(looped, 0, 60_000)
        #expect(abs(frequency(b[30_000..<40_000]) - 440) < 1, "looping: \(frequency(b[30_000..<40_000])) Hz")
        let peak = b[30_000..<40_000].map { abs($0) }.max()!
        #expect(abs(peak - 0.5) < 0.01, "level held: \(peak)")
        #expect(b[52_000..<60_000].allSatisfy { abs($0) < 1e-6 }, "note-off still releases (50 ms)")
        // A loop over the second half with a crossfade: still sounds, no click larger than a sine step at the seam.
        let half = sampler(short, "loop2.wav", [11: 50, 13: 20], normalized: [10: 1], notes: held); defer { dalnok_engine_destroy(half) }
        let c = render(half, 0, 48_000)
        let maxStep = zip(c[5_000..<40_000], c[5_001..<40_001]).map { abs($0 - $1) }.max()!
        #expect(maxStep < 0.05, "smooth across the loop seam: \(maxStep)")
        #expect(power(c[30_000..<40_000]) > 0.3, "still sounding: \(power(c[30_000..<40_000]))")
    }

    @Test func lowPassCutsHighs() {
        let bright = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 5_000 * Double($0) / 48_000)) }
        let open = sampler(bright, "lp0.wav", notes: held); defer { dalnok_engine_destroy(open) }
        let closed = sampler(bright, "lp1.wav", [14: 500], notes: held); defer { dalnok_engine_destroy(closed) }
        let a = power(render(open, 0, 40_000)[10_000..<40_000]), b = power(render(closed, 0, 40_000)[10_000..<40_000])
        #expect(abs(a - 0.5 / 2.squareRoot()) < 0.01, "wide open passes: \(a)")
        #expect(20 * log10(b / a) < -30, "5 kHz through a 500 Hz low-pass: \(20 * log10(b / a)) dB")
    }

    @Test func monoGlideSlidesBetweenNotes() {
        let tone = (0..<96_000).map { Float(0.5 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
        // Overlapping notes (legato) a fifth apart... an octave: 60 → 72, glide 100 ms, mono.
        let notes = [DalnokNote(start: 0, length: 30_000, pitch: 60, velocity: 127),
                     DalnokNote(start: 24_000, length: 24_000, pitch: 72, velocity: 127)]
        let e = sampler(tone, "glide.wav", [16: 100], normalized: [17: 1], notes: notes); defer { dalnok_engine_destroy(e) }
        let l = render(e, 0, 48_000)
        #expect(abs(frequency(l[14_000..<23_000]) - 220) < 1, "first note: \(frequency(l[14_000..<23_000]))")
        let mid = frequency(l[24_200..<25_600])
        #expect(mid > 240 && mid < 420, "on the way: \(mid) Hz")
        #expect(abs(frequency(l[36_000..<47_000]) - 440) < 1.5, "arrived: \(frequency(l[36_000..<47_000]))")
        let peak = l[26_000..<47_000].map { abs($0) }.max()!
        #expect(abs(peak - 0.5) < 0.02, "one voice, not two: \(peak)")
        // Poly without glide: the overlap is two voices.
        let p = sampler(tone, "poly.wav", notes: notes); defer { dalnok_engine_destroy(p) }
        let q = render(p, 0, 48_000)
        #expect(q[24_500..<29_000].map { abs($0) }.max()! > 0.8, "poly overlaps")
        #expect(abs(frequency(q[31_000..<47_000]) - 440) < 1.5, "poly jumps: \(frequency(q[31_000..<47_000]))")
    }
}
private func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count)) }

@Suite struct DalnokSynth {
    /// An instrument track with Dalnok Synth set by plain values (and choices by normalized value).
    func synth(_ values: [UInt32: Double], normalized: [UInt32: Double] = [:], notes: [DalnokNote]) -> OpaquePointer {
        let e = dalnok_engine_create(48_000)!
        let t = dalnok_track_add_instrument(e, "Synth")
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, "dalnok:synth", nil, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        for (pid, plain) in values {
            var lo = 0.0, hi = 1.0
            for _ in 0..<60 {
                let mid = (lo + hi) / 2
                var buf = [CChar](repeating: 0, count: 64)
                _ = dalnok_plugin_parameter_text(e, slot, pid, mid, &buf, 64)
                if (Double(cstr(buf)) ?? 0) < plain { lo = mid } else { hi = mid }
            }
            _ = dalnok_plugin_set_parameter(e, slot, pid, hi)
        }
        for (pid, v) in normalized { _ = dalnok_plugin_set_parameter(e, slot, pid, v) }
        let c = dalnok_midi_clip_add(e, t, 0, 192_000)
        var n = notes
        _ = dalnok_midi_clip_set_notes(e, c, &n, Int32(n.count))
        return e
    }

    @Test func pitchLevelFilterAndRelease() {
        // Sine, no detune, filter wide open and no filter envelope: A4 at 440 Hz, level -6 dB × sustain 70 %.
        let a = synth([1: 0, 3: 20_000, 5: 0], normalized: [0: 1], notes: [DalnokNote(start: 0, length: 48_000, pitch: 69, velocity: 127)])
        defer { dalnok_engine_destroy(a) }
        let l = render(a, 0, 96_000)
        #expect(abs(frequency(l[20_000..<44_000]) - 440) < 1, "\(frequency(l[20_000..<44_000])) Hz")
        let peak = l[30_000..<44_000].map { abs($0) }.max()!
        #expect(abs(peak - 0.5 * Float(pow(10, -6.0 / 20)) * 0.7) < 0.01, "sustain level \(peak)")
        #expect(l[60_000..<96_000].allSatisfy { abs($0) < 1e-4 }, "released (200 ms) to silence")
        // A 110 Hz saw through a 400 Hz low-pass: its 36th harmonic (3,960 Hz, a decade up) drops over 30 dB (12 dB/octave).
        func harmonic(_ cutoff: Double) -> Double {
            let e = synth([1: 0, 3: cutoff, 5: 0], notes: [DalnokNote(start: 0, length: 48_000, pitch: 45, velocity: 127)])
            defer { dalnok_engine_destroy(e) }
            let x = render(e, 0, 48_000)
            var s = 0.0, c = 0.0
            for i in 10_000..<40_000 { let ph = 2 * Double.pi * 3_960 * Double(i) / 48_000; s += Double(x[i]) * sin(ph); c += Double(x[i]) * cos(ph) }
            return sqrt(s * s + c * c)
        }
        let cut = 20 * log10(harmonic(400) / harmonic(20_000))
        #expect(cut < -30, "the filter cuts the 36th harmonic by \(cut) dB")
    }

    @Test func pitchEnvelopeAndMonoGlide() {
        // Pitch envelope: 12 semitones falling over 50 ms: the start is an octave up, later it settles.
        let p = synth([1: 0, 3: 20_000, 5: 0, 12: 12, 13: 50], normalized: [0: 1], notes: [DalnokNote(start: 0, length: 48_000, pitch: 57, velocity: 127)])
        defer { dalnok_engine_destroy(p) }
        let lp = render(p, 0, 48_000)
        #expect(frequency(lp[0..<2_400]) > 330 && abs(frequency(lp[24_000..<48_000]) - 220) < 1, "\(frequency(lp[0..<2_400])) then \(frequency(lp[24_000..<48_000]))")
        // Mono with 300 ms glide: the second note slides up from the first.
        let g = synth([1: 0, 3: 20_000, 5: 0, 11: 300], normalized: [0: 1, 15: 1],
                      notes: [DalnokNote(start: 0, length: 48_000, pitch: 57, velocity: 127), DalnokNote(start: 48_000, length: 48_000, pitch: 69, velocity: 127)])
        defer { dalnok_engine_destroy(g) }
        let lg = render(g, 0, 96_000)
        let mid = frequency(lg[49_000..<52_000]), settled = frequency(lg[80_000..<96_000])
        #expect(mid > 225 && mid < 430 && abs(settled - 440) < 1, "mid-glide \(mid) Hz, then \(settled)")
    }
}
