// Guitar tuning: measure rendered pitch, not only parameter plumbing.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct GuitarTuneTests {
    private func session(rate: Double, hz: Double, harmonic: Bool = false) -> (OpaquePointer, Int32) {
        let e = dalnok_engine_create(rate)!
        let t = dalnok_track_add(e, "Guitar DI")
        let samples = (0..<Int(rate * 3)).map { i -> Float in
            let phase = 2 * Double.pi * hz * Double(i) / rate
            return Float(0.3 * sin(phase) + (harmonic ? 0.12 * sin(2 * phase) + 0.07 * sin(3 * phase) : 0))
        }
        let m = makeMedia([samples, samples], rate: rate)
        dalnok_clip_add(e, t, m, 0, 0, 0); dalnok_media_release(m)
        let slot = dalnok_plugin_add(e, t, "dalnok:guitar-tune", nil, nil, 0)
        #expect(slot != 0)
        #expect(dalnok_plugin_set_parameter(e, slot, 0, 1) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, 1, 0) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, 2, 0) == DALNOK_OK)
        return (e, slot)
    }
    // Correlate against nearby frequencies: independent of the detector, robust to
    // crossfade amplitude modulation, sub-cent grid over a two-second steady region.
    private func dominant(_ samples: [Float], rate: Double, target: Double) -> Double {
        let signal = samples[Int(rate)..<Int(rate * 2.8)]
        var best = 0.0, bestHz = 0.0
        for cents in -100...100 {
            let hz = target * pow(2, Double(cents) / 2400)
            let step = 2 * Double.pi * hz / rate
            let cr = cos(step), ci = sin(step)
            var re = 0.0, im = 0.0, oscR = 1.0, oscI = 0.0
            for x in signal {
                re += Double(x) * oscR; im += Double(x) * oscI
                let next = oscR * cr - oscI * ci
                oscI = oscI * cr + oscR * ci; oscR = next
            }
            let power = re * re + im * im
            if power > best { best = power; bestHz = hz }
        }
        return bestHz
    }
    @Test(arguments: [44100.0, 48000.0])
    func correctsSharpAndFlatGuitarNotes(rate: Double) {
        for (target, detune) in [(82.4069, 24.0), (220.0, -28.0), (659.255, 21.0)] {
            let (e, _) = session(rate: rate, hz: target * pow(2, detune / 1200), harmonic: true)
            defer { dalnok_engine_destroy(e) }
            let (l, r) = renderStereo(e, Int(rate * 3))
            let measured = dominant(l, rate: rate, target: target)
            let error = 1200 * log2(measured / target)
            #expect(abs(error) <= 5, "\(rate) Hz: \(target) corrected within 5 cents, got \(error)")
            #expect(l == r)
            #expect(l.allSatisfy { $0.isFinite && abs($0) < 1 })
        }
    }
    @Test(arguments: [44100.0, 48000.0])
    func zeroAmountPreservesAudioWithCompensatedLatency(rate: Double) {
        let (e, slot) = session(rate: rate, hz: 226)
        defer { dalnok_engine_destroy(e) }
        dalnok_plugin_set_parameter(e, slot, 0, 0)
        let n = Int(rate * 3)
        let wet = renderStereo(e, n).0
        let dry = (0..<n).map { Float(0.3 * sin(2 * Double.pi * 226 * Double($0) / rate)) }
        let error = zip(wet[4800..<(n - 14000)], dry[4800..<(n - 14000)]).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-5, "\(rate) Hz: zero amount nulls after host delay compensation: \(error)")
    }
    /// A sharp note is corrected, then an in-tune note follows: once it settles the output is the input again,
    /// exactly (one tap at the reported latency), not two heads left straddling it (a comb that hollows the tone).
    @Test(arguments: [44100.0, 48000.0])
    func returnsToTransparentAfterACorrection(rate: Double) {
        let e = dalnok_engine_create(rate)!
        defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Guitar DI")
        let n = Int(rate * 4), split = Int(rate * 1.5)
        var phase = 0.0
        let x = (0..<n).map { i -> Float in
            phase += 2 * Double.pi * (i < split ? 220 * pow(2, 30.0 / 1200) : 220) / rate
            return Float(0.3 * sin(phase))
        }
        let m = makeMedia([x, x], rate: rate)
        dalnok_clip_add(e, t, m, 0, 0, 0); dalnok_media_release(m)
        let slot = dalnok_plugin_add(e, t, "dalnok:guitar-tune", nil, nil, 0)
        _ = dalnok_plugin_set_parameter(e, slot, 0, 1)
        _ = dalnok_plugin_set_parameter(e, slot, 2, 0)
        let y = renderStereo(e, n).0
        let tail = Int(rate * 3)..<Int(rate * 3.9)
        let error = tail.map { abs(y[$0] - x[$0]) }.max()!
        #expect(error < 1e-4, "\(rate) Hz: after the correction, the in-tune note passes unchanged (max error \(error))")
        // And the correction did happen: the sharp note left the plug-in near 220 Hz.
        let early = Array(y[Int(rate * 0.5)..<split])
        var best = 0.0, bestHz = 0.0
        for c in -60...60 {
            let hz = 220 * pow(2, Double(c) / 1200), w = 2 * Double.pi * hz / rate
            var re = 0.0, im = 0.0
            for (i, v) in early.enumerated() { re += Double(v) * cos(w * Double(i)); im += Double(v) * sin(w * Double(i)) }
            if re * re + im * im > best { best = re * re + im * im; bestHz = hz }
        }
        #expect(abs(1200 * log2(bestHz / 220)) <= 5, "the sharp note was corrected (\(1200 * log2(bestHz / 220)) cents)")
    }
    /// High notes: the lag is only a dozen analysis samples, so the vertex must be found on the normalized function.
    @Test(arguments: [44100.0, 48000.0])
    func highNotesCorrectWithinThreeCents(rate: Double) {
        for (target, detune) in [(880.0, 18.0), (1046.5, -22.0), (1318.51, 15.0)] {
            let (e, _) = session(rate: rate, hz: target * pow(2, detune / 1200), harmonic: true)
            defer { dalnok_engine_destroy(e) }
            let error = 1200 * log2(dominant(renderStereo(e, Int(rate * 3)).0, rate: rate, target: target) / target)
            #expect(abs(error) <= 3, "\(rate) Hz: \(target) corrected within 3 cents, got \(error)")
        }
    }
    @Test func bendToleranceLeavesOutsideNotesUncorrected() {
        let hz = 220 * pow(2.0, 30.0 / 1200)
        let (e, slot) = session(rate: 48000, hz: hz)
        defer { dalnok_engine_destroy(e) }
        dalnok_plugin_set_parameter(e, slot, 2, 10.0 / 200)
        let measured = dominant(renderStereo(e, 144000).0, rate: 48000, target: 220)
        #expect(abs(1200 * log2(measured / hz)) <= 2)
    }
    @Test func majorScaleTargetsAllowedNotes() {
        let (e, slot) = session(rate: 48000, hz: 230)
        defer { dalnok_engine_destroy(e) }
        dalnok_plugin_set_parameter(e, slot, 5, 0.5) // C major: A# is excluded
        let measured = dominant(renderStereo(e, 144000).0, rate: 48000, target: 220)
        #expect(abs(1200 * log2(measured / 220)) <= 5)
    }
    @Test(arguments: ["guitar-tune", "guitar-studio"])
    func stateAndAudioSurviveSaveReopen(id: String) {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, "dalnok:" + id, nil, nil, 0)
        #expect(dalnok_plugin_set_parameter(e, slot, 0, 0.37) == DALNOK_OK)
        let before = renderStereo(e, 4800)
        let path = tempDir().appendingPathComponent("guitar.dalnok").path
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK)
        let reopened = dalnok_engine_create(48000)!
        defer { dalnok_engine_destroy(reopened) }
        #expect(dalnok_project_load(reopened, path, nil, nil, 0) == DALNOK_OK)
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(reopened, dalnok_track_at(reopened, 0), 0, &info) == DALNOK_OK && info.loaded)
        var p = DalnokPluginParameter()
        #expect(dalnok_plugin_parameter(reopened, info.id, 0, &p) == DALNOK_OK && abs(p.value - 0.37) < 1e-6)
        let after = renderStereo(reopened, 4800)
        #expect(before.0 == after.0 && before.1 == after.1)
    }
    @Test func silenceAndReadOnlyMeters() {
        let e = dalnok_engine_create(48000)!
        defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Silence")
        let slot = dalnok_plugin_add(e, t, "dalnok:guitar-tune", nil, nil, 0)
        for id: UInt32 in [7, 8, 9] { #expect(dalnok_plugin_set_parameter(e, slot, id, 0.5) != DALNOK_OK) }
        let (l, r) = renderStereo(e, 48000)
        #expect(l.allSatisfy { $0 == 0 } && r.allSatisfy { $0 == 0 })
    }
}
