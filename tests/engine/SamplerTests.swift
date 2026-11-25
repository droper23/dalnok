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
        #expect(dalnok_plugin_set_sample(e, slot, 16, path, &err, 256) != DALNOK_OK, "the Sampler has 16 zones")
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

@Suite struct SamplerZones {
    /// A sine at MIDI note `root`'s pitch, at `amp`, two seconds.
    func tone(_ root: Int, _ amp: Double) -> [Float] {
        let f = 440 * pow(2, Double(root - 69) / 12)
        return (0..<96_000).map { Float(amp * sin(2 * Double.pi * f * Double($0) / 48_000)) }
    }
    func sampler() -> (OpaquePointer, Int32, DalnokClipId) {
        let e = dalnok_engine_create(48_000)!
        let t = dalnok_track_add_instrument(e, "S")
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, "dalnok:sampler", nil, &err, 256)
        _ = dalnok_plugin_set_parameter(e, slot, 8, 0) // velocity sensitivity off: level is the zone's own
        return (e, slot, dalnok_midi_clip_add(e, t, 0, 960_000))
    }
    func map(_ e: OpaquePointer, _ slot: Int32, _ files: [String]) -> (Int32, String) {
        var err = [CChar](repeating: 0, count: 512)
        let ptrs = files.map { strdup($0) }; defer { ptrs.forEach { free($0) } }
        let n = ptrs.map { UnsafePointer($0) }.withUnsafeBufferPointer { dalnok_plugin_map_samples(e, slot, $0.baseAddress, Int32(files.count), &err, 512) }
        return (n, cstr(err))
    }
    func zone(_ e: OpaquePointer, _ slot: Int32, _ z: Int32) -> [Int32] {
        var m = DalnokSampleZone()
        #expect(dalnok_plugin_sample_zone(e, slot, z, &m))
        return [m.lo, m.hi, m.root, m.vlo, m.vhi]
    }
    /// Plays `notes` (pitch, velocity) a quarter second each, a half second apart; returns each one's frequency and peak.
    func play(_ e: OpaquePointer, _ c: DalnokClipId, _ notes: [(Int, Int)]) -> [(Double, Float)] {
        var list = notes.enumerated().map { DalnokNote(start: Int64($0.offset * 24_000), length: 12_000, pitch: UInt8($0.element.0), velocity: UInt8($0.element.1)) }
        _ = dalnok_midi_clip_set_notes(e, c, &list, Int32(list.count))
        let l = render(e, 0, notes.count * 24_000)
        return notes.indices.map { i in
            let s = l[(i * 24_000 + 1_000)..<(i * 24_000 + 11_000)]
            return (frequency(s), s.map { abs($0) }.max()!)
        }
    }

    @Test func filesMapByTheNoteNamesInTheirNames() {
        let (e, slot, c) = sampler(); defer { dalnok_engine_destroy(e) }
        // Given out of order: C5 (72), C4 (60), C6 (84), with levels 0.4, 0.2, 0.6 so the zone playing is audible.
        let files = [wav(tone(72, 0.4), "Keys_C5.wav"), wav(tone(60, 0.2), "Keys C4.wav"), wav(tone(84, 0.6), "Keys-C6.wav")]
        #expect(map(e, slot, files) == (3, ""))
        // Sorted by root; each reaches halfway to its neighbours.
        #expect(zone(e, slot, 0) == [0, 66, 60, 1, 127])
        #expect(zone(e, slot, 1) == [67, 78, 72, 1, 127])
        #expect(zone(e, slot, 2) == [79, 127, 84, 1, 127])
        #expect(zone(e, slot, 3) == [0, 127, -1, 1, 127], "an unused zone keeps the default map")
        let notes = [(48, 100), (66, 100), (67, 100), (78, 100), (79, 100), (96, 100)]
        let heard = play(e, c, notes)
        let levels: [Float] = [0.2, 0.2, 0.4, 0.4, 0.6, 0.6]
        for (i, (f, peak)) in heard.enumerated() {
            let want = 440 * pow(2, Double(notes[i].0 - 69) / 12)
            #expect(abs(f / want - 1) < 0.005, "note \(notes[i].0): \(f) Hz, want \(want)")
            #expect(abs(peak - levels[i]) < 0.01, "note \(notes[i].0): level \(peak), want \(levels[i])")
        }
    }

    @Test func layersOnOneNoteSplitTheVelocities() {
        let (e, slot, c) = sampler(); defer { dalnok_engine_destroy(e) }
        let files = [wav(tone(36, 0.25), "Snare C2 soft.wav"), wav(tone(36, 0.75), "Snare C2 hard.wav")]
        #expect(map(e, slot, files).0 == 2)
        #expect(zone(e, slot, 0) == [0, 127, 36, 1, 63])
        #expect(zone(e, slot, 1) == [0, 127, 36, 64, 127])
        let heard = play(e, c, [(36, 40), (36, 63), (36, 64), (36, 127)])
        #expect(heard.map { abs($0.1 - 0.25) < 0.01 } == [true, true, false, false], "\(heard.map(\.1))")
        #expect(heard.map { abs($0.1 - 0.75) < 0.01 } == [false, false, true, true], "\(heard.map(\.1))")
    }

    @Test func unnamedFilesGoOnePerKeyUnlessOthersAreNamed() {
        let (e, slot, _) = sampler(); defer { dalnok_engine_destroy(e) }
        let a = wav(tone(60, 0.3), "hit one.wav"), b = wav(tone(60, 0.3), "hit two.wav")
        #expect(map(e, slot, [a, b]) == (2, ""))
        #expect(zone(e, slot, 0) == [60, 60, 60, 1, 127] && zone(e, slot, 1) == [61, 61, 61, 1, 127])
        // Mixed with a named file: the unnamed one is skipped (and named), the earlier zones cleared.
        let (n, err) = map(e, slot, [a, wav(tone(57, 0.3), "Bass A3.wav")])
        #expect(n == 1 && err.contains("hit one.wav"), "\(err)")
        #expect(zone(e, slot, 0) == [0, 127, 57, 1, 127])
        var out = [CChar](repeating: 0, count: 1_024)
        #expect(dalnok_plugin_sample_path(e, slot, 1, &out, 1_024) == 0, "zone 1 cleared")
        // Names that only look like notes don't count; flats, sharps and negative octaves do.
        #expect(map(e, slot, [wav(tone(60, 0.3), "Bass 01.wav"), wav(tone(60, 0.3), "Ebb-1.wav")]).0 == 2)
        #expect(zone(e, slot, 0)[2] == 60, "neither names a note: one per key")
        _ = map(e, slot, [wav(tone(61, 0.3), "Pad Db4.wav"), wav(tone(66, 0.3), "Pad F#4.wav"), wav(tone(1, 0.3), "Sub C#-1.wav")])
        #expect([zone(e, slot, 0)[2], zone(e, slot, 1)[2], zone(e, slot, 2)[2]] == [1, 61, 66])
    }

    @Test func handMadeZonesSaveAndReopen() throws {
        let (e, slot, c) = sampler(); defer { dalnok_engine_destroy(e) }
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_set_sample(e, slot, 0, wav(tone(60, 0.3), "low.wav"), &err, 256) == DALNOK_OK)
        #expect(dalnok_plugin_set_sample(e, slot, 1, wav(tone(72, 0.5), "high.wav"), &err, 256) == DALNOK_OK)
        // Ranges given backwards are put in order; a root out of range means the Root Key parameter.
        var low = DalnokSampleZone(lo: 59, hi: 0, root: 60, vlo: 1, vhi: 127), high = DalnokSampleZone(lo: 60, hi: 127, root: 72, vlo: 1, vhi: 127)
        #expect(dalnok_plugin_set_sample_zone(e, slot, 0, &low, &err, 256) == DALNOK_OK)
        #expect(dalnok_plugin_set_sample_zone(e, slot, 1, &high, &err, 256) == DALNOK_OK)
        #expect(dalnok_plugin_set_sample_zone(e, slot, 16, &high, &err, 256) != DALNOK_OK)
        #expect(zone(e, slot, 0) == [0, 59, 60, 1, 127])
        let before = play(e, c, [(55, 127), (65, 127)])
        #expect(abs(before[0].1 - 0.3) < 0.01 && abs(before[1].1 - 0.5) < 0.01, "\(before)")
        let project = tempDir().appendingPathComponent("zones.dalnok").path
        #expect(dalnok_project_save(e, project, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let r = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(r) }
        var missing: Int32 = 0
        #expect(dalnok_project_load(r, project, &missing, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let a = render(e, 0, 48_000), b = render(r, 0, 48_000)
        #expect(zip(a, b).map { abs($0 - $1) }.max()! < 1e-6, "the reopened Sampler plays the same zones")
    }
}
