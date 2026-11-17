// Volume and pan automation: exact values at breakpoints and between them, live = offline, persistence, undo.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

private func constantTrack(_ e: OpaquePointer, frames: Int = 96_000) -> (DalnokTrackId, OpaquePointer) {
    let m = makeMedia([[Float](repeating: 0.5, count: frames)])
    let t = dalnok_track_add(e, "A")
    DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, m, ""), 0, 0, 0)
    return (t, m)
}

private func setAuto(_ e: OpaquePointer, _ t: DalnokTrackId, _ target: DalnokAutoTarget, _ pts: [(Int64, Float)]) -> DalnokStatus {
    let points = pts.map { DalnokAutoPoint(frame: $0.0, value: $0.1) }
    return dalnok_track_set_automation(e, t, Int32(target.rawValue), points, Int32(points.count))
}

@Suite struct Automation {
    @Test func volumeFollowsTheFaderTaperBetweenPoints() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let (t, m) = constantTrack(e); defer { dalnok_media_release(m) }
        #expect(dalnok_track_set_gain_db(e, t, -20) == DALNOK_OK) // automation overrides the fader
        #expect(setAuto(e, t, DALNOK_AUTO_VOLUME, [(24_000, 0), (72_000, -200)]) == DALNOK_OK)
        let out = render(e, 0, 96_000)
        #expect(abs(out[1_000] - 0.5) < 1e-6, "held at the first value before it (\(out[1_000]))")
        #expect(abs(out[24_000] - 0.5) < 1e-6)
        // Midway the taper (amplitude^(1/4)) is 0.5 → amplitude 0.0625.
        #expect(abs(out[48_000] - 0.5 * 0.0625) < 1e-5, "\(out[48_000])")
        // A quarter of the way: taper 0.75 → 0.3164.
        #expect(abs(out[36_000] - 0.5 * 0.316_406) < 1e-4, "\(out[36_000])")
        #expect(out[72_000...].allSatisfy { abs($0) < 1e-7 }, "silent from the last point on")
        // Smooth: no step larger than the ramp allows.
        #expect(maxStep(Array(out[24_000..<72_000])) < 1e-3)
    }

    @Test func panAutomationAndMute() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let (t, m) = constantTrack(e); defer { dalnok_media_release(m) }
        #expect(setAuto(e, t, DALNOK_AUTO_PAN, [(0, -1), (48_000, 1)]) == DALNOK_OK)
        var l = [Float](repeating: 0, count: 96_000), r = l
        #expect(dalnok_render_offline(e, 0, 96_000, &l, &r) == DALNOK_OK)
        #expect(abs(l[0] - 0.707_107) < 1e-4 && abs(r[0]) < 1e-4, "hard left at the start (\(l[0]), \(r[0]))")
        #expect(abs(l[24_000] - 0.5) < 1e-4 && abs(r[24_000] - 0.5) < 1e-4, "center midway")
        #expect(abs(l[60_000]) < 1e-4 && abs(r[60_000] - 0.707_107) < 1e-4, "hard right after the last point")
        #expect(dalnok_track_set_mute(e, t, true) == DALNOK_OK)
        #expect(render(e, 0, 96_000).allSatisfy { $0 == 0 }, "mute still silences an automated track")
    }

    @Test func livePlaybackMatchesTheExport() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let (t, m) = constantTrack(e); defer { dalnok_media_release(m) }
        #expect(setAuto(e, t, DALNOK_AUTO_VOLUME, [(0, -30), (20_000, 3), (40_000, -12)]) == DALNOK_OK)
        #expect(setAuto(e, t, DALNOK_AUTO_PAN, [(10_000, 0.5), (30_000, -0.25)]) == DALNOK_OK)
        var offL = [Float](repeating: 0, count: 48_000), offR = offL
        #expect(dalnok_render_offline(e, 0, 48_000, &offL, &offR) == DALNOK_OK)
        dalnok_transport_play(e)
        let (liveL, liveR) = pump(e, 48_000, block: 333)
        for i in 300..<48_000 where abs(liveL[i] - offL[i]) > 1e-6 || abs(liveR[i] - offR[i]) > 1e-6 {
            Issue.record("sample \(i): live \(liveL[i]),\(liveR[i]) offline \(offL[i]),\(offR[i])"); break
        }
    }

    @Test func persistenceUndoAndValidation() throws {
        let dir = tempDir()
        let wav = dir.appendingPathComponent("a.wav")
        try writeTestWav(wav, frames: 48_000)
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var loaded: OpaquePointer?
        #expect(dalnok_media_load(wav.path, 48_000, &loaded, nil, 0) == DALNOK_OK)
        let t = dalnok_track_add(e, "A")
        DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, loaded, wav.path), 0, 0, 0)
        dalnok_media_release(loaded)
        #expect(setAuto(e, t, DALNOK_AUTO_VOLUME, [(48_000, -6), (0, 0)]) == DALNOK_OK) // sorted by the engine
        var pts = [DalnokAutoPoint](repeating: DalnokAutoPoint(), count: 4)
        #expect(dalnok_track_automation(e, t, Int32(DALNOK_AUTO_VOLUME.rawValue), &pts, 4) == 2 && pts[0].frame == 0)
        #expect(setAuto(e, t, DALNOK_AUTO_PAN, [(0, 1.5)]) != DALNOK_OK)
        #expect(setAuto(e, t, DALNOK_AUTO_VOLUME, [(0, 7)]) != DALNOK_OK)
        #expect(setAuto(e, t, DALNOK_AUTO_VOLUME, [(-1, 0)]) != DALNOK_OK)
        let expected = render(e, 0, 48_000)
        let project = dir.appendingPathComponent("auto.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, err.count) == DALNOK_OK)
        let doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
        #expect(doc["version"] as? Int == 6)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, err.count) == DALNOK_OK, "\(cstr(err))")
        #expect(zip(expected, render(e2, 0, 48_000)).allSatisfy { abs($0 - $1) < 1e-6 })
        let e44 = dalnok_engine_create(44_100)!; defer { dalnok_engine_destroy(e44) }
        #expect(dalnok_project_load(e44, project.path, nil, &err, err.count) == DALNOK_OK)
        #expect(dalnok_track_automation(e44, dalnok_track_at(e44, 0), 0, &pts, 4) == 2 && pts[1].frame == 44_100)
        // Undo restores the previous lane; an empty list removes it.
        #expect(setAuto(e, t, DALNOK_AUTO_VOLUME, []) == DALNOK_OK && dalnok_track_automation(e, t, 0, nil, 0) == 0)
        #expect(dalnok_undo(e) && dalnok_track_automation(e, t, 0, nil, 0) == 2)
        #expect(runCommand(e, "track.setAutomation", "{\"track\":\(t),\"target\":\"pan\",\"points\":[[0,-1],[100,1]]}").0 == DALNOK_OK)
        #expect(dalnok_track_automation(e, t, 1, nil, 0) == 2)
    }
}
