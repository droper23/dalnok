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
