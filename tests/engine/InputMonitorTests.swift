// Input Monitoring (the I button), armed-track monitoring and the live waveform while recording, on the simulated input.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct InputMonitor {
    /// Runs `blocks` duplex cycles of channelSample on `channels` inputs; returns the last block's left output.
    @discardableResult
    func pump(_ e: OpaquePointer, from: inout Int, blocks: Int, channels: Int = 4, expectOK: Bool = true) -> [Float] {
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<blocks {
            let bufs = (0..<channels).map { c in (0..<512).map { channelSample(c, from + $0) } }
            let ok: Bool = withExtendedLifetime(bufs) {
                let raw = bufs.map { b in b.withUnsafeBufferPointer { $0.baseAddress } }
                return dalnok_engine_pump_input_channels(e, raw, Int32(channels), &l, &r, 512) == DALNOK_OK
            }
            #expect(ok == expectOK)
            from += 512
        }
        return l
    }

    func setInput(_ e: OpaquePointer) {
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_input_set_device(e, DALNOK_SIMULATED_INPUT, &err, 256) == DALNOK_OK, "\(cstr(err))")
    }

    @Test func monitoredTrackPlaysItsInputThroughItsFaderWhileStopped() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let vox = dalnok_track_add(e, "Vox"), other = dalnok_track_add(e, "Other")
        _ = dalnok_track_set_input(e, vox, 2)
        _ = dalnok_track_set_gain_db(e, vox, -6)
        setInput(e)
        var frame = 0
        pump(e, from: &frame, blocks: 1, expectOK: false) // nothing monitors yet: no input device open
        #expect(dalnok_track_set_input_monitor(e, vox, true) == DALNOK_OK)
        #expect(dalnok_track_set_input_monitor(e, dalnok_track_add_bus(e, "Bus"), true) != DALNOK_OK, "buses have no input")
        var info = DalnokTrackInfo()
        #expect(dalnok_track_info(e, vox, &info) == DALNOK_OK && info.input_monitor)
        pump(e, from: &frame, blocks: 4) // past the fader's first ramp
        let start = frame
        let out = pump(e, from: &frame, blocks: 1)
        let g = Float(pow(10.0, -6.0 / 20.0)) // mono source at centre: unity pan law
        let want = (0..<512).map { channelSample(2, start + $0) * g }
        #expect(zip(out, want).allSatisfy { abs($0 - $1) < 1e-5 }, "input 3 through the track's fader, transport stopped")
        #expect(!dalnok_transport_is_playing(e))
        _ = dalnok_track_set_mute(e, vox, true)
        #expect(pump(e, from: &frame, blocks: 3).allSatisfy { abs($0) < 1e-6 }, "mute silences the monitored input")
        _ = dalnok_track_set_mute(e, vox, false)
        _ = other
        #expect(dalnok_track_set_input_monitor(e, vox, false) == DALNOK_OK)
        pump(e, from: &frame, blocks: 1, expectOK: false) // the input closes when nothing monitors
    }

    @Test func armedTracksMonitorOnlyWithArmedMonitoringOn() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let vox = dalnok_track_add(e, "Vox")
        _ = dalnok_track_set_armed(e, vox, true)
        setInput(e)
        var frame = 0
        pump(e, from: &frame, blocks: 1, expectOK: false)
        dalnok_record_set_monitoring(e, true)
        pump(e, from: &frame, blocks: 4)
        let start = frame
        let out = pump(e, from: &frame, blocks: 1)
        #expect(zip(out, (0..<512).map { channelSample(0, start + $0) }).allSatisfy { abs($0 - $1) < 1e-5 })
        dalnok_record_set_monitoring(e, false)
        pump(e, from: &frame, blocks: 1, expectOK: false)
    }

    @Test func recordingWhileMonitoringKeepsTheInputOpenAndShowsALiveWaveform() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        let vox = dalnok_track_add(e, "Vox")
        _ = dalnok_track_set_input(e, vox, 1)
        _ = dalnok_track_set_input_monitor(e, vox, true)
        _ = dalnok_track_set_armed(e, vox, true)
        dalnok_record_set_simulated_latency(e, 0)
        setInput(e)
        var frame = 0
        pump(e, from: &frame, blocks: 2)
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 512) == DALNOK_OK, "\(cstr(err))")
        let recordFrom = frame
        pump(e, from: &frame, blocks: 10)
        var peaks = [Float](repeating: 0, count: 64)
        let n = Int(dalnok_record_live_peaks(e, vox, &peaks, 64))
        #expect(n == 10 * 512 / Int(DALNOK_LIVE_PEAK_FRAMES), "one peak per 256 recorded frames")
        for i in 0..<min(n, 64) {
            let want = (0..<256).map { abs(channelSample(1, recordFrom + i * 256 + $0)) }.max()!
            #expect(peaks[i] == want, "peak \(i)")
        }
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
        #expect(result.frames == 10 * 512)
        let info = clipInfo(e, result.audio_clip)
        #expect(mediaSamples(e, info.media, 0, 10 * 512) == (0..<(10 * 512)).map { channelSample(1, recordFrom + $0) })
        #expect(dalnok_record_live_peaks(e, vox, &peaks, 64) == 0)
        dalnok_transport_pause(e)
        pump(e, from: &frame, blocks: 6) // still monitoring after the take
    }

    @Test func inputMonitoringIsSavedWithTheProject() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let vox = dalnok_track_add(e, "Vox")
        _ = dalnok_track_set_input_monitor(e, vox, true)
        let path = tempDir().appendingPathComponent("m.dalnok").path
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, path, &err, 256) == DALNOK_OK)
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("\"monitor\": true"))
        let f = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(f) }
        var missing: Int32 = 0
        #expect(dalnok_project_load(f, path, &missing, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var info = DalnokTrackInfo()
        #expect(dalnok_track_info(f, dalnok_track_at(f, 0), &info) == DALNOK_OK && info.input_monitor)
    }
}

extension InputMonitor {
    /// A loaded project (not a fresh engine): the I button must reach the audio thread, and so must a changed input.
    @Test func monitoringWorksAfterLoadingAProjectAndFollowsTheInputChannel() throws {
        let path = tempDir().appendingPathComponent("p.dalnok").path
        var err = [CChar](repeating: 0, count: 256)
        do {
            let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
            _ = dalnok_track_add(e, "Vox")
            #expect(dalnok_project_save(e, path, &err, 256) == DALNOK_OK)
        }
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var missing: Int32 = 0
        #expect(dalnok_project_load(e, path, &missing, &err, 256) == DALNOK_OK)
        let vox = dalnok_track_at(e, 0)
        setInput(e)
        #expect(dalnok_track_set_input_monitor(e, vox, true) == DALNOK_OK)
        var frame = 0
        pump(e, from: &frame, blocks: 3)
        var start = frame
        var out = pump(e, from: &frame, blocks: 1)
        #expect(zip(out, (0..<512).map { channelSample(0, start + $0) }).allSatisfy { abs($0 - $1) < 1e-5 }, "input 1 after load")
        #expect(dalnok_track_set_input(e, vox, 3) == DALNOK_OK)
        pump(e, from: &frame, blocks: 1)
        start = frame
        out = pump(e, from: &frame, blocks: 1)
        #expect(zip(out, (0..<512).map { channelSample(3, start + $0) }).allSatisfy { abs($0 - $1) < 1e-5 }, "follows the new input channel")
    }
}
