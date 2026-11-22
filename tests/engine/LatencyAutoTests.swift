// Automatic latency check (C API 45): every duplex stream on the loopback device measures its own round trip, and
// takes on that stream are placed with it. The simulated device's "loopback" here is the engine's own output played
// back `delay` frames later, as a Scarlett's digital loopback does (1136 or 1142 frames, depending on the stream).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct LatencyAuto {
    /// Pumps `blocks` duplex cycles; the input is the output delayed by `delay` frames (the loopback).
    struct Loopback {
        let engine: OpaquePointer
        var delay: Int
        var history: [Float] = []
        var played: [Float] = [] // everything output, from the first cycle
        mutating func pump(_ blocks: Int, block: Int = 512) {
            var l = [Float](repeating: 0, count: block), r = l
            for _ in 0..<blocks {
                let start = played.count
                let input = (0..<block).map { i -> Float in let k = start + i - delay; return k >= 0 && k < played.count ? played[k] : 0 }
                #expect(dalnok_engine_pump_input(engine, input, &l, &r, Int32(block)) == DALNOK_OK)
                played += zip(l, r).map { 0.5 * ($0 + $1) }
            }
        }
    }

    func text(_ r: DalnokLatencyResult) -> String {
        withUnsafeBytes(of: r.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    func result(_ e: OpaquePointer) -> (UInt64, DalnokLatencyResult) {
        var r = DalnokLatencyResult()
        let g = dalnok_latency_auto_result(e, &r)
        return (g, r)
    }

    /// A take of `blocks` cycles on a new stream; returns the result.
    func take(_ e: OpaquePointer, _ loop: inout Loopback, blocks: Int) -> DalnokRecordResult {
        var err = [CChar](repeating: 0, count: 256)
        dalnok_transport_seek(e, 48_000) // so the compensated take starts after the timeline start
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, tempDir().path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        loop.played = []
        loop.pump(blocks)
        var r = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &r, &err, 256) == DALNOK_OK, "\(cstr(err))")
        return r
    }

    @Test func eachStreamMeasuresItsOwnRoundTripAndTakesUseIt() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Loop In")
        #expect(dalnok_track_set_armed(e, t, true) == DALNOK_OK)
        dalnok_record_set_simulated_latency(e, 1200) // what the device reports
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_latency_auto_set(e, DALNOK_SIMULATED_INPUT, 0, &err, 256) == DALNOK_OK)
        #expect(result(e).0 == 0, "no stream yet")
        var loop = Loopback(engine: e, delay: 1136)
        let a = take(e, &loop, blocks: 120) // 1.28 s: the check takes the first 0.75 s (+ its lag window)
        let (g1, r1) = result(e)
        #expect(g1 >= 1 && r1.ok && r1.measured_frames == 1136 && r1.reported_frames == 1200, "\(r1.measured_frames) \(text(r1))")
        #expect(r1.spread_frames > 990, "the loopback matches the output (correlation \(r1.spread_frames))")
        #expect(a.latency_frames == 1136, "the take uses its own stream's round trip (\(a.latency_frames))")
        #expect(clipInfo(e, a.audio_clip).start == a.start_frame - 1136)
        // The next stream comes up 6 frames later, as the Scarlett's sometimes does: measured again, used again.
        loop.delay = 1142
        let b = take(e, &loop, blocks: 120)
        let (g2, r2) = result(e)
        #expect(g2 > g1 && r2.ok && r2.measured_frames == 1142, "\(r2.measured_frames)")
        #expect(b.latency_frames == 1142)
        // Off: back to reported + offset.
        #expect(dalnok_latency_auto_set(e, nil, -1, nil, 0) == DALNOK_OK)
        dalnok_record_set_latency_offset(e, -64)
        let c = take(e, &loop, blocks: 120)
        #expect(c.latency_frames == 1200 - 64 && text(result(e).1) == "off")
    }

    @Test func itWorksUnderTheProjectAndTheTakeLandsOnTheSample() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        // A loud program on another track: noise-like, deterministic.
        var x: UInt32 = 12345
        let program = (0..<200_000).map { _ -> Float in x = x &* 1_664_525 &+ 1_013_904_223; return Float(Int32(bitPattern: x >> 8) - (1 << 23)) / Float(1 << 23) * 0.5 }
        let m = makeMedia([program]); defer { dalnok_media_release(m) }
        let bed = dalnok_track_add(e, "Program")
        DalnokEngine.dalnok_clip_add(e, bed, dalnok_pool_add(e, m, ""), 0, 0, 0)
        let t = dalnok_track_add(e, "Loop In")
        #expect(dalnok_track_set_armed(e, t, true) == DALNOK_OK)
        dalnok_record_set_simulated_latency(e, 1200)
        #expect(dalnok_latency_auto_set(e, DALNOK_SIMULATED_INPUT, 0, nil, 0) == DALNOK_OK)
        var loop = Loopback(engine: e, delay: 1142)
        let r = take(e, &loop, blocks: 160)
        let (_, check) = result(e)
        #expect(check.ok && check.measured_frames == 1142, "\(check.measured_frames) \(check.spread_frames)")
        // The recorded loopback, placed with the measured round trip, lines up with the program sample for sample
        // (after the check's bursts, which only the output carried).
        let clip = clipInfo(e, r.audio_clip)
        #expect(clip.start == r.start_frame - 1142)
        let k0 = 48_000 // one second into the take
        let got = mediaSamples(e, clip.media, Int64(k0), 256)
        let want = (0..<256).map { program[Int(clip.start) + k0 + $0] }
        #expect(zip(got, want).allSatisfy { abs($0 - $1) < 1e-6 }, "the take lands on the exact sample")
    }

    @Test func aSilentLoopbackFallsBackToTheReport() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Loop In")
        #expect(dalnok_track_set_armed(e, t, true) == DALNOK_OK)
        dalnok_record_set_simulated_latency(e, 1200)
        #expect(dalnok_latency_auto_set(e, DALNOK_SIMULATED_INPUT, 0, nil, 0) == DALNOK_OK)
        var silent = Loopback(engine: e, delay: 1 << 30) // never echoes
        let r = take(e, &silent, blocks: 120)
        let (_, check) = result(e)
        #expect(!check.ok && r.latency_frames == 1200, "falls back to reported + offset (\(r.latency_frames))")
        // A take shorter than the check keeps reported + offset too.
        var loop = Loopback(engine: e, delay: 1136)
        let short = take(e, &loop, blocks: 20)
        #expect(short.latency_frames == 1200)
        #expect(dalnok_latency_auto_set(e, "no-such-device", 2, nil, 0) != DALNOK_OK)
    }
}
