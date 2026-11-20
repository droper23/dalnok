// Streaming audio from disk (A-09): long files play from a bounded block cache, bit-exact with the same audio held in
// memory, offline and live. The stream limits are process-wide, so this suite sets them only around its own loads.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite(.serialized) struct Streaming {
    let dir = tempDir()

    /// A stereo 16-bit WAV with different, non-periodic content per channel.
    func stereoWav(seconds: Double, name: String) -> URL {
        let frames = Int(seconds * 48_000)
        var pcm = Data(capacity: frames * 4)
        var x: UInt32 = 12345
        for i in 0..<frames {
            x = x &* 1_103_515_245 &+ 12_345
            let l = Int16(truncatingIfNeeded: Int(x >> 16) % 20_000 - 10_000)
            let r = Int16(truncatingIfNeeded: (i * 7) % 16_000 - 8_000)
            for v in [l, r] { var le = v.littleEndian; withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) } }
        }
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(36 + pcm.count); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        d.append("data".data(using: .ascii)!); u32(pcm.count); d.append(pcm)
        let url = dir.appendingPathComponent(name)
        try! d.write(to: url)
        return url
    }

    /// Loads `url`, streamed (threshold 5 s) or held in memory (threshold beyond its length).
    func load(_ url: URL, streamed: Bool, cacheMB: Int32 = 256) -> OpaquePointer {
        setenv("DALNOK_STREAM_DIR", dir.appendingPathComponent("stream-cache").path, 1)
        dalnok_stream_set_limits(streamed ? 5 : 100_000, cacheMB)
        var m: OpaquePointer?
        #expect(dalnok_media_load(url.path, 48_000, &m, nil, 0) == DALNOK_OK)
        dalnok_stream_set_limits(60, 256)
        #expect(dalnok_media_streamed(m) == streamed)
        return m!
    }

    func engine(_ m: OpaquePointer, path: String) -> (OpaquePointer, DalnokClipId) {
        let e = dalnok_engine_create(48_000)!
        let t = dalnok_track_add(e, "Long")
        let c = dalnok_clip_add(e, t, dalnok_pool_add(e, m, path), 24_000, 1_000, 0)
        #expect(c != 0)
        return (e, c)
    }

    func stats() -> DalnokStreamStats { var s = DalnokStreamStats(); dalnok_stream_stats(&s); return s }

    @Test func streamedFileRendersBitExactAgainstMemory() throws {
        let url = stereoWav(seconds: 30, name: "long-a.wav")
        let mem = load(url, streamed: false), str = load(url, streamed: true)
        defer { dalnok_media_release(mem); dalnok_media_release(str) }
        #expect(dalnok_media_frames(mem) == dalnok_media_frames(str) && dalnok_media_frames(str) == 1_440_000)
        let (a, _) = engine(mem, path: url.path), (b, _) = engine(str, path: url.path)
        defer { dalnok_engine_destroy(a); dalnok_engine_destroy(b) }
        for (start, n) in [(0, 96_000), (700_000, 200_000), (1_400_000, 64_000)] {
            var al = [Float](repeating: 0, count: n), ar = al, bl = al, br = al
            #expect(dalnok_render_offline(a, Int64(start), Int64(n), &al, &ar) == DALNOK_OK)
            #expect(dalnok_render_offline(b, Int64(start), Int64(n), &bl, &br) == DALNOK_OK)
            #expect(al == bl && ar == br, "offline render of the streamed file is bit-exact at \(start)")
            #expect(al.contains { $0 != 0 } && ar.contains { $0 != 0 })
        }
        // Waveform peaks: the stored levels and close-up reads give the in-memory answers.
        for (c, fpc) in [(Int32(0), 4096.0), (1, 4096.0), (0, 37.5), (1, 3.0)] {
            var m1 = [Float](repeating: 0, count: 300), x1 = m1, m2 = m1, x2 = m1
            _ = dalnok_media_peaks(mem, c, 123_457, fpc, &m1, &x1, 300)
            _ = dalnok_media_peaks(str, c, 123_457, fpc, &m2, &x2, 300)
            if fpc >= 1024 {
                // Coarse levels start at different block sizes (64 vs 1,024 frames): the envelope matches within one block.
                #expect(zip(m1, m2).allSatisfy { $1 <= $0 + 1e-6 } && zip(x1, x2).allSatisfy { $1 >= $0 - 1e-6 }, "peaks cover the samples (ch \(c))")
            } else {
                #expect(m1 == m2 && x1 == x2, "close-up peaks equal (ch \(c), \(fpc) frames per column)")
            }
        }
    }

    @Test func livePlaybackReadsOnlyResidentBlocksAndStaysWithinBudget() throws {
        let url = stereoWav(seconds: 30, name: "long-b.wav")
        let mem = load(url, streamed: false)
        let str = load(url, streamed: true)
        defer { dalnok_media_release(mem); dalnok_media_release(str) }
        let (ref, _) = engine(mem, path: url.path); defer { dalnok_engine_destroy(ref) }
        let (e, _) = engine(str, path: url.path); defer { dalnok_engine_destroy(e) }
        dalnok_stream_set_limits(60, 2) // 2 MB: eight 32,768-frame stereo blocks, under a third of this file
        defer { dalnok_stream_set_limits(60, 256) }
        usleep(100_000) // the disk thread loads the clip's first blocks
        let before = stats()
        dalnok_transport_play(e)
        dalnok_transport_play(ref)
        var l = [Float](repeating: 0, count: 512), r = l, rl = l, rr = l
        var maxResident: UInt64 = 0, mismatched = 0, blocks = 0
        // 20 s of audio at about 5x real time: each 512-frame block is followed by a short pause, as a device would.
        for _ in 0..<1_875 {
            _ = dalnok_engine_pump(e, &l, &r, 512)
            _ = dalnok_engine_pump(ref, &rl, &rr, 512)
            if l != rl || r != rr { mismatched += 1 }
            blocks += 1
            maxResident = max(maxResident, stats().resident_bytes)
            usleep(2_000)
        }
        let after = stats()
        print(String(format: "STREAM live 20 s: missed %llu frames, loaded %llu blocks, evicted %llu, max resident %.1f MB (budget %.1f MB)",
                     after.missed_frames - before.missed_frames, after.blocks_loaded - before.blocks_loaded,
                     after.blocks_evicted - before.blocks_evicted, Double(maxResident) / 1e6, Double(after.budget_bytes) / 1e6))
        #expect(after.missed_frames == before.missed_frames, "every block was resident in time")
        #expect(mismatched == 0, "live output equals the in-memory engine block for block (\(mismatched) of \(blocks) differ)")
        #expect(after.blocks_evicted > before.blocks_evicted, "the file is longer than the budget, so blocks were evicted and reloaded")
        #expect(maxResident <= after.budget_bytes, "resident memory stays within the budget")
        // A seek far ahead: the first callbacks may miss blocks (played as silence, counted), then playback is exact again.
        dalnok_transport_seek(e, 1_200_000); dalnok_transport_seek(ref, 1_200_000)
        let seekStart = stats().missed_frames
        var exactAfter = 0
        for i in 0..<300 {
            _ = dalnok_engine_pump(e, &l, &r, 512)
            _ = dalnok_engine_pump(ref, &rl, &rr, 512)
            if i >= 100 && l == rl && r == rr { exactAfter += 1 }
            usleep(2_000)
        }
        print("STREAM seek: missed \(stats().missed_frames - seekStart) frames, then \(exactAfter) of 200 blocks exact")
        #expect(exactAfter == 200, "after the seek settles, output is exact again")
    }

    @Test func stretchedStreamedClipMatchesMemory() throws {
        let url = stereoWav(seconds: 12, name: "long-c.wav")
        let mem = load(url, streamed: false), str = load(url, streamed: true)
        defer { dalnok_media_release(mem); dalnok_media_release(str) }
        let (a, ca) = engine(mem, path: url.path), (b, cb) = engine(str, path: url.path)
        defer { dalnok_engine_destroy(a); dalnok_engine_destroy(b) }
        #expect(dalnok_clip_set_stretch(a, ca, 96_000, 0.5, 0, true) == DALNOK_OK)
        #expect(dalnok_clip_set_stretch(b, cb, 96_000, 0.5, 0, true) == DALNOK_OK)
        var al = [Float](repeating: 0, count: 120_000), ar = al, bl = al, br = al
        #expect(dalnok_render_offline(a, 0, 120_000, &al, &ar) == DALNOK_OK && dalnok_render_offline(b, 0, 120_000, &bl, &br) == DALNOK_OK)
        #expect(al == bl && ar == br && al.contains { $0 != 0 }, "a stretched streamed clip renders as the in-memory one")
    }

    @Test func cacheFileIsReusedAndProjectsReopenStreamed() throws {
        let url = stereoWav(seconds: 10, name: "long-d.wav")
        let first = load(url, streamed: true)
        let cache = dir.appendingPathComponent("stream-cache")
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".dlnkstream") }
        let t0 = Date()
        let second = load(url, streamed: true)
        let reopen = Date().timeIntervalSince(t0)
        defer { dalnok_media_release(first); dalnok_media_release(second) }
        let after = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".dlnkstream") }
        #expect(files.count == 1 && after == files, "loading the same file again reuses its cache file")
        print(String(format: "STREAM reuse: second load %.1f ms", reopen * 1000))
        // A saved project with the long file opens streamed (project prepare path) and renders the same.
        let (e, _) = engine(first, path: url.path); defer { dalnok_engine_destroy(e) }
        let project = dir.appendingPathComponent("streamed.dalnok").path
        #expect(dalnok_project_save(e, project, nil, 0) == DALNOK_OK)
        var reference = [Float](repeating: 0, count: 48_000), rr = reference
        #expect(dalnok_render_offline(e, 100_000, 48_000, &reference, &rr) == DALNOK_OK)
        setenv("DALNOK_STREAM_DIR", cache.path, 1)
        dalnok_stream_set_limits(5, 256)
        var data: OpaquePointer?
        var missing: Int32 = -1
        #expect(dalnok_project_prepare(project, 48_000, &data, &missing, nil, 0) == DALNOK_OK && missing == 0)
        dalnok_stream_set_limits(60, 256)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_apply(e2, data) == DALNOK_OK)
        var l = [Float](repeating: 0, count: 48_000), r = l
        #expect(dalnok_render_offline(e2, 100_000, 48_000, &l, &r) == DALNOK_OK)
        #expect(l == reference && r == rr, "the reopened project plays the streamed file identically")
    }
}
