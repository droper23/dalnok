// The render compiler (A-06: compilation moved out of Engine into RenderCompiler). Live snapshots reuse cached
// per-track content and delay lines; offline renders build fresh. Both must produce the same audio.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

struct RenderCompiler {
    /// A routed project (two sources into a bus, one by its output and one by a post-fader send, with gain, pan and
    /// clip gain) sounds the same through the live path (cached content, pumped like a device) as rendered offline.
    @Test func liveAndOfflineSnapshotsAgree() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var g = SystemRandomNumberGenerator()
        let noise = (0..<48_000).map { _ in Float.random(in: -0.5...0.5, using: &g) }
        let tone = (0..<48_000).map { Float(0.4 * sin(Double($0) * 2 * .pi * 220 / 48_000)) }
        let n = makeMedia([noise]), t = makeMedia([tone]); defer { dalnok_media_release(n); dalnok_media_release(t) }
        let nid = dalnok_pool_add(e, n, ""), tid = dalnok_pool_add(e, t, "")
        let a = dalnok_track_add(e, "A"), b = dalnok_track_add(e, "B"), bus = dalnok_track_add_bus(e, "Bus")
        DalnokEngine.dalnok_clip_add(e, a, nid, 0, 0, 0)
        DalnokEngine.dalnok_clip_add(e, b, tid, 0, 2_400, 0)
        #expect(dalnok_track_set_output(e, a, bus) == DALNOK_OK)
        #expect(dalnok_track_set_send(e, b, bus, -6, false) == DALNOK_OK)
        dalnok_track_set_gain_db(e, a, -3)
        dalnok_track_set_pan(e, b, 0.4)
        // Edit, undo and edit again so the live caches hold reused content.
        dalnok_track_set_gain_db(e, b, -2)
        _ = dalnok_undo(e)
        dalnok_track_set_gain_db(e, b, -1.5)
        #expect(dalnok_engine_snapshot_mismatches(e) == 0, "reused content equals a fresh build")
        let frames = 24_576
        let offline = renderStereo(e, frames)
        dalnok_transport_play(e)
        var live: ([Float], [Float]) = ([], [])
        var l = [Float](repeating: 0, count: 512), r = l
        while live.0.count < frames {
            _ = dalnok_engine_pump(e, &l, &r, 512)
            live.0 += l; live.1 += r
        }
        // Skip the play de-click ramp (5 ms) at the start of the live path.
        let skip = 1_024
        let worst = zip(offline.0[skip..<frames], live.0[skip..<frames]).map { abs($0 - $1) }.max() ?? 1
        let worstR = zip(offline.1[skip..<frames], live.1[skip..<frames]).map { abs($0 - $1) }.max() ?? 1
        let level = offline.0[skip..<frames].map(abs).max() ?? 0
        #expect(level > 0.1, "the project makes sound (peak \(level))")
        #expect(worst < 1e-6 && worstR < 1e-6, "live and offline agree (worst difference \(worst), \(worstR))")
    }
}
