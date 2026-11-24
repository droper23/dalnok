// Several armed audio tracks recording their own inputs in one take.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Different deterministic signals per device input channel.
func channelSample(_ channel: Int, _ n: Int) -> Float { Float(((n + channel * 977) * (31 + channel * 6)) % 2_000 - 1_000) / 1_024 }

@Suite struct MultiInput {
    func pump(_ e: OpaquePointer, from: inout Int, blocks: Int, channels: Int = 4) {
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<blocks {
            let bufs = (0..<channels).map { c in (0..<512).map { channelSample(c, from + $0) } }
            var ptrs = bufs.map { b -> UnsafePointer<Float>? in nil }
            bufs.withUnsafeBufferPointer { _ in }
            // Keep each buffer alive while calling.
            let ok: Bool = withExtendedLifetime(bufs) {
                var raw: [UnsafePointer<Float>?] = []
                for b in bufs { raw.append(b.withUnsafeBufferPointer { $0.baseAddress }) }
                ptrs = raw
                return dalnok_engine_pump_input_channels(e, ptrs, Int32(channels), &l, &r, 512) == DALNOK_OK
            }
            #expect(ok)
            from += 512
        }
    }

    @Test func eachArmedTrackGetsItsOwnInputAsOneUndoStep() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        let vox = dalnok_track_add(e, "Vox"), gtr = dalnok_track_add(e, "Gtr"), idle = dalnok_track_add(e, "Idle")
        #expect(dalnok_track_set_input(e, vox, 0) == DALNOK_OK && dalnok_track_set_input(e, gtr, 2) == DALNOK_OK)
        _ = dalnok_track_set_armed(e, vox, true); _ = dalnok_track_set_armed(e, gtr, true)
        dalnok_record_set_simulated_latency(e, 0)
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 512) == DALNOK_OK, "\(cstr(err))")
        var frame = 0
        pump(e, from: &frame, blocks: 30)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
        #expect(result.audio_clip_count == 2 && result.frames == 30 * 512)
        #expect(files(dir) == ["Gtr Take 1.wav", "Vox Take 1.wav"], "\(files(dir))")
        let clips = withUnsafeBytes(of: result.audio_clips) { Array($0.bindMemory(to: DalnokClipId.self).prefix(2)) }
        for (clip, (track, channel)) in zip(clips, [(vox, 0), (gtr, 2)]) {
            let info = clipInfo(e, clip)
            #expect(info.track == track && info.start == 0 && info.length == 30 * 512)
            let got = mediaSamples(e, info.media, 0, 30 * 512)
            #expect(got == (0..<(30 * 512)).map { channelSample(channel, $0) }, "track on input \(channel + 1) holds that input")
        }
        #expect(dalnok_track_clip_at(e, idle, 0) == 0)
        #expect(dalnok_undo(e) && dalnok_track_clip_at(e, vox, 0) == 0 && dalnok_track_clip_at(e, gtr, 0) == 0, "one undo removes both takes")
    }

    @Test func aFailedMultiTrackTakeRecoversEveryTrack() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B")
        _ = dalnok_track_set_input(e, b, 1)
        _ = dalnok_track_set_armed(e, a, true); _ = dalnok_track_set_armed(e, b, true)
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 512) == DALNOK_OK)
        var frame = 0
        pump(e, from: &frame, blocks: 8)
        dalnok_transport_pause(e) // interrupt: the take fails, the valid prefix is kept per track
        pump(e, from: &frame, blocks: 2)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) != DALNOK_OK && result.recovered && result.audio_clip_count == 0)
        let names = files(dir)
        #expect(names.contains("A Take 1 (recovered).wav") && names.contains("B Take 1 (recovered).wav") &&
                names.contains("A Take 1.dlncap") && names.contains("A Take 1.dlntake"), "\(names)")
        // Recovering the journal again (as after a crash) is repeatable and reports both files.
        var json = [CChar](repeating: 0, count: 8_192)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("B Take 1 (recovered).wav"))
        #expect(dalnok_record_recover(dir.appendingPathComponent("A Take 1.dlntake").path, &json, json.count, &err, 512) == DALNOK_OK, "\(cstr(err))")
        #expect(files(dir).contains("B Take 1 (recovered).wav"))
        var loaded: OpaquePointer?
        #expect(dalnok_media_load(dir.appendingPathComponent("B Take 1 (recovered).wav").path, 48_000, &loaded, nil, 0) == DALNOK_OK)
        defer { dalnok_media_release(loaded) }
        let frames = Int(dalnok_media_frames(loaded))
        var mins = [Float](repeating: 0, count: frames), maxs = mins
        _ = dalnok_media_peaks(loaded, 0, 0, 1, &mins, &maxs, Int64(frames))
        #expect(frames > 0 && mins == (0..<frames).map { channelSample(1, $0) }, "B's file holds input 2 (\(frames) frames)")
    }
}

@Suite struct StereoInput {
    @Test func aStereoTrackRecordsTwoInputsAsOneStereoTake() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        let keys = dalnok_track_add(e, "Keys")
        #expect(dalnok_track_set_input(e, keys, 2) == DALNOK_OK && dalnok_track_set_input_stereo(e, keys, true) == DALNOK_OK)
        var info = DalnokTrackInfo(); _ = dalnok_track_info(e, keys, &info)
        #expect(info.input_stereo && info.input_channel == 2)
        _ = dalnok_track_set_armed(e, keys, true)
        dalnok_record_set_simulated_latency(e, 0)
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 512) == DALNOK_OK, "\(cstr(err))")
        var frame = 0
        MultiInput().pump(e, from: &frame, blocks: 20)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
        #expect(result.audio_clip_count == 1 && files(dir) == ["Keys Take 1.wav"], "\(files(dir))")
        let clip = clipInfo(e, result.audio_clip)
        guard let m = dalnok_pool_media(e, clip.media) else { Issue.record("no media"); return }
        #expect(dalnok_media_channels(m) == 2)
        var mins = [Float](repeating: 0, count: 20 * 512), maxs = mins
        _ = dalnok_media_peaks(m, 0, 0, 1, &mins, &maxs, Int64(mins.count))
        #expect(mins == (0..<(20 * 512)).map { channelSample(2, $0) }, "left is input 3")
        _ = dalnok_media_peaks(m, 1, 0, 1, &mins, &maxs, Int64(mins.count))
        #expect(mins == (0..<(20 * 512)).map { channelSample(3, $0) }, "right is input 4")
    }
}
