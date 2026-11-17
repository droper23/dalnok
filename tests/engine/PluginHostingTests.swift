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
}
