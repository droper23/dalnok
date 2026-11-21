// Vector mix kernels (A-13): the mix through Accelerate matches the plain scalar loops within 1e-6, offline and live,
// on random projects (every track kind, fades, gains, pan, routing, sends, automation, stretch).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite(.serialized) struct VectorMix {
    func render(_ seed: Int, scalar: Bool, live: Bool, media: [String]) -> ([Float], [Float]) {
        dalnok_debug_set_scalar_mix(scalar)
        defer { dalnok_debug_set_scalar_mix(false) }
        let e = dalnok_engine_create(48_000)!
        defer { dalnok_engine_destroy(e) }
        let ids: [DalnokMediaId] = media.map { p in
            var m: OpaquePointer?
            _ = dalnok_media_load(p, 48_000, &m, nil, 0)
            defer { if let m { dalnok_media_release(m) } }
            return m.map { dalnok_pool_add(e, $0, p) } ?? 0
        }
        var r = RandomProject(rng: .init(state: UInt64(seed) &* 0x9E3779B97F4A7C15))
        r.build(e, media: ids)
        while dalnok_engine_poll_jobs(e) > 0 { usleep(1_000) }
        let frames = 96_000
        if !live {
            var l = [Float](repeating: 0, count: frames), rr = l
            dalnok_render_offline(e, 0, Int64(frames), &l, &rr)
            return (l, rr)
        }
        dalnok_transport_play(e)
        var outL: [Float] = [], outR: [Float] = []
        var l = [Float](repeating: 0, count: 512), rr = l
        var block = 0
        while outL.count < frames {
            // Fader and pan moves while playing, so the per-block gain ramps run (not just steady gains).
            if block % 10 == 5 {
                for i in 0..<dalnok_track_count(e) {
                    let t = dalnok_track_at(e, i)
                    _ = dalnok_track_set_gain_db(e, t, Float(-(block % 30)) * 0.5)
                    _ = dalnok_track_set_pan(e, t, Float((block / 10) % 5) * 0.4 - 0.8)
                }
            }
            _ = dalnok_engine_pump(e, &l, &rr, 512); outL += l; outR += rr
            block += 1
        }
        return (outL, outR)
    }

    @Test func vectorMixMatchesScalarLoops() throws {
        let dir = tempDir()
        let media = try (0..<2).map { k -> String in
            let url = dir.appendingPathComponent("v\(k).wav"); try writeTestWav(url, frames: 48_000, seed: k + 3); return url.path
        }
        var worst: Float = 0, loudest: Float = 0
        for seed in 1...24 {
            for live in [false, true] {
                let a = render(seed, scalar: true, live: live, media: media), b = render(seed, scalar: false, live: live, media: media)
                let d = max(zip(a.0, b.0).map { abs($0 - $1) }.max() ?? 0, zip(a.1, b.1).map { abs($0 - $1) }.max() ?? 0)
                worst = max(worst, d)
                loudest = max(loudest, a.0.map(abs).max() ?? 0)
                #expect(d <= 1e-6, "seed \(seed) \(live ? "live" : "offline"): vector and scalar differ by \(d)")
            }
        }
        print(String(format: "VECMIX 24 random projects, offline and live: worst difference %.2e (peak level %.2f)", worst, loudest))
        #expect(loudest > 0.05, "the projects make sound")
    }
}
