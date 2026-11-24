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
    @Test func zeroAmountPreservesAudioWithCompensatedLatency() {
        let (e, slot) = session(rate: 48000, hz: 226)
        defer { dalnok_engine_destroy(e) }
        dalnok_plugin_set_parameter(e, slot, 0, 0)
        let wet = renderStereo(e, 144000).0
        let dry = (0..<144000).map { Float(0.3 * sin(2 * Double.pi * 226 * Double($0) / 48000)) }
        let error = zip(wet[4800..<130000], dry[4800..<130000]).map { abs($0 - $1) }.max() ?? 1
        #expect(error < 1e-5, "zero amount nulls after host delay compensation: \(error)")
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
