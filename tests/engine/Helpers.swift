// Shared test helpers.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation

/// Convenience overload: pools `media` and places it (API v2 takes pool ids).
@discardableResult
func dalnok_clip_add(_ e: OpaquePointer, _ t: DalnokTrackId, _ m: OpaquePointer, _ start: Int64, _ offset: Int64,
                     _ length: Int64) -> DalnokClipId {
    DalnokEngine.dalnok_clip_add(e, t, dalnok_pool_add(e, m, nil), start, offset, length)
}

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("dalnok-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Writes a mono 16-bit WAV with deterministic content; returns its samples as floats.
@discardableResult
func writeTestWav(_ url: URL, frames: Int, rate: Int = 48_000, seed: Int = 1) throws -> [Float] {
    var pcm = Data()
    var out: [Float] = []
    for i in 0..<frames {
        let v = Int16((i * 37 + seed * 101) % 2_000 - 1_000) * 8
        out.append(Float(v) / 32_768)
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { pcm.append(contentsOf: $0) }
    }
    try wavFile(pcm16: pcm, rate: rate).write(to: url)
    return out
}

func clipInfo(_ e: OpaquePointer, _ c: DalnokClipId) -> DalnokClipInfo {
    var i = DalnokClipInfo()
    _ = dalnok_clip_info(e, c, &i)
    return i
}

func name<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

func runCommand(_ e: OpaquePointer, _ cmd: String, _ args: String = "{}") -> (DalnokStatus, [String: Any]) {
    var buf = [CChar](repeating: 0, count: 65_536)
    let st = dalnok_command_run(e, cmd, args, &buf, buf.count)
    let obj = (try? JSONSerialization.jsonObject(with: Data(cstr(buf).utf8))) as? [String: Any] ?? [:]
    return (st, obj)
}

func undoName(_ e: OpaquePointer) -> String {
    var b = [CChar](repeating: 0, count: 64)
    dalnok_undo_name(e, &b, 64)
    return cstr(b)
}
