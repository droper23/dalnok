// Clip launcher: slot clips loop sample-exactly, launches land on the bar, scenes, exports ignore slots.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct Launcher {
    /// One track with a constant 0.25 timeline clip and a 10,000-frame ramp copied into slot 0.
    func session() -> (OpaquePointer, DalnokTrackId, [Float], [OpaquePointer]) {
        let e = dalnok_engine_create(48_000)!
        let t = dalnok_track_add(e, "Loop")
        let bed = makeMedia([[Float](repeating: 0.25, count: 400_000)])
        let ramp = (0..<10_000).map { Float($0 % 1_000) / 2_000 + 0.01 }
        let loop = makeMedia([ramp])
        DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, bed, ""), 0, 0, 0)
        let src = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, loop, ""), 300_000, 0, 0)
        #expect(dalnok_launcher_copy_clip(e, src, 0) != 0 && undoName(e) == "Copy to Launcher")
        #expect(dalnok_clip_remove(e, src) == DALNOK_OK) // keep only the slot copy
        return (e, t, ramp, [bed, loop])
    }

    @Test func launchingWhilePlayingSwitchesOnTheNextBarAndLoops() {
        let (e, t, ramp, media) = session(); defer { media.forEach { dalnok_media_release($0) }; dalnok_engine_destroy(e) }
        dalnok_transport_play(e)
        _ = pump(e, 30_000, block: 333)
        #expect(dalnok_launcher_launch(e, t, 0) == DALNOK_OK)
        let (l, _) = pump(e, 200_000 - 30_000, block: 333) // up to frame 200,000
        // 120 BPM 4/4: bar 2 starts at 96,000.
        let at = { (frame: Int) in l[frame - 30_000] }
        #expect(abs(at(95_999) - 0.25) < 1e-4, "arrangement until the bar")
        #expect(abs(at(96_000) - ramp[0]) < 1e-4 && abs(at(96_500) - ramp[500]) < 1e-4, "the slot starts exactly on the bar")
        #expect(abs(at(106_000) - ramp[0]) < 1e-4 && abs(at(115_123) - ramp[9_123]) < 1e-4, "and loops every 10,000 frames")
        #expect(dalnok_launcher_playing(e, t) == 0)
        // Back to the arrangement on the following bar (288,000; the playhead is near 200,000).
        #expect(dalnok_launcher_launch(e, t, -1) == DALNOK_OK)
        let (l2, _) = pump(e, 100_000, block: 512) // 200,000 … 300,000
        #expect(abs(l2[87_999] - 0.25) > 1e-3 && abs(l2[88_000] - 0.25) < 1e-4 && dalnok_launcher_playing(e, t) == -1,
                "arrangement again from bar 4 (288,000)")
    }

    @Test func launchingWhileStoppedStartsTheTransportAndExportsIgnoreSlots() {
        let (e, t, ramp, media) = session(); defer { media.forEach { dalnok_media_release($0) }; dalnok_engine_destroy(e) }
        #expect(abs(render(e, 0, 1_000)[500] - 0.25) < 1e-4)
        #expect(dalnok_launcher_launch(e, t, 0) == DALNOK_OK && dalnok_transport_is_playing(e))
        let (l, _) = pump(e, 12_000, block: 256)
        #expect(abs(l[1_000] - ramp[1_000]) < 1e-4 && abs(l[11_000] - ramp[1_000]) < 1e-4)
        #expect(abs(render(e, 0, 1_000)[500] - 0.25) < 1e-4, "exports play the arrangement")
        #expect(dalnok_launcher_launch(e, t, 3) != DALNOK_OK, "empty slot")
    }

    @Test func scenesLaunchEveryTrackAndSlotsSave() throws {
        let (e, t, _, media) = session(); defer { media.forEach { dalnok_media_release($0) }; dalnok_engine_destroy(e) }
        let other = dalnok_track_add(e, "Other")
        #expect(dalnok_launcher_launch_scene(e, 0) == DALNOK_OK)
        _ = pump(e, 1_000)
        #expect(dalnok_launcher_playing(e, t) == 0 && dalnok_launcher_playing(e, other) == -1)
        #expect(dalnok_launcher_launch_scene(e, 5) != DALNOK_OK)
        dalnok_launcher_stop_all(e)
        _ = pump(e, 200_000)
        #expect(dalnok_launcher_playing(e, t) == -1)
        #expect(dalnok_launcher_scenes(e) == 8)
        #expect(runCommand(e, "launcher.launch", "{\"track\":\(t),\"slot\":0}").0 == DALNOK_OK)
        var info = DalnokClipInfo()
        var found = false
        var ti = DalnokTrackInfo()
        _ = dalnok_track_info(e, t, &ti)
        for k in 0..<ti.clip_count {
            _ = dalnok_clip_info(e, dalnok_track_clip_at(e, t, k), &info)
            if info.slot == 0 { found = true }
        }
        #expect(found)
    }
}

@Suite struct LauncherFollowAndRecord {
    @Test func followActionsChainSlotsExactlyAtLoopEnds() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "T")
        let a = makeMedia([[Float](repeating: 0.1, count: 10_000)]), b = makeMedia([[Float](repeating: 0.4, count: 8_000)])
        defer { dalnok_media_release(a); dalnok_media_release(b) }
        let ca = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, a, ""), 0, 0, 0)
        let cb = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, b, ""), 20_000, 0, 0)
        let sa = dalnok_launcher_copy_clip(e, ca, 0), sb = dalnok_launcher_copy_clip(e, cb, 1)
        _ = dalnok_clip_remove(e, ca); _ = dalnok_clip_remove(e, cb)
        #expect(dalnok_launcher_set_follow(e, sa, 1, 1) == DALNOK_OK && undoName(e) == "Follow Action")
        #expect(dalnok_launcher_set_follow(e, sb, 2, 2) == DALNOK_OK)
        #expect(dalnok_launcher_set_follow(e, sb, 3, 1) != DALNOK_OK)
        #expect(dalnok_launcher_launch(e, t, 0) == DALNOK_OK)
        let (l, _) = pump(e, 30_000, block: 333)
        #expect(abs(l[9_999] - 0.1) < 1e-4 && abs(l[10_000] - 0.4) < 1e-4, "next slot exactly after one loop")
        #expect(abs(l[25_999] - 0.4) < 1e-4 && abs(l[26_000]) < 1e-6, "stop after two loops of slot 2 (the arrangement is empty)")
        #expect(dalnok_launcher_playing(e, t) == -1)
    }

    @Test func recordingAPerformanceWritesItIntoTheArrangement() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "T")
        let a = makeMedia([[Float](repeating: 0.3, count: 40_000)]); defer { dalnok_media_release(a) }
        let c = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, a, ""), 0, 0, 0)
        #expect(dalnok_launcher_copy_clip(e, c, 0) != 0)
        _ = dalnok_clip_remove(e, c)
        dalnok_launcher_set_recording(e, true)
        #expect(dalnok_launcher_recording(e))
        dalnok_transport_play(e)
        _ = pump(e, 10_000)
        #expect(dalnok_launcher_launch(e, t, 0) == DALNOK_OK) // lands on bar 2 (96,000)
        _ = pump(e, 200_000 - 10_000)
        dalnok_launcher_set_recording(e, false)
        #expect(undoName(e) == "Record Launcher")
        var info = DalnokTrackInfo()
        _ = dalnok_track_info(e, t, &info)
        var starts: [Int64] = []
        for k in 0..<info.clip_count {
            let ci = clipInfo(e, dalnok_track_clip_at(e, t, k))
            if ci.slot < 0 { starts.append(ci.start) }
        }
        #expect(starts.sorted().first == 96_000 && starts.count >= 2, "loop passes from the launch on: \(starts.sorted())")
        #expect(abs(render(e, 100_000, 10)[5] - 0.3) < 1e-4, "the arrangement now plays the performance")
        #expect(dalnok_undo(e))
    }
}
