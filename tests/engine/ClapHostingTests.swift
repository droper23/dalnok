// CLAP hosting with a test plug-in (scripts/ci/plugin-host.sh builds it and sets DALNOK_TEST_CLAP).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

let testClap = ProcessInfo.processInfo.environment["DALNOK_TEST_CLAP"] ?? ""

@Suite(.enabled(if: !testClap.isEmpty, "set DALNOK_TEST_CLAP (scripts/ci/plugin-host.sh)"))
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
}
