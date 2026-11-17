// Cycle (loop) playback: sample-exact wrap, persistence, recording plays through.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct Cycle {
    /// A ramp, so any off-by-one at the wrap shows up as a wrong sample value.
    func ramp(_ n: Int) -> [Float] { (0..<n).map { Float($0) / Float(n) * 0.5 } }

    @Test func wrapsOnTheExactSampleInAnyBlockSize() {
        for block in [64, 256, 333, 512, 1_024] {
            let (e, _, m) = liveEngine(ramp(48_000))
            defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
            #expect(dalnok_cycle_set(e, true, 10_000, 13_001) == DALNOK_OK)
            dalnok_transport_seek(e, 10_000)
            _ = pump(e, 512, block: block) // let the seek land while stopped
            dalnok_transport_play(e)
            let (l, _) = pump(e, 3_001 * 4, block: block)
            // After the 240-sample start fade, every pass repeats the region exactly.
            let expected = render(e, 10_000, 3_001)
            for pass in 0..<4 {
                for i in stride(from: pass == 0 ? 300 : 0, to: 3_001, by: 1) where l[pass * 3_001 + i] != expected[i] {
                    Issue.record("block \(block) pass \(pass) sample \(i): \(l[pass * 3_001 + i]) != \(expected[i])"); return
                }
            }
            let pos = dalnok_transport_position(e)
            #expect(pos >= 10_000 && pos < 13_001, "position stays inside the cycle (\(pos))")
        }
    }

    @Test func playingFromOutsideRunsIntoTheCycleAndOffStopsLooping() {
        let (e, _, m) = liveEngine(ramp(48_000))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        #expect(dalnok_cycle_set(e, true, 2_000, 4_000) == DALNOK_OK)
        dalnok_transport_play(e)
        _ = pump(e, 9_000)
        let pos = dalnok_transport_position(e)
        #expect(pos >= 2_000 && pos < 4_000)
        #expect(dalnok_cycle_set(e, false, 2_000, 4_000) == DALNOK_OK)
        _ = pump(e, 5_000)
        #expect(dalnok_transport_position(e) > 4_000, "cycle off plays on")
        // Started past the cycle end: no jump back.
        dalnok_transport_seek(e, 20_000)
        #expect(dalnok_cycle_set(e, true, 2_000, 4_000) == DALNOK_OK)
        _ = pump(e, 3_000)
        #expect(dalnok_transport_position(e) > 20_000)
    }

    @Test func rejectsBadRangesAndSavesWithTheProject() throws {
        let (e, _, m) = liveEngine(ramp(48_000))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        #expect(dalnok_cycle_set(e, true, 1_000, 1_010) != DALNOK_OK)
        #expect(dalnok_cycle_set(e, true, -5, 1_000) != DALNOK_OK)
        #expect(dalnok_cycle_set(e, true, 24_000, 72_000) == DALNOK_OK)
        let project = tempDir().appendingPathComponent("cycle.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        // Media must exist on disk to save; write the clip's audio.
        let wav = project.deletingLastPathComponent().appendingPathComponent("a.wav")
        try writeTestWav(wav, frames: 48_000)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        let t = dalnok_track_add(e2, "A")
        var loaded: OpaquePointer?
        #expect(dalnok_media_load(wav.path, 48_000, &loaded, nil, 0) == DALNOK_OK)
        let me = dalnok_pool_add(e2, loaded, wav.path)
        dalnok_media_release(loaded)
        DalnokEngine.dalnok_clip_add(e2, t, me, 0, 0, 0)
        #expect(dalnok_cycle_set(e2, true, 24_000, 72_000) == DALNOK_OK)
        #expect(dalnok_project_save(e2, project.path, &err, err.count) == DALNOK_OK)
        let at44 = dalnok_engine_create(44_100)!; defer { dalnok_engine_destroy(at44) }
        #expect(dalnok_project_load(at44, project.path, nil, &err, err.count) == DALNOK_OK)
        var on = false; var a: Int64 = 0, b: Int64 = 0
        dalnok_cycle_get(at44, &on, &a, &b)
        #expect(on && a == 22_050 && b == 66_150, "cycle scales to the engine rate (\(a)–\(b))")
        dalnok_project_new(at44)
        dalnok_cycle_get(at44, &on, &a, &b)
        #expect(!on, "new project clears the cycle")
        #expect(runCommand(e2, "transport.setCycle", #"{"on":false}"#).0 == DALNOK_OK)
        dalnok_cycle_get(e2, &on, &a, &b)
        #expect(!on && a == 24_000 && b == 72_000)
        #expect(dalnok_cycle_set(e2, false, 0, 0) == DALNOK_OK)
        dalnok_cycle_get(e2, &on, &a, &b)
        #expect(!on && a == 0 && b == 0, "(false, 0, 0) clears the region")
    }
}
