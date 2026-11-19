// Parser robustness and real-time float-environment checks (audit A-10, A-12).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct RealTimeFloatEnvironment {
    /// Subnormal samples must be flushed to zero by the render path: no denormal arithmetic reaches the DSP,
    /// and the result is exactly silent (audit A-12).
    @Test func subnormalSamplesFlushToZeroOnLiveAndOfflinePaths() {
        let tiny = Float.leastNonzeroMagnitude * 1e3 // a subnormal, far below -140 dBFS
        #expect(tiny > 0 && tiny < Float.leastNormalMagnitude)
        let (e, _, m) = liveEngine([Float](repeating: tiny, count: 4_800))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_transport_play(e)
        let (live, right) = pump(e, 2_048)
        #expect(live.allSatisfy { $0 == 0 }, "live path keeps subnormals out of the mix")
        #expect(right.allSatisfy { $0 == 0 })
        let (offline, _) = render(e, frames: 2_048)
        #expect(offline.allSatisfy { $0 == 0 }, "offline render flushes subnormals too")
    }
}

@Suite struct ProjectParsingRobustness {
    /// Save -> load -> save must preserve the document (compared as JSON, so key order is irrelevant).
    @Test func randomProjectsRoundTripThroughTheWriter() throws {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<8 {
            let dir = tempDir()
            let wav = dir.appendingPathComponent("audio.wav")
            try writeTestWav(wav, frames: 2_000)
            let e = dalnok_engine_create(sr)!
            defer { dalnok_engine_destroy(e) }
            var media: OpaquePointer?
            #expect(dalnok_media_load(wav.path, sr, &media, nil, 0) == DALNOK_OK)
            let pool = dalnok_pool_add(e, media, wav.path)
            dalnok_media_release(media)

            for i in 0..<Int.random(in: 1...5, using: &rng) {
                let audio = dalnok_track_add(e, "Audio \(i) \(Int.random(in: 0...999, using: &rng))")
                let start = Int64.random(in: 0...3_000, using: &rng)
                let length = Int64.random(in: 400...1_500, using: &rng)
                let c = DalnokEngine.dalnok_clip_add(e, audio, pool, start, 0, length)
                _ = dalnok_clip_set_gain_db(e, c, Float.random(in: -18...6, using: &rng))
                _ = dalnok_clip_set_fades(e, c, 40, 60, Bool.random(using: &rng) ? DALNOK_FADE_EQUAL_POWER : DALNOK_FADE_LINEAR)
                _ = dalnok_track_set_gain_db(e, audio, Float.random(in: -30...6, using: &rng))
                _ = dalnok_track_set_pan(e, audio, Float.random(in: -1...1, using: &rng))
                if Bool.random(using: &rng) { _ = dalnok_track_set_mute(e, audio, true) }
                if Bool.random(using: &rng) {
                    _ = dalnok_midi_clip_add(e, dalnok_track_add_instrument(e, "Synth \(i)"),
                                             Int64.random(in: 0...2_000, using: &rng),
                                             Int64.random(in: 500...1_500, using: &rng))
                }
                _ = dalnok_marker_add(e, start, "M\(i)")
            }

            let first = dir.appendingPathComponent("a.dalnok"), second = dir.appendingPathComponent("b.dalnok")
            var err = [CChar](repeating: 0, count: 512)
            #expect(dalnok_project_save(e, first.path, &err, err.count) == DALNOK_OK, "\(cstr(err))")
            let reloaded = dalnok_engine_create(sr)!
            defer { dalnok_engine_destroy(reloaded) }
            var missing: Int32 = -1
            #expect(dalnok_project_load(reloaded, first.path, &missing, &err, err.count) == DALNOK_OK, "\(cstr(err))")
            #expect(missing == 0)
            #expect(dalnok_project_save(reloaded, second.path, &err, err.count) == DALNOK_OK, "\(cstr(err))")
            let a = try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any] ?? [:]
            let b = try JSONSerialization.jsonObject(with: Data(contentsOf: second)) as? [String: Any] ?? [:]
            #expect(NSDictionary(dictionary: a).isEqual(to: b), "save/load/save changed the document")
        }
    }

    /// Mutated and truncated project files must fail cleanly; they must never crash, hang or over-read.
    @Test func mutatedProjectFilesAreRejectedWithoutCrashing() throws {
        let dir = tempDir()
        let wav = dir.appendingPathComponent("audio.wav")
        try writeTestWav(wav, frames: 1_000)
        let e = dalnok_engine_create(sr)!
        var media: OpaquePointer?
        #expect(dalnok_media_load(wav.path, sr, &media, nil, 0) == DALNOK_OK)
        let pool = dalnok_pool_add(e, media, wav.path)
        dalnok_media_release(media)
        let track = dalnok_track_add(e, "A")
        DalnokEngine.dalnok_clip_add(e, track, pool, 0, 0, 800)
        _ = dalnok_marker_add(e, 100, "M")
        let project = dir.appendingPathComponent("seed.dalnok")
        #expect(dalnok_project_save(e, project.path, nil, 0) == DALNOK_OK)
        dalnok_engine_destroy(e)

        let seed = try Data(contentsOf: project)
        var rng = SystemRandomNumberGenerator()
        var accepted = 0
        for i in 0..<120 {
            var mutated = seed
            if i % 12 == 11 {
                mutated = Data(mutated.prefix(Int.random(in: 0..<mutated.count, using: &rng)))
            } else {
                for _ in 0..<Int.random(in: 1...6, using: &rng) {
                    let at = Int.random(in: 0..<mutated.count, using: &rng)
                    mutated[at] = UInt8.random(in: 0...255, using: &rng)
                }
            }
            let path = dir.appendingPathComponent("mutant-\(i).dalnok")
            try mutated.write(to: path)
            var prepared: OpaquePointer?
            var missing: Int32 = 0
            var err = [CChar](repeating: 0, count: 256)
            if dalnok_project_prepare(path.path, sr, &prepared, &missing, &err, err.count) == DALNOK_OK {
                accepted += 1
                let target = dalnok_engine_create(sr)!
                _ = dalnok_project_apply(target, prepared)
                dalnok_engine_destroy(target)
            }
        }
        #expect(accepted < 120, "most mutations are rejected")
    }
}
