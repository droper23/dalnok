// dalnok-cli — headless driver for smoke tests, benchmarks, and batch work.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Darwin

func cstr(_ a: [CChar]) -> String { String(decoding: a.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
/// Ends the process without running library teardown: some plug-ins crash or hang in their own static destructors
/// during exit() (seen with a Qt-based VST3), long after Dalnok's work is done and its files are closed.
func leave(_ code: Int32) -> Never { fflush(stdout); fflush(stderr); _exit(code) }
func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("error: \(msg)\n".utf8)); leave(1) }

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
  dalnok-cli load-bench <project.dalnok> [--play S]                     open as the app does; load time, worst block, misses
  dalnok-cli dirty-check <project.dalnok>                               does opening and playing mark it edited? (which tracks)
  dalnok-cli export-dawproject <project.dalnok> <out.dawproject>
  dalnok-cli recover-capture <spool> <new-output.wav>
  dalnok-cli command <project.dalnok> <command> [args-json] [--save]   run a catalog command
  dalnok-cli commands                                                  list the command catalog
  dalnok-cli latency <input-device> <channel> [--output <name|default>]   measure the loopback round trip
  dalnok-cli inputs                                                    list audio input devices
  dalnok-cli midi-inputs                                               list MIDI sources
  dalnok-cli capture-test <device-name> <channel> <seconds> <new-spool>  experimental duplex capture
  dalnok-cli record <device-name> <channel[,channel…]> <seconds> <folder> [--save p.dalnok] [--monitor] [--output <name|default>]  record an armed track
  dalnok-cli simulate-record <folder> <seconds>                         record generated input in real time (crash tests)
  dalnok-cli recover-takes <folder>                                      recover unfinished takes from their journals
  dalnok-cli midi-play <source-id> <seconds> [--record]                  play (and record) the built-in synth from MIDI
  dalnok-cli make-test-project <folder> [--preset demo|band|midi|states|large] [--rate R] [--bpm B] [--tracks N] [--seconds S]
                                                                         generate a deterministic test project (no external files)
  dalnok-cli plugins [--no-au] [--folder F] [--json]                       list VST3, CLAP and Audio Unit plugins (no code loaded)
  dalnok-cli plugins --validate [--match NAME] [--folder F --only-folder] [--au] [--timeout S] [--rescan] [--cache FILE]
                                                                         load each plugin in a separate scanner process
  dalnok-cli bench [--tracks N] [--audible N] [--seconds S]             render-cost benchmark (no device)
  dalnok-cli audit-bench <project.dalnok> [--edits N]                   audit-only: model-read, edit and undo cost
  dalnok-cli audit-ui <project.dalnok>                               audit-only: AppKit drag and refresh timings
  dalnok-cli stream-bench <file.wav> --mode memory|stream [--seconds S]  audit-only: RSS and misses playing one long file
  dalnok-cli audit-scale [--tracks N] [--clips N]                       audit-only: edit cost vs model size
  dalnok-cli import <project.rpp|.als|.logicx|.fcpxml|stems-folder> [--save out.dalnok] [--render out.wav] [--quiet]
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first, args.count >= 2 || cmd == "commands" || cmd == "bench" || cmd == "inputs" || cmd == "midi-inputs" || cmd == "recover-takes" || cmd == "plugins" else { print(usage); leave(2) }

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
          let seconds = Double(args[3]), seconds > 0, seconds <= 60 else { print(usage); leave(2) }
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
    guard simulated ? args.count == 3 : args.count >= 5 else { print(usage); leave(2) }
    // One armed track per listed input channel ("1,2"): each records its own take, all in one undo step.
    let channels = simulated ? [Int32(1)] : args[2].split(separator: ",").map { Int32($0) ?? 0 }
    let channel = channels.min() ?? 0
    let seconds = Double(simulated ? args[2] : args[3]) ?? 0
    let folder = simulated ? args[1] : args[4]
    guard channel > 0, seconds > 0, seconds <= 3_600 else { print(usage); leave(2) }
    var uid = DALNOK_SIMULATED_INPUT, rate = 48_000.0
    if !simulated {
        let count = dalnok_input_devices(nil, 0)
        var devices = [DalnokInputDeviceInfo](repeating: DalnokInputDeviceInfo(), count: Int(max(count, 0)))
        let current = devices.withUnsafeMutableBufferPointer { dalnok_input_devices($0.baseAddress, Int32($0.count)) }
        guard let device = devices.prefix(Int(max(0, min(count, current)))).first(where: {
            withUnsafeBytes(of: $0.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == args[1]
        }) else { fail("input device not found") }
        guard channels.allSatisfy({ $0 <= device.input_channels }), Set(channels).count == channels.count else { fail("input channel is out of range") }
        uid = withUnsafeBytes(of: device.uid) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        rate = device.sample_rate
    }
    guard let engine = dalnok_engine_create(rate) else { fail("engine creation failed") }
    defer { dalnok_engine_destroy(engine) }
    var err = [CChar](repeating: 0, count: 1_024)
    if !simulated {
        // --output <name|default>: listen elsewhere (the engine pairs the two devices); otherwise the input device.
        var out = uid
        if let name = opt("--output") {
            var list = [DalnokDeviceInfo](repeating: DalnokDeviceInfo(), count: 64)
            let n = Int(dalnok_output_devices(&list, 64))
            if name == "default" { out = "" }
            else if let d = list.prefix(min(n, 64)).first(where: { withUnsafeBytes(of: $0.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == name }) {
                out = withUnsafeBytes(of: d.uid) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            } else { fail("output device not found") }
        }
        guard dalnok_engine_set_output_device(engine, out, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    }
    for ch in channels {
        let track = dalnok_track_add(engine, "Input \(ch)")
        _ = dalnok_track_set_input(engine, track, ch - 1)
        _ = dalnok_track_set_armed(engine, track, true)
    }
    let before = Set((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
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
    if channels.count > 1 {
        // Per-take level, overall and per second, so each input can be told apart (e.g. guitar first, then voice).
        print("\(result.audio_clip_count) takes placed for \(channels.count) armed tracks")
        let made = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !before.contains($0) && $0.hasSuffix(".wav") }.sorted()
        for name in made {
            var media: OpaquePointer?
            guard dalnok_media_load("\(folder)/\(name)", rate, &media, &err, err.count) == DALNOK_OK, let media else { print("\(name): load failed: \(cstr(err))"); continue }
            defer { dalnok_media_release(media) }
            let frames = dalnok_media_frames(media), seconds = Int((Double(frames) / rate).rounded(.up))
            var lo = [Float](repeating: 0, count: seconds), hi = lo
            _ = dalnok_media_peaks(media, 0, 0, rate, &lo, &hi, Int64(seconds))
            let peaks = zip(lo, hi).map { max(-$0, $1) }
            print("\(name): \(frames) frames, \(dalnok_media_channels(media)) ch, peak \(String(format: "%.3f", peaks.max() ?? 0)); per second: " + peaks.map { String(format: "%.2f", $0) }.joined(separator: " "))
        }
        guard result.audio_clip_count == Int32(channels.count) else { fail("expected \(channels.count) takes, placed \(result.audio_clip_count)") }
    }
    if let project = opt("--save") {
        guard dalnok_project_save(engine, project, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
        print("saved \(project)")
    }
    guard status == DALNOK_OK else { fail(cstr(err)) }
    print("record: PASS")

case "latency":
    // dalnok-cli latency <input-device> <channel> [--output <name|default>]: loopback round-trip measurement.
    guard args.count >= 3, let channel = Int32(args[2]), channel > 0 else { print(usage); leave(2) }
    var inputs = [DalnokInputDeviceInfo](repeating: DalnokInputDeviceInfo(), count: 64)
    let ni = Int(dalnok_input_devices(&inputs, 64))
    func str<T>(_ t: T) -> String { withUnsafeBytes(of: t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } }
    guard let device = inputs.prefix(min(ni, 64)).first(where: { str($0.name) == args[1] }) else { fail("input device not found") }
    guard let engine = dalnok_engine_create(device.sample_rate) else { fail("engine creation failed") }
    defer { dalnok_engine_destroy(engine) }
    var err = [CChar](repeating: 0, count: 1_024)
    var out = str(device.uid)
    if let name = opt("--output") {
        var list = [DalnokDeviceInfo](repeating: DalnokDeviceInfo(), count: 64)
        let n = Int(dalnok_output_devices(&list, 64))
        if name == "default" { out = "" }
        else if let d = list.prefix(min(n, 64)).first(where: { str($0.name) == name }) { out = str(d.uid) }
        else { fail("output device not found") }
    }
    guard dalnok_engine_set_output_device(engine, out, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    guard dalnok_latency_measure_start(engine, str(device.uid), channel - 1, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    var r = DalnokLatencyResult()
    while !dalnok_latency_measure_poll(engine, &r) { Thread.sleep(forTimeInterval: 0.05) }
    let ms = { (f: Int64) in String(format: "%.2f ms", Double(f) / device.sample_rate * 1000) }
    print("measured \(r.measured_frames) frames (\(ms(r.measured_frames))); reported \(r.reported_frames) (\(ms(r.reported_frames))); difference \(r.measured_frames - r.reported_frames); \(r.clicks) clicks, spread \(r.spread_frames), level \(r.level)")
    guard r.ok else { fail(str(r.error)) }
    print("latency: PASS")

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
    if failures > 0 { leave(1) }

case "midi-play":
    guard args.count >= 3, let source = Int32(args[1]), let seconds = Double(args[2]) else { print(usage); leave(2) }
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
    if args.contains("--json") { print(cstr(buf)); break }
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
    leave(ok ? 0 : 1)

case "render":
    guard args.count >= 3 else { print(usage); leave(2) }
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
    guard args.count == 3 else { print(usage); leave(2) }
    var frames: UInt64 = 0, trailing: UInt32 = 0
    var err = [CChar](repeating: 0, count: 512)
    guard dalnok_capture_recover_wav(args[1], args[2], &frames, &trailing, &err, err.count) == DALNOK_OK else { fail(cstr(err)) }
    print("recovered \(frames) frames; omitted \(trailing) incomplete trailing bytes; source preserved")

case "dirty-check":
    // Opens a project, runs live blocks with the transport stopped and then playing (no device), and reports whether
    // it became dirty and which tracks changed: finds plug-ins that report edits nobody made.
    let engine = openProject(args[1])
    var tracks: [(DalnokTrackId, UInt64)] = []
    for i in 0..<dalnok_track_count(engine) { let t = dalnok_track_at(engine, i); tracks.append((t, dalnok_track_revision(engine, t))) }
    var l = [Float](repeating: 0, count: 512), r = l
    func report(_ phase: String) {
        let changed = tracks.filter { dalnok_track_revision(engine, $0.0) != $0.1 }.map { t -> String in
            var info = DalnokPluginSlotInfo(), names: [String] = []
            for j in 0..<dalnok_track_plugin_count(engine, t.0) where dalnok_track_plugin_info(engine, t.0, j, &info) == DALNOK_OK {
                let err = withUnsafeBytes(of: info.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                names.append(withUnsafeBytes(of: info.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } +
                             (info.loaded ? "" : " (not loaded: \(err))"))
            }
            return "track \(t.0) [\(names.joined(separator: ", "))]"
        }
        print("\(phase): dirty \(dalnok_project_dirty(engine)); changed: \(changed.isEmpty ? "none" : changed.joined(separator: "; "))")
    }
    print("opened: dirty \(dalnok_project_dirty(engine))")
    for (t, _) in tracks {
        var info = DalnokPluginSlotInfo()
        for j in 0..<dalnok_track_plugin_count(engine, t) where dalnok_track_plugin_info(engine, t, j, &info) == DALNOK_OK && !info.loaded {
            print("  track \(t): \(withUnsafeBytes(of: info.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) not loaded: \(withUnsafeBytes(of: info.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })")
        }
    }
    for _ in 0..<300 { _ = dalnok_engine_pump(engine, &l, &r, 512); usleep(10_000) }
    report("stopped 3 s")
    dalnok_transport_play(engine)
    for _ in 0..<40 { _ = dalnok_engine_pump(engine, &l, &r, 512); usleep(10_000) }
    report("playing 0.4 s")
    dalnok_engine_destroy(engine)
    leave(0)

case "load-bench":
    // Opens a project as the app does (prepare, deferred apply, then activate_next until every plug-in has loaded) and
    // reports how long that took, the slowest single activate call (what the main thread would block for), failures and
    // memory; then plays live blocks paced like a device and reports the slowest block and isolated plug-ins' misses.
    // DALNOK_PLUGIN_HOST=<dalnok-plughost> isolates plug-ins (ADR-0014), as Settings ▸ Plug-ins ▸ Safety does.
    guard args.count >= 2 else { print(usage); leave(2) }
    let playSeconds = Double(opt("--play") ?? "10") ?? 10
    let engine = dalnok_engine_create(48_000)!
    if let host = ProcessInfo.processInfo.environment["DALNOK_PLUGIN_HOST"] { dalnok_plugins_set_host(engine, host) }
    var err = [CChar](repeating: 0, count: 512)
    var missing: Int32 = 0
    var data: OpaquePointer?
    let t0 = Date()
    guard dalnok_project_prepare(args[1], 48_000, &data, &missing, &err, 512) == DALNOK_OK else { fail(cstr(err)) }
    let prepared = Date().timeIntervalSince(t0)
    guard dalnok_project_apply_deferred(engine, data) == DALNOK_OK else { fail("apply failed") }
    var worstCall = 0.0, calls = 0, slowest = (slot: Int32(0), seconds: 0.0)
    let start = Date()
    while true {
        var slot: Int32 = 0, seconds = 0.0
        let c0 = Date()
        let left = dalnok_plugins_activate_next(engine, &slot, &seconds)
        worstCall = max(worstCall, Date().timeIntervalSince(c0)); calls += 1
        if slot != 0 && seconds > slowest.seconds { slowest = (slot, seconds) }
        if ProcessInfo.processInfo.environment["DALNOK_LOAD_BENCH_TRACE"] != nil, Date().timeIntervalSince(c0) > 0.05 {
            print(String(format: "  call %d took %.0f ms (slot finished %d, init %.2f s, %d left)", calls, Date().timeIntervalSince(c0) * 1000, slot, seconds, left))
        }
        if left < 0 || (left == 0 && dalnok_plugins_pending(engine) == 0) { break }
        if Date().timeIntervalSince(start) > 300 { print("timeout: \(left) still loading"); break }
        usleep(1_000) // the app returns to its run loop between calls
    }
    let loadedIn = Date().timeIntervalSince(start)
    var total = 0, loaded = 0, isolated = 0, failures: [String] = []
    var slots: [Int32] = []
    for i in 0..<dalnok_track_count(engine) {
        let t = dalnok_track_at(engine, i)
        var info = DalnokPluginSlotInfo()
        for j in 0..<dalnok_track_plugin_count(engine, t) where dalnok_track_plugin_info(engine, t, j, &info) == DALNOK_OK {
            total += 1; if info.loaded { loaded += 1 }; if info.isolated { isolated += 1; slots.append(info.id) }
            if !info.loaded { failures.append(withUnsafeBytes(of: info.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }) }
        }
    }
    var rusage = rusage(); getrusage(RUSAGE_SELF, &rusage)
    print(String(format: "LOAD prepare %.2f s, plug-ins %.2f s (%d calls, worst call %.1f ms, slowest plug-in %.2f s); %d/%d loaded, %d isolated; dirty %@; peak RSS %.0f MB",
                 prepared, loadedIn, calls, worstCall * 1000, slowest.seconds, loaded, total, isolated,
                 dalnok_project_dirty(engine) ? "yes" : "no", Double(rusage.ru_maxrss) / 1_048_576))
    for f in Set(failures) { print("  not loaded: \(f)") }
    // Live blocks paced at the device rate (no device), transport playing.
    var l = [Float](repeating: 0, count: 512), r = l
    let period = 512.0 / 48_000
    dalnok_transport_play(engine)
    var worstBlock = 0.0, over = 0, blocks = 0, sum = 0.0
    let playStart = Date()
    let trace = ProcessInfo.processInfo.environment["DALNOK_LOAD_BENCH_TRACE"] != nil
    var seen: [Int32: (UInt64, UInt64)] = [:]
    while Date().timeIntervalSince(playStart) < playSeconds {
        let b0 = Date()
        _ = dalnok_engine_pump(engine, &l, &r, 512)
        let took = Date().timeIntervalSince(b0)
        worstBlock = max(worstBlock, took); blocks += 1; sum += took; if took > period { over += 1 }
        if took > period, ProcessInfo.processInfo.environment["DALNOK_LOAD_BENCH_TRACE"] != nil {
            print(String(format: "  block %d took %.1f ms", blocks, took * 1000))
        }
        if trace {
            for s in slots {
                var st = DalnokPluginIsolationStats()
                guard dalnok_plugin_isolation_stats(engine, s, &st) == DALNOK_OK else { continue }
                let was = seen[s] ?? (0, 0)
                if st.missed_blocks != was.0 || st.budget_skips != was.1 {
                    print(String(format: "  block %d (%.2f ms): slot %d missed +%llu, skips +%llu", blocks, took * 1000, s,
                                 st.missed_blocks - was.0, st.budget_skips - was.1))
                    seen[s] = (st.missed_blocks, st.budget_skips)
                }
            }
        }
        if blocks % 64 == 0 { dalnok_engine_collect_garbage(engine) }
        let rest = period - Date().timeIntervalSince(b0)
        // Run the main run loop while waiting, as the app does: plug-ins schedule main-thread work (timers, script
        // services) that changes what their audio thread does.
        if rest > 0 { CFRunLoopRunInMode(.defaultMode, rest, false) }
    }
    var missed: UInt64 = 0, skips: UInt64 = 0
    for s in slots {
        var st = DalnokPluginIsolationStats()
        if dalnok_plugin_isolation_stats(engine, s, &st) == DALNOK_OK { missed += st.missed_blocks; skips += st.budget_skips }
    }
    var failedNow: [String] = []
    for i in 0..<dalnok_track_count(engine) {
        let t = dalnok_track_at(engine, i)
        var info = DalnokPluginSlotInfo()
        for j in 0..<dalnok_track_plugin_count(engine, t) where dalnok_track_plugin_info(engine, t, j, &info) == DALNOK_OK && !info.loaded {
            failedNow.append(withUnsafeBytes(of: info.error) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        }
    }
    if failedNow.count > failures.count { print("FAILED DURING PLAY: \(failedNow.count - failures.count) (\(Set(failedNow).subtracting(failures).joined(separator: "; ")))") }
    print(String(format: "PLAY %d blocks, mean %.2f ms, worst %.2f ms of %.2f ms, %d over the period; isolated missed %llu, budget skips %llu; dirty %@",
                 blocks, sum / Double(max(blocks, 1)) * 1000, worstBlock * 1000, period * 1000, over, missed, skips, dalnok_project_dirty(engine) ? "yes" : "no"))
    dalnok_engine_destroy(engine)
    leave(0)

case "preview-check":
    // Auditions a note on a track (dalnok_track_preview_note) with the transport stopped and reports the output peak.
    let engine = openProject(args[1])
    let track = DalnokTrackId(Int32(args.count > 2 ? args[2] : "1") ?? 1), pitch = UInt8(Int(args.count > 3 && !args[3].hasPrefix("-") ? args[3] : "60") ?? 60)
    var l = [Float](repeating: 0, count: 512), r = l
    func peak(_ blocks: Int) -> Float {
        var m: Float = 0
        for _ in 0..<blocks { _ = dalnok_engine_pump(engine, &l, &r, 512); m = max(m, l.map(abs).max() ?? 0, r.map(abs).max() ?? 0); usleep(10_000) }
        return m
    }
    if args.contains("--device") {
        // The real output device: time from note-on to the first level on the track's meter (polled every 2 ms).
        var err = [CChar](repeating: 0, count: 256)
        guard dalnok_engine_start_device(engine, &err, 256) == DALNOK_OK else { fail(cstr(err)) }
        usleep(1_000_000)
        if args.contains("--warm") { _ = dalnok_track_preview_note(engine, track, 0, 0, false); usleep(500_000) }
        for round in 1...3 {
            var ml: Float = 0, mr: Float = 0
            _ = dalnok_meter_track(engine, track, &ml, &mr)
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = dalnok_track_preview_note(engine, track, pitch, 100, true)
            var first = -1.0
            while DispatchTime.now().uptimeNanoseconds - t0 < 1_500_000_000 {
                _ = dalnok_meter_track(engine, track, &ml, &mr)
                if first < 0 && max(ml, mr) > 0.001 { first = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
                usleep(2_000)
            }
            _ = dalnok_track_preview_note(engine, track, pitch, 0, false)
            print(String(format: "device round %d: first level after %.1f ms", round, first))
            usleep(1_000_000)
        }
        dalnok_engine_stop_device(engine)
        leave(0)
    }
    if args.contains("--warm") { _ = dalnok_track_preview_note(engine, track, 0, 0, false) } // what opening the piano roll does
    let before = peak(50)
    for round in 1...3 {
        let st = dalnok_track_preview_note(engine, track, pitch, 100, true)
        let held = peak(50)
        _ = dalnok_track_preview_note(engine, track, pitch, 0, false)
        let after = peak(100)
        print(String(format: "preview %d track %d pitch %d: status %d, peak before %.4f, held %.4f, after release %.4f", round, track, pitch, st.rawValue, before, held, after))
    }
    dalnok_engine_destroy(engine)
    leave(0)

case "render-project":
    guard args.count >= 3 else { print(usage); leave(2) }
    let engine = openProject(args[1])
    var err = [CChar](repeating: 0, count: 512)
    let frames = dalnok_session_length(engine)
    guard frames > 0 else { fail("project is empty") }
    guard dalnok_render_to_wav(engine, args[2], 0, frames, Int32(opt("--bits") ?? "24") ?? 24, &err, 512) == DALNOK_OK
    else { fail(cstr(err)) }
    print("rendered \(frames) frames to \(args[2])")
    dalnok_engine_destroy(engine)

case "export-dawproject":
    guard args.count >= 3 else { print(usage); leave(2) }
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
    guard args.count >= 3 else { print(usage); leave(2) }
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
    leave(st == DALNOK_OK ? 0 : 1)

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
    guard args.count >= 2 else { print(usage); leave(2) }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("Dalnok")
    let process = Process()
    process.executableURL = executable
    process.arguments = [args[1], "--uiwalk", NSTemporaryDirectory(), "--no-welcome"]
    var environment = ProcessInfo.processInfo.environment
    environment["DALNOK_AUDIT_UI"] = "1"
    environment["DALNOK_RECOVERY_DIR"] = NSTemporaryDirectory() + "dalnok-audit-recovery-" + UUID().uuidString
    process.environment = environment
    do { try process.run(); process.waitUntilExit() } catch { fail("AppKit audit launch failed: \(error)") }
    if process.terminationStatus != 0 { leave(process.terminationStatus) }

case "audit-bench":
    // Audit instrumentation only (docs/audits): measures what the app pays per model read and per edit on a
    // real project. It adds no engine or app behaviour; it only calls the public C API.
    guard args.count >= 2 else { print(usage); leave(2) }
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

case "stream-bench":
    // A-09 measurement: dalnok-cli stream-bench <file.wav> --mode memory|stream [--seconds S]. Loads one long file into a
    // track (in memory, or streamed through the block cache) and plays S seconds of it through the live path at about 4x
    // real time, reporting resident memory, load time and frames missed. Run once per mode, in separate processes.
    guard args.count > 1 else { print("usage: dalnok-cli stream-bench <file.wav> --mode memory|stream [--seconds S]"); leave(2) }
    func rss() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    let streamMode = opt("--mode") == "stream"
    let seconds = Double(opt("--seconds") ?? "60") ?? 60
    dalnok_stream_set_limits(streamMode ? 60 : 1e9, 256)
    let rssStart = rss()
    let t0 = DispatchTime.now().uptimeNanoseconds
    var media: OpaquePointer?
    var err = [CChar](repeating: 0, count: 512)
    guard dalnok_media_load(args[1], 48_000, &media, &err, 512) == DALNOK_OK, let media else { print("load failed: \(String(cString: err))"); leave(1) }
    let loadSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
    let engine = dalnok_engine_create(48_000)!
    let track = dalnok_track_add(engine, "Long")
    _ = dalnok_clip_add(engine, track, dalnok_pool_add(engine, media, args[1]), 0, 0, 0)
    let mediaFrames = dalnok_media_frames(media)
    dalnok_media_release(media)
    let rssLoaded = rss()
    var s0 = DalnokStreamStats(); dalnok_stream_stats(&s0)
    dalnok_transport_play(engine)
    var l = [Float](repeating: 0, count: 512), r = l, peak = rssLoaded
    let blocks = Int(seconds * 48_000 / 512)
    for i in 0..<blocks {
        _ = dalnok_engine_pump(engine, &l, &r, 512)
        if i % 4 == 0 { usleep(10_000) } // 4 blocks (42.7 ms of audio) per 10 ms: about 4x real time
        if i % 200 == 0 { peak = max(peak, rss()) }
    }
    // Then a jump to the middle of the file and another 10 s.
    dalnok_transport_seek(engine, mediaFrames / 2)
    for i in 0..<(48_000 * 10 / 512) { _ = dalnok_engine_pump(engine, &l, &r, 512); if i % 4 == 0 { usleep(10_000) } }
    peak = max(peak, rss())
    var s1 = DalnokStreamStats(); dalnok_stream_stats(&s1)
    print(String(format: "stream-bench %@: %.1f min file, load %.2f s, RSS start %.1f MB, after load %.1f MB, peak while playing %.1f MB; stream cache %.1f MB, missed %llu frames, blocks loaded %llu",
                 streamMode ? "stream" : "memory", Double(mediaFrames) / 48_000 / 60, loadSeconds, rssStart, rssLoaded, peak,
                 Double(s1.resident_bytes) / 1_048_576, s1.missed_frames - s0.missed_frames, s1.blocks_loaded - s0.blocks_loaded))
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
    // --audible N: only the first N tracks play during the measured range; the others' clips start after it, as
    // later sections of a song would (A-11).
    let audible = Int(opt("--audible") ?? "") ?? tracks
    if ProcessInfo.processInfo.environment["DALNOK_SCALAR_MIX"] != nil { dalnok_debug_set_scalar_mix(true) } // A-13 comparison
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
        let c = dalnok_clip_add(engine, tr, id, t < audible ? 0 : Int64(frames) + 48_000, 0, 0)
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
    print(String(format: "live path: %d tracks (%d audible), %d blocks of 512 frames: avg %.1f us, worst %.1f us (budget %.0f us, %.1f%% avg load)",
                 tracks, min(audible, tracks), blocks, total / Double(blocks), worst, budget, total / Double(blocks) / budget * 100))
    var ol = [Float](repeating: 0, count: frames), or = ol
    let t0 = Date()
    dalnok_render_offline(engine, 0, Int64(frames), &ol, &or)
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "offline: %.0f s of %d tracks (%d audible) in %.0f ms (%.0fx realtime)", seconds, tracks, min(audible, tracks), dt * 1000, seconds / dt))
    dalnok_engine_destroy(engine)

default:
    print(usage)
    leave(2)
}
leave(0)

func clipStart(_ e: OpaquePointer, _ clip: DalnokClipId) -> Int64 {
    var info = DalnokClipInfo()
    return dalnok_clip_info(e, clip, &info) == DALNOK_OK ? info.start : -1
}
