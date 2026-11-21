// Model views (A-15): the C API's clip and track structs are generated from engine/api/views.def, and a track's clips
// are read in one pass (dalnok_track_clips) instead of clip by clip, which scanned the whole project per clip.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

struct ModelViews {
    /// 2,048 clips on one track: reading them through dalnok_track_clip_at + dalnok_clip_info + dalnok_clip_muted
    /// (the app's old path) and through dalnok_track_clips gives identical fields, and the batch read is far faster.
    @Test func batchClipReadMatchesAndIsFaster() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([[Float](repeating: 0.25, count: 480)]); defer { dalnok_media_release(m) }
        let media = dalnok_pool_add(e, m, "")
        let t = dalnok_track_add(e, "Many"), other = dalnok_track_add(e, "Other")
        let n = 2_048
        for k in 0..<n { DalnokEngine.dalnok_clip_add(e, k % 5 == 0 ? other : t, media, Int64(k) * 480, 0, 0) }
        let onTrack = Int32(n - (n + 4) / 5)
        var ti = DalnokTrackInfo()
        #expect(dalnok_track_info(e, t, &ti) == DALNOK_OK && ti.clip_count == onTrack)
        _ = dalnok_clip_set_muted(e, dalnok_track_clip_at(e, t, 3), true)

        func old() -> [DalnokClipInfo] {
            (0..<ti.clip_count).map { k in
                var ci = DalnokClipInfo(); _ = dalnok_clip_info(e, dalnok_track_clip_at(e, t, k), &ci)
                ci.muted = dalnok_clip_muted(e, ci.id)
                return ci
            }
        }
        func batch() -> [DalnokClipInfo] {
            var out = [DalnokClipInfo](repeating: DalnokClipInfo(), count: Int(ti.clip_count))
            let got = dalnok_track_clips(e, t, &out, ti.clip_count)
            #expect(got == ti.clip_count)
            return out
        }
        func time(_ f: () -> [DalnokClipInfo]) -> (Double, [DalnokClipInfo]) {
            var best = Double.infinity, result: [DalnokClipInfo] = []
            for _ in 0..<3 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                result = f()
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            return (best, result)
        }
        let (oldMs, a) = time(old), (newMs, b) = time(batch)
        print(String(format: "TRACKREAD %d clips on the track (%d in the project): clip by clip %.2f ms, one pass %.3f ms (%.0fx)",
                     onTrack, n, oldMs, newMs, oldMs / max(newMs, 1e-6)))
        #expect(a.count == b.count && zip(a, b).allSatisfy { x, y in
            x.id == y.id && x.track == y.track && x.media == y.media && x.start == y.start && x.offset == y.offset &&
            x.length == y.length && x.media_frames == y.media_frames && x.offline == y.offline && x.gain_db == y.gain_db &&
            x.rate == y.rate && x.midi == y.midi && x.slot == y.slot && x.alt == y.alt && x.muted == y.muted &&
            withUnsafeBytes(of: x.name) { Array($0) } == withUnsafeBytes(of: y.name) { Array($0) }
        }, "same fields, same order")
        #expect(b.filter(\.muted).count == 1 && b[3].muted, "clip mute comes with the batch")
        #expect(newMs * 10 < oldMs, "one pass is at least 10x faster (\(oldMs) vs \(newMs) ms)")
        #expect(dalnok_track_clips(e, t, nil, 0) == onTrack, "capacity 0 sizes the buffer")
        #expect(dalnok_track_clips(e, 9_999, nil, 0) == -1, "no such track")
    }

    /// Track hidden and output come with dalnok_track_info (the app read them with separate calls).
    @Test func trackInfoCarriesHiddenAndOutput() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Audio"), bus = dalnok_track_add_bus(e, "Bus")
        #expect(dalnok_track_set_output(e, t, bus) == DALNOK_OK)
        #expect(dalnok_track_set_hidden(e, t, true) == DALNOK_OK)
        var ti = DalnokTrackInfo()
        #expect(dalnok_track_info(e, t, &ti) == DALNOK_OK)
        #expect(ti.hidden && ti.output == bus && ti.hidden == dalnok_track_hidden(e, t) && ti.output == dalnok_track_output(e, t))
    }
}
