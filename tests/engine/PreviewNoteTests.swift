// Auditioning notes from the piano roll (dalnok_track_preview_note, API 39): heard through the track's instrument
// whether or not the transport plays, without arming the track, and never recorded.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct PreviewNotes {
    /// Peak of `blocks` live 512-frame blocks (the real callback path).
    func pumpPeak(_ e: OpaquePointer, blocks: Int) -> Float {
        var l = [Float](repeating: 0, count: 512), r = l, peak: Float = 0
        for _ in 0..<blocks {
            _ = dalnok_engine_pump(e, &l, &r, 512)
            peak = max(peak, l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
        }
        return peak
    }

    @Test func builtInInstrumentSoundsStoppedAndPlayingAndReleases() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Keys")
        let other = dalnok_track_add_instrument(e, "Armed") // the armed track (the last one added) is a different one
        #expect(t != 0 && other != 0)
        _ = dalnok_track_set_armed(e, t, false)
        _ = dalnok_track_set_armed(e, other, true)
        #expect(pumpPeak(e, blocks: 4) == 0, "silent before")
        #expect(dalnok_track_preview_note(e, t, 60, 100, true) == DALNOK_OK)
        var ml: Float = 0, mr: Float = 0
        dalnok_meter_master(e, &ml, &mr) // resets
        let held = pumpPeak(e, blocks: 8)
        #expect(held > 0.05, "the note sounds with the transport stopped (peak \(held))")
        dalnok_meter_master(e, &ml, &mr)
        #expect(max(ml, mr) > 0.05, "the master meter shows it too (\(ml), \(mr))")
        #expect(dalnok_track_preview_note(e, t, 60, 0, false) == DALNOK_OK)
        _ = pumpPeak(e, blocks: 94) // ~1 s of release
        let tail = pumpPeak(e, blocks: 4)
        #expect(tail < 1e-4, "released to silence (peak \(tail))")
        // While playing (no clips, so only the auditioned note is heard).
        dalnok_transport_play(e)
        _ = pumpPeak(e, blocks: 8)
        #expect(dalnok_track_preview_note(e, t, 64, 100, true) == DALNOK_OK)
        let playing = pumpPeak(e, blocks: 8)
        #expect(playing > 0.05, "the note sounds while the transport plays (peak \(playing))")
        #expect(dalnok_track_preview_note(e, t, 64, 0, false) == DALNOK_OK)
        dalnok_transport_pause(e)
        _ = pumpPeak(e, blocks: 8)
        func clips(_ track: DalnokTrackId) -> Int32 { var i = DalnokTrackInfo(); _ = dalnok_track_info(e, track, &i); return i.clip_count }
        #expect(clips(t) == 0 && clips(other) == 0, "nothing recorded or created")
    }

    @Test func onlyInstrumentTracksAndValidPitches() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let audio = dalnok_track_add(e, "Audio")
        let keys = dalnok_track_add_instrument(e, "Keys")
        #expect(dalnok_track_preview_note(e, audio, 60, 100, true) == DALNOK_ERR_NOT_FOUND)
        #expect(dalnok_track_preview_note(e, 9_999, 60, 100, true) == DALNOK_ERR_NOT_FOUND)
        #expect(dalnok_track_preview_note(e, keys, 200, 100, true) == DALNOK_ERR_NOT_FOUND)
    }
}

extension PluginHosting {
    /// The test VST3 synth outputs velocity / 127 while a note is held: an auditioned note on its track is heard
    /// exactly (in process, and isolated under scripts/ci/plugin-isolation.sh), and stops when released.
    @Test func previewNotesPlayAPluginInstrument() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Synth")
        _ = dalnok_track_set_armed(e, t, false)
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_add(e, t, testVst3, synthClass, &err, 256) != 0, "\(cstr(err))")
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<4 { _ = dalnok_engine_pump(e, &l, &r, 512) }
        #expect(dalnok_track_preview_note(e, t, 60, 127, true) == DALNOK_OK)
        var peak: Float = 0
        for _ in 0..<8 { _ = dalnok_engine_pump(e, &l, &r, 512); peak = max(peak, l.max() ?? 0) }
        #expect(abs(peak - 1) < 1e-3, "the note is heard at velocity 127 / 127 (peak \(peak))")
        #expect(dalnok_track_preview_note(e, t, 60, 0, false) == DALNOK_OK)
        for _ in 0..<4 { _ = dalnok_engine_pump(e, &l, &r, 512) }
        #expect(l.allSatisfy { $0 == 0 }, "released")
    }

    /// A plug-in that is silent for its first blocks (sample players finishing their load) plays the first auditioned
    /// note at once if the track was warmed (a release of no note, as opening the piano roll sends) beforehand.
    @Test(.serialized, arguments: [false, true]) func warmingMakesTheFirstPreviewNoteImmediate(_ warm: Bool) {
        setenv("DALNOK_TEST_SYNTH_WARMUP_BLOCKS", "20", 1); defer { unsetenv("DALNOK_TEST_SYNTH_WARMUP_BLOCKS") }
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Synth")
        _ = dalnok_track_set_armed(e, t, false)
        #expect(dalnok_plugin_add(e, t, testVst3, synthClass, nil, 0) != 0)
        var l = [Float](repeating: 0, count: 512), r = l
        if warm { #expect(dalnok_track_preview_note(e, t, 0, 0, false) == DALNOK_OK) }
        for _ in 0..<30 { _ = dalnok_engine_pump(e, &l, &r, 512) } // ~0.3 s with nothing clicked yet
        #expect(dalnok_track_preview_note(e, t, 60, 127, true) == DALNOK_OK)
        var first: Float = 0
        for _ in 0..<2 { _ = dalnok_engine_pump(e, &l, &r, 512); first = max(first, l.max() ?? 0) }
        _ = dalnok_track_preview_note(e, t, 60, 0, false)
        if warm { #expect(abs(first - 1) < 1e-3, "warmed: the first note is heard in its first blocks (peak \(first))") }
        else { #expect(first == 0, "not warmed: the plug-in is still silent (the case warming fixes)") }
    }
}
