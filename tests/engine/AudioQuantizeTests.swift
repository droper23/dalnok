// Audio quantize (API 47): transient detection accuracy and quantized timing, measured on rendered output.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Drum-like hits: a sharp attack (0.3 ms rise) on a decaying tone plus a noise click, over a quiet noise floor.
private func hits(at starts: [Int], frames: Int, rate: Double = 48_000) -> [Float] {
    var x = [Float](repeating: 0, count: frames)
    var seed: UInt32 = 12_345
    func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
    for i in 0..<frames { x[i] = 0.0005 * noise() } // about -66 dBFS of hiss
    for (k, s) in starts.enumerated() {
        let hz = 180.0 + 40.0 * Double(k % 3)
        for i in 0..<Int(rate * 0.18) where s + i < frames {
            let t = Double(i) / rate
            let attack = min(1, t / 0.0003), decay = exp(-t / 0.035)
            let v = attack * decay * (0.6 * sin(2 * .pi * hz * t) + 0.25 * Double(noise()) * exp(-t / 0.004))
            x[s + i] += Float(v)
        }
    }
    return x
}

/// Attack starts in rendered audio: the first sample above 0.1 whose preceding 40 ms (up to 2 ms before it, the rise)
/// stay below 0.02.
private func attacks(_ x: [Float], rate: Double = 48_000) -> [Int] {
    var out: [Int] = []
    let quiet = Int(rate * 0.04), rise = Int(rate * 0.002)
    var i = quiet
    while i < x.count {
        if abs(x[i]) > 0.1, x[(i - quiet)..<(i - rise)].allSatisfy({ abs($0) < 0.02 }) {
            out.append(i)
            i += quiet
        } else { i += 1 }
    }
    return out
}

@Suite struct AudioQuantizeTests {
    let rate = 48_000.0
    let beat = 24_000 // 120 BPM
    func session(_ samples: [Float], start: Int64 = 0) -> (OpaquePointer, DalnokTrackId, DalnokClipId) {
        let e = dalnok_engine_create(rate)!
        _ = dalnok_tempo_set(e, 120, 4, 4)
        let t = dalnok_track_add(e, "Drums")
        let m = samples.withUnsafeBufferPointer { b -> OpaquePointer in
            var p: UnsafePointer<Float>? = b.baseAddress
            return dalnok_media_from_samples(&p, 1, Int64(samples.count), rate)!
        }
        let c = dalnok_clip_add(e, t, m, start, 0, Int64(samples.count))
        dalnok_media_release(m)
        return (e, t, c)
    }

    @Test func transientsAreFoundWithinAMillisecond() {
        let truth = [3_000, 14_400, 27_100, 37_000, 49_900, 61_150, 72_800, 85_300]
        let (e, _, c) = session(hits(at: truth, frames: 100_000)); defer { dalnok_engine_destroy(e) }
        var out = [Int64](repeating: 0, count: 64)
        let n = Int(dalnok_audio_transients(e, c, 0.5, &out, 64))
        #expect(n == truth.count, "found \(Array(out.prefix(n))) for \(truth)")
        for (found, real) in zip(out.prefix(n), truth) {
            #expect(abs(Int(found) - real) <= 48, "transient at \(found), real attack at \(real) (±1 ms)")
        }
    }

    @Test func quietOrSteadyAudioHasNoFalseTransients() {
        let steady = (0..<96_000).map { Float(0.4 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
        let (e, _, c) = session(steady); defer { dalnok_engine_destroy(e) }
        var tr = [Int64](repeating: 0, count: 64)
        let n = Int(dalnok_audio_transients(e, c, 0.5, &tr, 64))
        #expect(n <= 1, "a held tone has at most its start (\(tr.prefix(max(0, n))))")
    }

    @Test func hitsLandOnTheGridAndTheRestIsUnchanged() throws {
        // Eighth notes (12,000 frames) played up to ±30 ms off the grid.
        let jitter = [0, 900, -1_100, 1_400, -600, 1_200, -1_300, 700, -900, 0]
        let grid = (1...10).map { $0 * 12_000 }
        let truth = zip(grid, jitter).map { $0 + $1 }
        let total = 132_000
        let source = hits(at: truth, frames: total)
        let (e, t, c) = session(source); defer { dalnok_engine_destroy(e) }
        var ids = [DalnokClipId](repeating: 0, count: 64)
        let n = Int(dalnok_audio_quantize(e, c, 0.5, 1, 0.5, &ids, 64))
        #expect(n > truth.count && n <= 2 * (truth.count + 1), "a slice before the first hit and one per hit, each a head and maybe a tail (\(n))")
        #expect(undoName(e) == "Quantize Audio")
        let infos = ids.prefix(n).map { clipInfo(e, $0) }
        #expect(infos.first?.start == 0 && abs((infos.map { $0.start + $0.length }.max() ?? 0) - Int64(total)) <= 120,
                "the clip keeps its start and end (\(infos.first?.start ?? -1), \(infos.map { $0.start + $0.length }.max() ?? -1))")
        #expect(infos.allSatisfy { $0.rate >= 0.5 && $0.rate <= 2 })
        #expect(infos.contains { abs($0.rate - 1) < 1e-12 }, "hits already on the grid are not stretched")
        var l = [Float](repeating: 0, count: total), r = l
        #expect(dalnok_render_offline(e, 0, Int64(total), &l, &r) == DALNOK_OK)
        let found = attacks(l)
        #expect(found.count == grid.count, "every hit once: no gap swallowed one, no crossfade doubled one (\(found))")
        for (f, g) in zip(found, grid) {
            #expect(abs(f - g) <= 24, "hit at \(f), grid \(g): \(Double(f - g) / 48) ms off (tolerance 0.5 ms)")
        }
        // Each hit keeps its shape: the 30 ms after the attack correlates with the original hit (stretch, not smear).
        let len = 1_440
        for (k, (f, real)) in zip(found, truth).enumerated() {
            let a = Array(l[f..<(f + len)]), b = Array(source[real..<(real + len)])
            let dot = zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
            let na = sqrt(a.reduce(0) { $0 + Double($1) * Double($1) }), nb = sqrt(b.reduce(0) { $0 + Double($1) * Double($1) })
            #expect(dot / (na * nb) > 0.9, "hit \(k) keeps its sound (correlation \(dot / (na * nb)))")
        }
        // No clicks at the cuts: nothing between hits jumps more than the hiss and the decaying tones do.
        var worst: Float = 0
        for i in 1..<total {
            let nearHit = grid.contains { i >= $0 - 48 && i < $0 + 2_400 }
            if !nearHit { worst = max(worst, abs(l[i] - l[i - 1])) }
        }
        #expect(worst < 0.05, "largest sample step away from the attacks \(worst)")
        // One undo brings the original clip back.
        dalnok_undo(e)
        #expect(dalnok_track_clips(e, t, nil, 0) == 1 && clipInfo(e, c).length == Int64(total))
    }

    @Test func halfStrengthMovesHalfway() {
        let truth = [12_000 + 1_200, 24_000 - 800, 36_000 + 1_000]
        let (e, _, c) = session(hits(at: truth, frames: 60_000)); defer { dalnok_engine_destroy(e) }
        var tr = [Int64](repeating: 0, count: 16)
        let nt = Int(dalnok_audio_transients(e, c, 0.5, &tr, 16))
        var ids = [DalnokClipId](repeating: 0, count: 16)
        let ns = Int(dalnok_audio_quantize(e, c, 0.5, 0.5, 0.5, &ids, 16))
        #expect(nt == 3 && ns >= 4)
        var l = [Float](repeating: 0, count: 60_000), r = l
        _ = dalnok_render_offline(e, 0, 60_000, &l, &r)
        let found = attacks(l)
        let expected = [12_600, 23_600, 36_500]
        #expect(found.count == 3)
        for (f, x) in zip(found, expected) { #expect(abs(f - x) <= 24, "hit at \(f), expected \(x)") }
    }

    @Test func refusesMidiAndSilence() {
        let (e, _, c) = session([Float](repeating: 0, count: 48_000)); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_audio_quantize(e, c, 0.25, 1, 0.5, nil, 0) == 0, "silence has nothing to quantize")
        let keys = dalnok_track_add_instrument(e, "Keys")
        let m = dalnok_midi_clip_add(e, keys, 0, 1_000)
        #expect(dalnok_audio_quantize(e, m, 0.25, 1, 0.5, nil, 0) == 0 && dalnok_audio_transients(e, m, 0.5, nil, 0) == -1)
        let (st, _) = runCommand(e, "audio.quantize", #"{"clip":\#(c)}"#)
        #expect(st != DALNOK_OK)
    }
}
