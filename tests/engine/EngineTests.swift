// Engine correctness tests, exercised through the public C API.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

let sr = 48_000.0

func makeMedia(_ channels: [[Float]], rate: Double = sr) -> OpaquePointer {
    var ptrs: [UnsafePointer<Float>?] = []
    let copies = channels.map { ch -> UnsafeMutablePointer<Float> in
        let p = UnsafeMutablePointer<Float>.allocate(capacity: ch.count)
        p.initialize(from: ch, count: ch.count)
        return p
    }
    defer { copies.forEach { $0.deallocate() } }
    ptrs = copies.map { UnsafePointer($0) }
    return ptrs.withUnsafeBufferPointer {
        dalnok_media_from_samples($0.baseAddress, Int32(channels.count), Int64(channels[0].count), rate)!
    }
}

func render(_ e: OpaquePointer, start: Int64 = 0, frames: Int) -> ([Float], [Float]) {
    var l = [Float](repeating: .nan, count: frames), r = l
    #expect(dalnok_render_offline(e, start, Int64(frames), &l, &r) == DALNOK_OK)
    return (l, r)
}

func ramp(_ n: Int, scale: Float = 1) -> [Float] { (0..<n).map { scale * Float($0 % 97) / 97 - 0.4 } }

func expectClose(_ a: [Float], _ b: [Float], tol: Float, _ what: Comment) {
    #expect(a.count == b.count)
    let diffs = zip(a, b).map { abs($0 - $1) }
    let worst = diffs.max() ?? 0
    if worst > tol, let i = diffs.firstIndex(where: { $0 > tol }) {
        print("DEBUG first bad index \(i) got \(a[i]) want \(b[i]); count bad \(diffs.filter { $0 > tol }.count)")
    }
    #expect(worst <= tol, "\(what) worst=\(worst)")
}

@Suite struct OfflineMix {
    @Test func monoClipAtCenterIsUnityAndPlacedCorrectly() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let src = ramp(10_000)
        let m = makeMedia([src]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A")
        #expect(dalnok_clip_add(e, t, m, 1_000, 2_000, 5_000) > 0)
        #expect(dalnok_session_length(e) == 6_000)
        let (l, r) = render(e, frames: 8_000)
        expectClose(Array(l[0..<1000]), [Float](repeating: 0, count: 1000), tol: 0, "silence before clip")
        expectClose(Array(l[1000..<6000]), Array(src[2000..<7000]), tol: 1e-6, "left = source region")
        expectClose(Array(r[1000..<6000]), Array(src[2000..<7000]), tol: 1e-6, "right = source region")
        expectClose(Array(l[6000...]), [Float](repeating: 0, count: 2000), tol: 0, "silence after clip")
    }

    @Test func gainInDecibels() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let src = ramp(4_096); let m = makeMedia([src]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A")
        _ = dalnok_clip_add(e, t, m, 0, 0, 0)
        #expect(dalnok_track_set_gain_db(e, t, -6.0206) == DALNOK_OK)
        let (l, _) = render(e, frames: 4_096)
        expectClose(l, src.map { $0 * 0.5 }, tol: 1e-5, "-6.02 dB halves amplitude")
        dalnok_track_set_gain_db(e, t, -120)
        #expect(render(e, frames: 512).0.allSatisfy { $0 == 0 }, "<= -96 dB is silence")
        dalnok_track_set_gain_db(e, t, 0); dalnok_track_set_mute(e, t, true)
        #expect(render(e, frames: 512).0.allSatisfy { $0 == 0 }, "mute")
    }

    @Test func monoPanIsCompensatedConstantPower() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let src = ramp(2_048); let m = makeMedia([src]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A"); _ = dalnok_clip_add(e, t, m, 0, 0, 0)
        dalnok_track_set_pan(e, t, -1)
        let (l, r) = render(e, frames: 2_048)
        expectClose(l, src.map { $0 * 2.0.squareRoot().f }, tol: 1e-3, "hard left = +3 dB")
        expectClose(r, [Float](repeating: 0, count: 2048), tol: 1e-4, "hard left silences right")
        dalnok_track_set_pan(e, t, 0.5)
        let (l2, r2) = render(e, frames: 2_048)
        let pl = l2.map { $0 * $0 }.reduce(0, +), pr = r2.map { $0 * $0 }.reduce(0, +)
        let p0 = src.map { $0 * $0 }.reduce(0, +)
        #expect(abs((pl + pr) / (2 * p0) - 1) < 1e-3, "total power constant across pan")
    }

    @Test func stereoPanIsBalance() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let a = ramp(2_048), b = ramp(2_048, scale: -0.5)
        let m = makeMedia([a, b]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "S"); _ = dalnok_clip_add(e, t, m, 0, 0, 0)
        expectClose(render(e, frames: 2_048).0, a, tol: 1e-6, "center: left untouched")
        dalnok_track_set_pan(e, t, 1)
        let (l, r) = render(e, frames: 2_048)
        expectClose(l, [Float](repeating: 0, count: 2048), tol: 0, "hard right: left silent")
        expectClose(r, b, tol: 1e-6, "hard right: right untouched")
    }

    @Test func tracksSumAndRemoveWorks() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let a = ramp(3_000), b = ramp(3_000, scale: 0.3)
        let ma = makeMedia([a]), mb = makeMedia([b]); defer { dalnok_media_release(ma); dalnok_media_release(mb) }
        let t1 = dalnok_track_add(e, "1"), t2 = dalnok_track_add(e, "2")
        _ = dalnok_clip_add(e, t1, ma, 0, 0, 0)
        let c2 = dalnok_clip_add(e, t2, mb, 0, 0, 0)
        expectClose(render(e, frames: 3_000).0, zip(a, b).map { $0 + $1 }, tol: 1e-6, "sum")
        #expect(dalnok_clip_remove(e, c2) == DALNOK_OK)
        expectClose(render(e, frames: 3_000).0, a, tol: 1e-6, "after clip removal")
        #expect(dalnok_track_remove(e, t1) == DALNOK_OK)
        #expect(render(e, frames: 3_000).0.allSatisfy { $0 == 0 })
        #expect(dalnok_track_remove(e, 999) == DALNOK_ERR_NOT_FOUND)
    }

    @Test func rejectsInvalidClips() {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([ramp(100)]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A")
        #expect(dalnok_clip_add(e, 42, m, 0, 0, 0) == 0, "unknown track")
        #expect(dalnok_clip_add(e, t, m, -1, 0, 0) == 0, "negative start")
        #expect(dalnok_clip_add(e, t, m, 0, 100, 0) == 0, "offset past end")
        #expect(dalnok_clip_add(e, t, m, 0, 50, 1_000) > 0, "length clamped")
        #expect(dalnok_session_length(e) == 50)
    }
}

@Suite struct Peaks {
    @Test(arguments: [1.0, 3.5, 64, 100, 300, 1_000, 5_000, 70_000])
    func matchesBruteForce(fpc: Double) {
        var g = SystemRandomNumberGenerator()
        let src = (0..<200_000).map { _ in Float.random(in: -1...1, using: &g) }
        let m = makeMedia([src]); defer { dalnok_media_release(m) }
        let cols = 40, start: Int64 = 1_234
        var mins = [Float](repeating: 9, count: cols), maxs = mins
        #expect(dalnok_media_peaks(m, 0, start, fpc, &mins, &maxs, Int64(cols)) == Int64(cols))
        for c in 0..<cols {
            let a = Int(start) + Int((Double(c) * fpc).rounded(.down))
            let e = min(src.count, max(a + 1, Int(start) + Int((Double(c + 1) * fpc).rounded(.down))))
            guard a < e else { #expect(mins[c] == 0 && maxs[c] == 0); continue }
            let slice = src[a..<e]
            // Pyramid levels may widen a column to block boundaries: the true
            // extremes must always be contained (never clipped).
            #expect(mins[c] <= slice.min()! && maxs[c] >= slice.max()!)
            if fpc < 64 { #expect(mins[c] == slice.min()! && maxs[c] == slice.max()!) }
        }
    }
}

@Suite struct FileIO {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dalnok-tests-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    @Test(arguments: [(Int32(32), Float(1e-7)), (Int32(24), Float(2.0 / 8_388_608)), (Int32(16), Float(2.0 / 32_768))] as [(Int32, Float)])
    func renderToWavRoundTrips(bits: Int32, tol: Float) throws {
        let e = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e) }
        let a = ramp(50_000, scale: 0.9), b = ramp(50_000, scale: -0.5)
        let m = makeMedia([a, b]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "S"); _ = dalnok_clip_add(e, t, m, 0, 0, 0)
        let path = dir.appendingPathComponent("out\(bits).wav").path
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_render_to_wav(e, path, 0, 50_000, bits, &err, 256) == DALNOK_OK, "\(cstr(err))")

        var loaded: OpaquePointer?
        #expect(dalnok_media_load(path, sr, &loaded, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let lm = try #require(loaded); defer { dalnok_media_release(lm) }
        #expect(dalnok_media_frames(lm) == 50_000)
        #expect(dalnok_media_channels(lm) == 2)

        let e2 = dalnok_engine_create(sr)!; defer { dalnok_engine_destroy(e2) }
        _ = dalnok_clip_add(e2, dalnok_track_add(e2, "R"), lm, 0, 0, 0)
        let (l, r) = render(e2, frames: 50_000)
        expectClose(l, a, tol: tol, "left round trip at \(bits)-bit")
        expectClose(r, b, tol: tol, "right round trip at \(bits)-bit")
    }

    @Test func loadResamplesToEngineRate() throws {
        // Independent writer: a 1 kHz sine, 16-bit mono PCM WAV at 44.1 kHz.
        let rate = 44_100, n = 44_100
        var pcm = Data()
        for i in 0..<n {
            var s = Int16(sin(2 * .pi * 1_000 * Double(i) / Double(rate)) * 16_000).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        let path = dir.appendingPathComponent("sine.wav")
        try wavFile(pcm16: pcm, rate: rate).write(to: path)

        var media: OpaquePointer?
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_media_load(path.path, 48_000, &media, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let m = try #require(media); defer { dalnok_media_release(m) }
        #expect(abs(dalnok_media_frames(m) - 48_000) <= 64, "1 s at 44.1k -> ~48000 frames")

        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        _ = dalnok_clip_add(e, dalnok_track_add(e, "A"), m, 0, 0, 0)
        let (l, _) = render(e, frames: 48_000)
        let crossings = zip(l.dropFirst(1_000), l.dropFirst(1_001)).prefix(46_000).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(Double(crossings) / (46_000.0 / 48_000.0) - 1_000) < 3, "pitch preserved: \(crossings)")
    }

    @Test func missingFileReportsError() {
        var media: OpaquePointer?
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_media_load("/nonexistent/x.wav", sr, &media, &err, 256) == DALNOK_ERR_IO)
        #expect(media == nil)
        #expect(!cstr(err).isEmpty)
    }
}

func wavFile(pcm16: Data, rate: Int) -> Data {
    var d = Data()
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm16.count); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(pcm16.count); d.append(pcm16)
    return d
}

extension Double { var f: Float { Float(self) } }

func cstr(_ a: [CChar]) -> String { String(decoding: a.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
