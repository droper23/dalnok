// Audio Unit hosting against Apple's built-in units (present on every Mac).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct AudioUnitHosting {
    func parameter(_ e: OpaquePointer, _ slot: Int32, titled title: String) -> DalnokPluginParameter? {
        for i in 0..<dalnok_plugin_parameter_count(e, slot) {
            var p = DalnokPluginParameter()
            if dalnok_plugin_parameter(e, slot, i, &p) == DALNOK_OK, name(p.title).lowercased().contains(title) { return p }
        }
        return nil
    }

    @Test func appleDelayProcessesAndFollowsItsParameters() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, "au:aufx:dely:appl", nil, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        var info = DalnokPluginSlotInfo()
        dalnok_track_plugin_info(e, t, 0, &info)
        #expect(name(info.name) == "AUDelay" && name(info.vendor) == "Apple" && !info.instrument && info.loaded)
        guard let mix = parameter(e, slot, titled: "dry/wet"), let time = parameter(e, slot, titled: "delay time") else {
            Issue.record("AUDelay parameters not found"); return
        }
        // What it declares: the system's Audio Unit tags (used to sort it and choose its display).
        var cats = [CChar](repeating: 0, count: 256)
        dalnok_plugin_categories(e, slot, &cats, 256)
        #expect(cstr(cats).localizedCaseInsensitiveContains("delay"), "AUDelay declares \(cstr(cats))")
        // Text at any value, without changing the parameter (printed knob scales): delay time is 0-2 s.
        var text = [CChar](repeating: 0, count: 64)
        #expect(dalnok_plugin_parameter_text(e, slot, time.id, 0.5, &text, 64) == DALNOK_OK && cstr(text) == "1.00", "\(cstr(text))")
        #expect(dalnok_plugin_parameter_text(e, slot, time.id, 1.5, &text, 64) == DALNOK_ERR_INVALID_ARG)
        // All dry: the delay passes the signal through.
        #expect(dalnok_plugin_set_parameter(e, slot, mix.id, 0) == DALNOK_OK)
        let passthrough = renderStereo(e, 4_800)
        let worst = zip(passthrough.0, dry.0).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-5, "dry-only AUDelay differs by \(worst)")
        // All wet, 50 ms: nothing for the first 50 ms, then the delayed signal.
        dalnok_plugin_set_parameter(e, slot, mix.id, 1)
        dalnok_plugin_set_parameter(e, slot, time.id, 0.025) // 0…2 s range: 50 ms
        let wet = renderStereo(e, 4_800)
        #expect(wet.0[0..<2_300].allSatisfy { abs($0) < 1e-4 } && wet.0[2_500...].contains { abs($0) > 0.01 })
        // State survives save and reopen as an Audio Unit slot.
        let project = tempDir().appendingPathComponent("au.dalnok")
        #expect(dalnok_project_save(e, project.path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var info2 = DalnokPluginSlotInfo()
        dalnok_track_plugin_info(e2, dalnok_track_at(e2, 0), 0, &info2)
        #expect(info2.loaded && abs((parameter(e2, info2.id, titled: "dry/wet")?.value ?? 0) - 1) < 1e-4)
        let reopened = renderStereo(e2, 4_800)
        #expect(zip(reopened.0, wet.0).map { abs($0 - $1) }.max() ?? 1 < 1e-4)
    }

    @Test func appleSynthPlaysClipNotes() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "DLS")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_add(e, t, "au:aumu:dls :appl", nil, &err, 256) != 0, "\(cstr(err))")
        let c = dalnok_midi_clip_add(e, t, 0, 96_000)
        var note = DalnokNote(start: 12_000, length: 24_000, pitch: 60, velocity: 120)
        dalnok_midi_clip_set_notes(e, c, &note, 1)
        let (l, _) = renderStereo(e, 60_000)
        #expect(l[0..<12_000].allSatisfy { $0 == 0 }, "silent before the note")
        #expect(rms(l[12_000..<36_000]) > 0.005, "plays during the note")
    }
}
