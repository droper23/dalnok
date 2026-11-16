// Swift wrappers over the engine's C API.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
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
    deinit { dalnok_media_release(handle) }

    static func load(url: URL, sampleRate: Double) throws -> DecodedMedia {
        var out: OpaquePointer?
        var err = [CChar](repeating: 0, count: 512)
        guard dalnok_media_load(url.path, sampleRate, &out, &err, 512) == DALNOK_OK, let h = out else {
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
        handle = dalnok_engine_create(0)
        sampleRate = dalnok_engine_sample_rate(handle)
    }

    func startDevice() throws {
        var err = [CChar](repeating: 0, count: 512)
        guard dalnok_engine_start_device(handle, &err, 512) == DALNOK_OK else {
            throw EngineError(description: cString(err))
        }
    }

    func shutdown() {
        dalnok_engine_stop_device(handle)
        dalnok_engine_destroy(handle)
    }

    // Transport
    var isPlaying: Bool { dalnok_transport_is_playing(handle) }
    var position: Int64 { dalnok_transport_position(handle) }
    func play() { dalnok_transport_play(handle) }
    func pause() { dalnok_transport_pause(handle) }
    func seek(_ frame: Int64) { dalnok_transport_seek(handle, max(0, frame)) }
    func collectGarbage() { dalnok_engine_collect_garbage(handle) }

    // Model
    var revision: UInt64 { dalnok_model_revision(handle) }
    var sessionLength: Int64 { dalnok_session_length(handle) }
    func poolAdd(_ m: DecodedMedia) -> DalnokMediaId { dalnok_pool_add(handle, m.handle, m.url.path) }
    /// Borrowed; valid until the project is replaced.
    func poolMedia(_ id: DalnokMediaId) -> OpaquePointer? { dalnok_pool_media(handle, id) }

    // Undo
    var canUndo: Bool { dalnok_can_undo(handle) }
    var canRedo: Bool { dalnok_can_redo(handle) }
    var undoName: String { var b = [CChar](repeating: 0, count: 128); dalnok_undo_name(handle, &b, 128); return cString(b) }
    var redoName: String { var b = [CChar](repeating: 0, count: 128); dalnok_redo_name(handle, &b, 128); return cString(b) }
    func undo() { dalnok_undo(handle) }
    func redo() { dalnok_redo(handle) }
    func group(_ name: String, _ body: () -> Void) {
        dalnok_undo_begin_group(handle, name)
        body()
        dalnok_undo_end_group(handle)
    }
    func beginGroup(_ name: String) { dalnok_undo_begin_group(handle, name) }
    func endGroup() { dalnok_undo_end_group(handle) }

    // Project
    var isDirty: Bool { dalnok_project_dirty(handle) }
    func newProject() { dalnok_project_new(handle) }
    func save(to url: URL) throws {
        var err = [CChar](repeating: 0, count: 512)
        guard dalnok_project_save(handle, url.path, &err, 512) == DALNOK_OK else { throw EngineError(description: cString(err)) }
    }
    /// Returns the number of offline (missing) media files.
    func load(from url: URL) throws -> Int {
        var err = [CChar](repeating: 0, count: 512)
        var missing: Int32 = 0
        guard dalnok_project_load(handle, url.path, &missing, &err, 512) == DALNOK_OK else {
            throw EngineError(description: cString(err))
        }
        return Int(missing)
    }
    func exportWav(to url: URL, bits: Int32 = 24) throws {
        var err = [CChar](repeating: 0, count: 512)
        let frames = sessionLength
        guard frames > 0 else { throw EngineError(description: "Nothing to export") }
        guard dalnok_render_to_wav(handle, url.path, 0, frames, bits, &err, 512) == DALNOK_OK else {
            throw EngineError(description: cString(err))
        }
    }

    func stats() -> DalnokStats {
        var s = DalnokStats()
        dalnok_engine_stats(handle, &s)
        return s
    }
}
