// Parser robustness and real-time float-environment checks (audit A-10, A-12).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct RealTimeFloatEnvironment {
    /// Subnormal samples must be flushed to zero by the render path: no denormal arithmetic reaches the DSP,
    /// and the result is exactly silent (audit A-12).
    @Test func subnormalSamplesFlushToZeroOnLiveAndOfflinePaths() {
        let tiny = Float.leastNonzeroMagnitude * 1e3 // a subnormal, far below -140 dBFS
        #expect(tiny > 0 && tiny < Float.leastNormalMagnitude)
        let (e, _, m) = liveEngine([Float](repeating: tiny, count: 4_800))
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_transport_play(e)
        let (live, right) = pump(e, 2_048)
        #expect(live.allSatisfy { $0 == 0 }, "live path keeps subnormals out of the mix")
        #expect(right.allSatisfy { $0 == 0 })
        let (offline, _) = render(e, frames: 2_048)
        #expect(offline.allSatisfy { $0 == 0 }, "offline render flushes subnormals too")
    }
}

/// Deterministic generator so a failing property case replays from its seed.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct ProjectParsingRobustness {
    /// Found by scripts/ci/fuzz.sh: a malformed %-escape in an FCPXML media URL threw out of std::stoi and aborted
    /// the process; a non-numeric volume did the same through std::stof. Both must import with sensible values.
    @Test func fcpxmlMalformedEscapesAndVolumesImport() throws {
        let dir = tempDir()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <fcpxml version="1.10"><resources><format id="r1" frameDuration="1/48000s"/>
        <asset id="r2" name="a" start="0s" duration="1s" hasAudio="1"><media-rep kind="original-media" src="file:///tmp/a%zz%4.wav"/></asset></resources>
        <library><event><project name="P"><sequence format="r1" duration="2s"><spine>
        <asset-clip ref="r2" offset="0s" duration="1s" name="a"><adjust-volume amount="loud dB"/></asset-clip>
        <asset-clip ref="r2" offset="1s" duration="1s" name="b"><adjust-volume amount="1e999dB"/></asset-clip>
        </spine></sequence></project></event></library></fcpxml>
        """
        let url = dir.appendingPathComponent("escape.fcpxml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        var report = [CChar](repeating: 0, count: 1 << 14), err = [CChar](repeating: 0, count: 512)
        #expect(dalnok_project_import_report(url.path, &report, report.count, &err, err.count) == DALNOK_OK, "\(cstr(err))")
        var data: OpaquePointer?
        #expect(dalnok_project_import(url.path, sr, &data, nil, &report, report.count, &err, err.count) == DALNOK_OK, "\(cstr(err))")
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        #expect(dalnok_project_apply_recovery(e, data) == DALNOK_OK)
        let clips = (0..<dalnok_track_count(e)).reduce(0) { n, i in
            var info = DalnokTrackInfo(); _ = dalnok_track_info(e, dalnok_track_at(e, i), &info); return n + Int(info.clip_count)
        }
        #expect(clips == 2, "both clips import despite the bad escape and volumes (\(clips))")
    }

    /// Found by scripts/ci/fuzz.sh: a ZIP whose directory claimed a multi-gigabyte size made the reader allocate it.
    /// Sizes and offsets must be checked against the file before anything is allocated or read.
    @Test func zipSizesAreCheckedAgainstTheFile() throws {
        let dir = tempDir()
        func put16(_ d: inout Data, _ v: UInt32) { d.append(UInt8(v & 0xff)); d.append(UInt8((v >> 8) & 0xff)) }
        func put32(_ d: inout Data, _ v: UInt32) { put16(&d, v & 0xffff); put16(&d, v >> 16) }
        func eocd(count: UInt32, dirSize: UInt32, dirAt: UInt32) -> Data {
            var d = Data(); put32(&d, 0x0605_4b50); put16(&d, 0); put16(&d, 0); put16(&d, count); put16(&d, count)
            put32(&d, dirSize); put32(&d, dirAt); put16(&d, 0); return d
        }
        // A one-entry directory whose entry claims 4 GB of stored data at a valid offset.
        var central = Data(); put32(&central, 0x0201_4b50); for _ in 0..<4 { put16(&central, 20) }; put16(&central, 0); put16(&central, 0)
        put32(&central, 0); put32(&central, 0xffff_fff0); put32(&central, 0xffff_fff0)
        put16(&central, 11); for _ in 0..<4 { put16(&central, 0) }; put32(&central, 0); put32(&central, 0)
        central.append("project.xml".data(using: .utf8)!)
        var local = Data(); put32(&local, 0x0403_4b50); for _ in 0..<5 { put16(&local, 0) }; for _ in 0..<3 { put32(&local, 0) }
        put16(&local, 0); put16(&local, 0)
        let cases: [(String, Data)] = [
            ("huge directory", eocd(count: 1, dirSize: 0xffff_ff00, dirAt: 0)),
            ("directory past the end", eocd(count: 1, dirSize: 64, dirAt: 0x7fff_0000)),
            ("huge entry", local + central + eocd(count: 1, dirSize: UInt32(central.count), dirAt: UInt32(local.count))),
        ]
        func peakMB() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_maxrss) / 1_048_576 }
        let before = peakMB()
        defer { #expect(peakMB() - before < 256, "rejecting them must not allocate the claimed sizes (peak +\(Int(peakMB() - before)) MB)") }
        for (what, bytes) in cases {
            let url = dir.appendingPathComponent("\(what).dawproject")
            try bytes.write(to: url)
            var data: OpaquePointer?
            var err = [CChar](repeating: 0, count: 256)
            #expect(dalnok_project_import(url.path, sr, &data, nil, nil, 0, &err, err.count) != DALNOK_OK, "\(what) is rejected")
            #expect(data == nil)
        }
    }

    /// Save -> load -> save must preserve the document (compared as JSON, so key order is irrelevant).
    /// DALNOK_PROPERTY_ITERATIONS raises the model count (scripts/ci/fuzz.sh runs 1,000); DALNOK_PROPERTY_SEED
    /// replays a failure. Each model is seeded separately so a failing one is reported by its seed.
    @Test func randomProjectsRoundTripThroughTheWriter() throws {
        let env = ProcessInfo.processInfo.environment
        let iterations = env["DALNOK_PROPERTY_ITERATIONS"].flatMap(Int.init) ?? 8
        let base = env["DALNOK_PROPERTY_SEED"].flatMap(UInt64.init) ?? UInt64.random(in: 1...UInt64.max >> 1)
        for iteration in 0..<iterations {
            let seed = base &+ UInt64(iteration)
            var rng = SeededRandom(state: seed)
            let dir = tempDir()
            let wav = dir.appendingPathComponent("audio.wav")
            try writeTestWav(wav, frames: 2_000)
            let e = dalnok_engine_create(sr)!
            defer { dalnok_engine_destroy(e) }
            var media: OpaquePointer?
            #expect(dalnok_media_load(wav.path, sr, &media, nil, 0) == DALNOK_OK)
            let pool = dalnok_pool_add(e, media, wav.path)
            dalnok_media_release(media)

            for i in 0..<Int.random(in: 1...5, using: &rng) {
                let audio = dalnok_track_add(e, "Audio \(i) \(Int.random(in: 0...999, using: &rng))")
                let start = Int64.random(in: 0...3_000, using: &rng)
                let length = Int64.random(in: 400...1_500, using: &rng)
                let c = DalnokEngine.dalnok_clip_add(e, audio, pool, start, 0, length)
                _ = dalnok_clip_set_gain_db(e, c, Float.random(in: -18...6, using: &rng))
                _ = dalnok_clip_set_fades(e, c, 40, 60, Bool.random(using: &rng) ? DALNOK_FADE_EQUAL_POWER : DALNOK_FADE_LINEAR)
                _ = dalnok_track_set_gain_db(e, audio, Float.random(in: -30...6, using: &rng))
                _ = dalnok_track_set_pan(e, audio, Float.random(in: -1...1, using: &rng))
                if Bool.random(using: &rng) { _ = dalnok_track_set_mute(e, audio, true) }
                if Bool.random(using: &rng) {
                    _ = dalnok_midi_clip_add(e, dalnok_track_add_instrument(e, "Synth \(i)"),
                                             Int64.random(in: 0...2_000, using: &rng),
                                             Int64.random(in: 500...1_500, using: &rng))
                }
                _ = dalnok_marker_add(e, start, "M\(i)")
                if Bool.random(using: &rng) { _ = dalnok_plugin_add(e, audio, "dalnok:channel-eq", nil, nil, 0) }
            }
            // Routing, tempo and meter changes exercise the rest of the document.
            if Bool.random(using: &rng) {
                let bus = dalnok_track_add_bus(e, "Bus")
                _ = dalnok_track_set_send(e, dalnok_track_at(e, 0), bus, Float.random(in: -24...0, using: &rng), Bool.random(using: &rng))
                if Bool.random(using: &rng) { _ = dalnok_track_set_output(e, dalnok_track_at(e, 0), bus) }
            }
            if Bool.random(using: &rng) {
                var tempo = [DalnokTempoPoint(beat: 0, bpm: Double.random(in: 60...180, using: &rng)),
                             DalnokTempoPoint(beat: 8, bpm: Double.random(in: 60...180, using: &rng))]
                var meter = [DalnokMeterPoint(bar: 0, numerator: 4, denominator: 4), DalnokMeterPoint(bar: 2, numerator: 3, denominator: 4)]
                _ = dalnok_tempo_map_set(e, &tempo, 2, &meter, 2)
            }

            let first = dir.appendingPathComponent("a.dalnok"), second = dir.appendingPathComponent("b.dalnok")
            var err = [CChar](repeating: 0, count: 512)
            #expect(dalnok_project_save(e, first.path, &err, err.count) == DALNOK_OK, "\(cstr(err))")
            let reloaded = dalnok_engine_create(sr)!
            defer { dalnok_engine_destroy(reloaded) }
            var missing: Int32 = -1
            #expect(dalnok_project_load(reloaded, first.path, &missing, &err, err.count) == DALNOK_OK, "\(cstr(err))")
            #expect(missing == 0)
            #expect(dalnok_project_save(reloaded, second.path, &err, err.count) == DALNOK_OK, "\(cstr(err))")
            let a = try JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any] ?? [:]
            let b = try JSONSerialization.jsonObject(with: Data(contentsOf: second)) as? [String: Any] ?? [:]
            #expect(NSDictionary(dictionary: a).isEqual(to: b), "save/load/save changed the document (DALNOK_PROPERTY_SEED=\(seed))")
            if !NSDictionary(dictionary: a).isEqual(to: b) { return }
        }
    }

    /// Mutated and truncated project files must fail cleanly; they must never crash, hang or over-read.
    @Test func mutatedProjectFilesAreRejectedWithoutCrashing() throws {
        let dir = tempDir()
        let wav = dir.appendingPathComponent("audio.wav")
        try writeTestWav(wav, frames: 1_000)
        let e = dalnok_engine_create(sr)!
        var media: OpaquePointer?
        #expect(dalnok_media_load(wav.path, sr, &media, nil, 0) == DALNOK_OK)
        let pool = dalnok_pool_add(e, media, wav.path)
        dalnok_media_release(media)
        let track = dalnok_track_add(e, "A")
        DalnokEngine.dalnok_clip_add(e, track, pool, 0, 0, 800)
        _ = dalnok_marker_add(e, 100, "M")
        let project = dir.appendingPathComponent("seed.dalnok")
        #expect(dalnok_project_save(e, project.path, nil, 0) == DALNOK_OK)
        dalnok_engine_destroy(e)

        let seed = try Data(contentsOf: project)
        var rng = SystemRandomNumberGenerator()
        var accepted = 0
        for i in 0..<120 {
            var mutated = seed
            if i % 12 == 11 {
                mutated = Data(mutated.prefix(Int.random(in: 0..<mutated.count, using: &rng)))
            } else {
                for _ in 0..<Int.random(in: 1...6, using: &rng) {
                    let at = Int.random(in: 0..<mutated.count, using: &rng)
                    mutated[at] = UInt8.random(in: 0...255, using: &rng)
                }
            }
            let path = dir.appendingPathComponent("mutant-\(i).dalnok")
            try mutated.write(to: path)
            var prepared: OpaquePointer?
            var missing: Int32 = 0
            var err = [CChar](repeating: 0, count: 256)
            if dalnok_project_prepare(path.path, sr, &prepared, &missing, &err, err.count) == DALNOK_OK {
                accepted += 1
                let target = dalnok_engine_create(sr)!
                _ = dalnok_project_apply(target, prepared)
                dalnok_engine_destroy(target)
            }
        }
        #expect(accepted < 120, "most mutations are rejected")
    }
}
