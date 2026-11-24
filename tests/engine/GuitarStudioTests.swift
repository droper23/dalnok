// Guitar Studio: numeric offline render checks through the public plug-in API.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

private func guitarStudioSession(_ samples: [Float], rate: Double) -> (OpaquePointer, Int32) {
    let e = dalnok_engine_create(rate)!
    let track = dalnok_track_add(e, "Generated guitar")
    let media = makeMedia([samples, samples], rate: rate)
    _ = dalnok_clip_add(e, track, media, 0, 0, 0)
    dalnok_media_release(media)
    let slot = dalnok_plugin_add(e, track, "dalnok:guitar-studio", nil, nil, 0)
    #expect(slot != 0)
    return (e, slot)
}
private func rigSet(_ e: OpaquePointer, _ slot: Int32, _ values: [UInt32: Double]) {
    for (id, value) in values { #expect(dalnok_plugin_set_parameter(e, slot, id, value) == DALNOK_OK) }
}
private func rigEnergy(_ samples: ArraySlice<Float>) -> Double {
    samples.reduce(0) { $0 + Double($1) * Double($1) }
}

@Suite struct GuitarStudioTests {
    @Test(arguments: [44_100.0, 48_000.0])
    func dryMixNullsAndOfflineIsDeterministic(rate: Double) {
        let x = (0..<Int(rate / 2)).map { Float(0.3 * sin(2 * .pi * 110 * Double($0) / rate)) }
        let (e, slot) = guitarStudioSession(x, rate: rate); defer { dalnok_engine_destroy(e) }
        rigSet(e, slot, [22: 0])
        let dry = renderStereo(e, x.count)
        #expect(zip(dry.0, x).allSatisfy { abs($0 - $1) < 1e-7 })
        rigSet(e, slot, [22: 1])
        let a = renderStereo(e, x.count), b = renderStereo(e, x.count)
        #expect(a.0 == b.0 && a.1 == b.1)
        #expect(rigEnergy(a.0[1000...]) > 0.01)
        #expect(zip(a.0, x).contains { abs($0 - $1) > 0.01 })
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func echoOccursAtSelectedTimeAndFeedbackFalls(rate: Double) {
        var x = [Float](repeating: 0, count: Int(rate))
        for i in 100..<500 { x[i] = Float(0.3 * sin(2 * .pi * 440 * Double(i) / rate)) }
        let (e, slot) = guitarStudioSession(x, rate: rate); defer { dalnok_engine_destroy(e) }
        // Gate disabled, no compression/room/chorus, 200 ms echo, 50% feedback, 60% send.
        rigSet(e, slot, [1: 0, 2: 0, 12: 0, 14: 0, 15: log(200 / 25.0) / log(1500 / 25.0),
                          16: 50 / 85.0, 17: 1, 20: 0])
        let (l, r) = renderStereo(e, x.count)
        let n = Int(rate * 0.2)
        let before = rigEnergy(l[(n - 1000)..<n])
        let first = rigEnergy(l[n..<(n + 2000)])
        let second = rigEnergy(l[(2 * n)..<(2 * n + 2000)])
        #expect(before < 1e-9)
        #expect(first > 0.001)
        #expect(second / first > 0.15 && second / first < 0.30)
        #expect(l == r, "modulation and room disabled preserve mono")
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func cabinetSuppressesFizzAndGateRejectsNoise(rate: Double) {
        let x = (0..<Int(rate / 2)).map { Float(0.02 * sin(2 * .pi * 8000 * Double($0) / rate)) }
        let (e, slot) = guitarStudioSession(x, rate: rate); defer { dalnok_engine_destroy(e) }
        rigSet(e, slot, [1: 0, 2: 0, 4: 0, 8: 1, 9: 0, 20: 0])
        let open = renderStereo(e, x.count)
        rigSet(e, slot, [9: 1])
        let cabinet = renderStereo(e, x.count)
        let openEnergy = rigEnergy(open.0[1000...])
        #expect(openEnergy > 0.01)
        #expect(rigEnergy(cabinet.0[1000...]) / openEnergy < 0.03,
                "closed cabinet attenuates 8 kHz by at least 15 dB")
        rigSet(e, slot, [1: 1, 9: 0]) // -20 dB gate, signal remains below its threshold
        let gated = renderStereo(e, x.count)
        #expect(rigEnergy(gated.0[1000...]) < 1e-12)
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func oversamplingReducesFoldedDriveHarmonics(rate: Double) {
        let hz = 7000.0
        let x = (0..<Int(rate / 2)).map { Float(0.3 * sin(2 * .pi * hz * Double($0) / rate)) }
        let (e, slot) = guitarStudioSession(x, rate: rate); defer { dalnok_engine_destroy(e) }
        rigSet(e, slot, [1: 0, 2: 0, 3: 1, 4: 1, 9: 0, 20: 0])
        let wet = renderStereo(e, x.count).0
        let drive = pow(10.0, 48 / 20.0)
        let naive = x.map { Float(tanh(Double($0) * drive) / sqrt(drive)) }
        // The fifth harmonic lies above Nyquist and folds to |rate - 35 kHz|.
        // Compare alias/fundamental ratios so the output gain and low-pass loss cannot fake success.
        func amplitude(_ samples: [Float], _ frequency: Double) -> Double {
            var re = 0.0, im = 0.0
            let start = Int(rate / 5), end = Int(rate * 2 / 5)
            for i in start..<end {
                let phase = 2 * Double.pi * frequency * Double(i) / rate
                re += Double(samples[i]) * cos(phase)
                im += Double(samples[i]) * sin(phase)
            }
            return hypot(re, im)
        }
        let aliasHz = abs(rate - hz * 5)
        let wetAlias = amplitude(wet, aliasHz) / amplitude(wet, hz)
        let naiveAlias = amplitude(naive, aliasHz) / amplitude(naive, hz)
        #expect(naiveAlias > 0.1, "reference generates the intended alias")
        #expect(wetAlias < naiveAlias * 0.3,
                "oversampled alias ratio \(wetAlias), base-rate reference \(naiveAlias)")
    }

    @Test(arguments: [44_100.0, 48_000.0])
    func extremeControlsStayFiniteAndRoomDecays(rate: Double) {
        var x = [Float](repeating: 0, count: Int(rate * 3))
        for i in 0..<Int(rate * 0.1) { x[i] = Float(0.9 * sin(2 * .pi * 82.41 * Double(i) / rate)) }
        let (e, slot) = guitarStudioSession(x, rate: rate); defer { dalnok_engine_destroy(e) }
        rigSet(e, slot, [0: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1, 7: 1, 8: 1,
                          10: 1, 11: 1, 12: 1, 13: 1, 14: 1, 16: 1, 17: 1,
                          18: 0, 19: 1, 20: 1, 21: 1])
        let (l, r) = renderStereo(e, x.count)
        #expect(l.allSatisfy { $0.isFinite && abs($0) < 32 })
        #expect(r.allSatisfy { $0.isFinite && abs($0) < 32 })
        // Disable echo: the shortest room must die away, rather than retaining unstable feedback.
        rigSet(e, slot, [17: 0])
        let room = renderStereo(e, x.count)
        #expect(rigEnergy(room.0[Int(rate / 10)..<Int(rate / 2)]) > 1e-8)
        #expect(rigEnergy(room.0[Int(rate * 2)...]) < 1e-12)
    }
}
