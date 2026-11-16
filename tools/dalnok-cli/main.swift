// dalnok-cli — headless driver for smoke tests, benchmarks, and batch work.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation

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
  dalnok-cli command <project.dalnok> <command> [args-json] [--save]   run a catalog command
  dalnok-cli commands                                                  list the command catalog
  dalnok-cli bench [--tracks N] [--seconds S]                          render-cost benchmark (no device)
  dalnok-cli import <project.rpp|.als|.logicx|.fcpxml|stems-folder> [--save out.dalnok] [--render out.wav] [--quiet]
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first, args.count >= 2 || cmd == "commands" || cmd == "bench" else { print(usage); exit(2) }

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
