// Clip launcher, Phase 5: recording into slots, dragging clips between the timeline and slots (one undo step each
// way), and the queued-launch state the launcher animates.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct LauncherSlots {
    /// The track's clips: (timeline clips, slot clips) by id.
    func clips(_ e: OpaquePointer, _ t: DalnokTrackId) -> (timeline: [DalnokClipInfo], slots: [DalnokClipInfo]) {
        var info = DalnokTrackInfo()
        _ = dalnok_track_info(e, t, &info)
        let all = (0..<info.clip_count).map { clipInfo(e, dalnok_track_clip_at(e, t, $0)) }
        return (all.filter { $0.slot < 0 }, all.filter { $0.slot >= 0 })
    }

    @Test func recordingIntoASlotKeepsTheWholeBarsAndIsOneUndoStep() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let dir = tempDir()
        let t = dalnok_track_add(e, "Vox")
        // The slot already holds a clip: the take replaces it.
        let old = makeMedia([[Float](repeating: 0.3, count: 20_000)]); defer { dalnok_media_release(old) }
        let src = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, old, ""), 0, 0, 0)
        #expect(dalnok_launcher_copy_clip(e, src, 1) != 0)
        #expect(dalnok_clip_remove(e, src) == DALNOK_OK)
        #expect(dalnok_track_set_armed(e, t, true) == DALNOK_OK)
        dalnok_record_set_simulated_latency(e, 0)
        dalnok_record_set_slot(e, 1)
        #expect(dalnok_record_slot(e) == 1)
        #expect(runCommand(e, "launcher.setRecordSlot", "{\"slot\":-1}").0 == DALNOK_OK && dalnok_record_slot(e) == -1)
        #expect(runCommand(e, "launcher.setRecordSlot", "{\"slot\":1}").0 == DALNOK_OK && dalnok_record_slot(e) == 1)
        dalnok_transport_seek(e, 30_000)
        var err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, dir.path, &err, 512) == DALNOK_OK, "\(cstr(err))")
        var take = SimulatedTake(engine: e)
        take.pump(500) // 256,000 frames: the take covers 30,512 … 286,512
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 512) == DALNOK_OK, "\(cstr(err))")
        let start = result.start_frame
        #expect(start == 30_512)
        // 120 BPM 4/4 at 48 kHz: bars every 96,000 frames. The whole bars inside the take are bar 2 (96,000 … 192,000).
        let (timeline, slots) = clips(e, t)
        #expect(timeline.isEmpty, "the take doesn't stay in the arrangement")
        #expect(slots.count == 1)
        let s = try #require(slots.first)
        #expect(s.slot == 1 && s.start == 0 && s.length == 96_000 && s.offset == 96_000 - start, "\(s.offset) \(s.length)")
        // Bit-exact: the slot clip begins with the input sample played on bar 2. The take file starts at input frame
        // 512 (the first block applies the seek).
        let got = mediaSamples(e, s.media, s.offset, 64)
        let want = (0..<64).map { inputSample(512 + Int(s.offset) + $0) }
        #expect(got == want)
        #expect(undoName(e) == "Record", "one undo step: \(undoName(e))")
        // Launching it plays the take from the bar it was cut at.
        #expect(dalnok_launcher_launch(e, t, 1) == DALNOK_OK)
        let (l, _) = pump(e, 4_096, block: 256)
        #expect(abs(l[2_000] - inputSample(512 + Int(s.offset) + 2_000)) < 1e-6, "the slot plays the recorded take")
        dalnok_launcher_stop_all(e)
        dalnok_transport_pause(e)
        // One undo brings back the clip that was in the slot; redo puts the take back.
        #expect(dalnok_undo(e))
        let back = clips(e, t)
        #expect(back.timeline.isEmpty && back.slots.count == 1 && back.slots[0].length == 20_000, "\(back.slots.map(\.length))")
        #expect(dalnok_redo(e))
        #expect(clips(e, t).slots.first?.length == 96_000)
        dalnok_record_set_slot(e, -1)
    }

    @Test func aTakeShorterThanABarStaysWhole() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Short")
        #expect(dalnok_track_set_armed(e, t, true) == DALNOK_OK)
        dalnok_record_set_simulated_latency(e, 0)
        dalnok_record_set_slot(e, 0)
        dalnok_transport_seek(e, 10_000)
        #expect(dalnok_record_start(e, DALNOK_SIMULATED_INPUT, tempDir().path, nil, 0) == DALNOK_OK)
        var take = SimulatedTake(engine: e)
        take.pump(40) // ≈ 20,000 frames, no bar line inside
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, nil, 0) == DALNOK_OK)
        let s = clips(e, t).slots
        #expect(s.count == 1 && s[0].offset == 0 && s[0].length == 39 * 512, "\(s.map { ($0.offset, $0.length) })")
    }

    @Test func draggingBetweenTimelineAndSlotsIsOneUndoStepEachWay() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Loop")
        let ramp = (0..<24_000).map { Float($0 % 1_000) / 2_000 + 0.01 }
        let m = makeMedia([ramp]); defer { dalnok_media_release(m) }
        let pool = dalnok_pool_add(e, m, "")
        let clip = DalnokEngine.dalnok_clip_add(e, t, pool, 48_000, 0, 0)
        // Timeline → slot: a copy; the arrangement keeps its clip.
        let slot = dalnok_launcher_copy_clip(e, clip, 2)
        #expect(slot != 0 && undoName(e) == "Copy to Launcher")
        #expect(clips(e, t).timeline.count == 1 && clips(e, t).slots.count == 1)
        #expect(dalnok_undo(e))
        #expect(clips(e, t).slots.isEmpty && clips(e, t).timeline.count == 1, "one undo removes the slot copy only")
        #expect(dalnok_redo(e))
        let slotClip = clips(e, t).slots[0]
        #expect(slotClip.slot == 2 && slotClip.length == 24_000 && slotClip.start == 0)
        // Slot → timeline: a copy at the drop point; the slot keeps its clip.
        let placed = dalnok_clip_place_copy(e, slotClip.id, t, 192_000)
        #expect(placed != 0 && undoName(e) == "Place Copy")
        let c = clipInfo(e, placed)
        #expect(c.start == 192_000 && c.slot == -1 && c.length == 24_000)
        #expect(abs(render(e, 192_000 + 500, 4)[0] - ramp[500]) < 1e-6, "the placed copy plays where it was dropped")
        #expect(clips(e, t).slots.count == 1)
        #expect(dalnok_undo(e))
        #expect(clips(e, t).timeline.count == 1 && clips(e, t).slots.count == 1, "one undo removes the placed copy only")
        #expect(abs(render(e, 192_000 + 500, 4)[0]) < 1e-9)
        // Dropping on a filled slot replaces it, still in one step.
        let other = DalnokEngine.dalnok_clip_add(e, t, pool, 300_000, 0, 1_000)
        #expect(dalnok_launcher_copy_clip(e, other, 2) != 0)
        #expect(clips(e, t).slots.count == 1 && clips(e, t).slots[0].length == 1_000)
        #expect(dalnok_undo(e))
        #expect(clips(e, t).slots.count == 1 && clips(e, t).slots[0].length == 24_000, "undo restores the replaced clip")
        // A MIDI clip can't be placed on an audio track.
        let inst = dalnok_track_add_instrument(e, "Keys")
        let midi = dalnok_midi_clip_add(e, inst, 0, 24_000)
        #expect(midi != 0)
        #expect(dalnok_clip_place_copy(e, midi, t, 0) == 0)
    }

    @Test func aQueuedLaunchIsReportedUntilItsBar() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Loop")
        let m = makeMedia([[Float](repeating: 0.2, count: 10_000)]); defer { dalnok_media_release(m) }
        let c = DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, m, ""), 0, 0, 0)
        #expect(dalnok_launcher_copy_clip(e, c, 0) != 0)
        var at: Int64 = 0
        #expect(dalnok_launcher_queued(e, t, &at) == -2, "nothing queued")
        #expect(dalnok_launcher_queued(e, 9_999, &at) == -2, "no such track")
        dalnok_transport_play(e)
        _ = pump(e, 10_000)
        #expect(dalnok_launcher_launch(e, t, 0) == DALNOK_OK)
        #expect(dalnok_launcher_queued(e, t, &at) == 0 && at == 96_000)
        #expect(dalnok_launcher_playing(e, t) == -1, "still the arrangement until the bar")
        _ = pump(e, 96_000 - 10_000 + 256)
        #expect(dalnok_launcher_queued(e, t, nil) == -2 && dalnok_launcher_playing(e, t) == 0)
        #expect(dalnok_launcher_launch(e, t, -1) == DALNOK_OK)
        #expect(dalnok_launcher_queued(e, t, &at) == -1 && at == 192_000, "a stop waits for the next bar too")
    }
}
