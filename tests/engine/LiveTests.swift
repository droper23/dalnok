// Live render path (transport fades, smoothing, meters), devices, two-phase load.
// Uses dalnok_engine_pump to drive the exact code the audio callback runs.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Pumps `frames` through the live path in device-sized blocks.
func pump(_ e: OpaquePointer, _ frames: Int, block: Int = 256) -> ([Float], [Float]) {
    var l = [Float](), r = [Float]()
    var bl = [Float](repeating: 0, count: block), br = bl
    var done = 0
    while done < frames {
        let n = min(block, frames - done)
        #expect(dalnok_engine_pump(e, &bl, &br, Int32(n)) == DALNOK_OK)
        l += bl[0..<n]; r += br[0..<n]
        done += n
    }
    return (l, r)
}

func maxStep(_ x: [Float]) -> Float { zip(x, x.dropFirst()).map { abs($1 - $0) }.max() ?? 0 }

/// Engine with one stereo-free mono track holding `samples` at 0, center pan (unity).
func liveEngine(_ samples: [Float]) -> (OpaquePointer, DalnokTrackId, OpaquePointer) {
    let e = dalnok_engine_create(sr)!
    let m = makeMedia([samples])
    let t = dalnok_track_add(e, "A")
    dalnok_clip_add(e, t, m, 0, 0, 0)
    return (e, t, m)
}

@Suite struct LivePath {
    // 5 ms fade at 48 kHz = 240 samples; a 0.5 step spread over 240 samples is ~0.0021/sample.
    let declickStep: Float = 0.5 / 240 * 1.05

    @Test func playFadesInWithoutAClickAndPositionIsExact() {
        let (e, _, m) = liveEngine([Float](repeating: 0.5, count: 48_000))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        #expect(pump(e, 1_000).0.allSatisfy { $0 == 0 }, "stopped transport is silent")
        #expect(dalnok_transport_position(e) == 0, "stopped transport does not advance")
        dalnok_transport_play(e)
        let (l, _) = pump(e, 4_096)
        #expect(l[0] < 0.01, "starts near zero")
        #expect(abs(l[300] - 0.5) < 1e-3 && abs(l[4_000] - 0.5) < 1e-3, "reaches full level after the fade")
        #expect(maxStep(l) <= declickStep, "fade-in step \(maxStep(l))")
        #expect(dalnok_transport_position(e) == 4_096)
    }

    @Test func pauseFadesOutAndStops() {
        let (e, _, m) = liveEngine([Float](repeating: 0.5, count: 48_000))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_transport_play(e)
        let before = pump(e, 2_048).0
        dalnok_transport_pause(e)
        let (l, _) = pump(e, 2_048)
        let joined = [before.last!] + l // include the boundary sample: a click can hide there
        #expect(maxStep(joined) <= declickStep, "fade-out step \(maxStep(joined))")
        #expect(l[300...].allSatisfy { $0 == 0 }, "silent after the fade")
        let pos = dalnok_transport_position(e)
        _ = pump(e, 1_000)
        #expect(dalnok_transport_position(e) == pos, "paused transport holds position")
    }

    @Test func seekWhilePlayingIsClickFree() {
        let src = [Float](repeating: 0.5, count: 24_000) + [Float](repeating: -0.5, count: 24_000)
        let (e, _, m) = liveEngine(src)
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_transport_play(e)
        let before = pump(e, 2_048).0
        dalnok_transport_seek(e, 30_000)
        let (l, _) = pump(e, 4_096)
        let joined = [before.last!] + l
        #expect(maxStep(joined) <= declickStep, "seek step \(maxStep(joined)) (would be 1.0 without de-click)")
        #expect(l.min()! < -0.49, "arrives in the -0.5 region")
        let pos = dalnok_transport_position(e)
        #expect(pos > 30_000 && pos < 30_000 + 4_096, "position after seek: \(pos)")
    }

    @Test func gainChangesAreSmoothed() {
        let (e, t, m) = liveEngine([Float](repeating: 0.5, count: 48_000))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_transport_play(e)
        let before = pump(e, 2_048).0
        dalnok_track_set_gain_db(e, t, -200)
        let (l, _) = pump(e, 2_048)
        let joined = [before.last!] + l
        #expect(maxStep(joined) <= 0.5 / 256 * 1.05, "gain ramp step \(maxStep(joined))")
        #expect(l.last! == 0)
    }

    @Test func metersReportPostFaderPeaksAndReset() {
        let (e, t, m) = liveEngine([Float](repeating: 0.5, count: 48_000))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_track_set_gain_db(e, t, -6.0206)
        dalnok_transport_play(e)
        _ = pump(e, 4_096)
        var l: Float = 0, r: Float = 0
        #expect(dalnok_meter_track(e, t, &l, &r) == DALNOK_OK)
        #expect(abs(l - 0.25) < 1e-3 && abs(r - 0.25) < 1e-3, "track peak \(l), \(r)")
        dalnok_meter_master(e, &l, &r)
        #expect(abs(l - 0.25) < 1e-3, "master peak \(l)")
        dalnok_meter_track(e, t, &l, &r)
        #expect(l == 0 && r == 0, "reading resets")
        #expect(dalnok_meter_track(e, 999, &l, &r) == DALNOK_ERR_NOT_FOUND)
    }

    @Test func pluginMetersReportInputAndOutputPeaks() {
        let (e, t, m) = liveEngine([Float](repeating: 0.25, count: 48_000))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
        #expect(slot != 0)
        dalnok_plugin_set_parameter(e, slot, 32, (6.0206 + 24) / 48) // Channel EQ master gain +6 dB (x2)
        dalnok_transport_play(e)
        _ = pump(e, 4_096)
        var il: Float = 0, ir: Float = 0, ol: Float = 0, orr: Float = 0
        #expect(dalnok_meter_plugin(e, slot, &il, &ir, &ol, &orr) == DALNOK_OK)
        #expect(abs(il - 0.25) < 1e-3 && abs(ir - 0.25) < 1e-3, "plug-in input peak \(il), \(ir)")
        #expect(abs(ol - 0.5) < 1e-3 && abs(orr - 0.5) < 1e-3, "plug-in output peak \(ol), \(orr)")
        dalnok_meter_plugin(e, slot, &il, nil, &ol, nil)
        #expect(il == 0 && ol == 0, "reading resets")
        #expect(dalnok_meter_plugin(e, 999_999, nil, nil, nil, nil) == DALNOK_ERR_NOT_FOUND)
    }

    @Test func pluginTapDeliversRecentInputAndOutput() {
        let (e, t, m) = liveEngine((0..<48_000).map { Float(sin(Double($0) * 0.05)) * 0.25 })
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
        dalnok_plugin_set_parameter(e, slot, 32, (6.0206 + 24) / 48) // master gain x2
        var inBuf = [Float](repeating: 0, count: 1_024), outBuf = inBuf
        #expect(dalnok_plugin_tap(e, slot, &inBuf, &outBuf, 1_024) == 0, "the first call starts the tap")
        dalnok_transport_play(e)
        _ = pump(e, 4_096)
        #expect(dalnok_plugin_tap(e, slot, &inBuf, &outBuf, 1_024) == 1_024)
        #expect(inBuf.contains { abs($0) > 0.1 }, "input reaches the tap")
        let worst = zip(inBuf, outBuf).map { abs($1 - 2 * $0) }.max() ?? 1
        #expect(worst < 1e-5, "output is the input through the plug-in (x2), aligned: \(worst)")
        #expect(dalnok_plugin_tap(e, 999_999, nil, nil, 16) == 0)
        var l = [Float](repeating: 0, count: 1_024), r = l
        #expect(dalnok_plugin_tap_stereo(e, slot, &l, &r, 1_024) == 1_024)
        #expect(zip(zip(l, r), outBuf).allSatisfy { abs(0.5 * ($0.0 + $0.1) - $1) < 1e-6 }, "the stereo output matches the mono tap")
    }

    @Test func structuralEditsWhilePlayingAreAdopted() {
        let (e, t, m) = liveEngine([Float](repeating: 0.5, count: 48_000))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_transport_play(e)
        _ = pump(e, 1_024)
        for i in 0..<500 { // snapshot churn through the real handoff
            let c = dalnok_clip_add(e, t, m, Int64(i * 10), 0, 100)
            dalnok_clip_remove(e, c)
            _ = pump(e, 64)
        }
        let (l, _) = pump(e, 512)
        #expect(l.allSatisfy { abs($0 - 0.5) < 1e-3 }, "audio intact after 1000 snapshot swaps")
    }
}

@Suite struct Devices {
    @Test func enumerationIsWellFormed() {
        let n = dalnok_output_devices(nil, 0)
        #expect(n >= 0)
        var list = [DalnokDeviceInfo](repeating: DalnokDeviceInfo(), count: Int(max(n, 1)))
        #expect(dalnok_output_devices(&list, n) == n)
        for d in list.prefix(Int(n)) {
            #expect(!name(d.uid).isEmpty && !name(d.name).isEmpty)
            #expect(d.sample_rate > 0 && d.output_channels > 0)
        }
        #expect(list.prefix(Int(n)).filter(\.is_default).count <= 1)
    }

    @Test func midiSourceEnumerationIsWellFormed() {
        let n = dalnok_midi_sources(nil, 0)
        #expect(n >= 0)
        var list = [DalnokMidiSourceInfo](repeating: DalnokMidiSourceInfo(), count: Int(max(n, 1)))
        let current = dalnok_midi_sources(&list, n)
        for source in list.prefix(Int(max(0, min(n, current)))) {
            #expect(source.unique_id != 0 && !name(source.name).isEmpty)
        }
    }

    @Test func inputEnumerationIsWellFormed() {
        let n = dalnok_input_devices(nil, 0)
        #expect(n >= 0)
        var list = [DalnokInputDeviceInfo](repeating: DalnokInputDeviceInfo(), count: Int(max(n, 1)))
        let current = dalnok_input_devices(&list, n)
        for d in list.prefix(Int(max(0, min(n, current)))) {
            #expect(!name(d.uid).isEmpty && !name(d.name).isEmpty)
            #expect(d.sample_rate > 0 && d.input_channels > 0)
        }
        #expect(list.prefix(Int(max(0, min(n, current)))).filter(\.is_default).count <= 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "needs real audio hardware"))
    func switchingDevicesKeepsAudioRunning() {
        let e = dalnok_engine_create(0)!; defer { dalnok_engine_destroy(e) }
        var list = [DalnokDeviceInfo](repeating: DalnokDeviceInfo(), count: 16)
        let n = Int(dalnok_output_devices(&list, 16))
        guard n > 0 else { return }
        var err = [CChar](repeating: 0, count: 256)
        for d in list.prefix(n) {
            let uid = name(d.uid)
            #expect(dalnok_engine_set_output_device(e, uid, &err, 256) == DALNOK_OK, "\(name(d.name)): \(cstr(err))")
            #expect(dalnok_engine_device_alive(e))
            var cur = [CChar](repeating: 0, count: 256)
            dalnok_engine_output_device(e, &cur, 256)
            #expect(cstr(cur) == uid)
            var b = [Float](repeating: 0, count: 64), c = b
            #expect(dalnok_engine_pump(e, &b, &c, 64) == DALNOK_ERR_INVALID_ARG, "pump refused while a device runs")
        }
        #expect(dalnok_engine_set_output_device(e, "no-such-device", &err, 256) == DALNOK_ERR_DEVICE)
        #expect(dalnok_engine_device_running(e), "previous device keeps running after a failed switch")
        #expect(dalnok_engine_set_output_device(e, nil, &err, 256) == DALNOK_OK, "back to system default")
        dalnok_engine_stop_device(e)
    }
}

@Suite struct TwoPhaseLoad {
    @Test func prepareOffThreadThenApplyMatchesSyncLoad() async throws {
        let dir = tempDir()
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let audio = dir.appendingPathComponent("a.wav")
        try writeTestWav(audio, frames: 20_000)
        var m: OpaquePointer?
        dalnok_media_load(audio.path, sr, &m, nil, 0)
        let id = dalnok_pool_add(e, m, audio.path); dalnok_media_release(m)
        DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "T"), id, 500, 0, 0)
        let path = dir.appendingPathComponent("p.dalnok").path
        dalnok_project_save(e, path, nil, 0)
        let expected = render(e, frames: 21_000)

        struct Box: @unchecked Sendable { let p: OpaquePointer? }
        let box = await Task.detached { () -> Box in
            var data: OpaquePointer?
            #expect(dalnok_project_prepare(path, sr, &data, nil, nil, 0) == DALNOK_OK)
            return Box(p: data)
        }.value
        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_apply(e2, box.p) == DALNOK_OK)
        expectClose(render(e2, frames: 21_000).0, expected.0, tol: 0, "identical to the saved project")

        var data: OpaquePointer?
        #expect(dalnok_project_prepare(path, 44_100, &data, nil, nil, 0) == DALNOK_OK)
        #expect(dalnok_project_apply(e2, data) == DALNOK_ERR_INVALID_ARG, "rate mismatch rejected (data consumed)")
        #expect(dalnok_project_prepare("/nonexistent.dalnok", sr, &data, nil, nil, 0) == DALNOK_ERR_IO)
    }
}
