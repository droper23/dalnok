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
    /// The samples as a 16-bit WAV file on disk (so projects can be saved and reopened), on one audio track.
    func session(_ samples: [Float], start: Int64 = 0) -> (OpaquePointer, DalnokTrackId, DalnokClipId) {
        let e = dalnok_engine_create(rate)!
        _ = dalnok_tempo_set(e, 120, 4, 4)
        let t = dalnok_track_add(e, "Drums")
        var pcm = Data()
        for v in samples { var i = Int16(max(-1, min(1, v)) * 32_767).littleEndian; withUnsafeBytes(of: &i) { pcm.append(contentsOf: $0) } }
        let url = tempDir().appendingPathComponent("drums.wav")
        try? wavFile(pcm16: pcm, rate: Int(rate)).write(to: url)
        var m: OpaquePointer?
        _ = dalnok_media_load(url.path, rate, &m, nil, 0)
        let c = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, m, url.path), start, 0, Int64(samples.count))
        dalnok_media_release(m)
        return (e, t, c)
    }
    func renderAll(_ e: OpaquePointer, _ n: Int) -> [Float] {
        var l = [Float](repeating: 0, count: n), r = l
        _ = dalnok_render_offline(e, 0, Int64(n), &l, &r)
        return l
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

    @Test func aHitJustAfterATrimmedStartIsFound() {
        // Trimmed so the clip's audio starts 1,500 frames (31 ms) before a hit: that first hit is still found.
        let truth = [3_000, 14_400, 27_100, 37_000]
        let (e, _, c) = session(hits(at: truth, frames: 50_000)); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_clip_set_region(e, c, 12_900, 12_900, 37_000) == DALNOK_OK)
        var out = [Int64](repeating: 0, count: 64)
        let n = Int(dalnok_audio_transients(e, c, 0.5, &out, 64))
        let found = Array(out.prefix(n))
        #expect(n == 3 && abs(Int(found[0]) - 14_400) <= 48, "found \(found)")
        #expect(found.allSatisfy { $0 >= 12_900 }, "nothing before the trim")
    }

    @Test func trimmedAndMovedClipQuantizesItsFirstHit() {
        let jitter = [0, 900, -1_100, 1_400, -600, 1_200, -1_300, 700, -900, 0]
        let grid = (1...10).map { $0 * 12_000 }
        let truth = zip(grid, jitter).map { $0 + $1 }
        let total = 132_000
        let (e, _, c) = session(hits(at: truth, frames: total)); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_clip_set_region(e, c, 20_000, 20_000, Int64(total - 20_000)) == DALNOK_OK)
        #expect(dalnok_clip_move(e, c, clipInfo(e, c).track, 30_000) == DALNOK_OK)
        #expect(dalnok_audio_quantize(e, c, 0.5, 1, 0.5) == DALNOK_OK)
        let found = attacks(renderAll(e, total + 20_000))
        // Hits in the clip: source 24,900 -> timeline 34,900 (grid 36,000), 34,900 -> 44,900 (48,000), ...
        #expect(found.count >= 8 && abs(found[0] - 36_000) <= 24, "first hits \(found.prefix(3))")
        #expect(found.allSatisfy { $0 % 12_000 <= 24 || $0 % 12_000 >= 11_976 }, "all on the grid: \(found)")
    }

    @Test func quietOrSteadyAudioHasNoFalseTransients() {
        let steady = (0..<96_000).map { Float(0.4 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
        let (e, _, c) = session(steady); defer { dalnok_engine_destroy(e) }
        var tr = [Int64](repeating: 0, count: 64)
        let n = Int(dalnok_audio_transients(e, c, 0.5, &tr, 64))
        #expect(n <= 1, "a held tone has at most its start (\(tr.prefix(max(0, n))))")
    }

    @Test func hitsLandOnTheGridInOneClip() throws {
        // Eighth notes (12,000 frames) played up to ±30 ms off the grid.
        let jitter = [0, 900, -1_100, 1_400, -600, 1_200, -1_300, 700, -900, 0]
        let grid = (1...10).map { $0 * 12_000 }
        let truth = zip(grid, jitter).map { $0 + $1 }
        let total = 132_000
        let source = hits(at: truth, frames: total)
        let (e, t, c) = session(source); defer { dalnok_engine_destroy(e) }
        let before = renderAll(e, total)
        #expect(dalnok_audio_quantize(e, c, 0.5, 1, 0.5) == DALNOK_OK)
        #expect(undoName(e) == "Quantize Audio")
        let info = clipInfo(e, c)
        #expect(dalnok_track_clips(e, t, nil, 0) == 1 && info.start == 0 && info.length == Int64(total) && info.offset == 0,
                "still one clip, same start, offset and length")
        let n = Int(dalnok_clip_warp(e, c, nil, nil, 0))
        var src = [Int64](repeating: 0, count: n), tm = src
        _ = dalnok_clip_warp(e, c, &src, &tm, Int32(n))
        #expect(n >= 10 && info.warp_points == Int32(n) && tm.first == 0 && tm.last == Int64(total) && src.last == Int64(total))
        let l = renderAll(e, total)
        let found = attacks(l)
        #expect(found.count == grid.count, "every hit once: none lost, none doubled (\(found))")
        for (f, g) in zip(found, grid) {
            #expect(abs(f - g) <= 24, "hit at \(f), grid \(g): \(Double(f - g) / 48) ms off (tolerance 0.5 ms)")
        }
        // Each hit keeps its shape: its first 30 ms match the original hit (attacks are never stretched).
        let len = 1_440
        for (k, (f, real)) in zip(found, attacks(before)).enumerated() {
            let a = Array(l[f..<(f + len)]), b = Array(before[real..<(real + len)])
            let dot = zip(a, b).reduce(0) { $0 + Double($1.0) * Double($1.1) }
            let na = sqrt(a.reduce(0) { $0 + Double($1) * Double($1) }), nb = sqrt(b.reduce(0) { $0 + Double($1) * Double($1) })
            #expect(dot / (na * nb) > 0.98, "hit \(k) keeps its sound (correlation \(dot / (na * nb)))")
        }
        // No clicks at the anchors: nothing between hits jumps more than the hiss and the decaying tones do.
        var worst: Float = 0
        for i in 1..<total where !grid.contains(where: { i >= $0 - 48 && i < $0 + 2_400 }) { worst = max(worst, abs(l[i] - l[i - 1])) }
        #expect(worst < 0.05, "largest sample step away from the attacks \(worst)")

        // Splitting keeps the timing: the two halves play what the whole did.
        let mid = Int64(grid[4] + 6_000)
        #expect(dalnok_clip_split(e, c, mid, nil) == DALNOK_OK)
        let split = renderAll(e, total)
        #expect(attacks(split) == found, "a split warped clip keeps every hit where it was")
        let diff = zip(split, l).enumerated().filter { abs($0.offset - Int(mid)) > 480 }.map { abs($0.element.0 - $0.element.1) }.max() ?? 1
        #expect(diff < 0.05, "and sounds nearly the same (the stretched part re-rendered from the cut) (\(diff))")
        dalnok_undo(e)
        // Saving and reopening keeps the warp (and the sound).
        let path = tempDir().appendingPathComponent("q.dalnok").path
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let e2 = dalnok_engine_create(rate)!; defer { dalnok_engine_destroy(e2) }
        var missing: Int32 = 0
        #expect(dalnok_project_load(e2, path, &missing, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let reopened = renderAll(e2, total)
        let d2 = zip(reopened, l).map { abs($0 - $1) }.max() ?? 1
        #expect(d2 < 1e-6, "the reopened project plays the quantized clip the same (\(d2))")
        // One undo brings back the clip as recorded.
        dalnok_undo(e)
        #expect(clipInfo(e, c).warp_points == 0 && attacks(renderAll(e, total)) == attacks(before))
    }

    @Test func halfStrengthMovesHalfway() {
        let truth = [12_000 + 1_200, 24_000 - 800, 36_000 + 1_000]
        let (e, _, c) = session(hits(at: truth, frames: 60_000)); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_audio_quantize(e, c, 0.5, 0.5, 0.5) == DALNOK_OK)
        let found = attacks(renderAll(e, 60_000))
        let expected = [12_600, 23_600, 36_500]
        #expect(found.count == 3)
        for (f, x) in zip(found, expected) { #expect(abs(f - x) <= 24, "hit at \(f), expected \(x)") }
        // Quantizing again starts from the recorded timing (100% now lands on the grid, not 75%).
        #expect(dalnok_audio_quantize(e, c, 0.5, 1, 0.5) == DALNOK_OK)
        for (f, g) in zip(attacks(renderAll(e, 60_000)), [12_000, 24_000, 36_000]) { #expect(abs(f - g) <= 24, "requantized hit at \(f), grid \(g)") }
    }

    @Test func transposingAQuantizedClipKeepsItsQuantize() {
        let truth = [12_000 + 1_200, 24_000 - 800, 36_000 + 1_000]
        let (e, _, c) = session(hits(at: truth, frames: 60_000)); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_audio_quantize(e, c, 0.5, 1, 0.5) == DALNOK_OK)
        let points = clipInfo(e, c).warp_points
        #expect(points > 0)
        // Transpose (same length and rate, new pitch): the hits stay where quantize put them.
        #expect(dalnok_clip_set_stretch(e, c, 60_000, 1, 3, true) == DALNOK_OK)
        #expect(clipInfo(e, c).warp_points == points, "a pitch change does not undo the quantize")
        // A new speed is a different clip: the old anchors no longer apply.
        #expect(dalnok_clip_set_stretch(e, c, 30_000, 2, 3, true) == DALNOK_OK)
        #expect(clipInfo(e, c).warp_points == 0)
    }

    @Test func refusesMidiAndSilence() {
        let (e, _, c) = session([Float](repeating: 0, count: 48_000)); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_audio_quantize(e, c, 0.25, 1, 0.5) != DALNOK_OK, "silence has nothing to quantize")
        let keys = dalnok_track_add_instrument(e, "Keys")
        let m = dalnok_midi_clip_add(e, keys, 0, 1_000)
        #expect(dalnok_audio_quantize(e, m, 0.25, 1, 0.5) != DALNOK_OK && dalnok_audio_transients(e, m, 0.5, nil, 0) == -1)
        let (st, _) = runCommand(e, "audio.quantize", #"{"clip":\#(c)}"#)
        #expect(st != DALNOK_OK)
    }
}
