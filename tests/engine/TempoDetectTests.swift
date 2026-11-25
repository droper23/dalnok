// Tempo detection on synthesized beats: tempo, first beat and confidence, with numeric tolerances.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct TempoDetection {
    /// A drum loop at `bpm`: kicks on beats 1 and 3, snares (noise) on 2 and 4, hats on eighths, starting at `first` s.
    func beat(_ bpm: Double, seconds: Double = 16, first: Double = 0.3, swingJitter: Double = 0) -> [Float] {
        let sr = 48_000.0, n = Int(seconds * sr), beatLen = 60 / bpm
        var x = [Float](repeating: 0, count: n)
        var seed: UInt32 = 7
        func noise() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) }
        var k = 0
        while true {
            let t = first + Double(k) * beatLen / 2
            let jitter = swingJitter * Double(noise())
            let at = Int((t + jitter) * sr)
            if at >= n { break }
            let onBeat = k % 2 == 0, beatIndex = k / 2
            for i in 0..<min(9_600, n - at) {
                let s = Double(i) / sr
                var v: Float = 0.15 * noise() * Float(exp(-s * 60)) // hat
                if onBeat && beatIndex % 2 == 0 { v += Float(0.8 * exp(-s * 12) * sin(2 * Double.pi * 55 * s)) } // kick
                if onBeat && beatIndex % 2 == 1 { v += 0.4 * noise() * Float(exp(-s * 25)) } // snare
                x[at + i] += v
            }
            k += 1
        }
        return x
    }
    func detect(_ x: [Float]) -> (bpm: Double, first: Int64, confidence: Double, status: DalnokStatus, err: String) {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([x, x]); defer { dalnok_media_release(m) }
        let c = DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "Loop"), dalnok_pool_add(e, m, ""), 0, 0, 0)
        var bpm = 0.0, conf = 0.0, first: Int64 = 0
        var err = [CChar](repeating: 0, count: 256)
        let s = dalnok_clip_detect_tempo(e, c, &bpm, &first, &conf, &err, 256)
        return (bpm, first, conf, s, cstr(err))
    }

    @Test(arguments: [128.0, 92.0, 140.0, 104.5, 75.0])
    func findsTheTempoAndFirstBeat(_ bpm: Double) {
        let r = detect(beat(bpm))
        #expect(r.status == DALNOK_OK, "\(r.err)")
        #expect(abs(r.bpm - bpm) < 0.1, "\(bpm): heard \(r.bpm) BPM")
        // The first beat: 0.3 s, or an earlier hat if the pulse train starts on an eighth (never off the grid).
        let beatFrames = 60 / bpm * 48_000, off = (Double(r.first) - 0.3 * 48_000) / beatFrames
        #expect(abs(off - off.rounded()) * beatFrames < 0.006 * 48_000, "\(bpm): first beat \(Double(r.first) / 48_000) s")
        #expect(r.confidence > 0.5, "\(bpm): confidence \(r.confidence)")
    }

    @Test func catalogCommandSetsTheProjectTempo() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([beat(97), beat(97)]); defer { dalnok_media_release(m) }
        let c = DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "Loop"), dalnok_pool_add(e, m, ""), 0, 0, 0)
        let (s, out) = runCommand(e, "clip.tempoToProject", "{\"clip\": \(c)}")
        #expect(s == DALNOK_OK, "\(out)")
        #expect(abs(dalnok_tempo_bpm(e) - 97) < 0.1, "\(dalnok_tempo_bpm(e)) BPM")
        dalnok_undo(e)
        #expect(dalnok_tempo_bpm(e) == 120, "one undo restores 120 BPM (\(dalnok_tempo_bpm(e)))")
        #expect(runCommand(e, "clip.tempoToProject", "{\"clip\": \(c), \"minConfidence\": 2}").0 != DALNOK_OK)
    }

    @Test func playedLooselyStillFindsTheTempo() {
        let r = detect(beat(120, seconds: 20, swingJitter: 0.008)) // hits ±8 ms off
        #expect(abs(r.bpm - 120) < 0.3, "\(r.bpm) BPM")
        #expect(r.confidence > 0.4, "confidence \(r.confidence)")
    }

    @Test func noiseAndShortClipsHaveNoTempo() {
        var seed: UInt32 = 3
        let hiss = (0..<480_000).map { _ -> Float in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.2 }
        let r = detect(hiss)
        #expect(r.status != DALNOK_OK || r.confidence < 0.2, "steady noise: \(r.bpm) BPM at \(r.confidence)")
        let short = detect(beat(120, seconds: 2))
        #expect(short.status != DALNOK_OK && short.err.contains("short"), "\(short.err)")
    }
}
