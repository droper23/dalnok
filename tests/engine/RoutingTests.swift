// Buses, outputs and sends: exact levels in offline renders, solo through routing, feedback, persistence.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

private let half: Float = -6.020_6 // dB for a gain of 0.5

/// One mono track holding a constant 0.5 (center pan of a mono source is unity).
private func session() -> (OpaquePointer, DalnokTrackId, OpaquePointer) {
    let e = dalnok_engine_create(48_000)!
    let m = makeMedia([[Float](repeating: 0.5, count: 4_800)])
    let t = dalnok_track_add(e, "A")
    let id = dalnok_pool_add(e, m, "")
    DalnokEngine.dalnok_clip_add(e, t, id, 0, 0, 0)
    return (e, t, m)
}

private func level(_ e: OpaquePointer) -> (Float, Float) {
    var l = [Float](repeating: 0, count: 1_000), r = l
    #expect(dalnok_render_offline(e, 1_000, 1_000, &l, &r) == DALNOK_OK)
    return (l[500], r[500])
}

private func close(_ a: (Float, Float), _ b: Float) -> Bool { abs(a.0 - b) < 1e-4 && abs(a.1 - b) < 1e-4 }

@Suite struct Routing {
    @Test func outputThroughABusAppliesTheBusFader() {
        let (e, a, m) = session(); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        #expect(close(level(e), 0.5))
        let bus = dalnok_track_add_bus(e, "Drums")
        #expect(dalnok_track_set_output(e, a, bus) == DALNOK_OK && dalnok_track_output(e, a) == bus)
        #expect(dalnok_track_set_gain_db(e, bus, half) == DALNOK_OK)
        #expect(close(level(e), 0.25), "\(level(e))")
        var info = DalnokTrackInfo()
        #expect(dalnok_track_info(e, bus, &info) == DALNOK_OK && info.kind == Int32(DALNOK_TRACK_BUS.rawValue))
        #expect(dalnok_track_set_pan(e, bus, 1) == DALNOK_OK) // bus balance: hard right keeps the right side
        let p = level(e)
        #expect(abs(p.0) < 1e-6 && abs(p.1 - 0.25) < 1e-4)
    }

    @Test func postAndPreFaderSendsAndMute() {
        let (e, a, m) = session(); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        let bus = dalnok_track_add_bus(e, "Reverb")
        #expect(dalnok_track_set_gain_db(e, a, half) == DALNOK_OK)
        #expect(dalnok_track_set_send(e, a, bus, 0, false) == DALNOK_OK)
        #expect(close(level(e), 0.5), "post-fader: 0.25 direct + 0.25 via the bus \(level(e))")
        #expect(dalnok_track_set_send(e, a, bus, half, true) == DALNOK_OK)
        #expect(close(level(e), 0.5), "pre-fader at -6 dB: 0.25 direct + 0.25 via the bus \(level(e))")
        #expect(dalnok_track_set_send(e, a, bus, 0, true) == DALNOK_OK)
        #expect(close(level(e), 0.75), "pre-fader at 0 dB ignores the track fader \(level(e))")
        var sends = [DalnokSend](repeating: DalnokSend(), count: 4)
        #expect(dalnok_track_sends(e, a, &sends, 4) == 1 && sends[0].bus == bus && sends[0].pre)
        #expect(dalnok_track_set_mute(e, a, true) == DALNOK_OK)
        #expect(close(level(e), 0), "mute silences pre-fader sends too")
        #expect(dalnok_track_set_mute(e, a, false) == DALNOK_OK)
        #expect(dalnok_track_remove_send(e, a, bus) == DALNOK_OK && close(level(e), 0.25))
        #expect(dalnok_track_remove_send(e, a, bus) != DALNOK_OK)
    }

    @Test func soloFollowsRouting() {
        let (e, a, m) = session(); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        let other = dalnok_track_add(e, "B")
        let mb = makeMedia([[Float](repeating: 0.125, count: 4_800)]); defer { dalnok_media_release(mb) }
        DalnokEngine.dalnok_clip_add(e, other, dalnok_pool_add(e, mb, ""), 0, 0, 0)
        let bus = dalnok_track_add_bus(e, "Bus")
        #expect(dalnok_track_set_output(e, a, bus) == DALNOK_OK)
        #expect(close(level(e), 0.625))
        #expect(dalnok_track_set_solo(e, bus, true) == DALNOK_OK)
        #expect(close(level(e), 0.5), "soloing the bus keeps A (feeding it) and mutes B \(level(e))")
        #expect(dalnok_track_set_solo(e, bus, false) == DALNOK_OK && dalnok_track_set_solo(e, a, true) == DALNOK_OK)
        #expect(close(level(e), 0.5), "soloing A keeps the bus it feeds \(level(e))")
    }

    @Test func feedbackAndClipsOnBusesAreRejected() {
        let (e, a, m) = session(); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        let b1 = dalnok_track_add_bus(e, "B1"), b2 = dalnok_track_add_bus(e, "B2")
        #expect(dalnok_track_set_output(e, b1, b2) == DALNOK_OK)
        #expect(dalnok_track_set_output(e, b2, b1) != DALNOK_OK)
        #expect(dalnok_track_set_send(e, b2, b1, 0, false) != DALNOK_OK)
        #expect(dalnok_track_set_output(e, b1, b1) != DALNOK_OK)
        #expect(dalnok_track_set_output(e, a, a) != DALNOK_OK, "outputs go to buses only")
        #expect(dalnok_track_set_send(e, a, b1, 7, false) != DALNOK_OK, "send level capped at +6 dB")
        let clip = dalnok_track_clip_at(e, a, 0)
        #expect(dalnok_clip_move(e, clip, b1, 0) != DALNOK_OK)
        // Chained buses: A → B1 → B2 (B2 at -6 dB) → master.
        #expect(dalnok_track_set_output(e, a, b1) == DALNOK_OK && dalnok_track_set_gain_db(e, b2, half) == DALNOK_OK)
        #expect(close(level(e), 0.25), "\(level(e))")
        // Deleting a bus sends what fed it to the master; undo restores the routing.
        #expect(dalnok_track_remove(e, b1) == DALNOK_OK)
        #expect(dalnok_track_output(e, a) == 0 && close(level(e), 0.5))
        #expect(dalnok_undo(e) && dalnok_track_output(e, a) == b1 && close(level(e), 0.25))
        #expect(runCommand(e, "track.setSend", "{\"track\":\(a),\"bus\":\(b2),\"db\":-6.0206}").0 == DALNOK_OK)
        #expect(close(level(e), 0.375), "\(level(e))")
    }

    @Test func routingSavesAndDamagedRoutingIsRejected() throws {
        let dir = tempDir()
        let wav = dir.appendingPathComponent("a.wav")
        let samples = try writeTestWav(wav, frames: 4_800)
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var loaded: OpaquePointer?
        #expect(dalnok_media_load(wav.path, 48_000, &loaded, nil, 0) == DALNOK_OK)
        let a = dalnok_track_add(e, "A")
        DalnokEngine.dalnok_clip_add(e, a, dalnok_pool_add(e, loaded, wav.path), 0, 0, 0)
        dalnok_media_release(loaded)
        let bus = dalnok_track_add_bus(e, "Verb")
        #expect(dalnok_track_set_output(e, a, bus) == DALNOK_OK && dalnok_track_set_send(e, a, bus, -3, true) == DALNOK_OK)
        var l = [Float](repeating: 0, count: 4_800), r = l
        #expect(dalnok_render_offline(e, 0, 4_800, &l, &r) == DALNOK_OK)
        let project = dir.appendingPathComponent("routing.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, err.count) == DALNOK_OK)
        var doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
        #expect(doc["version"] as? Int == 5)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, err.count) == DALNOK_OK, "\(cstr(err))")
        var l2 = l, r2 = r
        #expect(dalnok_render_offline(e2, 0, 4_800, &l2, &r2) == DALNOK_OK)
        #expect(zip(l, l2).allSatisfy { abs($0 - $1) < 1e-6 } && l.contains { $0 != 0 } && samples.count == 4_800)
        // A loop in the file is rejected.
        var tracks = try #require(doc["tracks"] as? [[String: Any]])
        let busIndex = try #require(tracks.firstIndex { $0["kind"] as? String == "bus" })
        tracks[busIndex]["sends"] = [[tracks[busIndex]["id"] as Any, 0, false]]
        doc["tracks"] = tracks
        let bad = dir.appendingPathComponent("loop.dalnok")
        try JSONSerialization.data(withJSONObject: doc).write(to: bad)
        #expect(dalnok_project_load(e2, bad.path, nil, &err, err.count) != DALNOK_OK)
    }
}

@Suite struct MasterFader {
    @Test func masterGainScalesTheMixLiveAndOfflineAndSaves() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([(0..<48_000).map { $0 % 2 == 0 ? Float(0.5) : -0.5 }]); defer { dalnok_media_release(m) } // no DC (meters ignore it)
        DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "A"), dalnok_pool_add(e, m, ""), 0, 0, 0)
        #expect(dalnok_master_set_gain_db(e, -6.020_6) == DALNOK_OK && undoName(e) == "Master Volume")
        #expect(abs(render(e, 0, 2_000)[1_000] - 0.25) < 1e-4)
        dalnok_transport_play(e)
        let (l, _) = pump(e, 4_000)
        #expect(abs(l[3_000] - 0.25) < 1e-4, "live \(l[3_000])")
        var ml: Float = 0, mr: Float = 0
        dalnok_meter_master(e, &ml, &mr)
        #expect(abs(ml - 0.25) < 1e-3, "meter reads after the fader")
        #expect(dalnok_undo(e) && dalnok_master_gain_db(e) == 0 && abs(render(e, 0, 2_000)[1_000] - 0.5) < 1e-4)
        #expect(runCommand(e, "master.setGain", #"{"db":-200}"#).0 == DALNOK_OK && render(e, 0, 2_000).allSatisfy { $0 == 0 })
    }
}

@Suite struct TrackStacks {
    @Test func aStackSumsItsMembersAndUngroups() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([[Float](repeating: 0.25, count: 4_800)]); defer { dalnok_media_release(m) }
        let id = dalnok_pool_add(e, m, "")
        let a = dalnok_track_add(e, "A"), x = dalnok_track_add(e, "X"), b = dalnok_track_add(e, "B")
        for t in [a, x, b] { DalnokEngine.dalnok_clip_add(e, t, id, 0, 0, 0) }
        let stack = dalnok_track_stack_create(e, [a, b], 2, "Drums")
        #expect(stack != 0 && undoName(e) == "Create Track Stack")
        // Order: Stack, A, B (the members follow the stack), then X.
        #expect((0..<4).map { dalnok_track_at(e, $0) } == [stack, a, b, x])
        var info = DalnokTrackInfo()
        _ = dalnok_track_info(e, a, &info)
        #expect(info.stack == stack && dalnok_track_output(e, a) == stack)
        _ = dalnok_track_info(e, stack, &info)
        #expect(info.is_stack && info.kind == Int32(DALNOK_TRACK_BUS.rawValue))
        #expect(abs(render(e, 0, 2_000)[1_000] - 0.75) < 1e-4)
        #expect(dalnok_track_set_gain_db(e, stack, -6.020_6) == DALNOK_OK)
        #expect(abs(render(e, 0, 2_000)[1_000] - 0.5) < 1e-4, "the stack's fader scales A and B only")
        #expect(dalnok_track_stack_set_collapsed(e, stack, true) == DALNOK_OK)
        _ = dalnok_track_info(e, stack, &info)
        #expect(info.collapsed)
        #expect(dalnok_track_stack_create(e, [a, x], 2, nil) == 0, "members must share a parent stack")
        #expect(dalnok_track_stack_ungroup(e, stack) == DALNOK_OK)
        #expect(dalnok_track_output(e, a) == 0 && abs(render(e, 0, 2_000)[1_000] - 0.75) < 1e-4)
        #expect(dalnok_undo(e) && dalnok_track_output(e, a) == stack)
        #expect(runCommand(e, "track.ungroupStack", "{\"track\":\(stack)}").0 == DALNOK_OK)
    }

    @Test func stacksNest() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([[Float](repeating: 0.25, count: 4_800)]); defer { dalnok_media_release(m) }
        let id = dalnok_pool_add(e, m, "")
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B"), c = dalnok_track_add(e, "C")
        for t in [a, b, c] { DalnokEngine.dalnok_clip_add(e, t, id, 0, 0, 0) }
        let inner = dalnok_track_stack_create(e, [a, b], 2, "Kit")
        let outer = dalnok_track_stack_create(e, [inner, c], 2, "Drums")
        #expect(inner != 0 && outer != 0)
        // Order: Drums, Kit, A, B, C; Kit sits in Drums and feeds it.
        #expect((0..<5).map { dalnok_track_at(e, $0) } == [outer, inner, a, b, c])
        var info = DalnokTrackInfo()
        _ = dalnok_track_info(e, inner, &info)
        #expect(info.stack == outer && dalnok_track_output(e, inner) == outer && dalnok_track_output(e, c) == outer)
        _ = dalnok_track_info(e, a, &info)
        #expect(info.stack == inner && dalnok_track_output(e, a) == inner, "A stays in Kit")
        #expect(abs(render(e, 0, 2_000)[1_000] - 0.75) < 1e-4)
        // Faders multiply down the chain: Kit at -6 dB halves A and B; Drums at -6 dB halves everything.
        #expect(dalnok_track_set_gain_db(e, inner, -6.020_6) == DALNOK_OK)
        #expect(abs(render(e, 0, 2_000)[1_000] - 0.5) < 1e-4)
        #expect(dalnok_track_set_gain_db(e, outer, -6.020_6) == DALNOK_OK)
        #expect(abs(render(e, 0, 2_000)[1_000] - 0.25) < 1e-4)
        // A stack inside Kit (members from Kit), and one across levels is refused.
        let pair = dalnok_track_stack_create(e, [b], 1, "B Sub")
        _ = dalnok_track_info(e, pair, &info)
        #expect(pair != 0 && info.stack == inner && dalnok_track_output(e, pair) == inner)
        #expect(dalnok_track_stack_create(e, [a, c], 2, nil) == 0, "A (in Kit) and C (in Drums) can't share a new stack")
        #expect(abs(render(e, 0, 2_000)[1_000] - 0.25) < 1e-4, "an extra unity stack changes nothing")
        // Ungrouping Drums returns Kit and C to the top level; deleting Kit moves A and B Sub up to the top too.
        #expect(dalnok_track_stack_ungroup(e, outer) == DALNOK_OK)
        _ = dalnok_track_info(e, inner, &info)
        #expect(info.stack == 0 && dalnok_track_output(e, inner) == 0 && dalnok_track_output(e, c) == 0)
        #expect(dalnok_track_remove(e, inner) == DALNOK_OK)
        _ = dalnok_track_info(e, a, &info)
        #expect(info.stack == 0 && dalnok_track_output(e, a) == 0 && abs(render(e, 0, 2_000)[1_000] - 0.75) < 1e-4)
        // Save and reopen keeps the nesting (undo back to the nested state first).
        #expect(dalnok_undo(e) && dalnok_undo(e))
        let dir = tempDir(), project = dir.appendingPathComponent("nested.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, err.count) == DALNOK_OK)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, err.count) == DALNOK_OK, "\(cstr(err))")
        _ = dalnok_track_info(e2, inner, &info)
        #expect(info.stack == outer && info.is_stack)
    }
}

@Suite struct TrackHeights {
    @Test func heightsAreViewStateThatSavesAndUndoes() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B")
        func h(_ t: DalnokTrackId) -> Float { var i = DalnokTrackInfo(); dalnok_track_info(e, t, &i); return i.height }
        #expect(h(a) == 0, "new tracks use the default height")
        #expect(dalnok_track_set_height(e, a, 150) == DALNOK_OK && h(a) == 150 && h(b) == 0 && undoName(e) == "Track Height")
        #expect(dalnok_track_set_height(e, 0, 1_000) == DALNOK_OK && h(a) == 400 && h(b) == 400, "track 0 sets all, clamped to 400")
        #expect(dalnok_track_set_height(e, a, -1) != DALNOK_OK && dalnok_track_set_height(e, 999, 100) != DALNOK_OK)
        #expect(dalnok_undo(e) && h(a) == 150 && h(b) == 0, "one undo per change")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let project = dir.appendingPathComponent("heights.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, err.count) == DALNOK_OK)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, err.count) == DALNOK_OK)
        var i = DalnokTrackInfo()
        dalnok_track_info(e2, dalnok_track_at(e2, 0), &i)
        #expect(i.height == 150, "the height is saved with the project (\(i.height))")
        #expect(runCommand(e, "track.setHeight", #"{"track":0,"height":0}"#).0 == DALNOK_OK && h(a) == 0)
    }
}
