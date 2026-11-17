// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct CaptureRecovery {
    func little<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    @Test func convertsCompleteFramesAndPreservesSource() throws {
        let dir = tempDir(), input = dir.appendingPathComponent("take.raw"), output = dir.appendingPathComponent("take.wav")
        let samples: [Float] = [0.25, -0.5, 0.75, -1, -0.125, 0.5]
        var spool = Data("DLNCAP01".utf8)
        spool.append(contentsOf: little(UInt32(48_000)))
        spool.append(contentsOf: little(UInt32(2)))
        for sample in samples { spool.append(contentsOf: little(sample.bitPattern)) }
        spool.append(0xAA) // interrupted final frame
        try spool.write(to: input)
        var frames: UInt64 = 0, trailing: UInt32 = 0
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_capture_recover_wav(input.path, output.path, &frames, &trailing, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let inputAfter = try Data(contentsOf: input)
        #expect(frames == 3 && trailing == 1 && inputAfter == spool)
        var media: OpaquePointer?
        #expect(dalnok_media_load(output.path, 48_000, &media, &err, 256) == DALNOK_OK, "\(cstr(err))")
        guard let media else { return }
        defer { dalnok_media_release(media) }
        #expect(dalnok_media_frames(media) == 3 && dalnok_media_channels(media) == 2)
        for channel in 0..<2 {
            var mins = [Float](repeating: 0, count: 3), maxs = mins
            #expect(dalnok_media_peaks(media, Int32(channel), 0, 1, &mins, &maxs, 3) == 3)
            for frame in 0..<3 { #expect(abs(mins[frame] - samples[frame * 2 + channel]) < 0.000001) }
        }
        let originalOutput = try Data(contentsOf: output)
        #expect(dalnok_capture_recover_wav(input.path, output.path, &frames, &trailing, nil, 0) == DALNOK_ERR_IO)
        let outputAfter = try Data(contentsOf: output), inputAfterRetry = try Data(contentsOf: input)
        #expect(outputAfter == originalOutput && inputAfterRetry == spool)
    }

    @Test func rejectsMalformedAndUnsupportedSpools() throws {
        let dir = tempDir(), input = dir.appendingPathComponent("bad.raw"), output = dir.appendingPathComponent("out.wav")
        try Data("bad".utf8).write(to: input)
        #expect(dalnok_capture_recover_wav(input.path, output.path, nil, nil, nil, 0) == DALNOK_ERR_IO)
        #expect(!FileManager.default.fileExists(atPath: output.path))
        var spool = Data("DLNCAP01".utf8)
        spool.append(contentsOf: little(UInt32(48_000)))
        spool.append(contentsOf: little(UInt32(4)))
        try spool.write(to: input)
        #expect(dalnok_capture_recover_wav(input.path, output.path, nil, nil, nil, 0) == DALNOK_ERR_IO)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
