// Hostile input files: the engine must stay finite and bounded.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct HostileImport {
    @Test func deeplyNestedReaperBlocksAreRejectedNotCrashed() throws {
        let p = tempDir().appendingPathComponent("deep.rpp")
        try String(repeating: "<TRACK\n", count: 50_000).write(to: p, atomically: true, encoding: .utf8)
        #expect(throws: EngineErr.self) { try importInto(p.path) }
    }
}

@Suite struct HostileCommands {
    @Test func emptyOrRepeatedTakeFolderIsRejected() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([[Float](repeating: 0.1, count: 1_000)]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A")
        let c = dalnok_clip_add(e, t, m, 0, 0, 0)
        #expect(runCommand(e, "takes.makeFolder", "{\"track\":\(t)}").0 != DALNOK_OK, "no clips: would save a project that cannot reload")
        #expect(runCommand(e, "takes.makeFolder", "{\"track\":\(t),\"clips\":[\(c),\(c)]}").0 != DALNOK_OK)
        #expect(runCommand(e, "takes.makeFolder", "{\"track\":\(t),\"clips\":[\(c)]}").0 == DALNOK_OK)
    }

    @Test func moveClipRejectsEndOverflow() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([[Float](repeating: 0.1, count: 1_000)]); defer { dalnok_media_release(m) }
        let c = dalnok_clip_add(e, dalnok_track_add(e, "A"), m, 0, 0, 0)
        let (st, _) = runCommand(e, "clip.move", "{\"clip\":\(c),\"start\":9223372036854775807}")
        #expect(st != DALNOK_OK)
        #expect(clipInfo(e, c).start == 0, "clip stays where it was")
        #expect(runCommand(e, "clip.move", "{\"clip\":\(c),\"start\":5000}").0 == DALNOK_OK)
    }

    @Test func outOfRangeValuesAreErrorsNotClamps() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([[Float](repeating: 0.1, count: 1_000)]); defer { dalnok_media_release(m) }
        let t = dalnok_track_add(e, "A")
        let c = dalnok_clip_add(e, t, m, 0, 0, 0)
        let bad = [("track.setVolume", "{\"track\":\(t),\"db\":1e9}"), ("track.setVolume", "{\"track\":\(t),\"db\":12.5}"),
                   ("master.setGain", "{\"db\":1e30}"), ("clip.setGain", "{\"clip\":\(c),\"db\":25}"),
                   ("track.setPan", "{\"track\":\(t),\"pan\":2}"), ("transport.seek", "{\"frame\":-1}"),
                   ("transport.seek", "{\"seconds\":1e300}"),
                   ("clip.setFades", "{\"clip\":\(c),\"fadeIn\":800,\"fadeOut\":800}")]
        for (name, args) in bad { #expect(runCommand(e, name, args).0 == DALNOK_ERR_INVALID_ARG, "\(name) \(args)") }
        let good = [("track.setVolume", "{\"track\":\(t),\"db\":12}"), ("track.setVolume", "{\"track\":\(t),\"db\":-200}"),
                    ("master.setGain", "{\"db\":-6}"), ("clip.setGain", "{\"clip\":\(c),\"db\":24}"),
                    ("track.setPan", "{\"track\":\(t),\"pan\":-1}"), ("transport.seek", "{\"frame\":0}"),
                    ("clip.setFades", "{\"clip\":\(c),\"fadeIn\":500,\"fadeOut\":500}")]
        for (name, args) in good { #expect(runCommand(e, name, args).0 == DALNOK_OK, "\(name) \(args)") }
    }
}

@Suite struct HostileAudio {
    /// Mono 32-bit float WAV from raw samples.
    func floatWav(_ s: [Float], rate: Int = 48_000) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + s.count * 4); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1); u32(rate); u32(rate * 4); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(s.count * 4)
        for v in s { var b = v.bitPattern.littleEndian; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) } }
        return d
    }

    @Test func nonFiniteSamplesNeverReachTheMix() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nan.wav")
        let src: [Float] = [0.5, .nan, .infinity, -.infinity, 1e38, -0.25, .nan, 0.1] + [Float](repeating: 0.25, count: 56)
        try floatWav(src).write(to: url)
        var m: OpaquePointer?
        var err = [CChar](repeating: 0, count: 256)
        try #require(dalnok_media_load(url.path, 48_000, &m, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let e = dalnok_engine_create(48_000)!
        defer { dalnok_media_release(m); dalnok_engine_destroy(e) }
        dalnok_clip_add(e, dalnok_track_add(e, "A"), m!, 0, 0, 0)
        let (l, r) = render(e, frames: 64)
        for v in l + r { #expect(v.isFinite && abs(v) <= 1_000.01, "sample \(v)") }
        #expect(abs(l[63] - 0.25) < 0.05, "ordinary samples survive")
    }
}

@Suite struct ExportDither {
    @Test func sixteenBitExportDithersAndKeepsSilenceSilent() throws {
        // A 1 kHz sine of 0.4 LSB at 16 bits: rounding alone writes zeros (the signal is gone); with TPDF dither it
        // survives as noise whose correlation with the sine gives back about 0.4 LSB.
        let lsb: Float = 1 / 32768, n = 48_000
        let sine = (0..<n).map { i -> Float in i < 24_000 ? 0.4 * lsb * sin(2 * .pi * 1_000 * Float(i) / 48_000) : 0 }
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let m = makeMedia([sine]); defer { dalnok_media_release(m) }
        _ = dalnok_clip_add(e, dalnok_track_add(e, "S"), m, 0, 0, 0)
        let path = tempDir().appendingPathComponent("d16.wav").path
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_render_to_wav(e, path, 0, Int64(n), 16, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var media: OpaquePointer?
        #expect(dalnok_media_load(path, 48_000, &media, &err, 256) == DALNOK_OK)
        let out = try #require(media); defer { dalnok_media_release(out) }
        let p = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(p) }
        _ = dalnok_clip_add(p, dalnok_track_add(p, "R"), out, 0, 0, 0)
        let (l, _) = render(p, frames: n)
        let ref = sine.map { $0 / (0.4 * lsb) } // unit sine
        var dot: Float = 0, refE: Float = 0
        for i in 0..<24_000 { dot += l[i] * ref[i]; refE += ref[i] * ref[i] }
        let amp = dot / refE / lsb
        #expect(amp > 0.3 && amp < 0.5, "recovered \(amp) LSB of 0.4")
        #expect(l[24_000..<n].allSatisfy { $0 == 0 }, "digital silence stays silent")
    }
}
