// Real hardware (opt-in): DALNOK_TEST_LOOPBACK="<device name>:<input number>" names an interface whose input hears its
// own output (a loopback input, or a cable). Measures the round trip, then records a playing clip back through that
// input and checks the placed take lines up with the clip to the sample.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

let loopbackSpec = ProcessInfo.processInfo.environment["DALNOK_TEST_LOOPBACK"] ?? ""

@Suite(.serialized, .enabled(if: !loopbackSpec.isEmpty, "set DALNOK_TEST_LOOPBACK=<device>:<input>"))
struct HardwareLoopback {
    func str<T>(_ t: T) -> String { withUnsafeBytes(of: t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }

    @Test func measuredCompensationPlacesALoopbackTakeOnTheSample() throws {
        let parts = loopbackSpec.split(separator: ":")
        let deviceName = String(parts[0]), channel = Int32(parts[1])! - 1
        var inputs = [DalnokInputDeviceInfo](repeating: DalnokInputDeviceInfo(), count: 64)
        let n = Int(dalnok_input_devices(&inputs, 64))
        let device = try #require(inputs.prefix(n).first { str($0.name) == deviceName })
        let uid = str(device.uid)
        let e = dalnok_engine_create(device.sample_rate)!; defer { dalnok_engine_destroy(e) }
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_engine_set_output_device(e, uid, &err, 512) == DALNOK_OK, "\(cstr(err))")
        // Keep the input open across the measurement and the take, as Input Monitoring does: the device's round trip can
        // change by a few samples each time its stream restarts (a Scarlett Solo 4th Gen measures 1136 or 1142 per start).
        let keepOpen = dalnok_track_add(e, "Keep input open")
        _ = dalnok_track_set_input(e, keepOpen, channel == 0 ? 1 : 0)
        _ = dalnok_track_set_mute(e, keepOpen, true)
        #expect(dalnok_input_set_device(e, uid, &err, 512) == DALNOK_OK && dalnok_track_set_input_monitor(e, keepOpen, true) == DALNOK_OK)
        #expect(dalnok_input_running(e))

        // 1. Measure.
        #expect(dalnok_latency_measure_start(e, uid, channel, &err, 512) == DALNOK_OK, "\(cstr(err))")
        var m = DalnokLatencyResult()
        while !dalnok_latency_measure_poll(e, &m) { usleep(20_000) }
        #expect(m.ok && m.spread_frames == 0, "loopback measurement: \(m.measured_frames) frames, spread \(m.spread_frames), \(str(m.error))")
        print("LOOPBACK measured \(m.measured_frames) reported \(m.reported_frames)")
        dalnok_record_set_latency_offset(e, m.measured_frames - m.reported_frames)

        // 2. Play noise on one track, record the loopback on another.
        var seed: UInt32 = 3
        let source = (0..<Int(device.sample_rate) * 3).map { _ -> Float in seed = seed &* 1_664_525 &+ 1_013_904_223; return (Float(seed >> 8) / 8_388_608 - 1) * 0.25 }
        let media = makeMedia([source], rate: device.sample_rate); defer { dalnok_media_release(media) }
        let player = dalnok_track_add(e, "Player"), recorder = dalnok_track_add(e, "Loopback")
        DalnokEngine.dalnok_clip_add(e, player, dalnok_pool_add(e, media, ""), 24_000, 0, 0)
        _ = dalnok_track_set_input(e, recorder, channel)
        _ = dalnok_track_set_armed(e, recorder, true)
        dalnok_transport_seek(e, 0)
        #expect(dalnok_record_start(e, uid, tempDir().path, &err, 512) == DALNOK_OK, "\(cstr(err))")
        usleep(4_000_000)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
        let take = clipInfo(e, result.audio_clip)
        // 3. Where does the clip's audio sit in the take, on the timeline? It should be at frame 24,000.
        let got = mediaSamples(e, take.media, 0, Int(take.length))
        let probe = Array(source[10_000..<10_480])
        var best = 0, bestScore = -1.0
        for lag in 0..<(got.count - probe.count) {
            var acc = 0.0
            for j in stride(from: 0, to: probe.count, by: 1) { acc += Double(got[lag + j] * probe[j]) }
            if acc > bestScore { bestScore = acc; best = lag }
        }
        let timelineFrame = take.start - take.offset + Int64(best) - 10_000
        print("LOOPBACK take starts at \(take.start); clip audio lands at \(timelineFrame) (expected 24000)")
        #expect(timelineFrame == 24_000, "the recorded clip is \(timelineFrame - 24_000) frames off")
        let residual = zip(got[best..<(best + 480)], probe).map { abs($0 - $1) }.max() ?? 1
        #expect(residual < 1e-3, "the loopback copy matches the source (max difference \(residual))")
    }

    /// The automatic check (C API 45), stream after stream: every take opens a new stream (no Input Monitoring keeps
    /// one open), so each can have a different round trip. Everything played is quiet (-60 dBFS noise, -80 dBFS check
    /// bursts): a digital loopback carries it exactly, and nothing is audible on speakers.
    @Test func everyStreamIsCheckedSoEveryTakeLandsOnTheSample() throws {
        let parts = loopbackSpec.split(separator: ":")
        let deviceName = String(parts[0]), channel = Int32(parts[1])! - 1
        var inputs = [DalnokInputDeviceInfo](repeating: DalnokInputDeviceInfo(), count: 64)
        let n = Int(dalnok_input_devices(&inputs, 64))
        let device = try #require(inputs.prefix(n).first { str($0.name) == deviceName })
        let uid = str(device.uid)
        let e = dalnok_engine_create(device.sample_rate)!; defer { dalnok_engine_destroy(e) }
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_engine_set_output_device(e, uid, &err, 512) == DALNOK_OK, "\(cstr(err))")
        #expect(dalnok_latency_auto_set(e, uid, channel, &err, 512) == DALNOK_OK, "\(cstr(err))")
        var seed: UInt32 = 7
        let source = (0..<Int(device.sample_rate) * 3).map { _ -> Float in seed = seed &* 1_664_525 &+ 1_013_904_223; return (Float(seed >> 8) / 8_388_608 - 1) * 0.001 }
        let media = makeMedia([source], rate: device.sample_rate); defer { dalnok_media_release(media) }
        let player = dalnok_track_add(e, "Player"), recorder = dalnok_track_add(e, "Loopback")
        DalnokEngine.dalnok_clip_add(e, player, dalnok_pool_add(e, media, ""), 24_000, 0, 0)
        _ = dalnok_track_set_input(e, recorder, channel)
        _ = dalnok_track_set_armed(e, recorder, true)
        var measured: [Int64] = [], offsets: [Int64] = []
        for _ in 0..<6 {
            dalnok_transport_seek(e, 0)
            #expect(dalnok_record_start(e, uid, tempDir().path, &err, 512) == DALNOK_OK, "\(cstr(err))")
            usleep(2_000_000)
            var result = DalnokRecordResult()
            #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
            var check = DalnokLatencyResult()
            _ = dalnok_latency_auto_result(e, &check)
            #expect(check.ok, "stream check: \(str(check.error)) (correlation \(check.spread_frames))")
            #expect(result.latency_frames == check.measured_frames, "the take used its stream's round trip")
            measured.append(check.measured_frames)
            let take = clipInfo(e, result.audio_clip)
            let got = mediaSamples(e, take.media, 0, Int(take.length))
            let probe = Array(source[20_000..<20_960])
            var best = 0, bestScore = -1.0
            for lag in 0..<(got.count - probe.count) {
                var acc = 0.0
                for j in 0..<probe.count { acc += Double(got[lag + j] * probe[j]) }
                if acc > bestScore { bestScore = acc; best = lag }
            }
            let at = take.start - take.offset + Int64(best) - 20_000
            offsets.append(at - 24_000)
            let residual = zip(got[best..<(best + 960)], probe).map { abs($0 - $1) }.max() ?? 1
            #expect(residual < 1e-5, "the loopback copy matches the source (max difference \(residual))")
            _ = dalnok_undo(e)
        }
        print("LOOPBACK AUTO measured per stream \(measured); placement error per take \(offsets) frames")
        #expect(offsets.allSatisfy { $0 == 0 }, "every take lands on the sample: \(offsets)")
    }
}
