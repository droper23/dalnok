// Loudness metering against the EBU Tech 3341 / 3342 reference signals (generated here) and BS.1770 arithmetic.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

private func sine(_ hz: Double, dbfs: Double, seconds: Double, rate: Double = 48_000, phase: Double = 0) -> [Float] {
    let a = pow(10, dbfs / 20)
    return (0..<Int(seconds * rate)).map { Float(a * sin(2 * Double.pi * hz * Double($0) / rate + phase)) }
}

private func measure(_ l: [Float], _ r: [Float], rate: Double = 48_000) -> DalnokLoudness {
    let e = dalnok_engine_create(rate)!; defer { dalnok_engine_destroy(e) }
    let m = makeMedia([l, r], rate: rate); defer { dalnok_media_release(m) }
    // A stereo clip on a centered track plays at unity (balance law), so the render is the signal itself.
    DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "S"), dalnok_pool_add(e, m, ""), 0, 0, 0)
    var out = DalnokLoudness()
    var err = [CChar](repeating: 0, count: 256)
    #expect(dalnok_render_loudness(e, 0, Int64(l.count), &out, &err, 256) == DALNOK_OK, "\(cstr(err))")
    return out
}

@Suite struct Loudness {
    @Test func oneKilohertzAtMinus23IsMinus23LUFS() {
        // EBU 3341 case 1: stereo 1 kHz sine at -23 dBFS for 20 s -> M, S and I all -23.0 LUFS (±0.1).
        for rate in [44_100.0, 48_000.0] {
            let s = sine(1_000, dbfs: -23, seconds: 20, rate: rate)
            let r = measure(s, s, rate: rate)
            #expect(abs(r.integrated + 23) <= 0.1 && abs(r.momentary + 23) <= 0.1 && abs(r.short_term + 23) <= 0.1,
                    "\(rate) Hz: I \(r.integrated), M \(r.momentary), S \(r.short_term)")
        }
    }

    @Test func relativeGateIgnoresTheQuietPart() {
        // EBU 3341 case 3-style: 10 s at -36, 60 s at -23, 10 s at -36 dBFS -> I = -23.0 (the -36 parts fall under
        // the relative gate at about -33); a level of -46 sits under it too.
        let s = sine(1_000, dbfs: -36, seconds: 10) + sine(1_000, dbfs: -23, seconds: 60) + sine(1_000, dbfs: -36, seconds: 10)
        let r = measure(s, s)
        #expect(abs(r.integrated + 23) <= 0.1, "I \(r.integrated)")
        #expect(abs(r.max_momentary + 23) <= 0.1, "max M \(r.max_momentary)")
    }

    @Test func absoluteGateAndSilence() {
        let silent = [Float](repeating: 0, count: 48_000 * 5)
        let r = measure(silent, silent)
        #expect(r.integrated == -Float.infinity && r.true_peak == -Float.infinity)
        let quiet = sine(1_000, dbfs: -80, seconds: 5) // below the -70 LUFS absolute gate
        let q = measure(quiet, quiet)
        #expect(q.integrated == -Float.infinity && abs(q.momentary + 80) < 0.2, "I \(q.integrated), M \(q.momentary)")
    }

    @Test func truePeakFindsTheInterSamplePeak() {
        // EBU 3341 case 15-style: a 0 dBFS sine at a quarter of the sample rate sampled 45° off its peaks -> sample
        // peaks of -3.01 dBFS, true peak 0 dBTP (±0.3 with 4x oversampling, Tech 3341's tolerance is +0.2/-0.4).
        let s = sine(12_000, dbfs: 0, seconds: 2, phase: Double.pi / 4)
        #expect(abs(20 * log10(Double(s.map { abs($0) }.max()!)) + 3.01) < 0.01)
        let r = measure(s, s)
        #expect(r.true_peak > -0.4 && r.true_peak < 0.2, "true peak \(r.true_peak) dBTP")
    }

    @Test func liveMeterFollowsPlaybackAndResets() {
        let s = sine(1_000, dbfs: -20, seconds: 4)
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([s, s]); defer { dalnok_media_release(m) }
        DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "S"), dalnok_pool_add(e, m, ""), 0, 0, 0)
        var r = DalnokLoudness()
        dalnok_loudness_live(e, &r)
        #expect(r.momentary == -Float.infinity, "nothing before playing")
        #expect(dalnok_render_loudness(e, 0, 48_000 * 4, &r, nil, 0) == DALNOK_OK && abs(r.integrated + 20) < 0.1)
    }
}
