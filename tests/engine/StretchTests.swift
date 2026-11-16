// Time-stretch, pitch shift and varispeed: measured on rendered output.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

func sine(_ hz: Double, seconds: Double, amp: Float = 0.5) -> [Float] {
    (0..<Int(seconds * sr)).map { amp * Float(sin(2 * .pi * hz * Double($0) / sr)) }
}

/// Frequency from upward zero crossings over the middle 80% (avoids edge effects).
func frequency(_ x: [Float]) -> Double {
    let a = x.count / 10, b = x.count - x.count / 10
    var crossings = 0
    for i in max(a, 1)..<b where x[i - 1] < 0 && x[i] >= 0 { crossings += 1 }
    return Double(crossings) / (Double(b - a) / sr)
}
func rmsDb(_ x: [Float]) -> Double {
    let a = x.count / 10, b = x.count - x.count / 10
    let ms = x[a..<b].reduce(0.0) { $0 + Double($1 * $1) } / Double(b - a)
    return 10 * log10(ms)
}

/// One mono clip at 0; returns (engine, clip, media).
func stretchEngine(_ s: [Float]) -> (OpaquePointer, DalnokClipId, OpaquePointer) {
    let e = dalnok_engine_create(sr)!
    let m = makeMedia([s])
    let c = dalnok_clip_add(e, dalnok_track_add(e, "A"), m, 0, 0, 0)
    return (e, c, m)
}

@Suite struct TimeStretch {
    @Test func stretchPreservesPitchAndLevel() {
        let src = sine(440, seconds: 1)
        let (e, c, m) = stretchEngine(src); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        #expect(dalnok_clip_set_stretch(e, c, 96_000, 0.5, 0, true) == DALNOK_OK) // 1 s of source over 2 s
        #expect(clipInfo(e, c).length == 96_000 && clipInfo(e, c).rate == 0.5)
        let (l, _) = render(e, frames: 96_000)
        #expect(abs(frequency(l) - 440) < 440 * 0.01, "pitch preserved: \(frequency(l)) Hz")
        #expect(abs(rmsDb(l) - rmsDb(src)) < 1.5, "level: \(rmsDb(l)) vs \(rmsDb(src)) dB")
        #expect(l[95_000...].contains { abs($0) > 0.1 }, "audio continues to the end of the stretched clip")
    }

    @Test func varispeedChangesPitchWithSpeed() {
        let src = sine(440, seconds: 1)
        let (e, c, m) = stretchEngine(src); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        #expect(dalnok_clip_set_stretch(e, c, 24_000, 2.0, 0, false) == DALNOK_OK) // double speed
        let (l, _) = render(e, frames: 30_000)
        #expect(abs(frequency(Array(l[0..<24_000])) - 880) < 880 * 0.01, "varispeed 2×: \(frequency(Array(l[0..<24_000]))) Hz")
        #expect(l[24_100...].allSatisfy { $0 == 0 }, "clip ends at half length")
    }

    @Test func transposeKeepsLength() {
        let src = sine(440, seconds: 1)
        let (e, c, m) = stretchEngine(src); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        #expect(dalnok_clip_set_stretch(e, c, 48_000, 1.0, 12, true) == DALNOK_OK)
        let (l, _) = render(e, frames: 48_000)
        #expect(abs(frequency(l) - 880) < 880 * 0.015, "+12 semitones: \(frequency(l)) Hz")
        #expect(abs(rmsDb(l) - rmsDb(src)) < 1.5)
    }

    @Test func rendersInBackgroundThenPlays() async throws {
        let (e, c, m) = stretchEngine(sine(220, seconds: 2)); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_clip_set_stretch(e, c, 72_000, 96_000.0 / 72_000.0, 0, true)
        #expect(clipInfo(e, c).processing, "rendering starts in the background")
        var waited = 0
        while dalnok_engine_poll_jobs(e) > 0 && waited < 400 { try await Task.sleep(for: .milliseconds(10)); waited += 1 }
        #expect(!clipInfo(e, c).processing, "finished after \(waited * 10) ms")
        dalnok_transport_play(e)
        let (l, _) = pump(e, 4_096)
        #expect(l[1_000...].contains { abs($0) > 0.1 }, "live path plays the stretched audio")
    }

    @Test func validationUndoAndPersistence() throws {
        let dir = tempDir()
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let audio = dir.appendingPathComponent("s.wav")
        try writeTestWav(audio, frames: 48_000)
        var m: OpaquePointer?
        dalnok_media_load(audio.path, sr, &m, nil, 0)
        let c = DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "A"), dalnok_pool_add(e, m, audio.path), 0, 0, 0)
        dalnok_media_release(m)
        #expect(dalnok_clip_set_stretch(e, c, 48_000, 2.0, 0, true) == DALNOK_ERR_INVALID_ARG, "would read past the source")
        #expect(dalnok_clip_set_stretch(e, c, 48_000, 0.0, 0, true) == DALNOK_ERR_INVALID_ARG)
        #expect(dalnok_clip_set_stretch(e, c, 60_000, 0.8, -3, true) == DALNOK_OK)
        #expect(undoName(e) == "Time Stretch")
        let before = render(e, frames: 60_000)
        let project = dir.appendingPathComponent("st.dalnok").path
        dalnok_project_save(e, project, nil, 0)
        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project, nil, nil, 0) == DALNOK_OK)
        let c2 = clipInfo(e2, dalnok_track_clip_at(e2, dalnok_track_at(e2, 0), 0))
        #expect(c2.rate == 0.8 && c2.pitch == -3 && c2.preserve_pitch && !c2.processing, "precomputed on load")
        expectClose(render(e2, frames: 60_000).0, before.0, tol: 0, "deterministic after reload")
        dalnok_undo(e)
        #expect(clipInfo(e, c).rate == 1 && clipInfo(e, c).length == 48_000)
    }

    @Test func splitAndTrimRespectRate() {
        let (e, c, m) = stretchEngine(sine(330, seconds: 2)); defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_clip_set_stretch(e, c, 48_000, 2.0, 0, true) // 2 s of source in 1 s
        var right: DalnokClipId = 0
        #expect(dalnok_clip_split(e, c, 24_000, &right) == DALNOK_OK)
        #expect(clipInfo(e, right).offset == 48_000 && clipInfo(e, right).rate == 2, "right half starts 1 s into the source")
        #expect(dalnok_clip_set_region(e, right, 24_000, 48_000, 24_001) == DALNOK_ERR_INVALID_ARG, "trim limited by source × rate")
    }
}

@Suite struct StretchImports {
    @Test func reaperPlayrateBecomesStretch() throws {
        let dir = tempDir()
        try writeTestWav(dir.appendingPathComponent("a.wav"), frames: 96_000)
        let rpp = """
        <REAPER_PROJECT 0.1 "7.0/macOS"
          <TRACK
            <ITEM
              POSITION 0
              LENGTH 1
              PLAYRATE 1.25 1 2 -1 0 0.0025
              <SOURCE WAVE
                FILE "a.wav"
              >
            >
          >
        >
        """
        let path = dir.appendingPathComponent("p.rpp")
        try rpp.write(to: path, atomically: true, encoding: .utf8)
        let (e, r) = try importInto(path.path); defer { dalnok_engine_destroy(e) }
        let c = clips(e)[0].info
        #expect(abs(c.rate - 1.25) < 1e-9 && c.pitch == 2 && c.preserve_pitch && c.length == 48_000 && !c.processing,
                "rate \(c.rate) pitch \(c.pitch)")
        #expect((r["notes"] as? [String])?.contains { $0.contains("time-stretched") } == true)
    }

    @Test func abletonWarpMarkersBecomePiecewiseStretch() throws {
        let dir = tempDir()
        try writeTestWav(dir.appendingPathComponent("w.wav"), frames: 240_000) // 5 s
        // 120 BPM: beats 0–2 cover source 0–1 s (rate 1); beats 2–4 cover source 1–3 s (rate 2).
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Ableton Creator="Ableton Live 12.3.5"><LiveSet><Tracks>
          <AudioTrack Id="1"><Name><EffectiveName Value="Warp"/></Name><DeviceChain><Mixer/>
            <MainSequencer><ClipSlotList/><Sample><ArrangerAutomation><Events>
              <AudioClip Id="0" Time="0"><CurrentStart Value="0"/><CurrentEnd Value="4"/>
                <Loop><LoopStart Value="0"/><LoopEnd Value="4"/><StartRelative Value="0"/><LoopOn Value="false"/></Loop>
                <Name Value="w"/><IsWarped Value="true"/><WarpMode Value="4"/><SampleVolume Value="1"/><Fade Value="false"/>
                <PitchCoarse Value="0"/><PitchFine Value="0"/>
                <WarpMarkers><WarpMarker SecTime="0" BeatTime="0"/><WarpMarker SecTime="1" BeatTime="2"/><WarpMarker SecTime="3" BeatTime="4"/></WarpMarkers>
                <SampleRef><FileRef><Path Value="\(dir.appendingPathComponent("w.wav").path)"/></FileRef></SampleRef>
              </AudioClip>
            </Events></ArrangerAutomation></Sample></MainSequencer>
          </DeviceChain></AudioTrack>
        </Tracks><MainTrack><DeviceChain><Mixer><Tempo><Manual Value="120"/></Tempo></Mixer></DeviceChain></MainTrack></LiveSet></Ableton>
        """
        let als = dir.appendingPathComponent("w.als")
        try AbletonImport().gzip(xml, to: als)
        let (e, _) = try importInto(als.path); defer { dalnok_engine_destroy(e) }
        let c = clips(e).map(\.info)
        #expect(c.count == 2, "one clip per warp segment")
        #expect(c[0].start == 0 && c[0].offset == 0 && c[0].length == 48_000 && c[0].rate == 1)
        #expect(c[1].start == 48_000 && c[1].offset == 48_000 && c[1].length == 48_000 && abs(c[1].rate - 2) < 1e-9)
    }
}
