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

@Suite(.enabled(if: !testVst3.isEmpty, "set DALNOK_TEST_VST3 (scripts/ci/plugin-host.sh)"))
struct PluginAutomation {
    @Test func aParameterFollowsItsLanePerBlockAndSaves() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 48_000).0
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        var p = DalnokPluginParameter()
        #expect(dalnok_plugin_parameter(e, slot, 0, &p) == DALNOK_OK)
        let pts = [DalnokAutoPoint(frame: 0, value: 0.25), DalnokAutoPoint(frame: 48_000, value: 0.75)]
        #expect(dalnok_plugin_set_automation(e, t, slot, p.id, pts, 2) == DALNOK_OK && undoName(e) == "Plug-in Automation")
        let wet = renderStereo(e, 48_000).0
        // Gain follows the lane at block rate: within half a block's change of the exact ramp.
        for f in [2_000, 12_000, 24_000, 40_000] where abs(dry[f]) > 0.05 {
            let gain = wet[f] / dry[f], want = Float(0.25 + 0.5 * Double(f) / 48_000)
            #expect(abs(gain - want) < 0.006, "gain \(gain) at \(f), lane \(want)")
        }
        var got = [DalnokAutoPoint](repeating: DalnokAutoPoint(), count: 4)
        #expect(dalnok_plugin_automation(e, t, slot, p.id, &got, 4) == 2)
        #expect(dalnok_plugin_set_automation(e, t, slot, p.id, [DalnokAutoPoint(frame: 0, value: 1.5)], 1) != DALNOK_OK)
        // Removing the plug-in removes its lanes; undo brings both back.
        #expect(dalnok_plugin_remove(e, t, slot) == DALNOK_OK && dalnok_plugin_automation(e, t, slot, p.id, nil, 0) == 0)
        #expect(dalnok_undo(e) && dalnok_plugin_automation(e, t, slot, p.id, nil, 0) == 2)
    }
}

@Suite(.enabled(if: !testVst3.isEmpty, "set DALNOK_TEST_VST3 (scripts/ci/plugin-host.sh)"))
struct Sidechain {
    @Test func aDuckerListensToAnotherTrackAndLoopsAreRejected() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let bedM = makeMedia([[Float](repeating: 0.5, count: 48_000)])
        var keyS = [Float](repeating: 0, count: 48_000); for i in 24_000..<48_000 { keyS[i] = 0.75 }
        let keyM = makeMedia([keyS]); defer { dalnok_media_release(bedM); dalnok_media_release(keyM) }
        // The listening track comes first in display order, so the engine must reorder.
        let bed = dalnok_track_add(e, "Bed"), key = dalnok_track_add(e, "Key")
        DalnokEngine.dalnok_clip_add(e, bed, dalnok_pool_add(e, bedM, ""), 0, 0, 0)
        DalnokEngine.dalnok_clip_add(e, key, dalnok_pool_add(e, keyM, ""), 0, 0, 0)
        #expect(dalnok_track_set_mute(e, key, true) == DALNOK_OK) // only the bed is heard; the key still feeds the sidechain
        let slot = dalnok_plugin_add(e, bed, testVst3, classHex("DalnokTestDuck01"), nil, 0)
        #expect(slot != 0 && dalnok_plugin_has_sidechain(e, slot))
        #expect(abs(render(e, 30_000, 10)[5] - 0.5) < 1e-4, "no sidechain source: no ducking")
        #expect(dalnok_plugin_set_sidechain(e, bed, slot, key) == DALNOK_OK && undoName(e) == "Sidechain")
        let out = render(e, 0, 48_000)
        #expect(abs(out[10_000] - 0.5) < 1e-4, "key silent: full level")
        #expect(abs(out[30_000] - 0.125) < 1e-4, "key at 0.75: ducked to 0.25 of 0.5 (\(out[30_000]))")
        // A loop (the key listening to the bed through a duck of its own) is rejected.
        let slot2 = dalnok_plugin_add(e, key, testVst3, classHex("DalnokTestDuck01"), nil, 0)
        #expect(dalnok_plugin_set_sidechain(e, key, slot2, bed) != DALNOK_OK)
        #expect(dalnok_plugin_sidechain(e, bed, slot) == key)
    }

    /// Cycle playback with compensation: what is heard wraps at the cycle end exactly (it used to play `compensation`
    /// frames past the end, then skip that much of the start).
    @Test func cyclePlaybackWrapsExactlyWithCompensation() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let ramp = (0..<8_000).map { Float($0 + 1) / 16_384 }
        let m = makeMedia([ramp]); defer { dalnok_media_release(m) }
        let id = dalnok_pool_add(e, m, "")
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B")
        DalnokEngine.dalnok_clip_add(e, a, id, 0, 0, 0)
        DalnokEngine.dalnok_clip_add(e, b, id, 0, 0, 0)
        #expect(dalnok_plugin_add(e, a, testVst3, delayClass, nil, 0) != 0 && dalnok_latency_compensation(e) == 300)
        #expect(dalnok_cycle_set(e, true, 1_000, 3_000) == DALNOK_OK)
        dalnok_transport_seek(e, 1_000)
        _ = pump(e, 512, block: 256) // the seek lands while stopped
        dalnok_transport_play(e)
        let (l, _) = pump(e, 9_000, block: 256)
        // From well after the fade-in and the plug-in's own first 300 frames: every sample is the ramp at the playhead.
        var wrong: [(Int, Float, Float)] = []
        for k in 1_000..<9_000 {
            let pos = 1_000 + k % 2_000
            let want = 2 * Float(pos + 1) / 16_384
            if abs(l[k] - want) > 1e-6 { wrong.append((k, l[k], want)) }
        }
        #expect(wrong.isEmpty, "\(wrong.count) samples differ, first \(wrong.prefix(3))")
    }
}
