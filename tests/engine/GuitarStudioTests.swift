// Guitar Studio: numeric checks of the module chain through the public plug-in API (offline and live renders).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Module types in the engine's order (guitar_modules.hpp).
private enum Mod: Int, CaseIterable {
    case empty, gate, compressor, boost, overdrive, distortion, fuzz, ampClean, ampCrunch, ampLead, cabinet, eq,
         wah, chorus, flanger, phaser, tremolo, vibrato, delay, reverb, spring
    static let count = 21
}
private func typeId(_ s: Int) -> UInt32 { UInt32(2 + s * 8) }
private func onId(_ s: Int) -> UInt32 { typeId(s) + 1 }
private func knobId(_ s: Int, _ k: Int) -> UInt32 { typeId(s) + 2 + UInt32(k) }
private func lin(_ v: Double, _ lo: Double, _ hi: Double) -> Double { (v - lo) / (hi - lo) }
private func log(_ v: Double, _ lo: Double, _ hi: Double) -> Double { Foundation.log(v / lo) / Foundation.log(hi / lo) }

private func studio(_ samples: [Float], rate: Double, chain: [(Mod, [Int: Double])] = []) -> (OpaquePointer, Int32) {
    let e = dalnok_engine_create(rate)!
    let track = dalnok_track_add(e, "Generated guitar")
    let media = makeMedia([samples, samples], rate: rate)
    _ = dalnok_clip_add(e, track, media, 0, 0, 0)
    dalnok_media_release(media)
    let slot = dalnok_plugin_add(e, track, "dalnok:guitar-studio", nil, nil, 0)
    #expect(slot != 0)
    for s in 0..<8 { setModule(e, slot, s, s < chain.count ? chain[s].0 : .empty, s < chain.count ? chain[s].1 : [:]) }
    return (e, slot)
}
private func setModule(_ e: OpaquePointer, _ slot: Int32, _ s: Int, _ m: Mod, _ knobs: [Int: Double] = [:]) {
    #expect(dalnok_plugin_set_parameter(e, slot, typeId(s), Double(m.rawValue) / Double(Mod.count - 1)) == DALNOK_OK)
    for (k, v) in knobs { #expect(dalnok_plugin_set_parameter(e, slot, knobId(s, k), v) == DALNOK_OK) }
}
private func parameter(_ e: OpaquePointer, _ slot: Int32, _ id: UInt32) -> DalnokPluginParameter {
    var p = DalnokPluginParameter()
    #expect(dalnok_plugin_parameter(e, slot, Int32(id), &p) == DALNOK_OK) // index == id
    return p
}
private func text(_ e: OpaquePointer, _ slot: Int32, _ id: UInt32, _ v: Double) -> String {
    var buf = [CChar](repeating: 0, count: 64)
    _ = dalnok_plugin_parameter_text(e, slot, id, v, &buf, 64)
    return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
private func srms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))) }
private func dB(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }
private func sine(_ hz: Double, _ amp: Double, _ n: Int, _ rate: Double) -> [Float] {
    (0..<n).map { Float(amp * sin(2 * .pi * hz * Double($0) / rate)) }
}
/// A plucked low E: decaying harmonics plus a little noise, deterministic.
private func pluck(_ n: Int, _ rate: Double) -> [Float] {
    var seed: UInt32 = 1
    return (0..<n).map { i in
        let t = Double(i) / rate
        var x = 0.0
        for h in 1...8 { x += sin(2 * .pi * 82.41 * Double(h) * t) * exp(-t * (1.5 + Double(h))) / Double(h) }
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(0.45 * x + 0.002 * (Double(seed >> 8) / 8_388_608 - 1))
    }
}
/// Hann-windowed amplitude at one frequency.
private func amplitude(_ x: ArraySlice<Float>, _ hz: Double, _ rate: Double) -> Double {
    var re = 0.0, im = 0.0, w = 0.0
    let n = x.count
    for (i, s) in x.enumerated() {
        let win = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)), ph = 2 * .pi * hz * Double(i) / rate
        re += Double(s) * win * cos(ph); im += Double(s) * win * sin(ph); w += win
    }
    return 2 * sqrt(re * re + im * im) / w
}

@Suite struct GuitarStudioTests {
    @Test(arguments: [44_100.0, 48_000.0])
    func emptyChainIsTransparentAndDefaultRigIsDeterministic(rate: Double) {
        let x = pluck(Int(rate / 2), rate)
        let (e, slot) = studio(x, rate: rate); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, x.count)
        #expect(zip(dry.0, x).allSatisfy { abs($0 - $1) < 1e-6 } && dry.0 == dry.1)
        // A fresh instance is a complete rig: gate, compressor, crunch amp, cabinet, delay, reverb.
        let (d, rig) = { () -> (OpaquePointer, Int32) in
            let e = dalnok_engine_create(rate)!
            let t = dalnok_track_add(e, "Rig")
            let m = makeMedia([x, x], rate: rate); _ = dalnok_clip_add(e, t, m, 0, 0, 0); dalnok_media_release(m)
            return (e, dalnok_plugin_add(e, t, "dalnok:guitar-studio", nil, nil, 0))
        }()
        defer { dalnok_engine_destroy(d) }
        let names = (0..<8).map { text(d, rig, typeId($0), parameter(d, rig, typeId($0)).value) }
        #expect(names == ["Noise Gate", "Compressor", "Amp Crunch", "Cabinet", "Delay", "Reverb", "Empty", "Empty"])
        let a = renderStereo(d, x.count), b = renderStereo(d, x.count)
        #expect(a.0 == b.0 && a.1 == b.1)
        #expect(a.0.allSatisfy(\.isFinite) && srms(a.0[...]) > 0.01 && a.0 != a.1)
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func everyModuleIsFiniteBoundedAndBypassesExactly(rate: Double) {
        let x = pluck(Int(rate * 0.6), rate)
        for m in Mod.allCases where m != .empty {
            let (e, slot) = studio(x, rate: rate, chain: [(m, [:])]); defer { dalnok_engine_destroy(e) }
            #expect(name(parameter(e, slot, typeId(0)).title) == "1 \(text(e, slot, typeId(0), Double(m.rawValue) / 20)) Module")
            let (l, r) = renderStereo(e, x.count)
            let peak = (l + r).map { abs($0) }.max() ?? 0
            #expect(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite), "\(m) stays finite")
            #expect(peak < 4, "\(m) stays bounded (\(peak))")
            if ![.gate, .eq].contains(m) { #expect(zip(l, x).contains { abs($0 - $1) > 0.005 }, "\(m) changes the sound") }
            #expect(dalnok_plugin_set_parameter(e, slot, onId(0), 0) == DALNOK_OK)
            let off = renderStereo(e, x.count)
            #expect(off.0 == x && off.1 == x, "\(m) switched off passes the input exactly")
        }
    }

    @Test func choosingAModuleRelabelsAndResetsItsControls() {
        let (e, slot) = studio(sine(110, 0.3, 4800, 48000), rate: 48000, chain: [(.delay, [:])]); defer { dalnok_engine_destroy(e) }
        let time = parameter(e, slot, knobId(0, 0))
        #expect(name(time.title) == "1 Delay Time" && name(time.display) == "380 ms" && !time.hidden)
        #expect(abs(time.value - log(380, 20, 2000)) < 1e-9 && abs(time.default_value - time.value) < 1e-9)
        #expect(dalnok_plugin_set_parameter(e, slot, knobId(0, 0), 0.9) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, onId(0), 0) == DALNOK_OK)
        setModule(e, slot, 0, .tremolo) // a new module starts on, at its own defaults
        #expect(name(parameter(e, slot, knobId(0, 0)).title) == "1 Tremolo Rate")
        #expect(name(parameter(e, slot, knobId(0, 0)).display) == "5.00 Hz")
        #expect(parameter(e, slot, onId(0)).value == 1)
        #expect(parameter(e, slot, knobId(0, 4)).hidden && parameter(e, slot, knobId(0, 5)).hidden) // Tremolo has 4 knobs
        #expect(parameter(e, slot, typeId(1)).hidden && parameter(e, slot, knobId(1, 0)).hidden) // an empty slot
        #expect(!parameter(e, slot, typeId(0)).automatable)
        #expect(text(e, slot, typeId(0), 19.0 / 20) == "Reverb" && text(e, slot, knobId(0, 1), 1) == "100 %")
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func delayRepeatsAtItsTimeAndFeedbackFalls(rate: Double) {
        var x = [Float](repeating: 0, count: Int(rate * 0.7)); x[100] = 0.2
        let (e, _) = studio(x, rate: rate, chain: [(.delay, [0: log(250, 20, 2000), 1: lin(50, 0, 95), 2: 1, 3: 0, 5: 0.5])])
        defer { dalnok_engine_destroy(e) }
        let (l, r) = renderStereo(e, x.count)
        let d = Int((0.25 * rate).rounded())
        #expect(abs(l[100] - 0.2) < 1e-6, "dry stays at full level at 50 % mix")
        let first = l[(100 + d - 40)...(100 + d + 40)], second = l[(100 + 2 * d - 40)...(100 + 2 * d + 40)]
        let at = first.indices.max { abs(l[$0]) < abs(l[$1]) }!
        #expect(at == 100 + d && abs(Double(l[at]) - 0.2) < 0.002, "the first repeat is the input, unsaturated: \(l[at])")
        let ratio = srms(second) / srms(first)
        #expect(ratio > 0.3 && ratio < 0.55, "second repeat \(ratio) of the first")
        #expect(l == r, "no ping-pong: both sides repeat alike")
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func reverbDecaysNearItsSettingAndIsStereo(rate: Double) {
        var x = [Float](repeating: 0, count: Int(rate * 2.5)); x[10] = 0.5
        let (e, _) = studio(x, rate: rate, chain: [(.reverb, [0: log(1.5, 0.2, 12), 1: 0.6, 2: 0, 3: 1, 4: 0, 5: 1])])
        defer { dalnok_engine_destroy(e) }
        let (l, r) = renderStereo(e, x.count)
        let w = Int(rate * 0.05)
        let energy = stride(from: 0, to: l.count - w, by: w).map { srms(l[$0..<($0 + w)]) + srms(r[$0..<($0 + w)]) }
        let top = energy.indices.max { energy[$0] < energy[$1] }!
        let fall = energy.indices.first { $0 > top && dB(energy[$0] / energy[top]) < -30 }
        let rt60 = Double(((fall ?? energy.count) - top) * w) / rate * 2
        #expect(rt60 > 1.5 * 0.65 && rt60 < 1.5 * 1.35, "RT60 \(rt60) s for 1.5 s")
        let n = Int(rate * 0.8)
        let dot = zip(l[w..<n], r[w..<n]).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        let corr = dot / (srms(l[w..<n]) * srms(r[w..<n]) * Double(n - w))
        #expect(abs(corr) < 0.5, "left and right tails decorrelate (\(corr))")
    }

    @Test func compressorNarrowsLevelsAndGateClosesOnNoise() {
        let rate = 48_000.0, n = Int(rate * 0.5)
        func level(_ amp: Double, _ chain: [(Mod, [Int: Double])]) -> Double {
            let (e, _) = studio(sine(220, amp, n, rate), rate: rate, chain: chain); defer { dalnok_engine_destroy(e) }
            return dB(srms(renderStereo(e, n).0[(n / 2)...]))
        }
        let comp: [(Mod, [Int: Double])] = [(.compressor, [0: lin(-30, -50, 0), 1: log(8, 1, 20), 2: log(1, 0.1, 100), 3: log(100, 20, 1000), 4: 0, 5: 1])]
        let spread = level(0.5, comp) - level(0.05, comp)
        #expect(spread < 6, "20 dB of input spread becomes \(spread) dB")
        let gate: [(Mod, [Int: Double])] = [(.gate, [0: lin(-50, -90, -20), 1: log(50, 5, 1000), 2: lin(80, 0, 90)])]
        let quiet = level(0.0003, gate) - dB(0.0003 / sqrt(2)), loud = level(0.1, gate) - dB(0.1 / sqrt(2))
        #expect(quiet < -60 && abs(loud) < 0.2, "gate: \(quiet) dB on noise, \(loud) dB on a note")
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func cabinetAndEqShapeTheSpectrum(rate: Double) {
        let n = Int(rate * 0.4)
        func gain(_ hz: Double, _ chain: [(Mod, [Int: Double])]) -> Double {
            let (e, _) = studio(sine(hz, 0.1, n, rate), rate: rate, chain: chain); defer { dalnok_engine_destroy(e) }
            return dB(srms(renderStereo(e, n).0[(n / 2)...]) / (0.1 / sqrt(2)))
        }
        let cab = gain(1000, [(.cabinet, [:])]) - gain(9000, [(.cabinet, [:])])
        #expect(cab > 25, "the cabinet keeps fizz \(cab) dB below the midrange")
        let eq: [(Mod, [Int: Double])] = [(.eq, [1: lin(12, -15, 15)])]
        let bass = gain(40, eq), mid = gain(1000, eq)
        #expect(bass > 10.5 && bass < 12.5 && abs(mid) < 0.7, "EQ bass +12 dB: \(bass) dB at 40 Hz, \(mid) dB at 1 kHz")
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func oversampledDistortionKeepsAliasesLow(rate: Double) {
        let n = Int(rate * 0.5), f = 4_500.0
        let (e, _) = studio(sine(f, 0.5, n, rate), rate: rate, chain: [(.distortion, [0: 1, 1: 1, 3: 1])])
        defer { dalnok_engine_destroy(e) }
        let y = renderStereo(e, n).0[(n / 4)...]
        let fundamental = amplitude(y, f, rate)
        // Odd harmonics above Nyquist fold back to inharmonic frequencies; measure the strongest of them.
        let folded = [7.0, 9.0, 11.0].map { h -> Double in
            var a = h * f
            while a > rate / 2 { a = abs(rate - a) }
            return amplitude(y, a, rate)
        }.max()!
        #expect(dB(folded / fundamental) < -45, "strongest alias \(dB(folded / fundamental)) dB")
    }

    @Test func tremoloDepthAndLiveModuleSwitchIsClickFree() {
        let rate = 48_000.0, n = Int(rate)
        do {
            let (e, _) = studio(sine(1000, 0.3, n, rate), rate: rate, chain: [(.tremolo, [:])]); defer { dalnok_engine_destroy(e) }
            let l = renderStereo(e, n).0
            let w = Int(rate * 0.004)
            let env = stride(from: w, to: n - w, by: w).map { srms(l[$0..<($0 + w)]) }
            let ratio = env.max()! / env.min()!
            #expect(ratio > 2.2 && ratio < 2.8, "60 % depth swings \(ratio)x (2.5x)")
        }
        // Live: inserting chorus and switching modules while a note plays never steps the waveform.
        let x = sine(110, 0.3, n, rate)
        let (e, slot) = studio(x, rate: rate); defer { dalnok_engine_destroy(e) }
        dalnok_transport_play(e)
        var l = [Float](repeating: 0, count: 256), r = l, out: [Float] = []
        for block in 0..<120 {
            if block == 40 { setModule(e, slot, 0, .chorus) }
            if block == 70 { setModule(e, slot, 0, .phaser) }
            if block == 100 { #expect(dalnok_plugin_set_parameter(e, slot, onId(0), 0) == DALNOK_OK) }
            dalnok_engine_pump(e, &l, &r, 256)
            out += l
        }
        let step = zip(out.dropFirst(), out).map { abs($0 - $1) }.dropFirst(2048).max()!
        #expect(step < 0.02, "largest sample step \(step) (the note's own is 0.0043)")
    }

    /// A project saved with the first Guitar Studio (a fixed chain, parameters 0-22) opens as the same rig of modules.
    @Test func firstVersionStatesLoadAsTheEquivalentRig() throws {
        let rate = 48_000.0
        let (e, slot) = studio(pluck(Int(rate), rate), rate: rate); defer { dalnok_engine_destroy(e) }
        let old: [String: Double] = ["0": 3, "1": -60, "2": 40, "3": 2, "4": 70, "5": 6, "6": -3, "7": 0, "8": 1, "9": 80,
                                     "10": 0.7, "11": 2, "12": 0, "13": 4, "14": 50, "15": 375, "16": 30, "17": 20,
                                     "18": 1.8, "19": 5000, "20": 0, "21": -10, "22": 100]
        let json = try JSONSerialization.data(withJSONObject: ["plugin": "guitar-studio", "version": 1, "values": old])
        #expect(dalnok_plugin_set_state(e, slot, json.base64EncodedString()) == DALNOK_OK)
        let names = (0..<8).map { text(e, slot, typeId($0), parameter(e, slot, typeId($0)).value) }
        // Chorus (mix 0) and room (mix 0) were unused, so they're left out.
        #expect(names == ["Noise Gate", "Compressor", "Amp Lead", "Cabinet", "Tremolo", "Delay", "Empty", "Empty"], "\(names)")
        func shown(_ s: Int, _ k: Int) -> String { text(e, slot, knobId(s, k), parameter(e, slot, knobId(s, k)).value) }
        #expect(shown(0, 0) == "-60.0 dB", "gate threshold \(shown(0, 0))")
        #expect(shown(2, 0) == "70 %" && shown(2, 1) == "7.5" && shown(2, 2) == "3.8" && shown(2, 3) == "5.0",
                "amp gain and tone stack \([0, 1, 2, 3].map { shown(2, $0) })")
        #expect(shown(3, 0) == "2x12" && shown(3, 5) == "80 %", "cabinet \(shown(3, 0)), mix \(shown(3, 5))")
        #expect(shown(4, 1) == "50 %" && shown(5, 0) == "375 ms" && shown(5, 5) == "20 %")
        #expect(abs(parameter(e, slot, 0).value - 27.0 / 48) < 1e-9 && abs(parameter(e, slot, 1).value - 26.0 / 48) < 1e-9,
                "input +3 dB, output -10 dB")
        let (l, _) = renderStereo(e, Int(rate))
        #expect(l.allSatisfy(\.isFinite) && srms(l[...]) > 0.01)
        // A current state round-trips unchanged (not mistaken for an old one).
        var buf = [CChar](repeating: 0, count: 16_384)
        _ = dalnok_plugin_get_state(e, slot, &buf, buf.count)
        #expect(dalnok_plugin_set_state(e, slot, String(cString: buf)) == DALNOK_OK)
        #expect((0..<8).map { text(e, slot, typeId($0), parameter(e, slot, typeId($0)).value) } == names)
    }

    /// Knob smoothing follows time, not the host's block size: a drive change sounds the same in 8- and 64-frame blocks.
    @Test func knobSmoothingIsIndependentOfBlockSize() {
        let rate = 48_000.0, n = 9_600
        func run(_ block: Int) -> [Float] {
            let (e, slot) = studio(sine(220, 0.3, n, rate), rate: rate, chain: [(.overdrive, [0: 0])]); defer { dalnok_engine_destroy(e) }
            dalnok_transport_play(e)
            var l = [Float](repeating: 0, count: block), r = l, out: [Float] = []
            while out.count < n {
                if out.count == 4_096 { #expect(dalnok_plugin_set_parameter(e, slot, knobId(0, 0), 1) == DALNOK_OK) }
                dalnok_engine_pump(e, &l, &r, Int32(block))
                out += l
            }
            return out
        }
        let a = run(8), b = run(64)
        let w = 96 // 2 ms loudness windows through the change
        let diff = stride(from: 4_096, to: 8_000, by: w).map { abs(dB(srms(a[$0..<($0 + w)])) - dB(srms(b[$0..<($0 + w)]))) }.max()!
        #expect(diff < 0.1, "loudness through a drive change differs by \(diff) dB between block sizes")
    }
}

