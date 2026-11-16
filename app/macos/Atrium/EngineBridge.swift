// Swift wrappers over the engine's C API.
// SPDX-License-Identifier: GPL-3.0-or-later
import AtriumEngine
import Foundation

func cString(_ a: [CChar]) -> String {
    String(decoding: a.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func fixedString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

struct EngineError: Error, CustomStringConvertible { let description: String }

/// Decoded audio owned by Swift until it is added to the engine's pool.
final class DecodedMedia: @unchecked Sendable {
    let handle: OpaquePointer
    let url: URL
    init(handle: OpaquePointer, url: URL) { self.handle = handle; self.url = url }
    deinit { atrium_media_release(handle) }

    static func load(url: URL, sampleRate: Double) throws -> DecodedMedia {
        var out: OpaquePointer?
        var err = [CChar](repeating: 0, count: 512)
        guard atrium_media_load(url.path, sampleRate, &out, &err, 512) == ATRIUM_OK, let h = out else {
            throw EngineError(description: cString(err))
        }
        return DecodedMedia(handle: h, url: url)
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

    // Transport
    var isPlaying: Bool { atrium_transport_is_playing(handle) }
    var position: Int64 { atrium_transport_position(handle) }
    func play() { atrium_transport_play(handle) }
    func pause() { atrium_transport_pause(handle) }
    func seek(_ frame: Int64) { atrium_transport_seek(handle, max(0, frame)) }
    func collectGarbage() { atrium_engine_collect_garbage(handle) }

    // Model
    var revision: UInt64 { atrium_model_revision(handle) }
    var sessionLength: Int64 { atrium_session_length(handle) }
    func poolAdd(_ m: DecodedMedia) -> AtriumMediaId { atrium_pool_add(handle, m.handle, m.url.path) }
    /// Borrowed; valid until the project is replaced.
    func poolMedia(_ id: AtriumMediaId) -> OpaquePointer? { atrium_pool_media(handle, id) }

    // Undo
    var canUndo: Bool { atrium_can_undo(handle) }
    var canRedo: Bool { atrium_can_redo(handle) }
    var undoName: String { var b = [CChar](repeating: 0, count: 128); atrium_undo_name(handle, &b, 128); return cString(b) }
    var redoName: String { var b = [CChar](repeating: 0, count: 128); atrium_redo_name(handle, &b, 128); return cString(b) }
    func undo() { atrium_undo(handle) }
    func redo() { atrium_redo(handle) }
    func group(_ name: String, _ body: () -> Void) {
        atrium_undo_begin_group(handle, name)
        body()
        atrium_undo_end_group(handle)
    }
    func beginGroup(_ name: String) { atrium_undo_begin_group(handle, name) }
    func endGroup() { atrium_undo_end_group(handle) }

    // Project
    var isDirty: Bool { atrium_project_dirty(handle) }
    func newProject() { atrium_project_new(handle) }
    func save(to url: URL) throws {
        var err = [CChar](repeating: 0, count: 512)
        guard atrium_project_save(handle, url.path, &err, 512) == ATRIUM_OK else { throw EngineError(description: cString(err)) }
    }
    /// Returns the number of offline (missing) media files.
    func load(from url: URL) throws -> Int {
        var err = [CChar](repeating: 0, count: 512)
        var missing: Int32 = 0
        guard atrium_project_load(handle, url.path, &missing, &err, 512) == ATRIUM_OK else {
            throw EngineError(description: cString(err))
        }
        return Int(missing)
    }
    func exportWav(to url: URL, bits: Int32 = 24) throws {
        var err = [CChar](repeating: 0, count: 512)
        let frames = sessionLength
        guard frames > 0 else { throw EngineError(description: "Nothing to export") }
        guard atrium_render_to_wav(handle, url.path, 0, frames, bits, &err, 512) == ATRIUM_OK else {
            throw EngineError(description: cString(err))
        }
    }

    func stats() -> AtriumStats {
        var s = AtriumStats()
        atrium_engine_stats(handle, &s)
        return s
    }
}
