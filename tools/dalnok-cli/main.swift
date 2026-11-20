// dalnok-cli — headless driver for smoke tests, benchmarks, and batch work.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Darwin

func cstr(_ a: [CChar]) -> String { String(decoding: a.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("error: \(msg)\n".utf8)); exit(1) }

func load(_ path: String, rate: Double) -> OpaquePointer {
    var m: OpaquePointer?
    var err = [CChar](repeating: 0, count: 512)
    let t0 = Date()
    guard dalnok_media_load(path, rate, &m, &err, 512) == DALNOK_OK, let media = m else { fail(cstr(err)) }
    let ms = Date().timeIntervalSince(t0) * 1000
    print(String(format: "loaded %@: %lld frames, %d ch @ %.0f Hz in %.1f ms", (path as NSString).lastPathComponent,
                 dalnok_media_frames(media), dalnok_media_channels(media), rate, ms))
    return media
}

let usage = """
usage:
  dalnok-cli play <audio-file> [--seconds N] [--churn]   live playback on the default device
  dalnok-cli render <audio-file> <out.wav> [--bits 16|24|32]
  dalnok-cli render-project <project.dalnok> <out.wav> [--bits 16|24|32]
  dalnok-cli export-dawproject <project.dalnok> <out.dawproject>
  dalnok-cli recover-capture <spool> <new-output.wav>
  dalnok-cli command <project.dalnok> <command> [args-json] [--save]   run a catalog command
  dalnok-cli commands                                                  list the command catalog
  dalnok-cli inputs                                                    list audio input devices
  dalnok-cli midi-inputs                                               list MIDI sources
  dalnok-cli capture-test <device-name> <channel> <seconds> <new-spool>  experimental duplex capture
  dalnok-cli record <device-name> <channel> <seconds> <folder> [--save p.dalnok] [--monitor]  record an armed track
  dalnok-cli simulate-record <folder> <seconds>                         record generated input in real time (crash tests)
  dalnok-cli recover-takes <folder>                                      recover unfinished takes from their journals
  dalnok-cli midi-play <source-id> <seconds> [--record]                  play (and record) the built-in synth from MIDI
  dalnok-cli make-test-project <folder> [--preset demo|band|midi|states|large] [--rate R] [--bpm B] [--tracks N] [--seconds S]
                                                                         generate a deterministic test project (no external files)
  dalnok-cli plugins [--no-au] [--folder F]                              list VST3, CLAP and Audio Unit plugins (no code loaded)
  dalnok-cli plugins --validate [--match NAME] [--folder F --only-folder] [--au] [--timeout S] [--rescan] [--cache FILE]
                                                                         load each plugin in a separate scanner process
  dalnok-cli bench [--tracks N] [--seconds S]                          render-cost benchmark (no device)
  dalnok-cli audit-bench <project.dalnok> [--edits N]                   audit-only: model-read, edit and undo cost
  dalnok-cli audit-ui <project.dalnok>                               audit-only: AppKit drag and refresh timings
  dalnok-cli audit-scale [--tracks N] [--clips N]                       audit-only: edit cost vs model size
  dalnok-cli import <project.rpp|.als|.logicx|.fcpxml|stems-folder> [--save out.dalnok] [--render out.wav] [--quiet]
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first, args.count >= 2 || cmd == "commands" || cmd == "bench" || cmd == "inputs" || cmd == "midi-inputs" || cmd == "recover-takes" || cmd == "plugins" else { print(usage); exit(2) }

func openProject(_ path: String) -> OpaquePointer {
    let engine = dalnok_engine_create(48_000)!
    var err = [CChar](repeating: 0, count: 512)
    var missing: Int32 = 0
    guard dalnok_project_load(engine, path, &missing, &err, 512) == DALNOK_OK else { fail(cstr(err)) }
    if missing > 0 { print("warning: \(missing) media file(s) offline") }
    return engine
}
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

switch cmd {
case "capture-test":
    guard args.count == 5, let channel = Int32(args[2]), channel > 0,
          let seconds = Double(args[3]), seconds > 0, seconds <= 60 else { print(usage); exit(2) }
    let count = dalnok_input_devices(nil, 0)
    var devices = [DalnokInputDeviceInfo](repeating: DalnokInputDeviceInfo(), count: Int(max(count, 0)))
    let current = devices.withUnsafeMutableBufferPointer { dalnok_input_devices($0.baseAddress, Int32($0.count)) }
    guard let device = devices.prefix(Int(max(0, min(count, current)))).first(where: {
        withUnsafeBytes(of: $0.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == args[1]
    }) else { fail("input device not found") }
    let uid = withUnsafeBytes(of: device.uid) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    guard channel <= device.input_channels else { fail("input channel is out of range") }
    guard let engine = dalnok_engine_create(device.sample_rate) else { fail("engine creation failed") }
    defer { dalnok_engine_destroy(engine) }
    var err = [CChar](repeating: 0, count: 512)
    guard dalnok_engine_set_output_device(engine, uid, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    guard dalnok_capture_start(engine, uid, channel - 1, args[4], &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    let deadline = Date().addingTimeInterval(seconds)
    var live = DalnokCaptureStats()
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
        guard dalnok_capture_status(engine, &live) == DALNOK_OK else { break }
        if live.input_error || live.overflow || live.write_error || live.finalize_error { break }
    }
    var stats = DalnokCaptureStats()
    let result = dalnok_capture_stop(engine, &stats, &err, err.count)
    print("captured \(stats.captured_frames), wrote \(stats.written_frames), dropped \(stats.dropped_frames) frames")
    guard result == DALNOK_OK, stats.captured_frames > 0 else { fail(cstr(err).isEmpty ? "no captured frames" : cstr(err)) }
    print("experimental capture: PASS; spool retained at \(args[4])")

case "record", "simulate-record":
    let simulated = cmd == "simulate-record"
    guard simulated ? args.count == 3 : args.count >= 5 else { print(usage); exit(2) }
    let channel = simulated ? 1 : (Int32(args[2]) ?? 0)
    let seconds = Double(simulated ? args[2] : args[3]) ?? 0
    let folder = simulated ? args[1] : args[4]
    guard channel > 0, seconds > 0, seconds <= 3_600 else { print(usage); exit(2) }
    var uid = DALNOK_SIMULATED_INPUT, rate = 48_000.0
    if !simulated {
        let count = dalnok_input_devices(nil, 0)
        var devices = [DalnokInputDeviceInfo](repeating: DalnokInputDeviceInfo(), count: Int(max(count, 0)))
        let current = devices.withUnsafeMutableBufferPointer { dalnok_input_devices($0.baseAddress, Int32($0.count)) }
        guard let device = devices.prefix(Int(max(0, min(count, current)))).first(where: {
            withUnsafeBytes(of: $0.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == args[1]
        }) else { fail("input device not found") }
        guard channel <= device.input_channels else { fail("input channel is out of range") }
        uid = withUnsafeBytes(of: device.uid) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        rate = device.sample_rate
    }
    guard let engine = dalnok_engine_create(rate) else { fail("engine creation failed") }
    defer { dalnok_engine_destroy(engine) }
    var err = [CChar](repeating: 0, count: 1_024)
    if !simulated {
        guard dalnok_engine_set_output_device(engine, uid, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    }
    let track = dalnok_track_add(engine, "Input \(channel)")
    _ = dalnok_track_set_input(engine, track, channel - 1)
    _ = dalnok_track_set_armed(engine, track, true)
    dalnok_record_set_monitoring(engine, args.contains("--monitor"))
    guard dalnok_record_start(engine, uid, folder, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    print("recording (round-trip latency estimate \(dalnok_record_latency(engine)) frames)…")
    setvbuf(stdout, nil, _IOLBF, 0)
    let deadline = Date().addingTimeInterval(seconds)
    var frame = 0
    var l = [Float](repeating: 0, count: 512), r = l, input = l
    while Date() < deadline && !dalnok_record_broken(engine) {
        if simulated { // generated, exactly representable samples; real-time pace so a kill lands mid-take
            for i in 0..<512 { input[i] = Float((frame + i) * 37 % 2_000 - 1_000) / 1_024 }
            _ = dalnok_engine_pump_input(engine, input, &l, &r, 512)
            frame += 512
            if frame % 48_000 < 512 { print("written \(frame) frames") }
            Thread.sleep(forTimeInterval: 512.0 / 48_000)
        } else {
            Thread.sleep(forTimeInterval: 0.02)
            dalnok_engine_collect_garbage(engine)
        }
    }
    var result = DalnokRecordResult()
    let status = dalnok_record_stop(engine, &result, &err, err.count)
    let path = withUnsafeBytes(of: result.path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    print("captured \(result.capture.captured_frames), wrote \(result.capture.written_frames), dropped \(result.capture.dropped_frames); file \(result.frames) frames at \(path)")
    print("take began at frame \(result.start_frame); placed at \(clipStart(engine, result.audio_clip)) after \(result.latency_frames) frames of latency compensation")
    if let project = opt("--save") {
        guard dalnok_project_save(engine, project, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
        print("saved \(project)")
    }
    guard status == DALNOK_OK else { fail(cstr(err)) }
    print("record: PASS")

case "recover-takes":
    var buf = [CChar](repeating: 0, count: 1 << 20)
    dalnok_record_scan(args[1], &buf, buf.count)
    let takes = (try? JSONSerialization.jsonObject(with: Data(cstr(buf).utf8))) as? [[String: Any]] ?? []
    if takes.isEmpty { print("no take journals in \(args[1])") }
    var failures = 0
    for take in takes {
        let journal = take["journal"] as? String ?? ""
        var out = [CChar](repeating: 0, count: 65_536), err = [CChar](repeating: 0, count: 512)
        if dalnok_record_recover(journal, &out, out.count, &err, err.count) == DALNOK_OK {
            let r = (try? JSONSerialization.jsonObject(with: Data(cstr(out).utf8))) as? [String: Any] ?? [:]
            print("\((journal as NSString).lastPathComponent): \(r["frames"] ?? "?") frames -> \(r["path"] ?? "?")")
        } else {
            failures += 1
            print("\((journal as NSString).lastPathComponent): \(cstr(err))")
        }
    }
    if failures > 0 { exit(1) }

case "midi-play":
    guard args.count >= 3, let source = Int32(args[1]), let seconds = Double(args[2]) else { print(usage); exit(2) }
    let engine = dalnok_engine_create(0)!
    defer { dalnok_engine_destroy(engine) }
    var err = [CChar](repeating: 0, count: 512)
    let track = dalnok_track_add_instrument(engine, "Keys")
    guard dalnok_engine_start_device(engine, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    guard dalnok_midi_open_input(engine, source, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    let recording = args.contains("--record")
    if recording { guard dalnok_record_start(engine, nil, nil, &err, err.count) == DALNOK_OK else { fail(cstr(err)) } }
    print("play the keyboard for \(Int(seconds)) s…")
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { Thread.sleep(forTimeInterval: 0.02); dalnok_engine_collect_garbage(engine) }
    if recording {
        var result = DalnokRecordResult()
        let status = dalnok_record_stop(engine, &result, &err, err.count)
        print("recorded \(result.notes) notes on track \(track); dropped \(dalnok_midi_dropped(engine)) events")
        if status != DALNOK_OK { fail(cstr(err)) }
    }

case "make-test-project":
    let folder = URL(fileURLWithPath: args[1], isDirectory: true)
    if FileManager.default.fileExists(atPath: folder.appendingPathComponent("Audio Files").path) {
        fail("\(folder.path) already contains a project; choose an empty folder")
    }
    let project = try TestProject.make(folder: folder, preset: opt("--preset") ?? "demo",
                                       rate: Double(opt("--rate") ?? "48000") ?? 48_000, bpm: Double(opt("--bpm") ?? "120") ?? 120,
                                       tracks: Int(opt("--tracks") ?? "64") ?? 64, seconds: Double(opt("--seconds") ?? "30") ?? 30)
    print(project.path)

case "plugins" where args.contains("--validate"):
    let scanner = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("dalnok-scan").path
    guard FileManager.default.isExecutableFile(atPath: scanner) else { fail("dalnok-scan not found next to dalnok-cli (swift build --product dalnok-scan)") }
    let cache = opt("--cache") ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Dalnok/PluginCache.json").path)
    let timeout = Int32((Double(opt("--timeout") ?? "10") ?? 10) * 1000)
    let started = Date()
    func run(_ buf: UnsafeMutablePointer<CChar>?, _ len: Int) -> Int {
        dalnok_plugins_validate(scanner, cache, opt("--folder"), args.contains("--only-folder"), args.contains("--au"),
                                opt("--match"), timeout, args.contains("--rescan"), buf, len)
    }
    var buf = [CChar](repeating: 0, count: 1 << 22)
    _ = run(&buf, buf.count)
    let list = (try? JSONSerialization.jsonObject(with: Data(cstr(buf).utf8))) as? [[String: Any]] ?? []
    var counts: [String: Int] = [:]
    for p in list {
        let scan = p["scan"] as? [String: Any] ?? [:]
        let status = scan["status"] as? String ?? "?"
        counts[status, default: 0] += 1
        let cached = scan["cached"] as? Bool == true ? " (cached)" : ""
        let error = (scan["error"] as? String).map { " — \($0)" } ?? ""
        print("\(status.padding(toLength: 8, withPad: " ", startingAt: 0)) \((p["format"] as? String ?? "").uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) \((p["kind"] as? String ?? "").padding(toLength: 10, withPad: " ", startingAt: 0)) \(p["name"] ?? "")\(cached)\(error)")
    }
    print(String(format: "%d plugins in %.1f s: ", list.count, Date().timeIntervalSince(started)) +
          counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))

case "plugins":
    let folder = opt("--folder")
    let n = dalnok_plugins_scan(folder, !args.contains("--no-au"), nil, 0)
    var buf = [CChar](repeating: 0, count: n + 1)
    dalnok_plugins_scan(folder, !args.contains("--no-au"), &buf, buf.count)
    let list = (try? JSONSerialization.jsonObject(with: Data(cstr(buf).utf8))) as? [[String: Any]] ?? []
    var counts: [String: Int] = [:]
    for p in list {
        let format = p["format"] as? String ?? "?", kind = p["kind"] as? String ?? "?"
        counts["\(format) \(kind)", default: 0] += 1
        print("\(format.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) \(kind.padding(toLength: 10, withPad: " ", startingAt: 0)) \(p["name"] ?? "")\((p["vendor"] as? String ?? "").isEmpty ? "" : " — \(p["vendor"]!)")")
    }
    print("\(list.count) plugins: " + counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))

case "midi-inputs":
    let count = dalnok_midi_sources(nil, 0)
    var sources = [DalnokMidiSourceInfo](repeating: DalnokMidiSourceInfo(), count: Int(max(count, 0)))
    let current = sources.withUnsafeMutableBufferPointer { dalnok_midi_sources($0.baseAddress, Int32($0.count)) }
    for source in sources.prefix(Int(max(0, min(count, current)))) {
        let name = withUnsafeBytes(of: source.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        print("\(name) [ID \(source.unique_id)]")
    }

case "inputs":
    let count = dalnok_input_devices(nil, 0)
    var devices = [DalnokInputDeviceInfo](repeating: DalnokInputDeviceInfo(), count: Int(max(count, 0)))
    let current = devices.withUnsafeMutableBufferPointer { dalnok_input_devices($0.baseAddress, Int32($0.count)) }
    for d in devices.prefix(Int(max(0, min(count, current)))) {
        let name = withUnsafeBytes(of: d.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let uid = withUnsafeBytes(of: d.uid) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        print("\(name): \(d.input_channels) input channels, \(Int(d.sample_rate)) Hz\(d.is_default ? " (default)" : "") [\(uid)]")
    }

case "play":
    let seconds = Double(opt("--seconds") ?? "3") ?? 3
    let churn = args.contains("--churn")
    let engine = dalnok_engine_create(0)!
    let rate = dalnok_engine_sample_rate(engine)
    let media = load(args[1], rate: rate)
    let track = dalnok_track_add(engine, "Track 1")
    _ = dalnok_clip_add(engine, track, dalnok_pool_add(engine, media, args[1]), 0, 0, 0)

    var err = [CChar](repeating: 0, count: 512)
    guard dalnok_engine_start_device(engine, &err, 512) == DALNOK_OK else { fail("device: \(cstr(err))") }
    dalnok_transport_play(engine)
    let start = Date()
    var churnOps = 0
    while Date().timeIntervalSince(start) < seconds {
        if churn {
            // Stress the snapshot handoff: structural edits while playing.
            let t = dalnok_track_add(engine, "churn")
            _ = dalnok_clip_add(engine, t, dalnok_pool_add(engine, media, args[1]), Int64(churnOps % 1000) * 64, 0, 4_096)
            dalnok_track_remove(engine, t)
            churnOps += 1
            usleep(500)
        } else {
            usleep(20_000)
        }
        dalnok_engine_collect_garbage(engine)
    }
    let wall = Date().timeIntervalSince(start)
    let pos = dalnok_transport_position(engine)
    dalnok_transport_pause(engine)
    usleep(50_000)
    var s = DalnokStats()
    dalnok_engine_stats(engine, &s)
    dalnok_engine_stop_device(engine)
    dalnok_engine_collect_garbage(engine)

    let expected = wall * rate
    print(String(format: "played %.2f s wall; transport advanced %lld frames (%.2f%% of wall clock)", wall, pos,
                 Double(pos) / expected * 100))
    let budgetUs = Double(s.max_frames_per_callback) / rate * 1e6
    print(String(format: "callbacks %llu, max block %u frames (%.0f us budget), worst render %.1f us, overloads %u, snapshot swaps %u",
                 s.callbacks, s.max_frames_per_callback, budgetUs, Double(s.max_callback_ns) / 1000, s.overloads, s.snapshot_swaps))
    if churn { print("churn edits: \(churnOps)") }
    dalnok_media_release(media)
    dalnok_engine_destroy(engine)
    let ok = s.callbacks > 0 && abs(Double(pos) / expected - 1) < 0.05 && s.overloads == 0
    print(ok ? "RESULT: PASS" : "RESULT: FAIL")
    exit(ok ? 0 : 1)

case "render":
    guard args.count >= 3 else { print(usage); exit(2) }
    let bits = Int32(opt("--bits") ?? "24") ?? 24
    let engine = dalnok_engine_create(48_000)!
    let media = load(args[1], rate: 48_000)
    _ = dalnok_clip_add(engine, dalnok_track_add(engine, "Track 1"), dalnok_pool_add(engine, media, args[1]), 0, 0, 0)
    var err = [CChar](repeating: 0, count: 512)
    let frames = dalnok_session_length(engine)
    let t0 = Date()
    guard dalnok_render_to_wav(engine, args[2], 0, frames, bits, &err, 512) == DALNOK_OK else { fail(cstr(err)) }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "rendered %lld frames in %.1f ms (%.0fx realtime)", frames, dt * 1000,
                 Double(frames) / 48_000 / dt))
    dalnok_media_release(media)
    dalnok_engine_destroy(engine)

case "recover-capture":
    guard args.count == 3 else { print(usage); exit(2) }
    var frames: UInt64 = 0, trailing: UInt32 = 0
    var err = [CChar](repeating: 0, count: 512)
    guard dalnok_capture_recover_wav(args[1], args[2], &frames, &trailing, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    print("recovered \(frames) frames; omitted \(trailing) incomplete trailing bytes; source preserved")

case "render-project":
    guard args.count >= 3 else { print(usage); exit(2) }
    let engine = openProject(args[1])
    var err = [CChar](repeating: 0, count: 512)
    let frames = dalnok_session_length(engine)
    guard frames > 0 else { fail("project is empty") }
    guard dalnok_render_to_wav(engine, args[2], 0, frames, Int32(opt("--bits") ?? "24") ?? 24, &err, 512) == DALNOK_OK
    else { fail(cstr(err)) }
    print("rendered \(frames) frames to \(args[2])")
    dalnok_engine_destroy(engine)

case "export-dawproject":
    guard args.count >= 3 else { print(usage); exit(2) }
    let engine = openProject(args[1])
    var notes = [CChar](repeating: 0, count: 8192), err = [CChar](repeating: 0, count: 512)
    guard dalnok_project_export_dawproject(engine, args[2], &notes, notes.count, &err, 512) == DALNOK_OK else { fail(cstr(err)) }
    print("exported \(args[2])")
    for line in cstr(notes).split(separator: "\n") { print("  not carried: \(line)") }
    dalnok_engine_destroy(engine)

case "commands":
    for i in 0..<dalnok_command_count() {
        var n: UnsafePointer<CChar>?, t: UnsafePointer<CChar>?, a: UnsafePointer<CChar>?
        _ = dalnok_command_info(i, &n, &t, &a)
        print(String(cString: n!).padding(toLength: 18, withPad: " ", startingAt: 0),
              String(cString: t!).padding(toLength: 24, withPad: " ", startingAt: 0), String(cString: a!))
    }

case "command":
    guard args.count >= 3 else { print(usage); exit(2) }
    let engine = openProject(args[1])
    let json = args.count >= 4 && !args[3].hasPrefix("--") ? args[3] : "{}"
    var out = [CChar](repeating: 0, count: 1 << 20)
    let st = dalnok_command_run(engine, args[2], json, &out, out.count)
    print(cstr(out))
    if st == DALNOK_OK && args.contains("--save") {
        var err = [CChar](repeating: 0, count: 512)
        guard dalnok_project_save(engine, args[1], &err, 512) == DALNOK_OK else { fail(cstr(err)) }
    }
    dalnok_engine_destroy(engine)
    exit(st == DALNOK_OK ? 0 : 1)

case "import" where args.contains("--report-only"):
    var report = [CChar](repeating: 0, count: 1 << 16)
    var err = [CChar](repeating: 0, count: 1024)
    guard dalnok_project_import_report(args[1], &report, report.count, &err, err.count) == DALNOK_OK else {
        fail("import failed: \(cstr(err))")
    }
    print(cstr(report))

case "import":
    let engine = dalnok_engine_create(48_000)!
    var data: OpaquePointer?
    var missing: Int32 = 0
    var report = [CChar](repeating: 0, count: 1 << 16)
    var err = [CChar](repeating: 0, count: 1024)
    let t0 = Date()
    let st = dalnok_project_import(args[1], 48_000, &data, &missing, &report, report.count, &err, err.count)
    guard st == DALNOK_OK else { fail("import failed (\(st.rawValue)): \(cstr(err))") }
    dalnok_project_apply(engine, data)
    let ms = Date().timeIntervalSince(t0) * 1000
    if !args.contains("--quiet") { print(cstr(report)) }
    print(String(format: "imported %d tracks, session %.1f s, %d offline, in %.0f ms", dalnok_track_count(engine),
                 Double(dalnok_session_length(engine)) / 48_000, missing, ms))
    if let out = opt("--save") {
        guard dalnok_project_save(engine, out, &err, 1024) == DALNOK_OK else { fail(cstr(err)) }
        print("saved \(out)")
    }
    if let out = opt("--render") {
        let n = dalnok_session_length(engine)
        guard n > 0, dalnok_render_to_wav(engine, out, 0, n, 24, &err, 1024) == DALNOK_OK else { fail("render: \(cstr(err))") }
        print("rendered \(out)")
    }
    dalnok_engine_destroy(engine)

case "audit-ui":
    guard args.count >= 2 else { print(usage); exit(2) }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("Dalnok")
    let process = Process()
    process.executableURL = executable
    process.arguments = [args[1], "--uiwalk", NSTemporaryDirectory(), "--no-welcome"]
    var environment = ProcessInfo.processInfo.environment
    environment["DALNOK_AUDIT_UI"] = "1"
    environment["DALNOK_RECOVERY_DIR"] = NSTemporaryDirectory() + "dalnok-audit-recovery-" + UUID().uuidString
    process.environment = environment
    do { try process.run(); process.waitUntilExit() } catch { fail("AppKit audit launch failed: \(error)") }
    if process.terminationStatus != 0 { exit(process.terminationStatus) }

case "audit-bench":
    // Audit instrumentation only (docs/audits): measures what the app pays per model read and per edit on a
    // real project. It adds no engine or app behaviour; it only calls the public C API.
    guard args.count >= 2 else { print(usage); exit(2) }
    let engine = openProject(args[1])
    let edits = Int(opt("--edits") ?? "200") ?? 200
    func rssMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    // One pass over everything the Swift UI's Session.refresh() reads.
    func readModel() -> (tracks: Int, clips: Int, notes: Int) {
        var tracks = 0, clips = 0, notes = 0
        for i in 0..<max(0, dalnok_track_count(engine)) {
            let tid = dalnok_track_at(engine, i)
            var ti = DalnokTrackInfo()
            guard dalnok_track_info(engine, tid, &ti) == DALNOK_OK else { continue }
            tracks += 1
            for k in 0..<max(0, ti.clip_count) {
                var ci = DalnokClipInfo()
                guard dalnok_clip_info(engine, dalnok_track_clip_at(engine, tid, k), &ci) == DALNOK_OK else { continue }
                clips += 1
                if ci.midi && ci.note_count > 0 {
                    var n = [DalnokNote](repeating: DalnokNote(), count: Int(ci.note_count))
                    _ = dalnok_midi_clip_notes(engine, ci.id, &n, ci.note_count)
                    notes += Int(ci.note_count)
                }
            }
            for k in 0..<max(0, dalnok_track_plugin_count(engine, tid)) {
                var pi = DalnokPluginSlotInfo()
                _ = dalnok_track_plugin_info(engine, tid, k, &pi)
            }
            _ = dalnok_track_hidden(engine, tid)
            var sends = [DalnokSend](repeating: DalnokSend(), count: 16)
            _ = dalnok_track_sends(engine, tid, &sends, 16)
            for target in 0..<2 {
                let c = dalnok_track_automation(engine, tid, Int32(target), nil, 0)
                if c > 0 {
                    var pts = [DalnokAutoPoint](repeating: DalnokAutoPoint(), count: Int(c))
                    _ = dalnok_track_automation(engine, tid, Int32(target), &pts, c)
                }
            }
        }
        return (tracks, clips, notes)
    }
    func summarize(_ label: String, _ samples: [Double]) {
        guard !samples.isEmpty else { return }
        let s = samples.sorted()
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        print(String(format: "%@: n=%d p50=%.3f ms p95=%.3f ms p99=%.3f ms max=%.3f ms", label, s.count,
                     pct(0.50), pct(0.95), pct(0.99), s[s.count - 1]))
    }
    let model = readModel()
    var reads: [Double] = []
    for _ in 0..<20 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = readModel()
        reads.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    summarize("model read (one Session.refresh pass)", reads)
    print("model: \(model.tracks) tracks, \(model.clips) clips, \(model.notes) MIDI notes")

    let firstTrack = dalnok_track_at(engine, 0)
    var firstClip: DalnokClipId = 0
    for i in 0..<max(0, dalnok_track_count(engine)) where firstClip == 0 {
        let tid = dalnok_track_at(engine, i)
        if dalnok_track_clip_at(engine, tid, 0) != 0 { firstClip = dalnok_track_clip_at(engine, tid, 0) }
    }
    var gains: [Double] = []
    let rssBefore = rssMB()
    for i in 0..<edits {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = dalnok_track_set_gain_db(engine, firstTrack, -Double(i % 24) * 0.5 > -96 ? Float(-Double(i % 24) * 0.5) : -96)
        gains.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    summarize("parameter edit (track gain, undoable)", gains)
    print(String(format: "undo memory: RSS %.1f MB -> %.1f MB after %d undoable parameter edits (%.2f MB/edit)",
                 rssBefore, rssMB(), edits, (rssMB() - rssBefore) / Double(edits)))
    let trackIds = (0..<max(0, dalnok_track_count(engine))).map { dalnok_track_at(engine, $0) }
    func readParameters() {
        for tid in trackIds {
            var gain: Float = 0, pan: Float = 0, muted = false, solo = false
            _ = dalnok_track_parameters(engine, tid, &gain, &pan, &muted, &solo)
        }
    }
    var scalarReads: [Double] = [], dragEvents: [Double] = []
    for i in 0..<100 {
        var start = DispatchTime.now().uptimeNanoseconds
        readParameters()
        scalarReads.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        start = DispatchTime.now().uptimeNanoseconds
        _ = dalnok_track_set_gain_db(engine, firstTrack, Float(-(i % 20)))
        readParameters()
        dragEvents.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }
    summarize("scalar read (C API only)", scalarReads)
    summarize("gain edit plus scalar read (C API only)", dragEvents)
    if firstClip != 0 {
        var moves: [Double] = []
        let rssStructural = rssMB()
        for i in 0..<edits {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = dalnok_clips_nudge(engine, [firstClip], 1, i % 2 == 0 ? 1 : -1)
            moves.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        summarize("structural edit (nudge one clip, recompile)", moves)
        print(String(format: "undo memory: RSS %.1f MB -> %.1f MB after %d undoable structural edits (%.2f MB/edit)",
                     rssStructural, rssMB(), edits, (rssMB() - rssStructural) / Double(edits)))
    }
    var undo: [Double] = []
    for _ in 0..<20 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = dalnok_undo(engine)
        undo.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    summarize("undo (whole-model restore + recompile)", undo)
    dalnok_engine_destroy(engine)

case "audit-scale":
    // Audit instrumentation only: builds T tracks x C clips in memory and measures the cost of one model read,
    // one structural edit (which recompiles the render snapshot) and one undo at that size.
    let tracks = Int(opt("--tracks") ?? "64") ?? 64
    let clipsPer = Int(opt("--clips") ?? "16") ?? 16
    let rate = 48_000.0
    guard let e = dalnok_engine_create(rate) else { fail("engine creation failed") }
    var samples = (0..<4_800).map { Float(sin(Double($0) * 0.01)) * 0.1 }
    let media = samples.withUnsafeMutableBufferPointer { p in
        var chans: [UnsafePointer<Float>?] = [UnsafePointer(p.baseAddress)]
        return chans.withUnsafeMutableBufferPointer { dalnok_media_from_samples($0.baseAddress, 1, 4_800, rate)! }
    }
    let mid = dalnok_pool_add(e, media, nil)
    dalnok_media_release(media)
    func measure(_ label: String, _ body: (Int) -> Void, n: Int = 30) {
        var s: [Double] = []
        for i in 0..<n {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body(i)
            s.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        s.sort()
        func pct(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        print(String(format: "%@: n=%d p50=%.3f ms p95=%.3f ms p99=%.3f ms max=%.3f ms", label, s.count,
                     pct(0.50), pct(0.95), pct(0.99), s[s.count - 1]))
    }
    let t0 = DispatchTime.now().uptimeNanoseconds
    for t in 0..<tracks {
        let tr = dalnok_track_add(e, "T\(t)")
        for c in 0..<clipsPer { _ = dalnok_clip_add(e, tr, mid, Int64(c) * 4_800, 0, 4_800) }
    }
    let build = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    print(String(format: "model: %d tracks x %d clips = %d clips, built in %.0f ms", tracks, clipsPer, tracks * clipsPer, build))
    func readModel() {
        for i in 0..<max(0, dalnok_track_count(e)) {
            let tid = dalnok_track_at(e, i)
            var ti = DalnokTrackInfo()
            guard dalnok_track_info(e, tid, &ti) == DALNOK_OK else { continue }
            for k in 0..<max(0, ti.clip_count) {
                var ci = DalnokClipInfo()
                _ = dalnok_clip_info(e, dalnok_track_clip_at(e, tid, k), &ci)
            }
        }
    }
    measure("model read (one Session.refresh pass)", { _ in readModel() })
    let firstClip = dalnok_track_clip_at(e, dalnok_track_at(e, 0), 0)
    measure("structural edit (nudge one clip, recompile)", { i in _ = dalnok_clips_nudge(e, [firstClip], 1, i % 2 == 0 ? 1 : -1) })
    measure("parameter edit (track gain, undoable)", { i in _ = dalnok_track_set_gain_db(e, dalnok_track_at(e, 0), Float(-(i % 20))) })
    measure("undo (whole-model restore + recompile)", { _ in _ = dalnok_undo(e) })
    dalnok_engine_destroy(e)

case "bench":
    // N stereo tracks, each with a fully-faded clip over shared media; measures the
    // live render path (pump, 512-frame blocks like a device) and offline throughput.
    let tracks = Int(opt("--tracks") ?? "64") ?? 64
    let seconds = Double(opt("--seconds") ?? "30") ?? 30
    let rate = 48_000.0, frames = Int(rate * seconds)
    let engine = dalnok_engine_create(rate)!
    var l = (0..<frames).map { Float(sin(Double($0) * 0.0577)) * 0.1 }, r = l.map { -$0 }
    let media = l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
        var chans: [UnsafePointer<Float>?] = [UnsafePointer(lp.baseAddress), UnsafePointer(rp.baseAddress)]
        return chans.withUnsafeMutableBufferPointer { dalnok_media_from_samples($0.baseAddress, 2, Int64(frames), rate)! }
    } }
    let id = dalnok_pool_add(engine, media, nil)
    dalnok_media_release(media)
    for t in 0..<tracks {
        let tr = dalnok_track_add(engine, "T\(t)")
        let c = dalnok_clip_add(engine, tr, id, 0, 0, 0)
        dalnok_clip_set_fades(engine, c, Int64(rate), Int64(rate), DALNOK_FADE_EQUAL_POWER)
        dalnok_track_set_pan(engine, tr, Float(t % 7) / 3.5 - 1)
    }
    dalnok_transport_play(engine)
    var bl = [Float](repeating: 0, count: 512), br = bl
    var worst = 0.0, total = 0.0, blocks = 0
    for _ in 0..<(frames / 512) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = dalnok_engine_pump(engine, &bl, &br, 512)
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3
        worst = max(worst, dt); total += dt; blocks += 1
    }
    let budget = 512 / rate * 1e6
    print(String(format: "live path: %d tracks, %d blocks of 512 frames: avg %.1f us, worst %.1f us (budget %.0f us, %.1f%% avg load)",
                 tracks, blocks, total / Double(blocks), worst, budget, total / Double(blocks) / budget * 100))
    var ol = [Float](repeating: 0, count: frames), or = ol
    let t0 = Date()
    dalnok_render_offline(engine, 0, Int64(frames), &ol, &or)
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "offline: %.0f s of %d tracks in %.0f ms (%.0fx realtime)", seconds, tracks, dt * 1000, seconds / dt))
    dalnok_engine_destroy(engine)

default:
    print(usage)
    exit(2)
}

func clipStart(_ e: OpaquePointer, _ clip: DalnokClipId) -> Int64 {
    var info = DalnokClipInfo()
    return dalnok_clip_info(e, clip, &info) == DALNOK_OK ? info.start : -1
}
