// Deferred plug-in activation (A-08, ADR-0013): apply shows the project at once and plug-ins load one at a time.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct DeferredActivation {
    let dir = tempDir()

    /// A saved project with one audio track and three channel EQs (the second one changes the sound).
    func makeProject() -> (path: String, reference: [Float], dry: [Float], plugins: Data) {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let audio = dir.appendingPathComponent("deferred-\(UUID().uuidString).wav")
        _ = try! writeTestWav(audio, frames: 9_600)
        var m: OpaquePointer?
        #expect(dalnok_media_load(audio.path, sr, &m, nil, 0) == DALNOK_OK)
        let media = dalnok_pool_add(e, m, audio.path)
        dalnok_media_release(m)
        let t = dalnok_track_add(e, "A")
        _ = DalnokEngine.dalnok_clip_add(e, t, media, 0, 0, 0)
        let dry = render(e, frames: 4_800).0
        for k in 0..<3 {
            let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
            #expect(slot > 0)
            if k == 1 { #expect(dalnok_plugin_set_parameter(e, slot, 28, 1) == DALNOK_OK) } // high cut on
        }
        let reference = render(e, frames: 4_800).0
        let path = dir.appendingPathComponent("deferred-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK)
        return (path, reference, dry, pluginsJSON(path))
    }

    func pluginsJSON(_ path: String) -> Data {
        let doc = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let tracks = doc["tracks"] as! [[String: Any]]
        return try! JSONSerialization.data(withJSONObject: tracks[0]["plugins"]!, options: [.sortedKeys])
    }

    func infos(_ e: OpaquePointer, _ t: DalnokTrackId) -> [DalnokPluginSlotInfo] {
        (0..<3).compactMap { i in
            var info = DalnokPluginSlotInfo()
            return dalnok_track_plugin_info(e, t, Int32(i), &info) == DALNOK_OK ? info : nil
        }
    }

    func applyDeferred(_ path: String) -> OpaquePointer {
        let e = dalnok_engine_create(sr)!
        var data: OpaquePointer?
        var missing: Int32 = -1
        #expect(dalnok_project_prepare(path, sr, &data, &missing, nil, 0) == DALNOK_OK && missing == 0)
        #expect(dalnok_project_apply_deferred(e, data) == DALNOK_OK)
        return e
    }

    @Test func projectIsLiveBeforeItsPluginsAndLoadsThemOneAtATime() {
        let p = makeProject()
        let e = applyDeferred(p.path); defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_at(e, 0)
        #expect(dalnok_track_count(e) == 1 && dalnok_plugins_pending(e) == 3)
        #expect(infos(e, t).allSatisfy { $0.loading && !$0.loaded })
        // Unloaded inserts are bypassed, so the project plays dry while plug-ins load.
        expectClose(render(e, frames: 4_800).0, p.dry, tol: 1e-6, "dry while loading")
        #expect(zip(p.dry, p.reference).contains { abs($0 - $1) > 1e-3 }) // the EQ is audible
        let revision = dalnok_model_revision(e)
        var slot: Int32 = 0, seconds = -1.0
        #expect(dalnok_plugins_activate_next(e, &slot, &seconds) == 2)
        #expect(slot == infos(e, t)[0].id && seconds >= 0 && dalnok_model_revision(e) > revision)
        #expect(infos(e, t)[0].loaded && !infos(e, t)[0].loading && infos(e, t)[1].loading)
        #expect(dalnok_plugins_activate_next(e, nil, nil) == 1)
        #expect(dalnok_plugins_activate_next(e, nil, nil) == 0)
        #expect(dalnok_plugins_activate_next(e, &slot, nil) == -1 && slot == 0)
        #expect(infos(e, t).allSatisfy { $0.loaded && !$0.loading })
        expectClose(render(e, frames: 4_800).0, p.reference, tol: 1e-6, "all loaded")
        #expect(!dalnok_project_dirty(e)) // loading plug-ins is not an edit
    }

    @Test func cancelKeepsStateAndReloadRestoresTheSound() {
        let p = makeProject()
        let e = applyDeferred(p.path); defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_at(e, 0)
        #expect(dalnok_plugins_activate_next(e, nil, nil) == 2)
        dalnok_plugins_cancel_pending(e)
        #expect(dalnok_plugins_pending(e) == 0 && dalnok_plugins_activate_next(e, nil, nil) == -1)
        let after = infos(e, t)
        #expect(after[0].loaded && !after[1].loaded && !after[2].loaded && after.allSatisfy { !$0.loading })
        #expect(name(after[1].error).contains("cancelled"))
        // Saving with unloaded slots keeps every saved state exactly.
        let saved = dir.appendingPathComponent("cancelled-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, saved, nil, 0) == DALNOK_OK)
        #expect(pluginsJSON(saved) == p.plugins)
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_reload(e, after[1].id, &err, 256) == DALNOK_OK)
        #expect(dalnok_plugin_reload(e, after[2].id, &err, 256) == DALNOK_OK)
        #expect(dalnok_plugin_reload(e, after[2].id, &err, 256) == DALNOK_OK) // already loaded: no-op
        #expect(dalnok_plugin_reload(e, 9_999, &err, 256) == DALNOK_ERR_NOT_FOUND)
        #expect(infos(e, t).allSatisfy { $0.loaded && $0.error.0 == 0 })
        expectClose(render(e, frames: 4_800).0, p.reference, tol: 1e-6, "reloaded")
    }

    @Test func removedAndReloadedSlotsAreSkipped() {
        let p = makeProject()
        let e = applyDeferred(p.path); defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_at(e, 0)
        let ids = infos(e, t).map(\.id)
        #expect(dalnok_plugin_remove(e, t, ids[0]) == DALNOK_OK)
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_reload(e, ids[1], &err, 256) == DALNOK_OK) // loaded early by the user
        var slot: Int32 = 0
        #expect(dalnok_plugins_activate_next(e, &slot, nil) == 0 && slot == ids[2])
        #expect(dalnok_undo(e)) // the removed slot comes back unloaded, not silently re-queued
        let restored = infos(e, t)
        #expect(restored.count == 3 && !restored[0].loaded && !restored[0].loading && dalnok_plugins_pending(e) == 0)
        #expect(dalnok_plugin_reload(e, ids[0], &err, 256) == DALNOK_OK)
        expectClose(render(e, frames: 4_800).0, p.reference, tol: 1e-6, "after undo and reload")
    }
}
