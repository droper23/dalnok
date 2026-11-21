// CLAP hosting with a test plug-in (scripts/ci/plugin-host.sh builds it and sets DALNOK_TEST_CLAP).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine
import Foundation
import Testing

let testClap = ProcessInfo.processInfo.environment["DALNOK_TEST_CLAP"] ?? ""

@Suite(.serialized, .enabled(if: !testClap.isEmpty, "set DALNOK_TEST_CLAP (scripts/ci/plugin-host.sh)"))
struct ClapHosting {
    @Test func gainParametersStateAndAutomation() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, testClap, nil, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e, t, 0, &info) == DALNOK_OK && name(info.name) == "Dalnok Test CLAP Gain" && info.loaded)
        let wet = renderStereo(e, 4_800)
        #expect(zip(wet.0, dry.0).allSatisfy { abs($0 - $1 * 0.5) < 1e-6 }, "default gain 0.5")
        #expect(dalnok_plugin_parameter_count(e, slot) == 1)
        var p = DalnokPluginParameter()
        #expect(dalnok_plugin_parameter(e, slot, 0, &p) == DALNOK_OK && p.id == 7 && abs(p.value - 0.5) < 1e-9 && name(p.display) == "50 %")
        #expect(dalnok_plugin_set_parameter(e, slot, 7, 1) == DALNOK_OK)
        #expect(zip(renderStereo(e, 4_800).0, dry.0).allSatisfy { abs($0 - $1) < 1e-6 }, "gain 1 passes through")
        // State survives save and reopen.
        let dir = tempDir(), project = dir.appendingPathComponent("clap.dalnok")
        _ = try writeTestWav(dir.appendingPathComponent("x.wav"), frames: 10)
        #expect(dalnok_project_save(e, project.path, &err, err.count) == DALNOK_OK, "\(cstr(err))")
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, err.count) == DALNOK_OK, "\(cstr(err))")
        let t2 = dalnok_track_at(e2, 0)
        var info2 = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e2, t2, 0, &info2) == DALNOK_OK && info2.loaded)
        // Automation reaches the plug-in (plain range 0-1).
        let pts = [DalnokAutoPoint(frame: 0, value: 0.25)]
        #expect(dalnok_plugin_set_automation(e, t, slot, 7, pts, 1) == DALNOK_OK)
        #expect(zip(renderStereo(e, 4_800).0, dry.0).allSatisfy { abs($0 - $1 * 0.25) < 1e-6 }, "automated gain 0.25")
    }
    @Test func sidechainUsesAnotherTracksPreFaderSignal() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let bedMedia = makeMedia([[Float](repeating: 0.5, count: 48_000)])
        var key = [Float](repeating: 0, count: 48_000)
        for i in 24_000..<48_000 { key[i] = 0.75 }
        let keyMedia = makeMedia([key]); defer { dalnok_media_release(bedMedia); dalnok_media_release(keyMedia) }
        let bed = dalnok_track_add(e, "Bed"), source = dalnok_track_add(e, "Key")
        DalnokEngine.dalnok_clip_add(e, bed, dalnok_pool_add(e, bedMedia, ""), 0, 0, 0)
        DalnokEngine.dalnok_clip_add(e, source, dalnok_pool_add(e, keyMedia, ""), 0, 0, 0)
        #expect(dalnok_track_set_mute(e, source, true) == DALNOK_OK)
        let slot = dalnok_plugin_add(e, bed, testClap, nil, nil, 0)
        #expect(slot != 0 && dalnok_plugin_has_sidechain(e, slot))
        #expect(abs(render(e, 30_000, 10)[5] - 0.25) < 1e-4, "unconnected sidechain receives silence")
        #expect(dalnok_plugin_set_sidechain(e, bed, slot, source) == DALNOK_OK)
        let out = render(e, 0, 48_000)
        #expect(abs(out[10_000] - 0.25) < 1e-4, "silent key keeps full gain")
        #expect(abs(out[30_000] - 0.0625) < 1e-4, "0.75 key ducks 0.25 output to 0.0625")
        #expect(dalnok_plugin_set_sidechain(e, bed, slot, 0) == DALNOK_OK)
        #expect(abs(render(e, 30_000, 10)[5] - 0.25) < 1e-4, "disconnect returns sidechain to silence")
    }

    /// Edits made in the plug-in's own editor reach the project as changes (so closing asks to save): the plug-in
    /// marks its state dirty, or reports a parameter gesture. In process and isolated.
    /// Reported values that only repeat what the plug-in already holds (a sync after loading) are not edits.
    @Test func reportedValuesThatDoNotChangeAnythingAreNotEdits() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_plugin_add(e, t, testClap, nil, nil, 0) != 0)
        let path = tempDir().appendingPathComponent("clap-sync-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK)
        setenv("DALNOK_TEST_CLAP_SYNC", "1", 1); defer { unsetenv("DALNOK_TEST_CLAP_SYNC") }
        let b = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(b) }
        var missing: Int32 = -1
        #expect(dalnok_project_load(b, path, &missing, nil, 0) == DALNOK_OK)
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<8 { _ = dalnok_engine_pump(b, &l, &r, 512); usleep(10_000) } // stopped: flushes run
        dalnok_transport_play(b)
        for _ in 0..<8 { _ = dalnok_engine_pump(b, &l, &r, 512) }
        var info = DalnokPluginSlotInfo()
        _ = dalnok_track_plugin_info(b, dalnok_track_at(b, 0), 0, &info)
        #expect(!dalnok_project_dirty(b), "a plug-in repeating its own values after loading leaves the project clean (loaded \(info.loaded), error '\(cstr(withUnsafeBytes(of: info.error) { Array($0.bindMemory(to: CChar.self)) }))')")
    }

    @MainActor @Test(.serialized, arguments: ["event", "dirty", "flush", "queued"], [true, false])
    func editorEditsMarkTheProjectChanged(_ how: String, _ editorOpen: Bool) async throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, testClap, nil, nil, 0)
        #expect(slot != 0)
        let path = tempDir().appendingPathComponent("clap-edit-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK && !dalnok_project_dirty(e))
        setenv("DALNOK_TEST_CLAP_EDIT", how, 1); defer { unsetenv("DALNOK_TEST_CLAP_EDIT") }
        let b = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(b) }
        var missing: Int32 = -1
        #expect(dalnok_project_load(b, path, &missing, nil, 0) == DALNOK_OK && missing == 0)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var err = [CChar](repeating: 0, count: 256)
        if editorOpen {
            var w: Int32 = 0, h: Int32 = 0, slotInfo = DalnokPluginSlotInfo()
            _ = dalnok_track_plugin_info(b, dalnok_track_at(b, 0), 0, &slotInfo)
            if slotInfo.isolated { // its editor opens in the host's own window (ADR-0015)
                #expect(dalnok_plugin_show_editor_window(b, slotInfo.id, "Audio — Dalnok Test Gain", .nan, .nan, &err, 256) == DALNOK_OK, "\(cstr(err))")
            } else {
                #expect(dalnok_plugin_open_editor(b, slotInfo.id, Unmanaged.passUnretained(view).toOpaque(),
                                                  &w, &h, nil, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
            }
        }
        var l = [Float](repeating: 0, count: 512), r = l
        // "flush": the edit arrives while the transport is stopped, through the flush the plug-in asked for.
        if how != "flush" && how != "queued" {
            dalnok_transport_play(b)
            for _ in 0..<2 { _ = dalnok_engine_pump(b, &l, &r, 512) }
            #expect(!dalnok_project_dirty(b), "clean before the edit")
        }
        let deadline = Date().addingTimeInterval(editorOpen ? 5 : 1)
        while !dalnok_project_dirty(b) && Date() < deadline {
            _ = dalnok_engine_pump(b, &l, &r, 512)
            try await Task.sleep(for: .milliseconds(10)) // lets the main queue run the plug-in's callback ("dirty")
        }
        if editorOpen { #expect(dalnok_project_dirty(b), "an edit in the editor (\(how)) marks the project changed") }
        // The same reports with the editor closed come from the plug-in itself (finishing a background load): not edits.
        else { #expect(!dalnok_project_dirty(b), "a report (\(how)) with no editor open leaves the project clean") }
    }
}
