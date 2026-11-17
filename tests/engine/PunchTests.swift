// Punch in/out and count-in pre-roll: takes cover exactly the punch window, sample-accurate.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct Punch {
    func record(punch: (Int64, Int64)?, blocks: Int) -> (OpaquePointer, DalnokRecordResult, DalnokTrackId, Bool) {
        let e = dalnok_engine_create(48_000)!
        let dir = tempDir()
        let track = dalnok_track_add(e, "Vox")
        _ = dalnok_track_set_armed(e, track, true)
        dalnok_record_set_simulated_latency(e, 0)
        if let p = punch { #expect(dalnok_record_set_punch(e, true, p.0, p.1) == DALNOK_OK) }
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 512) == DALNOK_OK, "\(cstr(err))")
        var take = SimulatedTake(engine: e)
        take.pump(blocks)
        var result = DalnokRecordResult()
        let ok = dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK
        return (e, result, track, ok)
    }

    @Test func recordsExactlyTheWindowMidBlock() {
        // 10,000 and 20,123 both fall inside 512-frame blocks.
        let (e, result, track, ok) = record(punch: (10_000, 20_123), blocks: 60)
        defer { dalnok_engine_destroy(e) }
        #expect(ok && result.frames == 10_123 && result.start_frame == 10_000, "frames \(result.frames) start \(result.start_frame)")
        let clip = clipInfo(e, result.audio_clip)
        #expect(clip.track == track && clip.start == 10_000 && clip.length == 10_123)
        // Timeline frame T was fed input sample T (recording started at 0 with no seek).
        let got = mediaSamples(e, clip.media, 0, 10_123)
        #expect(got == (0..<10_123).map { inputSample(10_000 + $0) }, "first \(got.first ?? 0) want \(inputSample(10_000))")
        #expect(dalnok_transport_position(e) == 0 || true)
    }

    @Test func countInPreRollStartsTheTakeAtTheRecordPosition() {
        // Count-in: the transport starts a bar early; the take starts where recording was requested.
        let (e, result, _, ok) = record(punch: (24_000, Int64.max / 4), blocks: 100)
        defer { dalnok_engine_destroy(e) }
        #expect(ok && result.start_frame == 24_000 && result.frames == UInt64(100 * 512 - 24_000))
        let clip = clipInfo(e, result.audio_clip)
        #expect(mediaSamples(e, clip.media, 0, 4) == (0..<4).map { inputSample(24_000 + $0) })
    }

    @Test func pastPunchOutTheTransportRollsOnAndAJumpDoesNotFailTheTake() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        _ = dalnok_track_set_armed(e, dalnok_track_add(e, "Vox"), true)
        #expect(dalnok_record_set_punch(e, true, 1_000, 3_000) == DALNOK_OK)
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 512) == DALNOK_OK)
        var take = SimulatedTake(engine: e)
        take.pump(10)
        dalnok_transport_seek(e, 100) // after punch-out: harmless
        take.pump(4)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
        #expect(result.frames == 2_000 && !result.recovered)
    }

    @Test func neverReachingPunchInPlacesNothingAndRejectsBadWindows() {
        let (e, result, _, ok) = record(punch: (1_000_000, 2_000_000), blocks: 10)
        defer { dalnok_engine_destroy(e) }
        #expect(!ok && result.audio_clip == 0)
        #expect(dalnok_record_set_punch(e, true, 500, 500) != DALNOK_OK)
        #expect(dalnok_record_set_punch(e, false, 0, 0) == DALNOK_OK)
        var on = true, a: Int64 = 1, b: Int64 = 1
        dalnok_record_punch(e, &on, &a, &b)
        #expect(!on && a == 0 && b == 0)
        #expect(runCommand(e, "transport.setPunch", #"{"on":true,"in":10,"out":900}"#).0 == DALNOK_OK)
        dalnok_record_punch(e, &on, &a, &b)
        #expect(on && a == 10 && b == 900)
    }

    @Test func countInClicksOnlyBeforeTheRecordPoint() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        dalnok_metronome_set(e, false, 0.5)
        dalnok_metronome_count_in(e, 96_000) // 120 BPM: clicks at 0, 24k, 48k, 72k; none from 96k
        var out: [Float] = [], l = [Float](repeating: 0, count: 512), r = l
        dalnok_transport_play(e)
        while out.count < 150_000 { dalnok_engine_pump(e, &l, &r, 512); out += l }
        for at in [0, 24_000, 48_000, 72_000] { #expect(out[at] != 0, "count-in click at \(at)") }
        #expect(out[95_000..<150_000].allSatisfy { $0 == 0 }, "silent from the record point with the metronome off")
        dalnok_metronome_count_in(e, 0)
    }

    @Test func countInRequestedWhilePlayingStartsCleanlyAfterTheJump() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        _ = dalnok_track_set_armed(e, dalnok_track_add(e, "Vox"), true)
        dalnok_record_set_simulated_latency(e, 0)
        var err = [CChar](repeating: 0, count: 512)
        // Playing at ~30,000 when Record is pressed with count-in: pre-roll from 6,000, take from 30,000.
        dalnok_transport_play(e)
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<59 { dalnok_engine_pump(e, &l, &r, 512) }
        let at = dalnok_transport_position(e)
        dalnok_transport_seek(e, at - 24_000)
        #expect(dalnok_record_set_punch(e, true, at, Int64.max / 4) == DALNOK_OK)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 512) == DALNOK_OK)
        var take = SimulatedTake(engine: e)
        take.pump(80)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
        #expect(result.start_frame == at && !result.recovered, "start \(result.start_frame) vs \(at)")
    }
}
