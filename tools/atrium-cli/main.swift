// atrium-cli — headless driver for smoke tests, benchmarks, and batch work.
// SPDX-License-Identifier: GPL-3.0-or-later
import AtriumEngine
import Foundation

func cstr(_ a: [CChar]) -> String { String(decoding: a.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
func fail(_ msg: String) -> Never { FileHandle.standardError.write(Data("error: \(msg)\n".utf8)); exit(1) }

func load(_ path: String, rate: Double) -> OpaquePointer {
    var m: OpaquePointer?
    var err = [CChar](repeating: 0, count: 512)
    let t0 = Date()
    guard atrium_media_load(path, rate, &m, &err, 512) == ATRIUM_OK, let media = m else { fail(cstr(err)) }
    let ms = Date().timeIntervalSince(t0) * 1000
    print(String(format: "loaded %@: %lld frames, %d ch @ %.0f Hz in %.1f ms", (path as NSString).lastPathComponent,
                 atrium_media_frames(media), atrium_media_channels(media), rate, ms))
    return media
}

let usage = """
usage:
  atrium-cli play <audio-file> [--seconds N] [--churn]   live playback on the default device
  atrium-cli render <audio-file> <out.wav> [--bits 16|24|32]
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first, args.count >= 2 else { print(usage); exit(2) }
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

switch cmd {
case "play":
    let seconds = Double(opt("--seconds") ?? "3") ?? 3
    let churn = args.contains("--churn")
    let engine = atrium_engine_create(0)!
    let rate = atrium_engine_sample_rate(engine)
    let media = load(args[1], rate: rate)
    let track = atrium_track_add(engine, "Track 1")
    _ = atrium_clip_add(engine, track, media, 0, 0, 0)

    var err = [CChar](repeating: 0, count: 512)
    guard atrium_engine_start_device(engine, &err, 512) == ATRIUM_OK else { fail("device: \(cstr(err))") }
    atrium_transport_play(engine)
    let start = Date()
    var churnOps = 0
    while Date().timeIntervalSince(start) < seconds {
        if churn {
            // Stress the snapshot handoff: structural edits while playing.
            let t = atrium_track_add(engine, "churn")
            _ = atrium_clip_add(engine, t, media, Int64(churnOps % 1000) * 64, 0, 4_096)
            atrium_track_remove(engine, t)
            churnOps += 1
            usleep(500)
        } else {
            usleep(20_000)
        }
        atrium_engine_collect_garbage(engine)
    }
    let wall = Date().timeIntervalSince(start)
    let pos = atrium_transport_position(engine)
    atrium_transport_pause(engine)
    usleep(50_000)
    var s = AtriumStats()
    atrium_engine_stats(engine, &s)
    atrium_engine_stop_device(engine)
    atrium_engine_collect_garbage(engine)

    let expected = wall * rate
    print(String(format: "played %.2f s wall; transport advanced %lld frames (%.2f%% of wall clock)", wall, pos,
                 Double(pos) / expected * 100))
    let budgetUs = Double(s.max_frames_per_callback) / rate * 1e6
    print(String(format: "callbacks %llu, max block %u frames (%.0f us budget), worst render %.1f us, overloads %u, snapshot swaps %u",
                 s.callbacks, s.max_frames_per_callback, budgetUs, Double(s.max_callback_ns) / 1000, s.overloads, s.snapshot_swaps))
    if churn { print("churn edits: \(churnOps)") }
    atrium_media_release(media)
    atrium_engine_destroy(engine)
    let ok = s.callbacks > 0 && abs(Double(pos) / expected - 1) < 0.05 && s.overloads == 0
    print(ok ? "RESULT: PASS" : "RESULT: FAIL")
    exit(ok ? 0 : 1)

case "render":
    guard args.count >= 3 else { print(usage); exit(2) }
    let bits = Int32(opt("--bits") ?? "24") ?? 24
    let engine = atrium_engine_create(48_000)!
    let media = load(args[1], rate: 48_000)
    _ = atrium_clip_add(engine, atrium_track_add(engine, "Track 1"), media, 0, 0, 0)
    var err = [CChar](repeating: 0, count: 512)
    let frames = atrium_session_length(engine)
    let t0 = Date()
    guard atrium_render_to_wav(engine, args[2], 0, frames, bits, &err, 512) == ATRIUM_OK else { fail(cstr(err)) }
    let dt = Date().timeIntervalSince(t0)
    print(String(format: "rendered %lld frames in %.1f ms (%.0fx realtime)", frames, dt * 1000,
                 Double(frames) / 48_000 / dt))
    atrium_media_release(media)
    atrium_engine_destroy(engine)

default:
    print(usage)
    exit(2)
}
