// Project format (A-16): every historical version loads, saving is stable under random models, and every key a saved
// file holds is in engine/api/project-format.json with the version that introduced it, no newer than the version the
// file declares (so an older build never misreads a project that claims to be in its format).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// engine/api/project-format.json: key path (arrays as `[]`) → JSON types, the version that introduced it, and whether
/// an older build may ignore it (view state such as a lane height: it still plays the project correctly).
struct FormatSchema {
    struct Key { let types: Set<String>; let since: Int; let ignorable: Bool }
    let version: Int
    let keys: [String: Key]
    static func load() throws -> FormatSchema {
        let url = repoRoot.appendingPathComponent("engine/api/project-format.json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var keys: [String: Key] = [:]
        for (path, v) in root["keys"] as! [String: [String: Any]] {
            let t = v["type"] as! String
            keys[path] = Key(types: Set(t.split(separator: "|").map(String.init)), since: v["since"] as! Int,
                             ignorable: v["ignorable"] as? Bool ?? false)
        }
        return FormatSchema(version: root["version"] as! Int, keys: keys)
    }
}

func jsonType(_ v: Any) -> String {
    if v is NSNull { return "null" }
    if let n = v as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? "bool" : "number" }
    if v is String { return "string" }
    if v is [Any] { return "array" }
    return "object"
}

/// Every key path in a JSON document with its value's type. Arrays of objects descend as `name[]`; arrays of plain
/// values (points, note tuples) are leaves.
func keyPaths(_ v: Any, _ prefix: String = "", into out: inout [String: Set<String>]) {
    if let o = v as? [String: Any] {
        for (k, child) in o {
            let path = prefix.isEmpty ? k : prefix + "." + k
            out[path, default: []].insert(jsonType(child))
            if let a = child as? [Any] { for e in a where e is [String: Any] { keyPaths(e, path + "[]", into: &out) } }
            else if child is [String: Any] { keyPaths(child, path, into: &out) }
        }
    }
}

/// Checks a saved document against the schema: unknown keys, wrong types, and keys newer than the declared version.
func schemaProblems(_ doc: [String: Any], _ schema: FormatSchema) -> [String] {
    var paths: [String: Set<String>] = [:]
    keyPaths(doc, into: &paths)
    let version = doc["version"] as? Int ?? 1
    var problems: [String] = []
    for (path, types) in paths.sorted(by: { $0.key < $1.key }) {
        guard let key = schema.keys[path] else { problems.append("\(path): not in project-format.json"); continue }
        if !types.isSubset(of: key.types) { problems.append("\(path): \(types.sorted()) but the schema says \(key.types.sorted())") }
        if !key.ignorable && key.since > version { problems.append("\(path): since \(key.since), in a file declaring version \(version)") }
    }
    return problems
}

/// Builds a random project through the C API (seeded): tracks of every kind, audio and MIDI clips with every clip
/// setting, routing, stacks, automation, tempo and meter maps, markers, built-in plug-ins, launcher slots.
struct RandomProject {
    var rng: Rng
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 { // SplitMix64
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
    mutating func int(_ r: ClosedRange<Int64>) -> Int64 { Int64.random(in: r, using: &rng) }

    mutating func build(_ e: OpaquePointer, media: [DalnokMediaId]) {
        // Each feature is on for some projects only, so the version a file needs varies (3 to 13).
        let plugins = chance(0.25), launcher = chance(0.25), clipMute = chance(0.25), routing = chance(0.4)
        let automation = chance(0.4), markers = chance(0.3), tempoMap = chance(0.4)
        var tracks: [DalnokTrackId] = [], buses: [DalnokTrackId] = []
        for k in 0..<Int(int(1...6)) {
            let kind = routing ? int(0...2) : int(0...1)
            let t = kind == 0 ? dalnok_track_add(e, "Audio \(k)") : kind == 1 ? dalnok_track_add_instrument(e, "Synth \(k)") : dalnok_track_add_bus(e, "Bus \(k)")
            (kind == 2 ? { buses.append(t) } : { tracks.append(t) })()
            if chance(0.5) { _ = dalnok_track_set_gain_db(e, t, Float(int(-30...6))) }
            if chance(0.4) { _ = dalnok_track_set_pan(e, t, Float(int(-10...10)) / 10) }
            if chance(0.2) { _ = dalnok_track_set_mute(e, t, true) }
            if chance(0.15) { _ = dalnok_track_set_solo(e, t, true) }
            if chance(0.3) { _ = dalnok_track_set_color(e, t, Int32(int(0...0xFFFFFF))) }
            if chance(0.3) { _ = dalnok_track_set_height(e, t, Float(int(60...200))) }
            if chance(0.1) { _ = dalnok_track_set_hidden(e, t, true) }
            if kind == 0 && chance(0.3) { _ = dalnok_track_set_input(e, t, Int32(int(0...3))) }
            if automation && chance(0.5) {
                let pts = (0..<Int(int(1...4))).map { i in DalnokAutoPoint(frame: Int64(i) * 24_000, value: Float(int(-40...0))) }
                _ = dalnok_track_set_automation(e, t, 0, pts, Int32(pts.count))
            }
            if automation && chance(0.3) {
                let pts = (0..<Int(int(1...3))).map { i in DalnokAutoPoint(frame: Int64(i) * 12_000, value: Float(int(-10...10)) / 10) }
                _ = dalnok_track_set_automation(e, t, 1, pts, Int32(pts.count))
            }
            if plugins && chance(0.6) {
                let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
                if slot != 0 && chance(0.4) { _ = dalnok_plugin_set_bypassed(e, t, slot, true) }
                if slot != 0 && chance(0.3) { _ = dalnok_plugin_set_folded(e, t, slot, true) }
            }
            if kind == 2 { continue }
            for _ in 0..<Int(int(0...5)) {
                let start = int(0...400) * 480
                if kind == 1 || media.isEmpty {
                    let c = dalnok_midi_clip_add(e, t, start, int(1...8) * 4_800)
                    let notes = (0..<Int(int(0...6))).map { i in
                        DalnokNote(start: Int64(i) * 2_400, length: int(1...4) * 1_200, pitch: UInt8(int(36...90)), velocity: UInt8(int(1...127)))
                    }
                    if c != 0 { _ = dalnok_midi_clip_set_notes(e, c, notes, Int32(notes.count)) }
                    if c != 0 && chance(0.3) { _ = dalnok_clip_split(e, c, start + 2_400, nil) } // a shared note source
                } else {
                    let m = media[Int(int(0...Int64(media.count - 1)))]
                    let c = DalnokEngine.dalnok_clip_add(e, t, m, start, int(0...1) * 480, int(1...9) * 480)
                    guard c != 0 else { continue }
                    if chance(0.4) { _ = dalnok_clip_set_fades(e, c, int(0...480), int(0...480), DalnokFadeCurve(rawValue: UInt32(int(0...1)))) }
                    if chance(0.3) { _ = dalnok_clip_set_gain_db(e, c, Float(int(-12...6))) }
                    if clipMute && chance(0.4) { _ = dalnok_clip_set_muted(e, c, true) }
                    if chance(0.15) { _ = dalnok_clip_set_stretch(e, c, 4_800, 0.5, chance(0.5) ? 2 : 0, chance(0.5)) }
                    if launcher && chance(0.4) {
                        let s = dalnok_launcher_copy_clip(e, c, Int32(int(0...3)))
                        if s != 0 && chance(0.5) { _ = dalnok_launcher_set_follow(e, s, Int32(int(1...2)), Int32(int(1...4))) }
                    }
                }
            }
        }
        for t in tracks where !buses.isEmpty && chance(0.4) { _ = dalnok_track_set_output(e, t, buses[Int(int(0...Int64(buses.count - 1)))]) }
        for t in tracks where !buses.isEmpty && chance(0.3) { _ = dalnok_track_set_send(e, t, buses[0], Float(int(-24...0)), chance(0.5)) }
        if routing && tracks.count >= 2 && chance(0.4) {
            let stack = dalnok_track_stack_create(e, Array(tracks.prefix(2)), 2, "Stack")
            if stack != 0 && chance(0.5) { _ = dalnok_track_stack_set_collapsed(e, stack, true) }
        }
        if tempoMap {
            let tempo = [DalnokTempoPoint(beat: 0, bpm: Double(int(60...180))), DalnokTempoPoint(beat: Double(int(4...32)), bpm: Double(int(60...180)))]
            let meter = [DalnokMeterPoint(bar: 0, numerator: 4, denominator: 4), DalnokMeterPoint(bar: Int32(int(2...8)), numerator: Int32(int(2...7)), denominator: 8)]
            _ = dalnok_tempo_map_set(e, tempo, 2, meter, chance(0.5) ? 2 : 1)
        }
        if chance(0.15) { _ = dalnok_master_set_gain_db(e, Float(int(-12...3))) }
        for k in 0..<Int(int(0...3)) where markers { _ = dalnok_marker_add(e, int(0...200) * 480, "Marker \(k)") }
    }
}

struct ProjectFormat {
    func saved(_ e: OpaquePointer, _ path: String) -> [String: Any]? {
        var err = [CChar](repeating: 0, count: 256)
        guard dalnok_project_save(e, path, &err, 256) == DALNOK_OK, let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 150 random projects: save, load into a fresh engine, save again. The two files are identical, and every key is
    /// in the schema, no newer than the version the file declares.
    @Test func randomProjectsRoundTripAndMatchTheSchema() throws {
        let schema = try FormatSchema.load()
        #expect(schema.version == dalnok_project_format_version(), "project-format.json describes the current version")
        let dir = tempDir()
        var media: [DalnokMediaId] = []
        var paths: [String] = []
        for k in 0..<2 {
            let url = dir.appendingPathComponent("source\(k).wav")
            try writeTestWav(url, frames: 24_000, seed: k + 1)
            paths.append(url.path)
        }
        var seen: [String: Set<String>] = [:], versions: Set<Int> = []
        var failures = 0
        for seed in 1...150 {
            let e = dalnok_engine_create(48_000)!
            defer { dalnok_engine_destroy(e) }
            media = paths.map { p in
                var m: OpaquePointer?
                _ = dalnok_media_load(p, 48_000, &m, nil, 0)
                defer { if let m { dalnok_media_release(m) } }
                return m.map { dalnok_pool_add(e, $0, p) } ?? 0
            }
            var r = RandomProject(rng: .init(state: UInt64(seed) &* 0x9E3779B97F4A7C15))
            r.build(e, media: media)
            while dalnok_engine_poll_jobs(e) > 0 { usleep(1_000) } // stretched clips finish rendering
            let a = dir.appendingPathComponent("a\(seed).dalnok").path, b = dir.appendingPathComponent("b\(seed).dalnok").path
            guard let docA = saved(e, a) else { Issue.record("seed \(seed): save failed"); failures += 1; continue }
            let e2 = dalnok_engine_create(48_000)!
            defer { dalnok_engine_destroy(e2) }
            var missing: Int32 = -1, err = [CChar](repeating: 0, count: 256)
            guard dalnok_project_load(e2, a, &missing, &err, 256) == DALNOK_OK else {
                Issue.record("seed \(seed): load failed: \(String(cString: err))"); failures += 1; continue
            }
            _ = saved(e2, b)
            let textA = try String(contentsOfFile: a, encoding: .utf8), textB = try String(contentsOfFile: b, encoding: .utf8)
            if textA != textB { Issue.record("seed \(seed): save → load → save changed the file"); failures += 1 }
            let problems = schemaProblems(docA, schema)
            if !problems.isEmpty { Issue.record("seed \(seed): \(problems.joined(separator: "; "))"); failures += 1 }
            keyPaths(docA, into: &seen)
            versions.insert(docA["version"] as? Int ?? 0)
            if failures > 5 { break }
        }
        if ProcessInfo.processInfo.environment["DALNOK_FORMAT_KEYS"] != nil {
            for (k, t) in seen.sorted(by: { $0.key < $1.key }) { print("KEY \(k) \(t.sorted().joined(separator: "|"))") }
        }
        print("FORMAT round trips: 150 random projects, versions written \(versions.sorted()), \(seen.count) key paths seen")
        #expect(versions.count >= 5, "the random projects exercise several format versions (\(versions.sorted()))")
    }

    /// One hand-written file per format version (tests/fixtures/project-format, using only that version's keys).
    /// Each loads, keeps what its version added through a save, and the saved file declares a version that holds it.
    @Test func everyFormatVersionLoads() throws {
        let schema = try FormatSchema.load()
        let dir = repoRoot.appendingPathComponent("tests/fixtures/project-format")
        // What each version added, read back from the re-saved file: a path (track index, key …) and the value.
        func at(_ doc: [String: Any], _ path: [Any]) -> Any? {
            var v: Any? = doc
            for p in path {
                if let k = p as? String { v = (v as? [String: Any])?[k] }
                else if let i = p as? Int { v = (v as? [Any]).flatMap { i < $0.count ? $0[i] : nil } }
            }
            return v
        }
        let expect: [Int: [([Any], String)]] = [
            1: [(["tracks", 0, "solo"], "1"), (["tracks", 0, "clips", 0, "fadeCurve"], "equalPower"), (["tracks", 0, "clips", 0, "gainDb"], "-6")],
            2: [(["tracks", 0, "kind"], "instrument"), (["tracks", 0, "clips", 0, "notes"], "[[0, 2400, 60, 100], [2400, 2400, 64, 90]]"),
                (["tracks", 1, "input"], "2"), (["tracks", 1, "plugins", 0, "state"], "c2F2ZWQgc3RhdGU=")],
            3: [(["tracks", 0, "clips", 1, "noteSource"], "1")],
            4: [(["tempoMap"], "[[0, 120], [16, 90]]"), (["meterMap"], "[[0, 4, 4], [4, 7, 8]]")],
            5: [(["tracks", 0, "output"], "2"), (["tracks", 0, "sends"], "[[3, -6, 1]]")],
            6: [(["tracks", 0, "volumeAutomation"], "[[0, -6], [24000, 0]]"), (["tracks", 0, "panAutomation"], "[[0, -0.5], [48000, 0.5]]")],
            7: [(["takeFolders", 0, "comp"], "[[0, 2400, 0], [2400, 4800, 1]]"), (["tracks", 0, "stack"], "2"), (["masterGain"], "-4.5")],
            8: [(["tracks", 0, "pluginAutomation", 0, "points"], "[[0, 0.25], [24000, 0.75]]")],
            9: [(["tracks", 0, "plugins", 0, "sidechain"], "2"), (["tracks", 0, "clips", 1, "follow"], "1")],
            10: [(["tracks", 0, "plugins", 0, "bypassed"], "1")],
            11: [(["markers", 0, "name"], "Verse"), (["tracks", 0, "hidden"], "1")],
            12: [(["tracks", 0, "clips", 0, "muted"], "1")],
            13: [(["tracks", 0, "plugins", 0, "format"], "dalnok"), (["tracks", 0, "plugins", 0, "folded"], "1"), (["tracks", 0, "height"], "140")],
            14: [(["tracks", 0, "phaseInvert"], "1")],
            15: [(["tracks", 0, "clips", 0, "warp"], "[[0, 0], [2400, 2000], [4800, 4800]]")],
            16: [(["tracks", 0, "clips", 0, "loopLength"], "4800"), (["tracks", 0, "clips", 0, "loopPhase"], "1200")],
            17: [(["tracks", 1, "clips", 0, "controllers"], "[[0, 1, 64], [2400, 128, 12000], [4800, 64, 127]]")],
            18: [(["tracks", 0, "clips", 0, "followTempo"], "1")],
            19: [(["tracks", 0, "muteAutomation"], "[[0, 0], [4800, 1]]")],
            20: [(["tracks", 0, "inputStereo"], "1")],
        ]
        func text(_ v: Any?) -> String {
            guard let v else { return "nil" }
            if let a = v as? [Any] { return "[" + a.map(text).joined(separator: ", ") + "]" }
            if let n = v as? NSNumber { let d = n.doubleValue; return d == d.rounded() ? String(Int(d)) : String(d) }
            return "\(v)"
        }
        #expect(expect.count == Int(dalnok_project_format_version()), "a fixture for every version")
        let out = tempDir()
        for version in 1...Int(dalnok_project_format_version()) {
            let url = dir.appendingPathComponent(String(format: "v%02d.dalnok", version))
            let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            #expect(fixture["version"] as? Int == version, "v\(version): declares its version")
            #expect(schemaProblems(fixture, schema).isEmpty, "v\(version): only that version's keys: \(schemaProblems(fixture, schema))")
            let e = dalnok_engine_create(48_000)!
            defer { dalnok_engine_destroy(e) }
            var missing: Int32 = -1, err = [CChar](repeating: 0, count: 256)
            guard dalnok_project_load(e, url.path, &missing, &err, 256) == DALNOK_OK else {
                Issue.record("v\(version): does not load: \(String(cString: err))"); continue
            }
            let resaved = out.appendingPathComponent("v\(version).dalnok").path
            guard let doc = saved(e, resaved) else { Issue.record("v\(version): does not save"); continue }
            #expect(schemaProblems(doc, schema).isEmpty, "v\(version) re-saved: \(schemaProblems(doc, schema))")
            #expect((doc["version"] as? Int ?? 0) >= min(version, 3), "v\(version) re-saved as \(doc["version"] ?? "-")")
            for (path, want) in expect[version] ?? [] {
                #expect(text(at(doc, path)) == want, "v\(version): \(path) is \(text(at(doc, path))), want \(want)")
            }
        }
    }

    /// Versions the reader refuses: newer than this build, negative or fractional.
    @Test func unreadableVersionsAreRefused() throws {
        let dir = tempDir()
        for (version, message) in [("\(dalnok_project_format_version() + 1)", "newer version"), ("-1", "invalid project version"), ("2.5", "invalid project version")] {
            let path = dir.appendingPathComponent("v\(version).dalnok").path
            try #"{"format": "dalnok-project", "version": \#(version), "sampleRate": 48000, "tracks": []}"#.write(toFile: path, atomically: true, encoding: .utf8)
            let e = dalnok_engine_create(48_000)!
            defer { dalnok_engine_destroy(e) }
            var missing: Int32 = 0, err = [CChar](repeating: 0, count: 256)
            #expect(dalnok_project_load(e, path, &missing, &err, 256) != DALNOK_OK && String(cString: err).contains(message),
                    "version \(version): \(String(cString: err))")
        }
    }
}
