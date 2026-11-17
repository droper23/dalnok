// Recording sessions on the simulated duplex device: placement, latency, undo,
// persistence, failures, and journal recovery (ADR-0008 gates 2, 3 and 5 at engine level).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Deterministic input signal; exactly representable in float32.
func inputSample(_ n: Int) -> Float { Float((n * 37) % 2_000 - 1_000) / 1_024 }

struct SimulatedTake {
    let engine: OpaquePointer
    var frame = 0
    /// Runs `blocks` duplex cycles of 512 frames, feeding inputSample(frame...).
    mutating func pump(_ blocks: Int, monitorCheck: ((Float) -> Void)? = nil) {
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<blocks {
            let input = (0..<512).map { inputSample(frame + $0) }
            #expect(dalnok_engine_pump_input(engine, input, &l, &r, 512) == DALNOK_OK)
            monitorCheck?(l[100])
            frame += 512
        }
    }
}

func mediaSamples(_ e: OpaquePointer, _ media: DalnokMediaId, _ start: Int64, _ count: Int) -> [Float] {
    guard let m = dalnok_pool_media(e, media) else { return [] }
    var mins = [Float](repeating: 0, count: count), maxs = mins
    _ = dalnok_media_peaks(m, 0, start, 1, &mins, &maxs, Int64(count))
    return mins
}

func files(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
}

@Suite struct Recording {
    @Test func takeIsPlacedLatencyCompensatedAsOneUndoStep() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        let track = dalnok_track_add(e, "Vox")
        #expect(dalnok_track_set_armed(e, track, true) == DALNOK_OK)
        dalnok_record_set_simulated_latency(e, 100)
        dalnok_transport_seek(e, 48_000)
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 512) == DALNOK_OK, "\(cstr(err))")
        #expect(dalnok_record_active(e) && dalnok_transport_is_playing(e))
        #expect(files(dir) == ["Vox Take 1.dlncap", "Vox Take 1.dlntake"]) // journal exists during the take
        var take = SimulatedTake(engine: e)
        take.pump(40)
        // The first block applies the pending seek, so it is not part of the take.
        #expect(dalnok_record_start_frame(e) == 48_512)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
        #expect(!dalnok_record_active(e) && !dalnok_transport_is_playing(e))
        #expect(result.frames == 39 * 512 && result.capture.dropped_frames == 0 && !result.recovered)
        #expect(result.start_frame == 48_512 && result.latency_frames == 100)
        #expect(files(dir) == ["Vox Take 1.wav"]) // spool and journal removed only after verification

        let clip = clipInfo(e, result.audio_clip)
        #expect(clip.track == track && clip.start == 48_412 && clip.offset == 0 && clip.length == 39 * 512)
        // Bit-exact: input frame 512 (first take block) is the first sample of the file.
        let got = mediaSamples(e, clip.media, 0, 39 * 512)
        let want = (0..<(39 * 512)).map { inputSample(512 + $0) }
        #expect(got == want)

        #expect(undoName(e) == "Record")
        #expect(dalnok_undo(e))
        #expect(dalnok_track_clip_at(e, track, 0) == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Vox Take 1.wav").path)) // undo keeps audio
        #expect(dalnok_redo(e))
        #expect(dalnok_track_clip_at(e, track, 0) == result.audio_clip)

        // Save, reopen, and render: the take plays from its placed position.
        let project = dir.appendingPathComponent("session.dalnok")
        #expect(dalnok_project_save(e, project.path, &err, 512) == DALNOK_OK)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, 512) == DALNOK_OK, "\(cstr(err))")
        let t2 = dalnok_track_at(e2, 0), c2 = clipInfo(e2, dalnok_track_clip_at(e2, t2, 0))
        #expect(c2.start == 48_412 && c2.length == 39 * 512 && !c2.offline)
        var l = [Float](repeating: 0, count: 8), r = l
        #expect(dalnok_render_offline(e2, 48_412, 8, &l, &r) == DALNOK_OK)
        for i in 0..<8 { #expect(abs(l[i] - want[i]) < 1e-6) } // mono center pan = unity
    }

    @Test func latencyBeforeTimelineStartTrimsTheTake() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir(), track = dalnok_track_add(e, "Gtr")
        dalnok_track_set_armed(e, track, true)
        dalnok_record_set_simulated_latency(e, 300)
        dalnok_record_set_latency_offset(e, 20)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, nil, 0) == DALNOK_OK)
        var take = SimulatedTake(engine: e)
        take.pump(4)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, nil, 0) == DALNOK_OK)
        let clip = clipInfo(e, result.audio_clip)
        #expect(result.start_frame == 0 && result.latency_frames == 320)
        #expect(clip.start == 0 && clip.offset == 320 && clip.length == 4 * 512 - 320)
    }

    @Test func pausingDuringATakeFailsAndKeepsTheValidPrefix() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir(), track = dalnok_track_add(e, "Bass")
        dalnok_track_set_armed(e, track, true)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, nil, 0) == DALNOK_OK)
        var take = SimulatedTake(engine: e)
        take.pump(10)
        dalnok_transport_pause(e)
        take.pump(4) // one fade-out block still advances; the next stops the transport
        #expect(dalnok_record_broken(e))
        var result = DalnokRecordResult()
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_stop(e, &result, &err, 512) != DALNOK_OK)
        #expect(cstr(err).contains("transport"))
        #expect(result.recovered && result.audio_clip == 0 && dalnok_track_clip_at(e, track, 0) == 0)
        #expect(result.frames == 11 * 512) // the fade-out block was continuous, nothing after it
        #expect(files(dir) == ["Bass Take 1 (recovered).wav", "Bass Take 1.dlncap", "Bass Take 1.dlntake"])
        var json = [CChar](repeating: 0, count: 8_192)
        dalnok_record_scan(dir.path, &json, json.count)
        let list = try JSONSerialization.jsonObject(with: Data(cstr(json).utf8)) as? [[String: Any]] ?? []
        #expect(list.count == 1 && list.first?["state"] as? String == "recovered")
        #expect((list.first?["error"] as? String ?? "").contains("transport"))
    }

    @Test func journalRecoveryPreservesSpoolAndIsRepeatable() throws {
        let dir = tempDir(), spool = dir.appendingPathComponent("Keys Take 1.dlncap")
        var data = Data("DLNCAP01".utf8)
        withUnsafeBytes(of: UInt32(48_000).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { data.append(contentsOf: $0) }
        for n in 0..<1_000 { withUnsafeBytes(of: inputSample(n).bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: [1, 2]) // the process died mid-write
        try data.write(to: spool)
        let journal = dir.appendingPathComponent("Keys Take 1.dlntake")
        try #"{"format":"dalnok-take","version":1,"state":"recording","spool":"Keys Take 1.dlncap","wav":"Keys Take 1.wav","sampleRate":48000,"channels":1}"#
            .write(to: journal, atomically: true, encoding: .utf8)
        var json = [CChar](repeating: 0, count: 8_192), err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_record_recover(journal.path, &json, json.count, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let r = try JSONSerialization.jsonObject(with: Data(cstr(json).utf8)) as? [String: Any] ?? [:]
        #expect(r["frames"] as? Int == 1_000 && r["trailingBytes"] as? Int == 2 && r["state"] as? String == "recovered")
        #expect(try Data(contentsOf: spool) == data)
        let wav = dir.appendingPathComponent("Keys Take 1 (recovered).wav")
        let first = try Data(contentsOf: wav)
        #expect(dalnok_record_recover(journal.path, &json, json.count, &err, 256) == DALNOK_OK)
        #expect(try Data(contentsOf: wav) == first && (try Data(contentsOf: spool)) == data)
        var media: OpaquePointer?
        #expect(dalnok_media_load(wav.path, 48_000, &media, nil, 0) == DALNOK_OK)
        if let media {
            var mins = [Float](repeating: 0, count: 1_000), maxs = mins
            dalnok_media_peaks(media, 0, 0, 1, &mins, &maxs, 1_000)
            #expect(mins == (0..<1_000).map(inputSample))
            dalnok_media_release(media)
        }
        // A corrupt journal is rejected without touching anything.
        let bad = dir.appendingPathComponent("bad.dlntake")
        try "{\"format\":\"dalnok-take\"".write(to: bad, atomically: true, encoding: .utf8)
        #expect(dalnok_record_recover(bad.path, &json, json.count, &err, 256) != DALNOK_OK)
    }

    @Test func recordingNeedsAnArmedTrackAndAnInput() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 256) != DALNOK_OK)
        #expect(cstr(err).contains("arm"))
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B")
        dalnok_track_set_armed(e, a, true)
        dalnok_track_set_armed(e, b, true) // audio tracks can all be armed (one input each)
        var info = DalnokTrackInfo()
        dalnok_track_info(e, a, &info)
        #expect(info.armed)
        let k1 = dalnok_track_add_instrument(e, "K1"), k2 = dalnok_track_add_instrument(e, "K2")
        dalnok_track_set_armed(e, k1, true); dalnok_track_set_armed(e, k2, true) // one MIDI track at a time
        dalnok_track_info(e, k1, &info)
        #expect(!info.armed)
        #expect(dalnok_record_start(e, nil, dir.path, &err, 256) != DALNOK_OK)
        #expect(cstr(err).contains("input"))
        #expect(files(dir).isEmpty)
        #expect(dalnok_track_set_input(e, b, 1) == DALNOK_OK)
        dalnok_track_info(e, b, &info)
        #expect(info.input_channel == 1)
    }

    @Test func monitoringAddsInputToTheOutputOnlyWhenEnabled() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let track = dalnok_track_add(e, "Mic")
        dalnok_track_set_armed(e, track, true)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, tempDir().path, nil, 0) == DALNOK_OK)
        var take = SimulatedTake(engine: e)
        take.pump(1) { #expect($0 == 0) }
        dalnok_record_set_monitoring(e, true)
        var heard: [Float] = []
        take.pump(2) { heard.append($0) }
        #expect(heard == [inputSample(512 + 100), inputSample(1_024 + 100)])
        dalnok_record_set_monitoring(e, false)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, nil, 0) == DALNOK_OK)
    }
}
