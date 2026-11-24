// Dalnok Limiter, Saturator, Filter, Chorus and Utility: offline renders with numeric tolerances.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Sets parameters by plain value (`values`, found through their display text) or normalized (`normalized`, for choices).
private func run(_ l: [Float], _ r: [Float], _ id: String, _ values: [UInt32: Double], normalized: [UInt32: Double] = [:]) -> ([Float], [Float]) {
    let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
    let t = dalnok_track_add(e, "M")
    let m = makeMedia([l, r]); defer { dalnok_media_release(m) }
    DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, m, ""), 0, 0, 0)
    var err = [CChar](repeating: 0, count: 256)
    let slot = dalnok_plugin_add(e, t, "dalnok:\(id)", nil, &err, 256)
    #expect(slot != 0, "\(cstr(err))")
    for (pid, plain) in values { // the normalized value whose text reads `plain` (parameters are monotonic)
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            var buf = [CChar](repeating: 0, count: 64)
            _ = dalnok_plugin_parameter_text(e, slot, pid, mid, &buf, 64)
            let text = cstr(buf)
            let v = Double(text) ?? (text == "On" ? 1 : 0)
            if v < plain { lo = mid } else { hi = mid }
        }
        _ = dalnok_plugin_set_parameter(e, slot, pid, hi)
    }
    for (pid, v) in normalized { _ = dalnok_plugin_set_parameter(e, slot, pid, v) }
    return render(e, frames: l.count)
}
private func sine(_ hz: Double, _ amp: Double, _ n: Int = 48_000) -> [Float] { (0..<n).map { Float(amp * sin(2 * Double.pi * hz * Double($0) / 48_000)) } }
private func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count)) }
private func dB(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }

@Suite struct MixEffects {
    @Test func limiterNeverPassesTheCeiling() {
        let loud = sine(100, 2.0) // +6 dBFS
        let (l, _) = run(loud, loud, "limiter", [1: -1])
        let ceiling = Float(pow(10, -1.0 / 20))
        #expect(l.map { abs($0) }.max()! <= ceiling + 1e-6, "peak \(l.map { abs($0) }.max()!), ceiling \(ceiling)")
        #expect(abs(dB(Double(l[24_000..<48_000].map { abs($0) }.max()!)) + 1) < 0.1, "held at the ceiling")
        // Quiet audio passes unchanged, lined up by delay compensation.
        let quiet = sine(440, 0.2)
        let (q, _) = run(quiet, quiet, "limiter", [:])
        #expect(zip(q, quiet).map { abs($0 - $1) }.max()! < 1e-6, "transparent and on time")
    }

    @Test func saturatorAddsHarmonics() {
        let x = sine(1_000, 0.5)
        let (l, _) = run(x, x, "saturator", [0: 24])
        // Third harmonic (3 kHz) measured by correlation with a 3 kHz sine.
        func level(_ hz: Double) -> Double {
            var s = 0.0, c = 0.0
            for i in 4_800..<48_000 { let p = 2 * Double.pi * hz * Double(i) / 48_000; s += Double(l[i]) * sin(p); c += Double(l[i]) * cos(p) }
            return sqrt(s * s + c * c) / Double(48_000 - 4_800) * 2
        }
        #expect(dB(level(3_000) / level(1_000)) > -20, "3rd harmonic \(dB(level(3_000) / level(1_000))) dB")
        let (clean, _) = run(x, x, "saturator", [0: 0, 4: 0])
        #expect(zip(clean, x).map { abs($0 - $1) }.max()! < 1e-6, "mix 0 is transparent")
    }

    @Test func filterPassesAndCuts() {
        let low = sine(100, 0.5), high = sine(10_000, 0.5)
        let (lp, _) = run(low, low, "filter", [1: 1_000])
        let (lpHigh, _) = run(high, high, "filter", [1: 1_000])
        #expect(abs(dB(rms(lp[4_800...]) / rms(low[4_800...]))) < 0.5, "100 Hz passes a 1 kHz low-pass")
        #expect(dB(rms(lpHigh[4_800...]) / rms(high[4_800...])) < -35, "10 kHz is cut: \(dB(rms(lpHigh[4_800...]) / rms(high[4_800...]))) dB")
        let (hp, _) = run(low, low, "filter", [1: 1_000], normalized: [0: 1.0 / 3]) // type 1 of 0-3: high-pass
        #expect(dB(rms(hp[4_800...]) / rms(low[4_800...])) < -35, "a high-pass cuts 100 Hz")
    }

    @Test func chorusMovesAndMixZeroIsDry() {
        let x = sine(440, 0.5)
        let (dry, _) = run(x, x, "chorus", [3: 0])
        #expect(zip(dry, x).map { abs($0 - $1) }.max()! < 1e-6)
        // Broadband noise (a sine would comb against its delayed copy): half dry and half wet keeps the level within 4 dB.
        var seed: UInt32 = 9
        let noise = (0..<48_000).map { _ -> Float in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.3 }
        let (l, r) = run(noise, noise, "chorus", [3: 100])
        #expect(abs(dB(rms(l[4_800...]) / rms(noise[4_800...]))) < 4, "level \(dB(rms(l[4_800...]) / rms(noise[4_800...]))) dB")
        #expect(zip(l, r).map { abs($0 - $1) }.max()! > 0.01, "the sides differ (wide)")
    }

    @Test func utilityGainWidthMonoAndPolarity() {
        let a = sine(300, 0.4), b = sine(700, 0.3)
        let (g, _) = run(a, b, "utility", [0: -6])
        #expect(abs(dB(rms(g[...]) / rms(a[...])) + 6) < 0.05)
        let (ml, mr) = run(a, b, "utility", [2: 1])
        #expect(zip(ml, mr).allSatisfy { $0 == $1 } && abs(ml[123] - (a[123] + b[123]) / 2) < 1e-6, "mono")
        let (il, ir) = run(a, b, "utility", [3: 1])
        #expect(abs(il[123] + a[123]) < 1e-6 && abs(ir[123] - b[123]) < 1e-6, "left inverted")
        let (wl, wr) = run(a, b, "utility", [1: 0])
        #expect(zip(wl, wr).allSatisfy { abs($0 - $1) < 1e-6 }, "width 0 is mono")
    }
}
