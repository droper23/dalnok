// VST3 hosting (ADR-0009 gates 3 and 4) against the test plugin built by scripts/ci/plugin-host.sh.
// Runs when DALNOK_TEST_VST3 names that bundle; skipped otherwise.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

let testVst3 = ProcessInfo.processInfo.environment["DALNOK_TEST_VST3"] ?? ""
func classHex(_ ascii: String) -> String { ascii.utf8.map { String(format: "%02X", $0) }.joined() }
let gainClass = classHex("DalnokTestGain01"), synthClass = classHex("DalnokTestSynth1")
func floatState(_ v: Float) -> String { withUnsafeBytes(of: v.bitPattern.littleEndian) { Data($0).base64EncodedString() } }

func renderStereo(_ e: OpaquePointer, _ frames: Int) -> ([Float], [Float]) {
    var l = [Float](repeating: 0, count: frames), r = l
    _ = dalnok_render_offline(e, 0, Int64(frames), &l, &r)
    return (l, r)
}

/// An audio track playing a deterministic file (so saved projects find it again).
func audioSession() -> (OpaquePointer, DalnokTrackId) {
    let e = dalnok_engine_create(48_000)!
    let t = dalnok_track_add(e, "Audio")
    let url = tempDir().appendingPathComponent("source.wav")
    _ = try? writeTestWav(url, frames: 4_800)
    var media: OpaquePointer?
    _ = dalnok_media_load(url.path, 48_000, &media, nil, 0)
    if let media {
        _ = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, media, url.path), 0, 0, 0)
        dalnok_media_release(media)
    }
    return (e, t)
}

@Suite(.enabled(if: !testVst3.isEmpty, "set DALNOK_TEST_VST3 (scripts/ci/plugin-host.sh)"))
struct PluginHosting {
    @Test func gainInsertProcessesAndPassthroughNulls() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        #expect(undoName(e) == "Add Plug-in")
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e, t, 0, &info) == DALNOK_OK)
        #expect(name(info.name) == "Dalnok Test Gain" && !info.instrument && info.loaded && info.latency == 7)
        let wet = renderStereo(e, 4_800)
        #expect(wet.0 == dry.0.map { $0 * 0.5 } && wet.1 == dry.1.map { $0 * 0.5 }, "gain 0.5 is exact")
        // Null test: gain 1 passes audio through bit-exactly.
        #expect(dalnok_plugin_set_state(e, slot, floatState(1)) == DALNOK_OK)
        let passthrough = renderStereo(e, 4_800)
        #expect(passthrough.0 == dry.0 && passthrough.1 == dry.1, "passthrough nulls against the dry signal")
        // Undo removes the insert; redo brings back the same instance and state.
        #expect(dalnok_undo(e))
        #expect(dalnok_track_plugin_count(e, t) == 0 && renderStereo(e, 4_800).0 == dry.0)
        #expect(dalnok_redo(e))
        #expect(renderStereo(e, 4_800).0 == dry.0)
        // The effect also runs on the live path.
        dalnok_plugin_set_state(e, slot, floatState(0.25))
        dalnok_transport_play(e)
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<4 { dalnok_engine_pump(e, &l, &r, 512) } // past the 5 ms fade-in
        #expect(l[100] == dry.0[1_536 + 100] * 0.25, "fourth live block = frames 1536…2047")
    }

    @Test func parametersReachTheProcessorLiveAndOffline() {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        #expect(dalnok_plugin_parameter_count(e, slot) == 1)
        var p = DalnokPluginParameter()
        #expect(dalnok_plugin_parameter(e, slot, 0, &p) == DALNOK_OK)
        #expect(name(p.title) == "Gain" && p.id == 1 && p.value == 0.5 && name(p.display) == "50 %" && p.automatable)
        // Offline: the parameter set a moment ago is replayed into the export's own instance.
        #expect(dalnok_plugin_set_parameter(e, slot, 1, 0.25) == DALNOK_OK)
        #expect(dalnok_project_dirty(e))
        #expect(renderStereo(e, 4_800).0 == dry.0.map { $0 * 0.25 })
        dalnok_plugin_parameter(e, slot, 0, &p)
        #expect(p.value == 0.25 && name(p.display) == "25 %")
        // Live: applied from the next block.
        dalnok_transport_play(e)
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<4 { dalnok_engine_pump(e, &l, &r, 512) }
        #expect(l[100] == dry.0[1_536 + 100] * 0.25)
        #expect(dalnok_plugin_set_parameter(e, slot, 1, 2) != DALNOK_OK) // out of range
        // No editor view: opening fails cleanly. Isolated instances (ADR-0015) are never embedded and say where
        // their editor opens instead.
        var slotInfo = DalnokPluginSlotInfo()
        _ = dalnok_track_plugin_info(e, t, 0, &slotInfo)
        #expect(dalnok_plugin_has_editor(e, slot))
        var err = [CChar](repeating: 0, count: 128)
        let dummy = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8); defer { dummy.deallocate() }
        #expect(dalnok_plugin_open_editor(e, slot, dummy, nil, nil, nil, nil, &err, 128) == DALNOK_ERR_UNSUPPORTED)
        #expect(cstr(err).contains(slotInfo.isolated ? "its own window" : "no editor"), "\(cstr(err))")
    }

    @Test func instrumentPluginPlaysNotesSampleAccurately() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Synth")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_add(e, t, testVst3, synthClass, &err, 256) != 0, "\(cstr(err))")
        #expect(undoName(e) == "Set Instrument")
        let c = dalnok_midi_clip_add(e, t, 0, 8_000)
        var notes = [DalnokNote(start: 1_000, length: 500, pitch: 60, velocity: 127),
                     DalnokNote(start: 3_000, length: 100, pitch: 64, velocity: 64)]
        dalnok_midi_clip_set_notes(e, c, &notes, 2)
        let (l, r) = renderStereo(e, 4_096)
        let v2 = Float(64) / 127
        // Note boundaries fall inside 512-frame blocks (1000 = block 1 + 488): events land on the exact sample.
        #expect(l[0..<1_000].allSatisfy { $0 == 0 } && l[1_000..<1_500].allSatisfy { $0 == 1 })
        #expect(l[1_500..<3_000].allSatisfy { $0 == 0 } && l[3_000..<3_100].allSatisfy { $0 == v2 } && l[3_100...].allSatisfy { $0 == 0 })
        #expect(l == r)
        // An insert after the instrument processes its output.
        let gain = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        #expect(gain != 0 && dalnok_track_plugin_count(e, t) == 2)
        #expect(renderStereo(e, 2_000).0[1_200] == 0.5)
        dalnok_plugin_remove(e, t, gain)
        // Live MIDI reaches the plugin instrument while stopped, starting at the next block.
        var lb = [Float](repeating: 0, count: 512), rb = lb
        dalnok_engine_pump(e, &lb, &rb, 512)
        #expect(lb.allSatisfy { $0 == 0 })
        dalnok_midi_inject(e, 0x90, 67, 127)
        dalnok_engine_pump(e, &lb, &rb, 512)
        #expect(lb.allSatisfy { $0 == 1 }, "live note-on applies from the start of the next block")
        dalnok_midi_inject(e, 0x80, 67, 0)
        dalnok_engine_pump(e, &lb, &rb, 512)
        #expect(lb.allSatisfy { $0 == 0 })
        // Instrument plugins only go on instrument tracks.
        let audio = dalnok_track_add(e, "Audio")
        #expect(dalnok_plugin_add(e, audio, testVst3, synthClass, &err, 256) == 0 && cstr(err).contains("instrument"))
    }

    @Test func bypassedOrMissingInstrumentDoesNotSubstituteTheBuiltInSynth() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Instrument")
        let slot = dalnok_plugin_add(e, t, testVst3, synthClass, nil, 0)
        #expect(slot != 0)
        let c = dalnok_midi_clip_add(e, t, 0, 4_096)
        var note = DalnokNote(start: 100, length: 1_000, pitch: 60, velocity: 127)
        #expect(dalnok_midi_clip_set_notes(e, c, &note, 1) == DALNOK_OK)
        #expect(abs(renderStereo(e, 2_048).0[500] - 1) < 1e-6)
        #expect(dalnok_plugin_set_bypassed(e, t, slot, true) == DALNOK_OK)
        #expect(renderStereo(e, 2_048).0.allSatisfy { abs($0) < 1e-6 }, "a bypassed instrument is silent")
        #expect(dalnok_track_set_armed(e, t, true) == DALNOK_OK)
        dalnok_midi_inject(e, 0x90, 60, 127)
        let live = pump(e, 1_024).0
        #expect(live.allSatisfy { abs($0) < 1e-6 }, "live input cannot play the fallback synth either")
        dalnok_midi_inject(e, 0x80, 60, 0); _ = pump(e, 512)
        #expect(dalnok_plugin_set_bypassed(e, t, slot, false) == DALNOK_OK)
        let file = tempDir().appendingPathComponent("missing-instrument.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, file.path, &err, 256) == DALNOK_OK)
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: testVst3.replacingOccurrences(of: "/", with: "\\/"), with: "/nonexistent/Instrument.vst3")
            .replacingOccurrences(of: testVst3, with: "/nonexistent/Instrument.vst3")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, file.path, nil, &err, 256) == DALNOK_OK)
        #expect(renderStereo(e2, 2_048).0.allSatisfy { abs($0) < 1e-6 }, "a missing instrument is silent")
    }

    @Test func shortInstrumentNotesEndWithinTheSameBlock() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Short notes")
        #expect(dalnok_plugin_add(e, t, testVst3, synthClass, nil, 0) != 0)
        let c = dalnok_midi_clip_add(e, t, 0, 4_096)
        let notes = [DalnokNote(start: 100, length: 80, pitch: 60, velocity: 127),
                     DalnokNote(start: 250, length: 50, pitch: 60, velocity: 127)]
        #expect(dalnok_midi_clip_set_notes(e, c, notes, Int32(notes.count)) == DALNOK_OK)
        let out = renderStereo(e, 1_024).0
        #expect(out[0..<100].allSatisfy { abs($0) < 1e-6 })
        #expect(out[100..<180].allSatisfy { abs($0 - 1) < 1e-6 })
        #expect(out[180..<250].allSatisfy { abs($0) < 1e-6 })
        #expect(out[250..<300].allSatisfy { abs($0 - 1) < 1e-6 })
        #expect(out[300...].allSatisfy { abs($0) < 1e-6 })
    }

    @Test func stateSurvivesSaveAndAMissingPluginKeepsIt() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        dalnok_plugin_set_state(e, slot, floatState(0.25))
        let dir = tempDir(), project = dir.appendingPathComponent("hosted.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let t2 = dalnok_track_at(e2, 0)
        var info = DalnokPluginSlotInfo()
        dalnok_track_plugin_info(e2, t2, 0, &info)
        var b64 = [CChar](repeating: 0, count: 64)
        dalnok_plugin_get_state(e2, info.id, &b64, 64)
        #expect(info.loaded && cstr(b64) == floatState(0.25))
        #expect(renderStereo(e2, 4_800).0 == dry.0.map { $0 * 0.25 })
        // Point the project at a plugin that is not installed: it loads bypassed and keeps its state.
        var text = try String(contentsOf: project, encoding: .utf8)
        text = text.replacingOccurrences(of: testVst3.replacingOccurrences(of: "/", with: "\\/"), with: "/nonexistent/Gone.vst3")
            .replacingOccurrences(of: testVst3, with: "/nonexistent/Gone.vst3")
        try text.write(to: project, atomically: true, encoding: .utf8)
        let e3 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e3) }
        #expect(dalnok_project_load(e3, project.path, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let t3 = dalnok_track_at(e3, 0)
        dalnok_track_plugin_info(e3, t3, 0, &info)
        #expect(!info.loaded && !cstr(withUnsafeBytes(of: info.error) { Array($0.bindMemory(to: CChar.self)) }).isEmpty)
        #expect(renderStereo(e3, 4_800).0 == dry.0, "a missing insert is bypassed")
        let resaved = dir.appendingPathComponent("resaved.dalnok")
        #expect(dalnok_project_save(e3, resaved.path, &err, 256) == DALNOK_OK)
        #expect(try String(contentsOf: resaved, encoding: .utf8).contains(floatState(0.25)), "the saved state is kept")
    }

    @Test func rejectedPluginStateIsReportedAndPreserved() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        #expect(slot != 0)
        let dir = tempDir(), project = dir.appendingPathComponent("invalid-state.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, 256) == DALNOK_OK)
        var doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
        var tracks = try #require(doc["tracks"] as? [[String: Any]])
        var plugins = try #require(tracks[0]["plugins"] as? [[String: Any]])
        let rejected = Data([0x12, 0x34]).base64EncodedString()
        plugins[0]["state"] = rejected
        tracks[0]["plugins"] = plugins
        doc["tracks"] = tracks
        try JSONSerialization.data(withJSONObject: doc).write(to: project)
        let loaded = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(loaded) }
        #expect(dalnok_project_load(loaded, project.path, nil, &err, 256) == DALNOK_OK)
        let track = dalnok_track_at(loaded, 0)
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(loaded, track, 0, &info) == DALNOK_OK)
        let message = cstr(withUnsafeBytes(of: info.error) { Array($0.bindMemory(to: CChar.self)) })
        #expect(!info.loaded && message.contains("state") && message.contains("preserved"))
        var state = [CChar](repeating: 0, count: 64)
        dalnok_plugin_get_state(loaded, info.id, &state, state.count)
        #expect(cstr(state) == rejected)
        let resaved = dir.appendingPathComponent("resaved.dalnok")
        #expect(dalnok_project_save(loaded, resaved.path, &err, 256) == DALNOK_OK)
        #expect(try String(contentsOf: resaved, encoding: .utf8).contains(rejected))
    }

    @Test func bypassPassesAudioThroughAndSurvivesSaveAndUndo() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        dalnok_plugin_set_state(e, slot, floatState(0.5))
        #expect(renderStereo(e, 4_800).0 == dry.0.map { $0 * 0.5 })
        #expect(dalnok_plugin_set_bypassed(e, t, slot, true) == DALNOK_OK)
        #expect(dalnok_plugin_bypassed(e, t, slot) && undoName(e) == "Bypass Plug-in")
        let bypassed = renderStereo(e, 4_800)
        #expect(bypassed.0 == dry.0 && bypassed.1 == dry.1, "a bypassed insert nulls against the dry signal")
        #expect(dalnok_plugin_set_bypassed(e, t, slot, true) != DALNOK_OK, "bypassing twice is not an undo step")
        // Saved and reopened: still bypassed, state kept; the project is written as format 10.
        let project = tempDir().appendingPathComponent("bypass.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        #expect(try String(contentsOf: project, encoding: .utf8).contains("\"version\": 10") ||
                (try String(contentsOf: project, encoding: .utf8).contains("\"version\":10")))
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let t2 = dalnok_track_at(e2, 0)
        var info = DalnokPluginSlotInfo()
        dalnok_track_plugin_info(e2, t2, 0, &info)
        #expect(dalnok_plugin_bypassed(e2, t2, info.id) && renderStereo(e2, 4_800).0 == dry.0)
        // Undo brings the effect back.
        #expect(dalnok_undo(e))
        #expect(!dalnok_plugin_bypassed(e, t, slot) && renderStereo(e, 4_800).0 == dry.0.map { $0 * 0.5 })
    }

    @Test func reorderingTheChainChangesProcessingOrderAndUndoes() throws {
        // Two gain inserts: order doesn't change a product, so check the list order, undo and the render.
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        let a = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0), b = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        dalnok_plugin_set_state(e, a, floatState(0.5)); dalnok_plugin_set_state(e, b, floatState(0.25))
        #expect(dalnok_plugin_move(e, t, b, 0) == DALNOK_OK && undoName(e) == "Move Plug-in")
        var info = DalnokPluginSlotInfo()
        dalnok_track_plugin_info(e, t, 0, &info)
        #expect(info.id == b)
        #expect(renderStereo(e, 4_800).0 == dry.0.map { $0 * 0.25 * 0.5 }, "both still process after the move")
        #expect(dalnok_plugin_move(e, t, b, 5) != DALNOK_OK, "out-of-range index refused")
        #expect(dalnok_undo(e))
        dalnok_track_plugin_info(e, t, 0, &info)
        #expect(info.id == a)
    }

    @Test func duplicatingATrackCopiesItsPluginsWithTheirState() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        dalnok_plugin_set_state(e, slot, floatState(0.25))
        let one = renderStereo(e, 4_800)
        let d = dalnok_track_duplicate(e, t)
        var info = DalnokPluginSlotInfo()
        #expect(d != 0 && dalnok_track_plugin_info(e, d, 0, &info) == DALNOK_OK && info.loaded && info.id != slot)
        var b64 = [CChar](repeating: 0, count: 64)
        dalnok_plugin_get_state(e, info.id, &b64, 64)
        #expect(cstr(b64) == floatState(0.25), "the copy has its own instance with the same state")
        let two = renderStereo(e, 4_800)
        #expect(zip(two.0, one.0).allSatisfy { abs($0 - 2 * $1) < 1e-6 }, "both tracks process through gain 0.25")
        dalnok_plugin_set_state(e, info.id, floatState(1))
        #expect(renderStereo(e, 4_800).0 != two.0, "changing the copy's plug-in leaves the original alone")
    }

    /// A VST3 that reports its restored values through performEdit while loading (common in commercial plug-ins)
    /// must not make a freshly opened project look edited, in-process or isolated, synchronous or deferred.
    @Test func editsReportedWhileLoadingAreNotProjectChanges() throws {
        setenv("DALNOK_TEST_STATE_EDIT", "1", 1); defer { unsetenv("DALNOK_TEST_STATE_EDIT") }
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        #expect(slot != 0)
        dalnok_plugin_set_state(e, slot, floatState(0.25))
        let path = tempDir().appendingPathComponent("state-edit-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK && !dalnok_project_dirty(e))
        var l = [Float](repeating: 0, count: 512), r = l
        // Synchronous open.
        let a = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(a) }
        var missing: Int32 = -1
        #expect(dalnok_project_load(a, path, &missing, nil, 0) == DALNOK_OK && missing == 0)
        for _ in 0..<4 { _ = dalnok_engine_pump(a, &l, &r, 512) }
        #expect(!dalnok_project_dirty(a), "a synchronously opened project is clean")
        // Deferred open (the app's path).
        let b = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(b) }
        var data: OpaquePointer?
        #expect(dalnok_project_prepare(path, 48_000, &data, &missing, nil, 0) == DALNOK_OK)
        #expect(dalnok_project_apply_deferred(b, data) == DALNOK_OK)
        let deadline = Date().addingTimeInterval(10)
        while dalnok_plugins_activate_next(b, nil, nil) >= 0 && Date() < deadline { usleep(2_000) }
        for _ in 0..<4 { _ = dalnok_engine_pump(b, &l, &r, 512) }
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(b, dalnok_track_at(b, 0), 0, &info) == DALNOK_OK && info.loaded)
        #expect(!dalnok_project_dirty(b), "a project opened with deferred activation is clean")
    }
}
