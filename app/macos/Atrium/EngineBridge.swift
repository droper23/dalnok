// Swift wrappers over the engine's C API.
// SPDX-License-Identifier: GPL-3.0-or-later
import AtriumEngine
import Foundation

func cString(_ a: [CChar]) -> String {
    String(decoding: a.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

struct EngineError: Error, CustomStringConvertible { let description: String }

/// Decoded audio. Immutable after creation, so safe to share across threads.
final class AudioMedia: @unchecked Sendable {
    let handle: OpaquePointer
    let frames: Int64
    let channels: Int
    let name: String

    private init(handle: OpaquePointer, name: String) {
        self.handle = handle
        self.frames = atrium_media_frames(handle)
        self.channels = Int(atrium_media_channels(handle))
        self.name = name
    }
    deinit { atrium_media_release(handle) }

    static func load(url: URL, sampleRate: Double) throws -> AudioMedia {
        var out: OpaquePointer?
        var err = [CChar](repeating: 0, count: 512)
        guard atrium_media_load(url.path, sampleRate, &out, &err, 512) == ATRIUM_OK, let h = out else {
            throw EngineError(description: cString(err))
        }
        return AudioMedia(handle: h, name: url.deletingPathExtension().lastPathComponent)
    }

    func peaks(channel: Int, start: Int64, framesPerColumn: Double, count: Int,
               mins: inout [Float], maxs: inout [Float]) {
        if mins.count < count { mins = [Float](repeating: 0, count: count); maxs = mins }
        _ = atrium_media_peaks(handle, Int32(channel), start, framesPerColumn, &mins, &maxs, Int64(count))
    }
}

@MainActor
final class Engine {
    let handle: OpaquePointer
    let sampleRate: Double

    init() {
        handle = atrium_engine_create(0)
        sampleRate = atrium_engine_sample_rate(handle)
    }

    func startDevice() throws {
        var err = [CChar](repeating: 0, count: 512)
        guard atrium_engine_start_device(handle, &err, 512) == ATRIUM_OK else {
            throw EngineError(description: cString(err))
        }
    }

    func shutdown() {
        atrium_engine_stop_device(handle)
        atrium_engine_destroy(handle)
    }

    var isPlaying: Bool { atrium_transport_is_playing(handle) }
    var position: Int64 { atrium_transport_position(handle) }
    func play() { atrium_transport_play(handle) }
    func pause() { atrium_transport_pause(handle) }
    func seek(_ frame: Int64) { atrium_transport_seek(handle, max(0, frame)) }
    func collectGarbage() { atrium_engine_collect_garbage(handle) }

    func addTrack(_ name: String) -> AtriumTrackId { atrium_track_add(handle, name) }
    func setGain(_ t: AtriumTrackId, db: Float) { atrium_track_set_gain_db(handle, t, db) }
    func setPan(_ t: AtriumTrackId, _ pan: Float) { atrium_track_set_pan(handle, t, pan) }
    func setMute(_ t: AtriumTrackId, _ m: Bool) { atrium_track_set_mute(handle, t, m) }
    func addClip(_ t: AtriumTrackId, _ m: AudioMedia, start: Int64) -> AtriumClipId {
        atrium_clip_add(handle, t, m.handle, start, 0, 0)
    }
    var sessionLength: Int64 { atrium_session_length(handle) }

    func stats() -> AtriumStats {
        var s = AtriumStats()
        atrium_engine_stats(handle, &s)
        return s
    }
}
