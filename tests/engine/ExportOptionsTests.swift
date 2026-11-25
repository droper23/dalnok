// Export options: another sample rate, peak and loudness normalization (offline renders, numeric tolerances).
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import DalnokEngine
import Foundation
import Testing

@Suite struct ExportOptions {
    /// An engine at 48 kHz playing a 1 kHz sine of `amp` for a second.
    func mix(_ amp: Double) -> OpaquePointer {
        let e = dalnok_engine_create(48_000)!
        let x = (0..<48_000).map { Float(amp * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        let m = makeMedia([x, x]); defer { dalnok_media_release(m) }
        DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "Sine"), dalnok_pool_add(e, m, ""), 0, 0, 0)
        return e
    }
    func export(_ e: OpaquePointer, _ name: String, rate: Double = 0, normalize: Int32 = 0, target: Double = 0) -> (String, Double, DalnokStatus, String) {
        let path = tempDir().appendingPathComponent(name).path
        var o = DalnokExportOptions(format: Int32(DALNOK_FORMAT_WAV32F.rawValue), sample_rate: rate, normalize: normalize, target: target)
        var gain = 0.0
        var err = [CChar](repeating: 0, count: 256)
        let s = dalnok_render_export(e, path, 0, 48_000, &o, 0, nil, &gain, &err, 256)
        return (path, gain, s, cstr(err))
    }
    func read(_ path: String) throws -> (rate: Double, left: [Float]) {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return (f.processingFormat.sampleRate, Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))))
    }
    func loudness(_ path: String) -> DalnokLoudness {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var m: OpaquePointer?
        _ = dalnok_media_load(path, 48_000, &m, nil, 0)
        DalnokEngine.dalnok_clip_add(e, dalnok_track_add(e, "F"), dalnok_pool_add(e, m, ""), 0, 0, 0)
        dalnok_media_release(m)
        var out = DalnokLoudness()
        _ = dalnok_render_loudness(e, 0, 48_000, &out, nil, 0)
        return out
    }

    @Test func sampleRateAndPeakNormalize() throws {
        let e = mix(0.25); defer { dalnok_engine_destroy(e) }
        let (path, gain, s, err) = export(e, "peak.wav", rate: 44_100, normalize: 1, target: -1)
        #expect(s == DALNOK_OK, "\(err)")
        let f = try read(path)
        #expect(f.rate == 44_100)
        #expect(abs(f.left.count - 44_100) <= 2, "\(f.left.count) frames")
        #expect(abs(frequency(f.left[4_410..<40_000], rate: 44_100) - 1_000) < 1, "\(frequency(f.left[4_410..<40_000], rate: 44_100)) Hz")
        let peak = f.left.map { abs($0) }.max()!
        #expect(abs(peak - 0.8913) < 0.005, "peak \(peak)")
        #expect(abs(gain - 20 * log10(0.8913 / 0.25)) < 0.02, "gain \(gain) dB")
        #expect(!FileManager.default.fileExists(atPath: path + ".dalnok-render.wav"), "the intermediate file is removed")
    }

    @Test func loudnessNormalizeWithTruePeakCeiling() throws {
        let e = mix(0.1); defer { dalnok_engine_destroy(e) }
        let (path, _, s, err) = export(e, "lufs.wav", normalize: 2, target: -14)
        #expect(s == DALNOK_OK, "\(err)")
        let l = loudness(path)
        #expect(abs(l.integrated - -14) < 0.2, "integrated \(l.integrated) LUFS")
        // A 1 kHz sine reads about its peak level in LUFS, so -0.5 LUFS would put its peak at -0.5 dBFS: held at -1 dBTP.
        let (loud, gain, s2, _) = export(e, "ceiling.wav", normalize: 2, target: -0.5)
        #expect(s2 == DALNOK_OK)
        let peak = try read(loud).left.map { abs($0) }.max()!
        #expect(peak < 0.8913 + 0.002 && peak > 0.85, "peak \(peak) under -1 dBTP")
        let reached = loudness(loud).integrated
        #expect(reached < -0.8 && reached > -1.5, "the ceiling won over the target: \(reached) LUFS (\(gain) dB)")
    }

    @Test func plainOptionsMatchTheOrdinaryExportAndBadOnesAreRefused() throws {
        let e = mix(0.5); defer { dalnok_engine_destroy(e) }
        let (a, gain, s, _) = export(e, "plain.wav")
        let b = tempDir().appendingPathComponent("ordinary.wav").path
        #expect(s == DALNOK_OK && gain == 0)
        #expect(dalnok_render_to_file(e, b, 0, 48_000, Int32(DALNOK_FORMAT_WAV32F.rawValue), 0, nil, nil, 0) == DALNOK_OK)
        #expect(try read(a).left == read(b).left)
        #expect(export(e, "bad1.wav", rate: 1_000).2 != DALNOK_OK)
        #expect(export(e, "bad2.wav", normalize: 1, target: 3).2 != DALNOK_OK)
        #expect(export(e, "bad3.wav", normalize: 7, target: -1).2 != DALNOK_OK)
        // Silence normalizes to itself (no gain, no error).
        let quiet = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(quiet) }
        _ = dalnok_track_add(quiet, "Empty")
        let (_, g, s3, err3) = export(quiet, "silent.wav", normalize: 1, target: -1)
        #expect(s3 == DALNOK_OK && g == 0, "\(err3)")
    }
}
