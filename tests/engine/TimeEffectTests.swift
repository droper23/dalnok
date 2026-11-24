// Dalnok Delay, Reverb and Gate: offline renders with numeric tolerances.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

private func session(_ mono: [Float]) -> (OpaquePointer, DalnokTrackId) {
    let e = dalnok_engine_create(48_000)!
    let t = dalnok_track_add(e, "Main")
    let m = makeMedia([mono, mono]); defer { dalnok_media_release(m) }
    DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, m, ""), 0, 0, 0)
    return (e, t)
}

/// Adds a built-in and sets parameters by plain value (each parameter's range read back from the engine).
private func add(_ e: OpaquePointer, _ t: DalnokTrackId, _ id: String, _ values: [UInt32: Double]) -> Int32 {
    var err = [CChar](repeating: 0, count: 256)
    let slot = dalnok_plugin_add(e, t, "dalnok:\(id)", nil, &err, 256)
    #expect(slot != 0, "\(cstr(err))")
    for (pid, plain) in values {
        // Find the normalized value whose text matches: search the 0-1 range (parameters are monotonic).
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            var buf = [CChar](repeating: 0, count: 64)
            _ = dalnok_plugin_parameter_text(e, slot, pid, mid, &buf, 64)
            if (Double(cstr(buf)) ?? (cstr(buf) == "On" ? 1 : 0)) < plain { lo = mid } else { hi = mid }
        }
        #expect(dalnok_plugin_set_parameter(e, slot, pid, hi) == DALNOK_OK)
    }
    return slot
}

private func dB(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

@Suite struct TimeEffects {
    @Test func delayEchoesAtItsTimeAndFeedbackDecays() {
        var x = [Float](repeating: 0, count: 48_000); x[1_000] = 1
        let (e, t) = session(x); defer { dalnok_engine_destroy(e) }
        // 100 ms (4,800 frames), 50 % feedback, full range filters, wet only.
        _ = add(e, t, "delay", [0: 100, 1: 100, 2: 50, 4: 20, 5: 20_000, 6: 100])
        let (l, r) = render(e, frames: 48_000)
        #expect(abs(l[1_000]) < 1e-4, "wet only: no dry impulse (\(l[1_000]))")
        // Sums over each echo: a fractional delay splits the impulse between neighboring samples, and the feedback's
        // filters spread it, but both keep its sum (their gain at DC is 1).
        let first = l[5_790..<5_810].reduce(0, +), second = l[10_590..<10_640].reduce(0, +)
        let peakAt = (5_790..<5_810).max { abs(l[$0]) < abs(l[$1]) } ?? 0
        #expect(abs(peakAt - 5_800) <= 1, "first echo at \(peakAt), expected 5,800 (100 ms)")
        #expect(first > 0.8 && first <= 1.01, "first echo \(first)")
        #expect(abs(dB(Double(second / first)) - dB(0.5)) < 1.0, "second echo \(dB(Double(second / first))) dB below the first, want -6")
        #expect(abs(l[5_800] - r[5_800]) < 1e-6, "same time both sides: same echo")
    }

    @Test func pingPongAlternatesSides() {
        var x = [Float](repeating: 0, count: 48_000); x[0] = 1
        let (e, t) = session(x); defer { dalnok_engine_destroy(e) }
        _ = add(e, t, "delay", [0: 50, 1: 50, 2: 60, 3: 1, 4: 20, 5: 20_000, 6: 100])
        let (l, r) = render(e, frames: 48_000)
        func peak(_ v: [Float], _ at: Int) -> Float { v[(at - 3)...(at + 3)].map { abs($0) }.max() ?? 0 }
        #expect(peak(l, 2_400) > 0.5 && peak(r, 2_400) < 0.01, "first echo left only")
        #expect(peak(r, 4_800) > 0.2 && peak(l, 4_800) < 0.01, "second echo right only")
    }

    @Test func reverbDecaysInItsDecayTime() {
        var x = [Float](repeating: 0, count: 5 * 48_000); x[0] = 1
        let (e, t) = session(x); defer { dalnok_engine_destroy(e) }
        // T60 = 1.5 s, no damping, no low cut, no predelay, wet only.
        _ = add(e, t, "reverb", [0: 0, 1: 1.5, 2: 60, 3: 20_000, 4: 20, 6: 100])
        let (l, r) = render(e, frames: x.count)
        // Schroeder backward integration; T60 from the -5 to -25 dB slope.
        let energy = zip(l, r).map { Double($0) * Double($0) + Double($1) * Double($1) }
        var tail = [Double](repeating: 0, count: energy.count), acc = 0.0
        for i in stride(from: energy.count - 1, through: 0, by: -1) { acc += energy[i]; tail[i] = acc }
        let edc = tail.map { 10 * log10(max($0 / tail[0], 1e-30)) }
        guard let a = edc.firstIndex(where: { $0 <= -5 }), let b = edc.firstIndex(where: { $0 <= -25 }) else {
            Issue.record("the tail never fell 25 dB"); return
        }
        let t60 = Double(b - a) / 48_000 * 3
        #expect(abs(t60 - 1.5) < 0.3, "measured T60 \(t60) s, set 1.5 s")
        #expect(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite))
        let lr = zip(l, r).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let ll = l.reduce(0.0) { $0 + Double($1) * Double($1) }, rr = r.reduce(0.0) { $0 + Double($1) * Double($1) }
        #expect(lr / sqrt(ll * rr) < 0.5, "full width: left and right decorrelated (\(lr / sqrt(ll * rr)))")
    }

    @Test func reverbAtZeroMixIsTransparent() {
        let x = (0..<24_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48_000)) }
        let (e, t) = session(x); defer { dalnok_engine_destroy(e) }
        _ = add(e, t, "reverb", [6: 0])
        let (l, _) = render(e, frames: x.count)
        #expect(zip(l, x).map { abs($0 - $1) }.max() ?? 1 < 1e-6)
    }

    @Test func gatePassesLoudAndSilencesQuiet() {
        // 0.5 s of a 0.5 sine (-6 dBFS), then 1 s of a 0.001 sine (-60 dBFS).
        let x = (0..<72_000).map { i -> Float in
            Float((i < 24_000 ? 0.5 : 0.001) * sin(2 * Double.pi * 300 * Double(i) / 48_000))
        }
        let (e, t) = session(x); defer { dalnok_engine_destroy(e) }
        _ = add(e, t, "gate", [0: -40, 1: -100, 2: 0.5, 3: 20, 4: 50, 5: 3])
        let (l, _) = render(e, frames: x.count)
        let loud = l[4_800..<24_000].map { abs($0) }.max() ?? 0
        #expect(abs(dB(Double(loud)) - dB(0.5)) < 0.1, "open: unity (\(dB(Double(loud))) dBFS)")
        let quiet = l[48_000..<72_000].map { abs($0) }.max() ?? 1
        #expect(quiet < 1e-6, "closed: silent (\(quiet))")
    }

    @Test func gateRangeAttenuatesByItsAmount() {
        let x = (0..<48_000).map { Float(0.001 * sin(2 * Double.pi * 300 * Double($0) / 48_000)) }
        let (e, t) = session(x); defer { dalnok_engine_destroy(e) }
        _ = add(e, t, "gate", [0: -40, 1: -20, 4: 10])
        let (l, _) = render(e, frames: x.count)
        let out = l[24_000..<48_000].map { abs($0) }.max() ?? 0
        #expect(abs(dB(Double(out)) - (dB(0.001) - 20)) < 0.2, "-20 dB range: \(dB(Double(out)) - dB(0.001)) dB")
    }
}
