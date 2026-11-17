// Plug-in delay compensation with a test VST3 that delays by exactly the 300 frames it reports.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

private let delayClass = classHex("DalnokTestDelay1")

/// An engine with two mono tracks, each holding one impulse of 1.0 at frame 2,000.
private func impulses() -> (OpaquePointer, DalnokTrackId, DalnokTrackId, OpaquePointer) {
    let e = dalnok_engine_create(48_000)!
    var x = [Float](repeating: 0, count: 8_000); x[2_000] = 1
    let m = makeMedia([x])
    let id = dalnok_pool_add(e, m, "")
    let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B")
    DalnokEngine.dalnok_clip_add(e, a, id, 0, 0, 0)
    DalnokEngine.dalnok_clip_add(e, b, id, 0, 0, 0)
    return (e, a, b, m)
}

private func peaks(_ x: [Float]) -> [(Int, Float)] { x.enumerated().filter { abs($0.element) > 1e-6 }.map { ($0.offset, $0.element) } }

@Suite(.enabled(if: !testVst3.isEmpty, "set DALNOK_TEST_VST3 (scripts/ci/plugin-host.sh)"))
struct DelayCompensation {
    @Test func aLatentInsertStaysAlignedWithOtherTracks() {
        let (e, a, _, m) = impulses(); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        #expect(dalnok_latency_compensation(e) == 0)
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_add(e, a, testVst3, delayClass, &err, 256) != 0, "\(cstr(err))")
        #expect(dalnok_latency_compensation(e) == 300)
        let out = renderStereo(e, 8_000).0
        #expect(peaks(out).count == 1 && peaks(out).first?.0 == 2_000 && abs((peaks(out).first?.1 ?? 0) - 2) < 1e-6,
                "one impulse of 2.0 at 2,000: \(peaks(out))")
        #expect(dalnok_undo(e) && dalnok_latency_compensation(e) == 0)
    }

    @Test func busesAndSendsArriveTogether() {
        let (e, a, b, m) = impulses(); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        let bus = dalnok_track_add_bus(e, "Latent Bus")
        #expect(dalnok_plugin_add(e, bus, testVst3, delayClass, nil, 0) != 0)
        // A goes through the latent bus; B goes straight to the master.
        #expect(dalnok_track_set_output(e, a, bus) == DALNOK_OK)
        var out = renderStereo(e, 8_000).0
        #expect(peaks(out).count == 1 && peaks(out).first?.0 == 2_000, "bus path aligned: \(peaks(out))")
        // B also sends (post-fader, 0 dB) into the latent bus: its direct and bus copies coincide.
        #expect(dalnok_track_set_output(e, a, 0) == DALNOK_OK && dalnok_track_set_send(e, b, bus, 0, false) == DALNOK_OK)
        out = renderStereo(e, 8_000).0
        #expect(peaks(out).count == 1 && peaks(out).first?.0 == 2_000 && abs((peaks(out).first?.1 ?? 0) - 3) < 1e-6,
                "A + B + B's send all at 2,000: \(peaks(out))")
    }

    @Test func livePlaybackIsAlignedWithThePlayhead() {
        let (e, a, _, m) = impulses(); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        #expect(dalnok_plugin_add(e, a, testVst3, delayClass, nil, 0) != 0)
        dalnok_transport_play(e)
        let (l, _) = pump(e, 6_000, block: 256)
        #expect(peaks(l).first?.0 == 2_000 && abs((peaks(l).first?.1 ?? 0) - 2) < 1e-6, "heard at the playhead's 2,000: \(peaks(l))")
    }
}
