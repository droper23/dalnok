// Dalnok Compressor (built-in, ADR-0011): offline renders against an independent reference, the static curve,
// attack and release timing, and sidechain keying from another track.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Compressor settings in plain units (the reference and the parameter writes share them).
private struct Comp {
    var threshold = -20.0, ratio = 4.0, knee = 6.0, attack = 10.0, release = 100.0, makeup = 0.0
    var autoGain = false, rms = false, filter = false, filterHz = 100.0, listen = false, mix = 100.0

    func apply(_ e: OpaquePointer, _ slot: Int32) {
        func lin(_ v: Double, _ lo: Double, _ hi: Double) -> Double { (v - lo) / (hi - lo) }
        func lg(_ v: Double, _ lo: Double, _ hi: Double) -> Double { log(v / lo) / log(hi / lo) }
        let values: [(UInt32, Double)] = [
            (0, lin(threshold, -60, 0)), (1, lg(ratio, 1, 30)), (2, lin(knee, 0, 24)), (3, lg(attack, 0.05, 200)),
            (4, lg(release, 5, 5_000)), (5, lin(makeup, -20, 40)), (6, autoGain ? 1 : 0), (7, rms ? 1 : 0),
            (8, filter ? 1 : 0), (9, lg(filterHz, 20, 2_000)), (10, listen ? 1 : 0), (11, mix / 100),
        ]
        for (id, v) in values { #expect(dalnok_plugin_set_parameter(e, slot, id, v) == DALNOK_OK) }
    }

    static func curve(_ x: Double, _ t: Double, _ r: Double, _ w: Double) -> Double {
        let over = x - t, slope = 1 / r - 1
        if w > 0 && 2 * abs(over) <= w { return slope * (over + w / 2) * (over + w / 2) / (2 * w) }
        return over > 0 ? slope * over : 0
    }

    /// Independent reference (the algorithm in compressor.cpp's header comment, written again in Swift).
    func reference(_ inL: [Float], _ inR: [Float], keyL: [Float]? = nil, keyR: [Float]? = nil, rate: Double = 48_000) -> ([Double], [Double], Double) {
        let kL = keyL ?? inL, kR = keyR ?? keyL ?? inR
        let ac = exp(-1 / (attack * 1e-3 * rate)), rc = exp(-1 / (release * 1e-3 * rate)), msc = exp(-1 / (0.010 * rate))
        let mk = makeup - (autoGain ? Self.curve(0, threshold, ratio, knee) : 0), m = mix / 100
        let w = 2 * Double.pi * min(filterHz / rate, 0.49), cw = cos(w), alpha = sin(w) / (2 * 0.70710678118654752), a0 = 1 + alpha
        let b = [(1 + cw) / 2 / a0, -(1 + cw) / a0, (1 + cw) / 2 / a0], a1 = -2 * cw / a0, a2 = (1 - alpha) / a0
        var hp = [[Double]](repeating: [0, 0, 0, 0], count: 2)
        var g = 0.0, ms = 0.0, deepest = 0.0
        var outL = [Double](repeating: 0, count: inL.count), outR = outL
        for i in inL.indices {
            var k = [Double(kL[i]), Double(kR[i])]
            if filter {
                for c in 0..<2 {
                    let y = b[0] * k[c] + b[1] * hp[c][0] + b[2] * hp[c][1] - a1 * hp[c][2] - a2 * hp[c][3]
                    hp[c] = [k[c], hp[c][0], y, hp[c][2]]
                    k[c] = y
                }
            }
            let level: Double
            if rms { ms = msc * ms + (1 - msc) * 0.5 * (k[0] * k[0] + k[1] * k[1]); level = ms.squareRoot() }
            else { level = max(abs(k[0]), abs(k[1])) }
            let target = Self.curve(20 * log10(max(level, 1e-10)), threshold, ratio, knee)
            let c = target < g ? ac : rc
            g = c * g + (1 - c) * target
            deepest = min(deepest, g)
            if listen { outL[i] = k[0]; outR[i] = k[1]; continue }
            let gain = pow(10, (g + mk) / 20), dl = Double(inL[i]), dr = Double(inR[i])
            outL[i] = dl + m * (dl * gain - dl); outR[i] = dr + m * (dr * gain - dr)
        }
        return (outL, outR, -deepest)
    }
}

private let n = 24_000

/// A stereo test signal with quiet and loud passages: a decaying chord over a level staircase.
private func program(_ frames: Int = n) -> ([Float], [Float]) {
    var l = [Float](repeating: 0, count: frames), r = l
    for i in 0..<frames {
        let t = Double(i) / 48_000, step = pow(10, (-40 + 8 * Double(i / 3_000)) / 20)
        l[i] = Float(step * sin(2 * .pi * 220 * t) + 0.05 * sin(2 * .pi * 1_330 * t))
        r[i] = Float(step * 0.8 * sin(2 * .pi * 330 * t + 0.4))
    }
    return (l, r)
}

private func session(_ channels: [[Float]]) -> (OpaquePointer, DalnokTrackId) {
    let e = dalnok_engine_create(48_000)!
    let t = dalnok_track_add(e, "Main")
    let m = makeMedia(channels); defer { dalnok_media_release(m) }
    DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, m, ""), 0, 0, 0)
    return (e, t)
}

private func addCompressor(_ e: OpaquePointer, _ t: DalnokTrackId) -> Int32 {
    var err = [CChar](repeating: 0, count: 256)
    let slot = dalnok_plugin_add(e, t, "dalnok:compressor", nil, &err, 256)
    #expect(slot != 0, "\(cstr(err))")
    return slot
}

private func worst(_ got: [Float], _ want: [Double]) -> Double { zip(got, want).map { abs(Double($0) - $1) }.max() ?? 1 }

private func reduction(_ e: OpaquePointer, _ slot: Int32) -> Double {
    var p = DalnokPluginParameter()
    #expect(dalnok_plugin_parameter(e, slot, 12, &p) == DALNOK_OK && p.read_only)
    return 60 * p.value // 0-60 dB, normalized
}

@Suite struct CompressorPlugin {
    @Test func isListedAndRatioOneIsTransparent() throws {
        let len = dalnok_plugins_scan(nil, false, nil, 0)
        var buf = [CChar](repeating: 0, count: len + 1)
        dalnok_plugins_scan(nil, false, &buf, buf.count)
        let list = try #require(try JSONSerialization.jsonObject(with: Data(cstr(buf).utf8)) as? [[String: Any]])
        #expect(list.contains { $0["format"] as? String == "dalnok" && $0["path"] as? String == "compressor" })

        let (inL, inR) = program()
        let (e, t) = session([inL, inR]); defer { dalnok_engine_destroy(e) }
        let dry = render(e, frames: n)
        #expect(dry.0 == inL && dry.1 == inR, "a centred stereo track passes its clip unchanged")
        let slot = addCompressor(e, t)
        #expect(dalnok_plugin_has_sidechain(e, slot), "the compressor has a sidechain input")
        #expect(dalnok_plugin_parameter_count(e, slot) == 13)
        var cats = [CChar](repeating: 0, count: 64)
        dalnok_plugin_categories(e, slot, &cats, 64)
        #expect(cstr(cats) == "Fx|Dynamics")
        var c = Comp(); c.ratio = 1
        c.apply(e, slot)
        let wet = render(e, frames: n)
        #expect(wet.0 == inL && wet.1 == inR, "ratio 1:1 leaves every sample unchanged")
    }

    @Test(arguments: [
        (false, 0.0, false, 100.0), (false, 6.0, false, 100.0), (true, 6.0, false, 100.0),
        (false, 12.0, true, 100.0), (true, 0.0, true, 40.0),
    ])
    func matchesTheReference(rms: Bool, knee: Double, autoGain: Bool, mix: Double) {
        let (inL, inR) = program()
        let (e, t) = session([inL, inR]); defer { dalnok_engine_destroy(e) }
        let slot = addCompressor(e, t)
        var c = Comp(); c.threshold = -24; c.ratio = 6; c.knee = knee; c.attack = 2; c.release = 60
        c.rms = rms; c.autoGain = autoGain; c.mix = mix; c.makeup = 1.5
        c.apply(e, slot)
        let wet = render(e, frames: n)
        let (wl, wr, deepest) = c.reference(inL, inR)
        #expect(worst(wet.0, wl) < 2e-6 && worst(wet.1, wr) < 2e-6,
                "rms \(rms) knee \(knee) auto \(autoGain) mix \(mix): differs by \(worst(wet.0, wl)) / \(worst(wet.1, wr))")
        #expect(deepest > 6, "the loud passages are compressed (\(deepest) dB)")
    }

    @Test func staticCurveAndMeter() {
        // A constant 0.5 (-6.02 dBFS): threshold -20 dB, 4:1, hard knee -> 13.98 dB over, 10.49 dB of reduction.
        let dc = [Float](repeating: 0.5, count: n)
        let (e, t) = session([dc, dc]); defer { dalnok_engine_destroy(e) }
        let slot = addCompressor(e, t)
        var c = Comp(); c.knee = 0
        c.apply(e, slot)
        let wet = render(e, frames: n)
        let overDb = 20 * log10(0.5) + 20, expected = overDb * 0.75
        let gotDb = 20 * log10(Double(wet.0[n - 1]) / 0.5)
        #expect(abs(gotDb + expected) < 0.001, "settled reduction \(-gotDb) dB, expected \(expected)")
        // The meter belongs to the live instance: play it through the live render path.
        dalnok_transport_play(e)
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<40 { _ = dalnok_engine_pump(e, &l, &r, 512) }
        #expect(abs(reduction(e, slot) - expected) < 0.01, "meter reads \(reduction(e, slot)) dB")
        var p = DalnokPluginParameter()
        dalnok_plugin_parameter(e, slot, 12, &p)
        #expect(!p.automatable)
        #expect(dalnok_plugin_set_parameter(e, slot, 12, 0.5) != DALNOK_OK, "the meter can't be set")

        // Soft knee: at the threshold itself, a 6 dB knee takes (1/4 - 1) * 3^2 / 12 = 0.5625 dB.
        #expect(abs(Comp.curve(-20, -20, 4, 6) + 0.5625) < 1e-12)
        let atThreshold = [Float](repeating: Float(pow(10, -20.0 / 20)), count: n)
        let (e2, t2) = session([atThreshold, atThreshold]); defer { dalnok_engine_destroy(e2) }
        let s2 = addCompressor(e2, t2)
        Comp().apply(e2, s2)
        let w2 = render(e2, frames: n)
        #expect(abs(20 * log10(Double(w2.0[n - 1]) / 0.1) + 0.5625) < 0.001)
    }

    @Test func attackAndReleaseTimes() {
        // Quiet (-40 dB), then 0.5 for 0.25 s, then quiet again: the gain moves 1 - 1/e of the way in one time constant.
        var x = [Float](repeating: 0.01, count: n)
        for i in 4_800..<16_800 { x[i] = 0.5 }
        let (e, t) = session([x, x]); defer { dalnok_engine_destroy(e) }
        let slot = addCompressor(e, t)
        var c = Comp(); c.knee = 0; c.attack = 10; c.release = 50
        c.apply(e, slot)
        let wet = render(e, frames: n)
        let full = (20 * log10(0.5) + 20) * 0.75
        func gainDb(_ i: Int) -> Double { 20 * log10(Double(wet.0[i]) / Double(x[i])) }
        let afterAttack = gainDb(4_800 + 480 - 1) // 10 ms
        #expect(abs(afterAttack + full * (1 - exp(-1))) < 0.01, "after one attack time: \(afterAttack) dB")
        #expect(abs(gainDb(16_799) + full) < 0.001, "settled before the release")
        // Release from -full toward 0 dB (the quiet part is below the threshold): after 50 ms, full/e remains.
        let afterRelease = gainDb(16_800 + 2_400 - 1)
        #expect(abs(afterRelease + full * exp(-1)) < 0.01, "after one release time: \(afterRelease) dB")
    }

    @Test func sidechainKeysFromAnotherTrack() {
        let bed = [Float](repeating: 0.25, count: n)
        var key = [Float](repeating: 0, count: n)
        for i in 12_000..<n { key[i] = 0.5 }
        let (e, t) = session([bed, bed]); defer { dalnok_engine_destroy(e) }
        let source = dalnok_track_add(e, "Key")
        let km = makeMedia([key, key]); defer { dalnok_media_release(km) }
        DalnokEngine.dalnok_clip_add(e, source, dalnok_pool_add(e, km, ""), 0, 0, 0)
        #expect(dalnok_track_set_mute(e, source, true) == DALNOK_OK, "a muted key still keys (pre-fader)")
        let slot = addCompressor(e, t)
        var c = Comp(); c.knee = 0; c.attack = 0.05; c.release = 5
        c.apply(e, slot)

        // Unconnected: the bed keys itself (-12.04 dB, 7.96 dB over, 5.97 dB of reduction).
        let own = render(e, frames: n)
        let (refOwn, _, _) = c.reference(bed, bed)
        #expect(worst(own.0, refOwn) < 2e-6)
        #expect(abs(20 * log10(Double(own.0[n - 1]) / 0.25) + (20 * log10(0.25) + 20) * 0.75) < 0.001)

        #expect(dalnok_plugin_set_sidechain(e, t, slot, source) == DALNOK_OK)
        let keyed = render(e, frames: n)
        #expect(keyed.0[0..<12_000].allSatisfy { $0 == 0.25 }, "a silent key leaves the bed untouched")
        let (refKeyed, _, _) = c.reference(bed, bed, keyL: key, keyR: key)
        #expect(worst(keyed.0, refKeyed) < 2e-6, "keyed output differs from the reference by \(worst(keyed.0, refKeyed))")
        let expected = (20 * log10(0.5) + 20) * 0.75
        #expect(abs(20 * log10(Double(keyed.0[n - 1]) / 0.25) + expected) < 0.001, "the key's level sets the reduction")
        #expect(keyed.0[12_000] < 0.25, "the duck starts on the key's first sample")

        // Disconnecting returns to the bed's own level (the previous key buffer is never read again).
        #expect(dalnok_plugin_set_sidechain(e, t, slot, 0) == DALNOK_OK)
        let again = render(e, frames: n)
        #expect(worst(again.0, refOwn) < 2e-6, "after disconnecting, the compressor keys itself again")
    }

    @Test func liveDisconnectStopsReadingTheOldKey() {
        // Live path: the key is loud from the start. After disconnecting, the live instance must hear its own input,
        // not the last key buffer of an earlier render state (that buffer is freed once the state retires).
        let bed = [Float](repeating: 0.25, count: 96_000), key = [Float](repeating: 0.5, count: 96_000)
        let (e, t) = session([bed, bed]); defer { dalnok_engine_destroy(e) }
        let source = dalnok_track_add(e, "Key")
        let km = makeMedia([key, key]); defer { dalnok_media_release(km) }
        DalnokEngine.dalnok_clip_add(e, source, dalnok_pool_add(e, km, ""), 0, 0, 0)
        dalnok_track_set_mute(e, source, true)
        let slot = addCompressor(e, t)
        var c = Comp(); c.knee = 0; c.attack = 0.05; c.release = 5
        c.apply(e, slot)
        #expect(dalnok_plugin_set_sidechain(e, t, slot, source) == DALNOK_OK)
        dalnok_transport_play(e)
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<20 { _ = dalnok_engine_pump(e, &l, &r, 512) }
        let keyedDb = 20 * log10(Double(l[511]) / 0.25)
        #expect(abs(keyedDb + (20 * log10(0.5) + 20) * 0.75) < 0.01, "keyed live: \(keyedDb) dB")
        #expect(dalnok_plugin_set_sidechain(e, t, slot, 0) == DALNOK_OK)
        for _ in 0..<20 { _ = dalnok_engine_pump(e, &l, &r, 512) }
        let ownDb = 20 * log10(Double(l[511]) / 0.25)
        #expect(abs(ownDb + (20 * log10(0.25) + 20) * 0.75) < 0.01, "after disconnecting live: \(ownDb) dB")
    }

    @Test func sidechainFilterAndListen() {
        // A 50 Hz key: with the side-chain filter at 1 kHz it barely triggers the compressor.
        let bed = [Float](repeating: 0.25, count: n)
        let key = (0..<n).map { Float(0.5 * sin(2 * Double.pi * 50 * Double($0) / 48_000)) }
        let (e, t) = session([bed, bed]); defer { dalnok_engine_destroy(e) }
        let source = dalnok_track_add(e, "Key")
        let km = makeMedia([key, key]); defer { dalnok_media_release(km) }
        DalnokEngine.dalnok_clip_add(e, source, dalnok_pool_add(e, km, ""), 0, 0, 0)
        dalnok_track_set_mute(e, source, true)
        let slot = addCompressor(e, t)
        #expect(dalnok_plugin_set_sidechain(e, t, slot, source) == DALNOK_OK)
        var c = Comp(); c.knee = 0; c.attack = 1; c.release = 200
        c.apply(e, slot)
        let open = render(e, frames: n)
        c.filter = true; c.filterHz = 1_000
        c.apply(e, slot)
        let filtered = render(e, frames: n)
        let (ref, _, _) = c.reference(bed, bed, keyL: key, keyR: key)
        #expect(worst(filtered.0, ref) < 2e-6, "filtered differs by \(worst(filtered.0, ref)) \(filtered.0[100]) \(ref[100])")
        let openDb = 20 * log10(Double(open.0[n - 1]) / 0.25), filteredDb = 20 * log10(Double(filtered.0[n - 1]) / 0.25)
        #expect(openDb < -8 && filteredDb > -1, "unfiltered \(openDb) dB, filtered \(filteredDb) dB")

        c.listen = true
        c.apply(e, slot)
        let heard = render(e, frames: n)
        let (refListen, _, _) = c.reference(bed, bed, keyL: key, keyR: key)
        #expect(worst(heard.0, refListen) < 2e-6, "Listen plays the filtered key")
    }

    @Test func stateSurvivesSaveAndReopen() throws {
        let dir = tempDir(), project = dir.appendingPathComponent("comp.dalnok"), wav = dir.appendingPathComponent("in.wav")
        _ = try writeTestWav(wav, frames: n)
        var err = [CChar](repeating: 0, count: 256)
        var before: ([Float], [Float]) = ([], [])
        do {
            let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
            let t = dalnok_track_add(e, "Main"), key = dalnok_track_add(e, "Key")
            var media: OpaquePointer?
            #expect(dalnok_media_load(wav.path, 48_000, &media, &err, 256) == DALNOK_OK)
            DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, media, wav.path), 0, 0, 0)
            DalnokEngine.dalnok_clip_add(e, key, dalnok_pool_add(e, media, wav.path), 2_000, 0, 0)
            dalnok_media_release(media)
            let slot = addCompressor(e, t)
            var c = Comp(); c.threshold = -30; c.ratio = 8; c.rms = true; c.makeup = 4
            c.apply(e, slot)
            #expect(dalnok_plugin_set_sidechain(e, t, slot, key) == DALNOK_OK)
            before = render(e, frames: n)
            #expect(dalnok_project_save(e, project.path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        }
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        #expect(dalnok_project_load(e, project.path, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let after = render(e, frames: n)
        #expect(after.0 == before.0 && after.1 == before.1, "settings and the sidechain come back exactly")
    }
}
