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

    @Test func captureRequiresExplicitRunningDuplexDevice() {
        let engine = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(engine) }
        let spool = tempDir().appendingPathComponent("take.raw")
        var stats = DalnokCaptureStats()
        #expect(!dalnok_capture_active(engine))
        #expect(dalnok_capture_status(engine, &stats) == DALNOK_ERR_DEVICE)
        #expect(dalnok_capture_start(engine, "missing-device", 0, spool.path, nil, 0) == DALNOK_ERR_DEVICE)
        #expect(!FileManager.default.fileExists(atPath: spool.path))
        #expect(dalnok_capture_start(engine, "", -1, spool.path, nil, 0) == DALNOK_ERR_INVALID_ARG)
        #expect(dalnok_capture_stop(engine, &stats, nil, 0) == DALNOK_ERR_DEVICE)
        #expect(!dalnok_capture_active(engine))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DALNOK_TEST_DUPLEX"] != nil, "requires an explicitly selected duplex device"))
    func hardwareCapturePreservesFramesAndRejectsDeviceChanges() throws {
        let wanted = try #require(ProcessInfo.processInfo.environment["DALNOK_TEST_DUPLEX"])
        let count = dalnok_input_devices(nil, 0)
        var devices = [DalnokInputDeviceInfo](repeating: DalnokInputDeviceInfo(), count: Int(max(count, 0)))
        let current = devices.withUnsafeMutableBufferPointer { dalnok_input_devices($0.baseAddress, Int32($0.count)) }
        let device = try #require(devices.prefix(Int(max(0, min(count, current)))).first {
            withUnsafeBytes(of: $0.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == wanted
        })
        let uid = withUnsafeBytes(of: device.uid) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let engine = try #require(dalnok_engine_create(device.sample_rate))
        defer { dalnok_engine_destroy(engine) }
        var error = [CChar](repeating: 0, count: 512)
        try #require(dalnok_engine_set_output_device(engine, uid, &error, error.count) == DALNOK_OK, "\(cstr(error))")
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("existing.raw")
        let sentinel = Data("keep".utf8); try sentinel.write(to: existing)
        #expect(dalnok_capture_start(engine, uid, 0, existing.path, &error, error.count) != DALNOK_OK)
        #expect(try Data(contentsOf: existing) == sentinel)
        #expect(dalnok_engine_device_running(engine) && !dalnok_capture_active(engine))
        let spool = dir.appendingPathComponent("take.raw"), wav = dir.appendingPathComponent("take.wav")
        dalnok_transport_play(engine) // empty project: silent output, but the transport must continue
        try #require(dalnok_capture_start(engine, uid, 0, spool.path, &error, error.count) == DALNOK_OK, "\(cstr(error))")
        #expect(dalnok_capture_active(engine) && dalnok_engine_device_running(engine))
        #expect(dalnok_engine_set_output_device(engine, "", &error, error.count) == DALNOK_ERR_DEVICE)
        #expect(dalnok_capture_start(engine, uid, 0, dir.appendingPathComponent("other.raw").path, &error, error.count) == DALNOK_ERR_DEVICE)
        Thread.sleep(forTimeInterval: 0.5)
        var live = DalnokCaptureStats(), final = DalnokCaptureStats()
        #expect(dalnok_capture_status(engine, &live) == DALNOK_OK)
        try #require(dalnok_capture_stop(engine, &final, &error, error.count) == DALNOK_OK, "\(cstr(error))")
        #expect(!dalnok_capture_active(engine) && dalnok_engine_device_running(engine))
        #expect(final.captured_frames > 0 && final.captured_frames == final.written_frames && final.dropped_frames == 0)
        #expect(dalnok_transport_position(engine) > 0)
        dalnok_transport_pause(engine)
        var frames: UInt64 = 0, trailing: UInt32 = 0
        try #require(dalnok_capture_recover_wav(spool.path, wav.path, &frames, &trailing, &error, error.count) == DALNOK_OK, "\(cstr(error))")
        #expect(frames == final.captured_frames && trailing == 0)
        var media: OpaquePointer?
        try #require(dalnok_media_load(wav.path, device.sample_rate, &media, &error, error.count) == DALNOK_OK, "\(cstr(error))")
        defer { dalnok_media_release(media) }
        #expect(dalnok_media_frames(media) == Int64(frames) && dalnok_media_channels(media) == 1)
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
