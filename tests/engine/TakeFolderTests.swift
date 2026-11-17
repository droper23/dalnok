// Cycle recording into takes, take folders and comping: exact samples per pass and per comp segment.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

private func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-6 } // mono center pan is unity within float error

@Suite struct TakeFolders {
    /// Records with cycle [10,000, 20,000) from 10,000 for `blocks` × 512 frames; capture frame k = inputSample(k).
    func cycleTake(blocks: Int) -> (OpaquePointer, DalnokTrackId, DalnokRecordResult) {
        let e = dalnok_engine_create(48_000)!
        let t = dalnok_track_add(e, "Vox")
        _ = dalnok_track_set_armed(e, t, true)
        dalnok_record_set_simulated_latency(e, 0)
        #expect(dalnok_cycle_set(e, true, 10_000, 20_000) == DALNOK_OK)
        dalnok_transport_seek(e, 10_000)
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<2 { dalnok_engine_pump(e, &l, &r, 512) }
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, tempDir().path, &err, 512) == DALNOK_OK, "\(cstr(err))")
        var take = SimulatedTake(engine: e)
        take.pump(blocks)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
        return (e, t, result)
    }

    func folderTakes(_ e: OpaquePointer, _ f: Int32) -> [DalnokClipInfo] {
        var ids = [DalnokClipId](repeating: 0, count: 16)
        let n = dalnok_take_folder_takes(e, f, &ids, 16)
        return ids.prefix(Int(n)).map { clipInfo(e, $0) }
    }

    @Test func cycleRecordingMakesOneTakePerPassAndCompsTheNewest() {
        // 49 blocks = 25,088 frames: two full passes and a 5,088-frame third.
        let (e, t, result) = cycleTake(blocks: 49); defer { dalnok_engine_destroy(e) }
        #expect(result.take_folder_count == 1 && result.frames == 49 * 512)
        let folder = result.take_folders.0
        var ids = [Int32](repeating: 0, count: 4)
        #expect(dalnok_take_folders(e, t, &ids, 4) == 1 && ids[0] == folder)
        let takes = folderTakes(e, folder)
        #expect(takes.map(\.start) == [10_000, 10_000, 10_000] && takes.map(\.offset) == [0, 10_000, 20_000] &&
                takes.map(\.length) == [10_000, 10_000, 5_088], "\(takes.map { ($0.start, $0.offset, $0.length) })")
        #expect(takes.allSatisfy { $0.alt && $0.folder == folder })
        var comp = [DalnokCompSegment](repeating: DalnokCompSegment(), count: 8)
        #expect(dalnok_take_folder_comp(e, folder, &comp, 8) == 2)
        #expect(comp[0].from == 10_000 && comp[0].to == 15_088 && comp[0].take == 2 && comp[1].from == 15_088 && comp[1].to == 20_000 && comp[1].take == 1)
        // The newest pass plays where it exists, the second pass after it.
        let out = render(e, 10_000, 10_000)
        #expect(near(out[2_000], inputSample(22_000)), "pass 3 at 12,000")
        #expect(near(out[7_000], inputSample(17_000)), "pass 2 at 17,000 (after the crossfade)")
    }

    @Test func swipingACompSegmentChangesWhatPlaysAsOneUndoStep() {
        let (e, _, result) = cycleTake(blocks: 49); defer { dalnok_engine_destroy(e) }
        let folder = result.take_folders.0
        let comp = [DalnokCompSegment(from: 10_000, to: 13_000, take: 0), DalnokCompSegment(from: 13_000, to: 20_000, take: 1)]
        #expect(dalnok_take_folder_set_comp(e, folder, comp, 2) == DALNOK_OK && undoName(e) == "Comp")
        let out = render(e, 10_000, 10_000)
        #expect(near(out[1_000], inputSample(1_000)) && near(out[6_000], inputSample(16_000)))
        // Around the boundary at 13,000 the second piece fades in over the first (equal power), no gap.
        #expect(abs(out[2_999]) > 0 || inputSample(12_999) == 0)
        #expect(dalnok_undo(e))
        #expect(near(render(e, 10_000, 10_000)[2_000], inputSample(22_000)))
        // Bad comps are rejected without changes.
        let outside = [DalnokCompSegment(from: 15_000, to: 18_000, take: 2)] // take 3 ends at 15,088
        #expect(dalnok_take_folder_set_comp(e, folder, outside, 1) != DALNOK_OK)
        let overlap = [DalnokCompSegment(from: 10_000, to: 14_000, take: 0), DalnokCompSegment(from: 13_000, to: 14_500, take: 1)]
        #expect(dalnok_take_folder_set_comp(e, folder, overlap, 2) != DALNOK_OK)
        #expect(dalnok_take_folder_comp(e, folder, nil, 0) == 2)
    }

    @Test func foldersSaveReopenAndCanBeMadeFromClips() throws {
        let (e, t, result) = cycleTake(blocks: 49); defer { dalnok_engine_destroy(e) }
        let expected = render(e, 10_000, 10_000)
        let project = tempDir().appendingPathComponent("takes.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, err.count) == DALNOK_OK)
        let doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
        #expect(doc["version"] as? Int == 7)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, err.count) == DALNOK_OK, "\(cstr(err))")
        #expect(render(e2, 10_000, 10_000) == expected)
        #expect(dalnok_take_folder_takes(e2, result.take_folders.0, nil, 0) == 3)
        // A folder from two ordinary clips: the later covers the earlier where they overlap.
        let m1 = makeMedia([[Float](repeating: 0.25, count: 9_000)]), m2 = makeMedia([[Float](repeating: 0.5, count: 9_000)])
        defer { dalnok_media_release(m1); dalnok_media_release(m2) }
        let k = dalnok_track_add(e, "Gtr")
        let c1 = DalnokEngine.dalnok_clip_add(e, k, dalnok_pool_add(e, m1, ""), 30_000, 0, 9_000)
        let c2 = DalnokEngine.dalnok_clip_add(e, k, dalnok_pool_add(e, m2, ""), 33_000, 0, 6_000)
        let f = dalnok_take_folder_create(e, k, [c1, c2], 2)
        #expect(f != 0 && clipInfo(e, c1).alt && clipInfo(e, c2).alt)
        let out = render(e, 30_000, 9_000)
        #expect(near(out[1_000], 0.25) && near(out[5_000], 0.5))
        #expect(runCommand(e, "takes.setComp", "{\"folder\":\(f),\"comp\":[[30000,39000,0]]}").0 == DALNOK_OK)
        #expect(near(render(e, 30_000, 9_000)[5_000], 0.25))
        _ = t
    }
}
