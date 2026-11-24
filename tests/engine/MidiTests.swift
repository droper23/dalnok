// MIDI model, the Dalnok Poly instrument, live input, MIDI recording and Core MIDI ports.
// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMIDI
import DalnokEngine
import Foundation
import Testing

func render(_ e: OpaquePointer, _ start: Int64, _ frames: Int) -> [Float] {
    var l = [Float](repeating: 0, count: frames), r = l
    _ = dalnok_render_offline(e, start, Int64(frames), &l, &r)
    return l
}

func rms(_ x: ArraySlice<Float>) -> Float { (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot() }

/// Positive-going zero crossings per second.
func frequency(_ x: ArraySlice<Float>, rate: Double = 48_000) -> Double {
    var crossings: [Int] = []
    var prev = x.first ?? 0
    for (i, v) in x.enumerated() {
        if prev < 0 && v >= 0 { crossings.append(i) }
        prev = v
    }
    guard crossings.count > 2 else { return 0 }
    return Double(crossings.count - 1) * rate / Double(crossings.last! - crossings.first!)
}

func oneNoteSession(pitch: UInt8 = 69, velocity: UInt8 = 127) -> (OpaquePointer, DalnokTrackId, DalnokClipId) {
    let e = dalnok_engine_create(48_000)!
    let t = dalnok_track_add_instrument(e, "Keys")
    let c = dalnok_midi_clip_add(e, t, 0, 96_000)
    var note = DalnokNote(start: 4_800, length: 48_000, pitch: pitch, velocity: velocity)
    _ = dalnok_midi_clip_set_notes(e, c, &note, 1)
    return (e, t, c)
}

@Suite struct Midi {
    @Test func instrumentPlaysTheNoteAtItsPitchAndTime() {
        let (e, _, _) = oneNoteSession(); defer { dalnok_engine_destroy(e) }
        let out = render(e, 0, 120_000)
        #expect(out[0..<4_800].allSatisfy { $0 == 0 }) // nothing before the note
        let onset = out.firstIndex { $0 != 0 } ?? -1
        #expect(onset >= 4_800 && onset <= 4_802)
        let f = frequency(out[9_600..<52_800])
        #expect(abs(f - 440) < 0.5, "measured \(f) Hz")
        let level = rms(out[24_000..<52_800])
        #expect(level > 0.02 && level < 0.25, "sustain RMS \(level)")
        // Released at 52,800; the 180 ms release is over well before 64,000.
        #expect(out[64_000...].allSatisfy { abs($0) < 1e-6 })
        #expect(out[52_000..<52_800].contains { abs($0) > 0.01 })
    }

    @Test func velocityScalesLevelLinearly() {
        let (loud, _, _) = oneNoteSession(velocity: 127); defer { dalnok_engine_destroy(loud) }
        let (soft, _, _) = oneNoteSession(velocity: 64); defer { dalnok_engine_destroy(soft) }
        let ratio = rms(render(loud, 0, 52_000)[24_000...]) / rms(render(soft, 0, 52_000)[24_000...])
        #expect(abs(ratio - 127.0 / 64.0) < 0.01, "ratio \(ratio)")
    }

    @Test func liveInputPlaysWhileStoppedThroughTheArmedTrack() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Live")
        var l = [Float](repeating: 0, count: 512), r = l
        dalnok_engine_pump(e, &l, &r, 512)
        #expect(l.allSatisfy { $0 == 0 })
        #expect(dalnok_midi_inject(e, 0x90, 60, 100) == DALNOK_OK)
        var peak: Float = 0
        for _ in 0..<20 { dalnok_engine_pump(e, &l, &r, 512); peak = max(peak, l.map(abs).max()!) }
        #expect(peak > 0.05 && !dalnok_transport_is_playing(e))
        var ml: Float = 0, mr: Float = 0
        dalnok_meter_track(e, t, &ml, &mr)
        #expect(ml > 0.05) // live input is metered on its track
        // Muting the track silences live input too (after the fader's one-block de-click ramp).
        dalnok_track_set_mute(e, t, true)
        dalnok_engine_pump(e, &l, &r, 512)
        dalnok_engine_pump(e, &l, &r, 512)
        #expect(l.allSatisfy { $0 == 0 })
        dalnok_track_set_mute(e, t, false)
        #expect(dalnok_midi_inject(e, 0x80, 60, 0) == DALNOK_OK)
        for _ in 0..<40 { dalnok_engine_pump(e, &l, &r, 512) } // 0.43 s > release
        #expect(l.allSatisfy { abs($0) < 1e-6 })
        #expect(dalnok_midi_dropped(e) == 0)
        // Disarmed: no track plays live input.
        dalnok_track_set_armed(e, t, false)
        dalnok_midi_inject(e, 0x90, 60, 100)
        for _ in 0..<4 { dalnok_engine_pump(e, &l, &r, 512) }
        #expect(l.allSatisfy { $0 == 0 })
    }

    /// Live notes follow the track's routing, stopped or playing: into its bus (and the bus's fader), and its sends.
    @Test func liveInputFollowsRouting() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let keys = dalnok_track_add_instrument(e, "Keys"), bus = dalnok_track_add_bus(e, "Verb")
        #expect(dalnok_track_set_output(e, keys, bus) == DALNOK_OK)
        var l = [Float](repeating: 0, count: 512), r = l
        func level(_ blocks: Int) -> Float {
            var p: Float = 0
            for _ in 0..<blocks { dalnok_engine_pump(e, &l, &r, 512); p = max(p, l.map(abs).max()!) }
            return p
        }
        dalnok_midi_inject(e, 0x90, 60, 100)
        let open = level(10)
        #expect(open > 0.05, "heard through the bus while stopped (\(open))")
        var bl: Float = 0, br: Float = 0
        dalnok_meter_track(e, bus, &bl, &br)
        #expect(bl > 0.05, "the bus meter shows the live notes")
        #expect(dalnok_track_set_mute(e, bus, true) == DALNOK_OK)
        _ = level(1) // the fader's de-click ramp
        #expect(level(4) == 0, "a muted bus silences live notes routed to it (stopped)")
        dalnok_transport_play(e)
        #expect(level(10) == 0, "and while playing")
        _ = level(0)
        #expect(dalnok_track_set_mute(e, bus, false) == DALNOK_OK)
        #expect(level(10) > 0.05, "unmuted: heard while playing")
        _ = dalnok_track_set_gain_db(e, bus, -12)
        _ = level(1)
        let quieter = level(10)
        #expect(quieter < open * 0.4, "the bus fader applies (\(quieter) vs \(open))")
        dalnok_midi_inject(e, 0x80, 60, 0)
    }

    @Test func recordsNotesAsOneUndoableClip() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Keys")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_record_start(e, nil, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var l = [Float](repeating: 0, count: 512), r = l
        func pump(_ n: Int) { for _ in 0..<n { dalnok_engine_pump(e, &l, &r, 512) } }
        pump(4)
        dalnok_midi_inject(e, 0x90, 64, 90)
        pump(10)
        dalnok_midi_inject(e, 0x90, 64, 0) // note-on with velocity 0 = note-off
        dalnok_midi_inject(e, 0x91, 67, 80) // channel 2, held at stop
        pump(2)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 256) == DALNOK_OK, "\(cstr(err))")
        #expect(result.notes == 2 && result.audio_clip == 0 && result.start_frame == 0)
        let clip = clipInfo(e, result.midi_clip)
        #expect(clip.midi && clip.track == t && clip.start == 0 && clip.length == 16 * 512 && clip.note_count == 2)
        var notes = [DalnokNote](repeating: DalnokNote(), count: 4)
        #expect(dalnok_midi_clip_notes(e, result.midi_clip, &notes, 4) == 2)
        // Block-quantized: each event is stamped at the start of the block that received it.
        #expect(notes[0].start == 2_048 && notes[0].length == 5_120 && notes[0].pitch == 64 && notes[0].velocity == 90)
        #expect(notes[1].start == 7_168 && notes[1].length == 1_024 && notes[1].pitch == 67)
        #expect(undoName(e) == "Record")
        dalnok_undo(e)
        #expect(dalnok_track_clip_at(e, t, 0) == 0)
    }

    @Test func recordsControllersAndPitchBendWithTheNotes() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        _ = dalnok_track_add_instrument(e, "Keys")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_record_start(e, nil, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var l = [Float](repeating: 0, count: 512), r = l
        func pump(_ n: Int) { for _ in 0..<n { dalnok_engine_pump(e, &l, &r, 512) } }
        pump(2)
        dalnok_midi_inject(e, 0xB0, 64, 127) // sustain down
        dalnok_midi_inject(e, 0x90, 60, 100)
        pump(4)
        dalnok_midi_inject(e, 0xE0, 0x7F, 0x7F) // full bend up
        dalnok_midi_inject(e, 0x80, 60, 0)
        pump(2)
        dalnok_midi_inject(e, 0xB0, 64, 0)
        pump(2)
        var result = DalnokRecordResult()
        #expect(dalnok_record_stop(e, &result, &err, 256) == DALNOK_OK, "\(cstr(err))")
        #expect(result.notes == 1 && undoName(e) == "Record")
        var cc = [DalnokMidiCC](repeating: DalnokMidiCC(), count: 8)
        let n = Int(dalnok_midi_clip_controllers(e, result.midi_clip, &cc, 8))
        #expect(n == 3, "\(n) controller events")
        #expect(cc[0].start == 1_024 && cc[0].controller == 64 && cc[0].value == 127)
        #expect(cc[1].start == 3_072 && cc[1].controller == Int32(DALNOK_PITCH_BEND) && cc[1].value == 16_383)
        #expect(cc[2].start == 4_096 && cc[2].controller == 64 && cc[2].value == 0)
        dalnok_undo(e)
        #expect(dalnok_track_clip_at(e, dalnok_track_at(e, 0), 0) == 0, "one undo removes the take with its controllers")
    }

    @Test func inputNotesAreReportedForStepInput() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var l = [Float](repeating: 0, count: 512), r = l
        dalnok_midi_inject(e, 0x90, 60, 100)
        dalnok_midi_inject(e, 0xB0, 1, 20) // not a note: not reported
        dalnok_midi_inject(e, 0x90, 60, 0)
        dalnok_engine_pump(e, &l, &r, 512)
        var out = [DalnokInputNote](repeating: DalnokInputNote(), count: 8)
        #expect(dalnok_midi_take_input_notes(e, &out, 8) == 2)
        #expect(out[0].pitch == 60 && out[0].on && out[0].velocity == 100 && !out[1].on)
        #expect(dalnok_midi_take_input_notes(e, &out, 8) == 0, "taken once")
    }

    @Test func quantizeMovesStartsTowardTheGrid() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, nil)
        let c = dalnok_midi_clip_add(e, t, 1_000, 96_000)
        // 120 BPM at 48 kHz: a 16th (0.25 beat) is 6,000 frames. Timeline = 1,000 + start.
        var notes = [DalnokNote(start: 5_100, length: 100, pitch: 60, velocity: 100),
                     DalnokNote(start: 10_900, length: 100, pitch: 62, velocity: 100)]
        dalnok_midi_clip_set_notes(e, c, &notes, 2)
        #expect(dalnok_midi_quantize(e, c, 0.25, 0.5) == DALNOK_OK)
        dalnok_midi_clip_notes(e, c, &notes, 2)
        #expect(notes[0].start == 5_050 && notes[1].start == 10_950)
        #expect(dalnok_midi_quantize(e, c, 0.25, 1) == DALNOK_OK)
        dalnok_midi_clip_notes(e, c, &notes, 2)
        #expect(notes[0].start == 5_000 && notes[1].start == 11_000)
        #expect(dalnok_tempo_set(e, 90, 3, 4) == DALNOK_OK && dalnok_tempo_bpm(e) == 90)
        #expect(dalnok_tempo_set(e, 1_000, 4, 4) != DALNOK_OK && dalnok_tempo_set(e, 120, 4, 3) != DALNOK_OK)
        #expect(dalnok_midi_quantize(e, c, 0, 1) != DALNOK_OK)
    }

    @Test func quantizeKeepsNotesInsideTheClipWindow() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, nil)
        // Timeline 1,000 ... 91,000; a beat is 24,000 frames. 89,500 (timeline 90,500) rounds up to beat 4 = 96,000,
        // which is past the clip's end, where the note would neither show nor play.
        let c = dalnok_midi_clip_add(e, t, 1_000, 90_000)
        var notes = [DalnokNote(start: 89_500, length: 100, pitch: 60, velocity: 100),
                     DalnokNote(start: 23_000, length: 100, pitch: 62, velocity: 100)]
        dalnok_midi_clip_set_notes(e, c, &notes, 2)
        #expect(dalnok_midi_quantize(e, c, 1, 1) == DALNOK_OK)
        dalnok_midi_clip_notes(e, c, &notes, 2)
        #expect(notes[0].start == 23_000) // already on beat 1
        #expect(notes[1].start == 89_999) // the last frame of the clip, not 95,000
    }

    @Test func notesOnTheSamePitchAndStartMergeAndTheLaterWins() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let c = dalnok_midi_clip_add(e, dalnok_track_add_instrument(e, nil), 0, 96_000)
        var notes = [DalnokNote(start: 1_000, length: 100, pitch: 60, velocity: 50),
                     DalnokNote(start: 1_000, length: 900, pitch: 64, velocity: 80),
                     DalnokNote(start: 1_000, length: 500, pitch: 60, velocity: 110)] // dropped on the first: replaces it
        #expect(dalnok_midi_clip_set_notes(e, c, &notes, 3) == DALNOK_OK)
        var got = [DalnokNote](repeating: DalnokNote(), count: 4)
        #expect(dalnok_midi_clip_notes(e, c, &got, 4) == 2)
        #expect(got[0].pitch == 60 && got[0].length == 500 && got[0].velocity == 110 && got[1].pitch == 64)
        // Quantize pulling two notes onto one grid line leaves one note there.
        var near = [DalnokNote(start: 23_900, length: 100, pitch: 60, velocity: 100),
                    DalnokNote(start: 24_100, length: 100, pitch: 60, velocity: 100)]
        #expect(dalnok_midi_clip_set_notes(e, c, &near, 2) == DALNOK_OK)
        #expect(dalnok_midi_quantize(e, c, 1, 1) == DALNOK_OK)
        #expect(dalnok_midi_clip_notes(e, c, &got, 4) == 1 && got[0].start == 24_000)
    }

    @Test func quantizeStrengthZeroChangesNothingAndTripletsLandOnThirds() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, nil)
        let c = dalnok_midi_clip_add(e, t, 0, 96_000)
        // 1/8 triplet = 1/3 beat = 8,000 frames at 120 BPM / 48 kHz.
        var notes = [DalnokNote(start: 7_700, length: 100, pitch: 60, velocity: 100),
                     DalnokNote(start: 16_300, length: 100, pitch: 62, velocity: 100)]
        dalnok_midi_clip_set_notes(e, c, &notes, 2)
        #expect(dalnok_midi_quantize(e, c, 1.0 / 3, 0) == DALNOK_OK)
        dalnok_midi_clip_notes(e, c, &notes, 2)
        #expect(notes[0].start == 7_700 && notes[1].start == 16_300)
        #expect(dalnok_midi_quantize(e, c, 1.0 / 3, 1) == DALNOK_OK)
        dalnok_midi_clip_notes(e, c, &notes, 2)
        #expect(abs(notes[0].start - 8_000) <= 1 && abs(notes[1].start - 16_000) <= 1)
        #expect(dalnok_midi_quantize(e, c, 0.25, 1.5) != DALNOK_OK && dalnok_midi_quantize(e, c, 0.25, -0.1) != DALNOK_OK)
    }

    @Test func splitMidiClipRendersIdentically() {
        let (e, _, c) = oneNoteSession(); defer { dalnok_engine_destroy(e) }
        var note2 = [DalnokNote(start: 4_800, length: 20_000, pitch: 69, velocity: 127),
                     DalnokNote(start: 60_000, length: 10_000, pitch: 72, velocity: 100)]
        dalnok_midi_clip_set_notes(e, c, &note2, 2)
        let before = render(e, 0, 96_000)
        var right: DalnokClipId = 0
        #expect(dalnok_clip_split(e, c, 40_000, &right) == DALNOK_OK)
        #expect(clipInfo(e, right).offset == 40_000 && clipInfo(e, right).note_count == 2)
        let after = render(e, 0, 96_000)
        #expect(zip(before, after).allSatisfy { abs($0 - $1) < 1e-6 })
        // Trimming the right part's start past the second note silences it.
        #expect(dalnok_clip_set_region(e, right, 61_000, 61_000, 35_000) == DALNOK_OK)
        #expect(render(e, 60_000, 20_000).allSatisfy { abs($0) < 1e-6 })
    }

    @Test func tempoChangesKeepMidiOnBeatsAndAudioInTime() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let keys = dalnok_track_add_instrument(e, "Keys")
        let clip = dalnok_midi_clip_add(e, keys, 24_000, 48_000)
        var note = DalnokNote(start: 24_000, length: 12_000, pitch: 69, velocity: 127)
        #expect(dalnok_midi_clip_set_notes(e, clip, &note, 1) == DALNOK_OK)
        let dir = tempDir(), audioPath = dir.appendingPathComponent("audio.wav")
        try writeTestWav(audioPath, frames: 48_000)
        let audioTrack = dalnok_track_add(e, "Audio")
        var handle: OpaquePointer?
        #expect(dalnok_media_load(audioPath.path, 48_000, &handle, nil, 0) == DALNOK_OK)
        defer { dalnok_media_release(handle) }
        let media = dalnok_pool_add(e, handle, audioPath.path)
        let audio = dalnok_clip_add(e, audioTrack, media, 24_000, 0, 24_000)
        #expect(audio != 0 && dalnok_tempo_set(e, 60, 4, 4) == DALNOK_OK)
        let moved = clipInfo(e, clip), audioInfo = clipInfo(e, audio)
        #expect(moved.start == 48_000 && moved.length == 96_000 && audioInfo.start == 24_000 && audioInfo.length == 24_000)
        #expect(dalnok_midi_clip_notes(e, clip, &note, 1) == 1 && note.start == 48_000 && note.length == 24_000)
        // Mute audio so the offline signal measures the MIDI onset.
        dalnok_track_set_mute(e, audioTrack, true)
        let out = render(e, 0, 120_000)
        let onset = out.firstIndex { $0 != 0 } ?? -1
        #expect(onset >= 96_000 && onset <= 96_002)
        dalnok_undo(e) // mute
        dalnok_undo(e) // tempo
        #expect(dalnok_tempo_bpm(e) == 120 && clipInfo(e, clip).start == 24_000)
        #expect(dalnok_midi_clip_notes(e, clip, &note, 1) == 1 && note.start == 24_000 && note.length == 12_000)
    }

    @Test func tempoChangeKeepsSplitMidiContinuous() throws {
        let (e, track, clip) = oneNoteSession(); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_clip_move(e, clip, track, 1) == DALNOK_OK)
        #expect(dalnok_tempo_set(e, 96, 4, 4) == DALNOK_OK)
        let unsplit = render(e, 0, 120_000)
        #expect(dalnok_undo(e))
        var right: DalnokClipId = 0
        #expect(dalnok_clip_split(e, clip, 24_002, &right) == DALNOK_OK)
        #expect(dalnok_tempo_set(e, 96, 4, 4) == DALNOK_OK)
        let split = render(e, 0, 120_000)
        #expect(zip(unsplit, split).allSatisfy { abs($0 - $1) < 1e-6 })
        let project = tempDir().appendingPathComponent("split.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, err.count) == DALNOK_OK)
        var doc = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: project)) as? [String: Any])
        #expect(doc["version"] as? Int == 3)
        let reopened = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(reopened) }
        #expect(dalnok_project_load(reopened, project.path, nil, &err, err.count) == DALNOK_OK)
        let restored = render(reopened, 0, 120_000)
        #expect(zip(unsplit, restored).allSatisfy { abs($0 - $1) < 1e-6 })
        var tracks = try #require(doc["tracks"] as? [[String: Any]])
        try #require(!tracks.isEmpty)
        var clips = try #require(tracks[0]["clips"] as? [[String: Any]])
        try #require(clips.count >= 2)
        var notes = try #require(clips[1]["notes"] as? [[Int]])
        try #require((notes.first?.count ?? 0) >= 4)
        notes[0][2] = 70
        clips[1]["notes"] = notes; tracks[0]["clips"] = clips; doc["tracks"] = tracks
        let bad = project.deletingLastPathComponent().appendingPathComponent("bad-source.dalnok")
        try JSONSerialization.data(withJSONObject: doc).write(to: bad)
        #expect(dalnok_project_load(reopened, bad.path, nil, &err, err.count) != DALNOK_OK)
        #expect(zip(unsplit, render(reopened, 0, 120_000)).allSatisfy { abs($0 - $1) < 1e-6 })
    }

    @Test func tempoChangeRejectsTimelineOverflowWithoutMutation() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let track = dalnok_track_add_instrument(e, "Keys")
        let clip = dalnok_midi_clip_add(e, track, Int64.max / 4, 100)
        #expect(clip != 0 && dalnok_tempo_set(e, 20, 4, 4) != DALNOK_OK)
        #expect(dalnok_tempo_bpm(e) == 120 && clipInfo(e, clip).start == Int64.max / 4)
    }

    @Test func modelRulesAndPersistence() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let audio = dalnok_track_add(e, "Audio")
        let url = tempDir().appendingPathComponent("rules.wav")
        _ = try? writeTestWav(url, frames: 4_800)
        var media: OpaquePointer?
        _ = dalnok_media_load(url.path, 48_000, &media, nil, 0)
        _ = DalnokEngine.dalnok_clip_add(e, audio, dalnok_pool_add(e, media, url.path), 50_000, 0, 0)
        dalnok_media_release(media)
        let keys = dalnok_track_add_instrument(e, "Keys")
        #expect(dalnok_midi_clip_add(e, audio, 0, 100) == 0) // MIDI only on instrument tracks (or empty audio tracks)
        let c = dalnok_midi_clip_add(e, keys, 0, 10_000)
        #expect(dalnok_clip_move(e, c, audio, 0) != DALNOK_OK)
        #expect(dalnok_clip_set_stretch(e, c, 5_000, 2, 0, true) != DALNOK_OK)
        var bad = DalnokNote(start: 0, length: 0, pitch: 60, velocity: 100)
        #expect(dalnok_midi_clip_set_notes(e, c, &bad, 1) != DALNOK_OK)
        let (st, res) = runCommand(e, "midi.setNotes", #"{"clip":\#(c),"notes":[[100,200,60,90],[0,50,72,127]]}"#)
        #expect(st == DALNOK_OK, "\(res)")
        #expect(runCommand(e, "midi.setNotes", #"{"clip":\#(c),"notes":[[0,50,200,90]]}"#).0 != DALNOK_OK)
        #expect(runCommand(e, "project.setTempo", #"{"bpm":96,"numerator":7,"denominator":8}"#).0 == DALNOK_OK)
        #expect(runCommand(e, "track.addInstrument", #"{"name":"Pad"}"#).0 == DALNOK_OK)
        let dir = tempDir(), project = dir.appendingPathComponent("midi.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, project.path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let e2 = dalnok_engine_create(44_100)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        #expect(dalnok_track_count(e2) == 3 && dalnok_tempo_bpm(e2) == 96)
        var num: Int32 = 0, den: Int32 = 0
        dalnok_meter(e2, &num, &den)
        #expect(num == 7 && den == 8)
        var info = DalnokTrackInfo()
        dalnok_track_info(e2, dalnok_track_at(e2, 1), &info)
        #expect(info.kind == Int32(DALNOK_TRACK_INSTRUMENT.rawValue) && !info.armed) // "Pad" took the arm
        dalnok_track_info(e2, dalnok_track_at(e2, 2), &info)
        #expect(info.armed)
        let c2 = dalnok_track_clip_at(e2, dalnok_track_at(e2, 1), 0)
        var notes = [DalnokNote](repeating: DalnokNote(), count: 2)
        #expect(dalnok_midi_clip_notes(e2, c2, &notes, 2) == 2)
        // Rescaled 48 kHz -> 44.1 kHz.
        #expect(notes[0].start == 0 && notes[0].length == 58 && notes[0].pitch == 72 && notes[0].velocity == 127)
        #expect(notes[1].start == 115 && notes[1].length == 230)
    }

    /// A virtual Core MIDI source exercises the real input port and receive thread.
    @Test func coreMidiPortDeliversNotesToTheInstrument() throws {
        var client = MIDIClientRef(), source = MIDIEndpointRef()
        guard MIDIClientCreate("DalnokTests" as CFString, nil, nil, &client) == noErr,
              MIDISourceCreateWithProtocol(client, "Dalnok Test Source" as CFString, ._1_0, &source) == noErr else {
            Issue.record("Core MIDI is unavailable in this environment")
            return
        }
        defer { MIDIEndpointDispose(source); MIDIClientDispose(client) }
        var uid: Int32 = 0
        #expect(MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uid) == noErr)
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        _ = dalnok_track_add_instrument(e, "Keys")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_midi_open_input(e, uid, &err, 256) == DALNOK_OK, "\(cstr(err))")
        #expect(dalnok_midi_open_input(e, 12345, &err, 256) != DALNOK_OK)
        func send(_ word: UInt32) {
            var list = MIDIEventList()
            var w = word
            let packet = MIDIEventListInit(&list, ._1_0)
            _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &w)
            MIDIReceivedEventList(source, &list)
        }
        send(0x2090_4564) // note-on A4, velocity 100 (UMP MIDI 1.0 channel voice)
        var l = [Float](repeating: 0, count: 512), r = l, peak: Float = 0
        let deadline = Date().addingTimeInterval(2)
        while peak == 0 && Date() < deadline {
            dalnok_engine_pump(e, &l, &r, 512)
            peak = l.map(abs).max()!
            if peak == 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
        #expect(peak > 0, "no sound from Core MIDI input within 2 s")
        send(0x2080_4500)
        Thread.sleep(forTimeInterval: 0.05)
        for _ in 0..<40 { dalnok_engine_pump(e, &l, &r, 512) }
        #expect(l.allSatisfy { abs($0) < 1e-6 })
    }
}

@Suite struct Metronome {
    /// Pumps `frames` of live output with the transport rolling from 0.
    func live(_ e: OpaquePointer, _ frames: Int) -> [Float] {
        var out: [Float] = [], l = [Float](repeating: 0, count: 512), r = l
        dalnok_transport_play(e)
        while out.count < frames { dalnok_engine_pump(e, &l, &r, 512); out += l }
        return Array(out.prefix(frames))
    }

    @Test func clicksOnEveryBeatWithAccentedBars() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        dalnok_tempo_set(e, 120, 3, 4) // 24,000 frames per beat, 3 beats per bar
        dalnok_metronome_set(e, true, 0.5)
        let out = live(e, 24_000 * 4)
        for beat in 0..<4 {
            let at = beat * 24_000
            #expect(out[at] != 0 && (at == 0 || out[at - 1] == 0), "click starts exactly on beat \(beat)")
            #expect(out[(at + 4_000)..<(at + 23_000)].allSatisfy { $0 == 0 }, "silence between clicks after beat \(beat)")
        }
        // Accent: bar starts (beats 0 and 3) are higher and louder than beats 1 and 2.
        let accent = frequency(out[0..<2_000][...]), normal = frequency(out[24_000..<26_000][...])
        #expect(abs(accent - 1_600) < 40 && abs(normal - 1_000) < 40, "accent \(accent) Hz, beat \(normal) Hz")
        #expect(abs(out[72_000 + 2]) > abs(out[24_000 + 2]) * 1.2) // bar 2 accented
    }

    @Test func neverInOfflineRendersAndSilentWhenOff() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        dalnok_metronome_set(e, true, 1)
        var l = [Float](repeating: 1, count: 48_000), r = l
        dalnok_render_offline(e, 0, 48_000, &l, &r)
        #expect(l.allSatisfy { $0 == 0 })
        dalnok_metronome_set(e, false, 1)
        #expect(live(e, 48_000).allSatisfy { $0 == 0 })
        #expect(runCommand(e, "transport.setMetronome", #"{"on":true}"#).0 == DALNOK_OK && dalnok_metronome_enabled(e))
    }

    @Test func eighthNoteMeterClicksAndAccentsAtBarBoundary() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        dalnok_tempo_set(e, 120, 3, 8) // eighth-note beats: 12,000 frames, bar: 36,000
        dalnok_metronome_set(e, true, 0.5)
        let out = live(e, 48_000)
        for at in stride(from: 0, to: 48_000, by: 12_000) {
            #expect(out[at] != 0 && (at == 0 || out[at - 1] == 0))
        }
        let accent = frequency(out[36_000..<38_000][...]), normal = frequency(out[24_000..<26_000][...])
        #expect(abs(accent - 1_600) < 40 && abs(normal - 1_000) < 40)
    }
}

@Suite struct ExportTail {
    @Test func exportRingsOutPastTheLastClip() throws {
        // A note held to the very end of its clip: a plain export stops mid-note, an export with a tail plays the release.
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Keys")
        let c = dalnok_midi_clip_add(e, t, 0, 20_000)
        var note = DalnokNote(start: 0, length: 20_000, pitch: 69, velocity: 100)
        _ = dalnok_midi_clip_set_notes(e, c, &note, 1)
        let dir = tempDir()
        var err = [CChar](repeating: 0, count: 256)
        func load(_ path: String) throws -> (OpaquePointer, Int) {
            var m: OpaquePointer?
            #expect(dalnok_media_load(path, 48_000, &m, &err, 256) == DALNOK_OK, "\(cstr(err))")
            let media = try #require(m)
            return (media, Int(dalnok_media_frames(media)))
        }
        let plain = dir.appendingPathComponent("plain.wav").path, tailed = dir.appendingPathComponent("tail.wav").path
        #expect(dalnok_render_to_wav(e, plain, 0, 20_000, 32, &err, 256) == DALNOK_OK)
        var written: Int64 = 0
        #expect(dalnok_render_to_wav_tail(e, tailed, 0, 20_000, 32, 10 * 48_000, &written, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let (pm, pn) = try load(plain), (tm, tn) = try load(tailed)
        defer { dalnok_media_release(pm); dalnok_media_release(tm) }
        #expect(pn == 20_000)
        #expect(written > 4_800 && written < 10 * 48_000 && tn == 20_000 + Int(written), "tail of \(written) frames")
        // Read both back through a project and compare.
        func samples(_ media: OpaquePointer, _ n: Int) -> [Float] {
            let p = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(p) }
            _ = dalnok_clip_add(p, dalnok_track_add(p, "R"), media, 0, 0, 0)
            return render(p, 0, n)
        }
        let a = samples(pm, pn), b = samples(tm, tn)
        #expect(abs(a[pn - 1]) > 0.01, "the plain export ends in a hard cut at \(a[pn - 1])")
        #expect(zip(a, b).allSatisfy { abs($0 - $1) < 1e-6 }, "the first 20,000 frames are identical")
        #expect(abs(b[tn - 1]) < 1e-4, "the tailed export ends in silence (\(b[tn - 1]))")
        #expect(rms(b[20_000..<24_800]) > 0, "release is audible after the clip ends")
    }

    @Test func exportThatEndsInSilenceGetsNoTail() throws {
        // The note and its release end well before the range does: the tail adds nothing, the file is exactly the range.
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Keys")
        let c = dalnok_midi_clip_add(e, t, 0, 48_000)
        var note = DalnokNote(start: 0, length: 4_800, pitch: 69, velocity: 100)
        _ = dalnok_midi_clip_set_notes(e, c, &note, 1)
        var err = [CChar](repeating: 0, count: 256)
        let path = tempDir().appendingPathComponent("quiet.wav").path
        var written: Int64 = -1
        #expect(dalnok_render_to_wav_tail(e, path, 0, 48_000, 32, 10 * 48_000, &written, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var m: OpaquePointer?
        #expect(dalnok_media_load(path, 48_000, &m, &err, 256) == DALNOK_OK)
        let media = try #require(m); defer { dalnok_media_release(media) }
        #expect(written == 0 && dalnok_media_frames(media) == 48_000, "tail \(written), \(dalnok_media_frames(media)) frames")
    }
}

@Suite struct MidiFunctions {
    // 120 BPM at 48 kHz: one beat = 24,000 frames.
    func clip(_ notes: [DalnokNote]) -> (OpaquePointer, DalnokClipId) {
        let e = dalnok_engine_create(48_000)!
        let c = dalnok_midi_clip_add(e, dalnok_track_add_instrument(e, nil), 0, 192_000)
        var n = notes
        _ = dalnok_midi_clip_set_notes(e, c, &n, Int32(n.count))
        return (e, c)
    }
    func notes(_ e: OpaquePointer, _ c: DalnokClipId) -> [DalnokNote] {
        var out = [DalnokNote](repeating: DalnokNote(), count: 64)
        let n = Int(dalnok_midi_clip_notes(e, c, &out, 64))
        return Array(out.prefix(n))
    }

    @Test func legatoFixedLengthAndVelocity() {
        let (e, c) = clip([DalnokNote(start: 0, length: 100, pitch: 60, velocity: 80),
                           DalnokNote(start: 0, length: 100, pitch: 64, velocity: 90), // a chord with the first
                           DalnokNote(start: 24_000, length: 100, pitch: 62, velocity: 100),
                           DalnokNote(start: 60_000, length: 100, pitch: 65, velocity: 120)])
        defer { dalnok_engine_destroy(e) }
        #expect(dalnok_midi_transform(e, c, Int32(DALNOK_MIDI_LEGATO.rawValue), nil, 0, 0, 0, nil) == DALNOK_OK)
        #expect(notes(e, c).map(\.length) == [24_000, 24_000, 36_000, 100], "each to the next start; the last unchanged")
        #expect(undoName(e) == "Legato")
        #expect(dalnok_midi_transform(e, c, Int32(DALNOK_MIDI_FIXED_LENGTH.rawValue), nil, 0, 0.5, 0, nil) == DALNOK_OK)
        #expect(notes(e, c).allSatisfy { $0.length == 12_000 })
        // Only the selected note, and `out` reports it.
        var sel = [notes(e, c)[2]], out = [DalnokNote()]
        #expect(dalnok_midi_transform(e, c, Int32(DALNOK_MIDI_SET_VELOCITY.rawValue), &sel, 1, 33, 0, &out) == DALNOK_OK)
        #expect(notes(e, c).map(\.velocity) == [80, 90, 33, 120] && out[0].velocity == 33 && out[0].pitch == 62)
        #expect(dalnok_midi_transform(e, c, Int32(DALNOK_MIDI_SCALE_VELOCITY.rawValue), nil, 0, 150, 0, nil) == DALNOK_OK)
        #expect(notes(e, c).map(\.velocity) == [120, 127, 50, 127], "×1.5, capped at 127")
        #expect(dalnok_midi_transform(e, c, Int32(DALNOK_MIDI_SET_VELOCITY.rawValue), nil, 0, 0, 0, nil) != DALNOK_OK)
    }

    @Test func scaleQuantizeSnapsToTheNearestDegree() {
        // Every pitch of the chromatic octave from C4 into D minor (root 2, scale 1): D E F G A Bb C.
        let (e, c) = clip((0..<12).map { DalnokNote(start: Int64($0) * 1_000, length: 500, pitch: UInt8(60 + $0), velocity: 100) })
        defer { dalnok_engine_destroy(e) }
        #expect(dalnok_midi_transform(e, c, Int32(DALNOK_MIDI_SCALE_QUANTIZE.rawValue), nil, 0, 2, 1, nil) == DALNOK_OK)
        // C C# D D# E F F# G G# A A# B -> C C D D E F F G G A Bb Bb(B is 1 above Bb, 1 below C: tie goes down)
        #expect(notes(e, c).map(\.pitch) == [60, 60, 62, 62, 64, 65, 65, 67, 67, 69, 70, 70])
    }

    @Test func humanizeStaysWithinItsRangesAndVaries() {
        let grid = (0..<32).map { DalnokNote(start: Int64($0) * 6_000, length: 3_000, pitch: 60, velocity: 100) }
        let (e, c) = clip(grid); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_midi_transform(e, c, Int32(DALNOK_MIDI_HUMANIZE.rawValue), nil, 0, 10, 8, nil) == DALNOK_OK)
        let after = notes(e, c)
        #expect(after.count == 32)
        let shifts = zip(after, grid).map { abs($0.start - $1.start) }, vels = after.map { abs(Int($0.velocity) - 100) }
        #expect(shifts.max()! <= 480 && vels.max()! <= 8, "±10 ms (480 frames) and ±8")
        #expect(Set(shifts).count > 8 && Set(vels).count > 4, "not all the same")
    }
}

@Suite struct MidiControllers {
    @Test func controllersFollowTempoAndSplitsAndRejectBadValues() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let c = dalnok_midi_clip_add(e, dalnok_track_add_instrument(e, nil), 0, 96_000)
        var ccs = [DalnokMidiCC(start: 24_000, controller: 64, value: 127), DalnokMidiCC(start: 48_000, controller: 128, value: 16_383)]
        #expect(dalnok_midi_clip_set_controllers(e, c, &ccs, 2) == DALNOK_OK)
        #expect(dalnok_tempo_set(e, 60, 4, 4) == DALNOK_OK)
        var out = [DalnokMidiCC](repeating: DalnokMidiCC(), count: 4)
        let n = Int(dalnok_midi_clip_controllers(e, c, &out, 4))
        #expect(n == 2 && out[0].start == 48_000 && out[1].start == 96_000 && out[1].value == 16_383, "on their beats at 60 BPM")
        var right: DalnokClipId = 0
        #expect(dalnok_clip_split(e, c, 60_000, &right) == DALNOK_OK)
        #expect(dalnok_midi_clip_controllers(e, right, nil, 0) == 2, "the right part shares the clip's controller list")
        var bad = [DalnokMidiCC(start: 0, controller: 7, value: 128)]
        #expect(dalnok_midi_clip_set_controllers(e, c, &bad, 1) != DALNOK_OK)
        bad = [DalnokMidiCC(start: -1, controller: 7, value: 1)]
        #expect(dalnok_midi_clip_set_controllers(e, c, &bad, 1) != DALNOK_OK)
    }
}

@Suite struct PolyControllers {
    @Test func pitchBendAndSustainPedal() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let c = dalnok_midi_clip_add(e, dalnok_track_add_instrument(e, nil), 0, 96_000)
        // A4 for 0.1 s with the pedal down from 0 to 0.5 s, then (a second A4 at 1 s) bent fully up: B4.
        var notes = [DalnokNote(start: 0, length: 4_800, pitch: 69, velocity: 100),
                     DalnokNote(start: 48_000, length: 24_000, pitch: 69, velocity: 100)]
        _ = dalnok_midi_clip_set_notes(e, c, &notes, 2)
        var ccs = [DalnokMidiCC(start: 0, controller: 64, value: 127), DalnokMidiCC(start: 24_000, controller: 64, value: 0),
                   DalnokMidiCC(start: 48_000, controller: Int32(DALNOK_PITCH_BEND), value: 16_383)]
        #expect(dalnok_midi_clip_set_controllers(e, c, &ccs, 3) == DALNOK_OK)
        let l = render(e, 0, 96_000)
        func rms(_ s: ArraySlice<Float>) -> Float { sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(s.count)) }
        #expect(rms(l[20_000..<23_000]) > 0.01, "held by the pedal after the note ended (\(rms(l[20_000..<23_000])))")
        #expect(rms(l[40_000..<47_000]) < 1e-4, "released when the pedal came up")
        let f = frequency(l[50_000..<70_000])
        #expect(abs(f - 493.88) < 1, "bent two semitones up: \(f) Hz")
        // Without the pedal the first note has died away by 20,000 (0.18 s release).
        _ = dalnok_midi_clip_set_controllers(e, c, nil, 0)
        #expect(rms(render(e, 0, 24_000)[20_000..<23_000]) < 1e-4)
    }
}
