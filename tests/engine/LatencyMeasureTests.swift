// Loopback latency measurement on the simulated input: the "input" is the engine's own output, delayed.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct LatencyMeasure {
    /// Runs the probe with the output fed back after `delay` frames (plus `noise`); returns the result.
    func measure(delay: Int, gain: Float = 1, noise: Float = 0, channel: Int32 = 2) -> DalnokLatencyResult {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_latency_measure_start(e, DALNOK_SIMULATED_INPUT, channel, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var history = [Float](repeating: 0, count: delay) // output written so far, not yet heard
        var result = DalnokLatencyResult()
        var l = [Float](repeating: 0, count: 512), r = l
        var seed: UInt32 = 7
        for _ in 0..<400 {
            var input = Array(history.prefix(512))
            input += [Float](repeating: 0, count: 512 - input.count)
            for i in 0..<512 { seed = seed &* 1_664_525 &+ 1_013_904_223; input[i] = input[i] * gain + noise * (Float(seed >> 8) / 8_388_608 - 1) }
            history.removeFirst(min(512, history.count))
            let silent = [Float](repeating: 0, count: 512)
            let ok: Bool = withExtendedLifetime((input, silent)) {
                let p = input.withUnsafeBufferPointer { $0.baseAddress }, s = silent.withUnsafeBufferPointer { $0.baseAddress }
                let channels = (0..<4).map { $0 == Int(channel) ? p : s }
                return dalnok_engine_pump_input_channels(e, channels, 4, &l, &r, 512) == DALNOK_OK
            }
            #expect(ok)
            history += l
            if dalnok_latency_measure_poll(e, &result) { return result }
        }
        Issue.record("the measurement never finished")
        return result
    }

    @Test func measuresTheRoundTripExactly() {
        for delay in [512, 513, 777, 1_024, 4_321] { // the emulated loop is at least one 512-frame block, as on hardware
            let r = measure(delay: delay)
            #expect(r.ok && r.measured_frames == Int64(delay) && r.spread_frames == 0 && r.clicks >= 8,
                    "delay \(delay): measured \(r.measured_frames), clicks \(r.clicks), \(cstr(withUnsafeBytes(of: r.error) { Array($0.bindMemory(to: CChar.self)) }))")
        }
    }

    @Test func aQuietNoisyLoopStillMeasures() {
        let r = measure(delay: 1_000, gain: 0.05, noise: 0.002)
        #expect(r.ok && r.measured_frames == 1_000, "measured \(r.measured_frames) with \(r.clicks) clicks")
    }

    @Test func nothingHeardIsAnErrorNotANumber() {
        let r = measure(delay: 100, gain: 0)
        #expect(!r.ok && r.clicks == 0)
    }

    @Test func refusedWhileRecording() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "A"); _ = dalnok_track_set_armed(e, t, true)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, tempDir().path, nil, 0) == DALNOK_OK)
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_latency_measure_start(e, DALNOK_SIMULATED_INPUT, 0, &err, 256) != DALNOK_OK && cstr(err).contains("recording"))
        var result = DalnokRecordResult()
        _ = dalnok_record_stop(e, &result, nil, 0)
    }
}
