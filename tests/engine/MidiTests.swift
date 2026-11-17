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
        // Muting the track silences live input too.
        dalnok_track_set_mute(e, t, true)
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

    @Test func modelRulesAndPersistence() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let audio = dalnok_track_add(e, "Audio")
        let keys = dalnok_track_add_instrument(e, "Keys")
        #expect(dalnok_midi_clip_add(e, audio, 0, 100) == 0) // MIDI only on instrument tracks
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
        #expect(notes[0].start == 0 && notes[0].length == 46 && notes[0].pitch == 72 && notes[0].velocity == 127)
        #expect(notes[1].start == 92 && notes[1].length == 184)
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
