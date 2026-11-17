// Tempo and meter maps: MIDI stays on beats across changes, metronome, quantize, persistence, undo.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// 120 BPM for beats 0-4, then 60 BPM: beat 4 = 96,000 frames, every later beat 48,000 frames.
private func slowAfterBar1(_ e: OpaquePointer, meters: [DalnokMeterPoint] = [DalnokMeterPoint(bar: 0, numerator: 4, denominator: 4)]) -> DalnokStatus {
    let tempo = [DalnokTempoPoint(beat: 0, bpm: 120), DalnokTempoPoint(beat: 4, bpm: 60)]
    return dalnok_tempo_map_set(e, tempo, Int32(tempo.count), meters, Int32(meters.count))
}

private func notes(_ e: OpaquePointer, _ clip: DalnokClipId) -> [DalnokNote] {
    var out = [DalnokNote](repeating: DalnokNote(), count: 64)
    let n = dalnok_midi_clip_notes(e, clip, &out, 64)
    return Array(out.prefix(Int(max(0, n))))
}

@Suite struct TempoMaps {
    @Test func conversionsFollowTempoAndMeterChanges() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let meters = [DalnokMeterPoint(bar: 0, numerator: 4, denominator: 4), DalnokMeterPoint(bar: 2, numerator: 6, denominator: 8)]
        #expect(slowAfterBar1(e, meters: meters) == DALNOK_OK)
        #expect(dalnok_beat_to_frame(e, 2) == 48_000)
        #expect(dalnok_beat_to_frame(e, 6) == 192_000)
        #expect(abs(dalnok_frame_to_beat(e, 120_000) - 4.5) < 1e-12)
        #expect(dalnok_tempo_at(e, 3.99) == 120 && dalnok_tempo_at(e, 4) == 60)
        #expect(dalnok_bar_to_beat(e, 2) == 8 && dalnok_bar_to_beat(e, 3) == 11) // 6/8 bar = 3 quarter notes
        var bar: Int32 = 0, num: Int32 = 0, den: Int32 = 0, inBar = 0.0
        dalnok_beat_to_bar(e, 9.5, &bar, &inBar, &num, &den)
        #expect(bar == 2 && abs(inBar - 3) < 1e-9 && num == 6 && den == 8) // 1.5 quarters = 3 eighths
        dalnok_beat_to_bar(e, 5, &bar, &inBar, &num, &den)
        #expect(bar == 1 && abs(inBar - 1) < 1e-9 && num == 4 && den == 4)
        #expect(dalnok_tempo_points(e, nil, 0) == 2 && dalnok_meter_points(e, nil, 0) == 2)
    }

    @Test func midiKeepsItsBeatsAcrossATempoChange() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let track = dalnok_track_add_instrument(e, "Keys")
        // Clip over beats 0-8 with a note from beat 3 to beat 5 (crossing the change), and a clip at beat 8.
        let long = dalnok_midi_clip_add(e, track, 0, 192_000)
        var crossing = DalnokNote(start: 72_000, length: 48_000, pitch: 69, velocity: 127)
        #expect(dalnok_midi_clip_set_notes(e, long, &crossing, 1) == DALNOK_OK)
        let later = dalnok_midi_clip_add(e, track, 192_000, 24_000)
        var short = DalnokNote(start: 0, length: 12_000, pitch: 69, velocity: 127)
        #expect(dalnok_midi_clip_set_notes(e, later, &short, 1) == DALNOK_OK)

        #expect(slowAfterBar1(e) == DALNOK_OK)
        #expect(clipInfo(e, long).start == 0 && clipInfo(e, long).length == 96_000 + 4 * 48_000)
        let n = notes(e, long)
        #expect(n.count == 1 && n[0].start == 72_000 && n[0].length == 24_000 + 48_000) // beat 3 → beat 5
        #expect(clipInfo(e, later).start == 96_000 + 4 * 48_000 && clipInfo(e, later).length == 48_000)
        #expect(notes(e, later).first?.length == 24_000) // half a beat at 60 BPM

        // The rendered onset of the later note follows the map (the crossing note is released by then).
        let out = render(e, 280_000, 20_000)
        let onset = out.firstIndex { $0 != 0 } ?? -1
        #expect(onset >= 8_000 && onset <= 8_002, "onset at \(280_000 + onset)")

        // One undo restores both the map and every MIDI position.
        #expect(dalnok_undo(e))
        #expect(dalnok_tempo_points(e, nil, 0) == 1 && clipInfo(e, later).start == 192_000)
        #expect(notes(e, long).first?.length == 48_000)
    }

    @Test func firstTempoEditKeepsLaterChangesOnTheirBeats() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        #expect(slowAfterBar1(e) == DALNOK_OK)
        #expect(dalnok_tempo_set(e, 240, 3, 4) == DALNOK_OK)
        var points = [DalnokTempoPoint](repeating: DalnokTempoPoint(), count: 4)
        #expect(dalnok_tempo_points(e, &points, 4) == 2)
        #expect(points[0].bpm == 240 && points[1].beat == 4 && points[1].bpm == 60)
        #expect(dalnok_beat_to_frame(e, 4) == 48_000)
        var num: Int32 = 0, den: Int32 = 0
        dalnok_meter(e, &num, &den)
        #expect(num == 3 && den == 4)
    }

    @Test func invalidMapsAreRejectedWithoutChanges() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let meter = [DalnokMeterPoint(bar: 0, numerator: 4, denominator: 4)]
        let unsorted = [DalnokTempoPoint(beat: 0, bpm: 120), DalnokTempoPoint(beat: 4, bpm: 90), DalnokTempoPoint(beat: 4, bpm: 60)]
        #expect(dalnok_tempo_map_set(e, unsorted, 3, meter, 1) != DALNOK_OK)
        let late = [DalnokTempoPoint(beat: 1, bpm: 120)]
        #expect(dalnok_tempo_map_set(e, late, 1, meter, 1) != DALNOK_OK)
        let fast = [DalnokTempoPoint(beat: 0, bpm: 900)]
        #expect(dalnok_tempo_map_set(e, fast, 1, meter, 1) != DALNOK_OK)
        let ok = [DalnokTempoPoint(beat: 0, bpm: 100)]
        let badMeter = [DalnokMeterPoint(bar: 1, numerator: 4, denominator: 4)]
        #expect(dalnok_tempo_map_set(e, ok, 1, badMeter, 1) != DALNOK_OK)
        let oddDen = [DalnokMeterPoint(bar: 0, numerator: 4, denominator: 3)]
        #expect(dalnok_tempo_map_set(e, ok, 1, oddDen, 1) != DALNOK_OK)
        #expect(dalnok_tempo_bpm(e) == 120 && !dalnok_can_undo(e))
    }

    @Test func metronomeFollowsTempoAndMeterChanges() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        // 120 BPM until beat 2, then 60 BPM; 4/4 for bar 1, then 3/4.
        let tempo = [DalnokTempoPoint(beat: 0, bpm: 120), DalnokTempoPoint(beat: 2, bpm: 60)]
        let meters = [DalnokMeterPoint(bar: 0, numerator: 4, denominator: 4), DalnokMeterPoint(bar: 1, numerator: 3, denominator: 4)]
        #expect(dalnok_tempo_map_set(e, tempo, 2, meters, 2) == DALNOK_OK)
        dalnok_metronome_set(e, true, 0.5)
        var out: [Float] = [], l = [Float](repeating: 0, count: 512), r = l
        dalnok_transport_play(e)
        while out.count < 300_000 { dalnok_engine_pump(e, &l, &r, 512); out += l }
        // Beats 0-2 at 24,000; then 48,000 per beat. Bar 2 starts at beat 4, bar 3 at beat 7.
        let clicks = [0, 24_000, 48_000, 96_000, 144_000, 192_000, 240_000, 288_000]
        for at in clicks {
            #expect(out[at] != 0 && (at == 0 || out[at - 1] == 0), "click at \(at)")
        }
        #expect(out[52_000..<95_000].allSatisfy { $0 == 0 }, "no click at the old tempo's beat 3")
        for at in [144_000, 288_000] { #expect(abs(frequency(out[at..<(at + 2_000)][...]) - 1_600) < 40, "accent at \(at)") }
        for at in [96_000, 192_000, 240_000] { #expect(abs(frequency(out[at..<(at + 2_000)][...]) - 1_000) < 40, "beat at \(at)") }
    }

    @Test func quantizeUsesTheMapsGrid() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let track = dalnok_track_add_instrument(e, "Keys")
        let clip = dalnok_midi_clip_add(e, track, 0, 400_000)
        #expect(slowAfterBar1(e) == DALNOK_OK)
        var note = DalnokNote(start: 115_200, length: 1_000, pitch: 60, velocity: 100) // beat 4.4
        #expect(dalnok_midi_clip_set_notes(e, clip, &note, 1) == DALNOK_OK)
        #expect(dalnok_midi_quantize(e, clip, 1, 1) == DALNOK_OK)
        #expect(notes(e, clip).first?.start == 96_000) // beat 4, not 120,000 (beat 5 at a constant 120 BPM)
    }

    @Test func mapsSaveReopenAndRejectDamage() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let track = dalnok_track_add_instrument(e, "Keys")
        let clip = dalnok_midi_clip_add(e, track, 192_000, 48_000)
        var note = DalnokNote(start: 0, length: 24_000, pitch: 69, velocity: 127)
        #expect(dalnok_midi_clip_set_notes(e, clip, &note, 1) == DALNOK_OK)
        let meters = [DalnokMeterPoint(bar: 0, numerator: 4, denominator: 4), DalnokMeterPoint(bar: 3, numerator: 7, denominator: 8)]
        #expect(slowAfterBar1(e, meters: meters) == DALNOK_OK)
        let expected = render(e, 0, 400_000)
        let project = tempDir().appendingPathComponent("map.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, err.count) == DALNOK_OK)
        var doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
        #expect(doc["version"] as? Int == 4)

        let reopened = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(reopened) }
        #expect(dalnok_project_load(reopened, project.path, nil, &err, err.count) == DALNOK_OK)
        #expect(dalnok_tempo_points(reopened, nil, 0) == 2 && dalnok_meter_points(reopened, nil, 0) == 2)
        #expect(dalnok_bar_to_beat(reopened, 4) == 15.5)
        #expect(zip(expected, render(reopened, 0, 400_000)).allSatisfy { abs($0 - $1) < 1e-6 })

        // A different sample rate keeps beats: beat 8 lands at 8 s (4 × 0.5 s + 4 × 1 s) → 352,800 at 44.1 kHz.
        let other = dalnok_engine_create(44_100)!; defer { dalnok_engine_destroy(other) }
        #expect(dalnok_project_load(other, project.path, nil, &err, err.count) == DALNOK_OK)
        #expect(abs(clipInfo(other, clip).start - 264_600) <= 1)

        doc["tempoMap"] = [[0, 120], [4, 60], [3, 90]]
        let bad = project.deletingLastPathComponent().appendingPathComponent("bad-map.dalnok")
        try JSONSerialization.data(withJSONObject: doc).write(to: bad)
        #expect(dalnok_project_load(reopened, bad.path, nil, &err, err.count) != DALNOK_OK)
        #expect(dalnok_tempo_points(reopened, nil, 0) == 2)
    }

    @Test func commandCatalogSetsTheMap() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        #expect(runCommand(e, "project.setTempoMap", #"{"tempo":[[0,100],[8,150]],"meter":[[0,4,4],[2,5,4]]}"#).0 == DALNOK_OK)
        #expect(dalnok_tempo_at(e, 9) == 150 && dalnok_meter_points(e, nil, 0) == 2)
        #expect(runCommand(e, "project.setTempoMap", #"{"tempo":[[2,100]]}"#).0 != DALNOK_OK)
    }
}
