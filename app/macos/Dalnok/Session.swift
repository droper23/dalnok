// Read-only view of the engine's project model, rebuilt when its revision changes.
// All edits go through engine commands (undoable); nothing is mirrored here.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

struct ClipView {
    let id: DalnokClipId
    let track: DalnokTrackId
    let media: DalnokMediaId
    let start: Int64
    let offset: Int64
    let length: Int64
    let mediaFrames: Int64
    let offline: Bool
    let name: String
    var end: Int64 { start + length }
}

struct TrackView {
    let id: DalnokTrackId
    let name: String
    let color: NSColor
    let gainDb: Float
    let pan: Float
    let muted: Bool
    let clips: [ClipView] // z-order
}

@MainActor
final class Session {
    let engine: Engine
    private(set) var tracks: [TrackView] = []
    private var revision: UInt64 = 0
    var projectURL: URL?
    /// Called after the model changed (any source: UI, undo, scripts).
    var onChange: (() -> Void)?
    var onMessage: ((String) -> Void)?

    init(engine: Engine) {
        self.engine = engine
        refresh()
    }

    var h: OpaquePointer { engine.handle }
    var length: Int64 { engine.sessionLength }

    /// Rebuilds the view if the engine's revision moved. Returns true if it did.
    @discardableResult
    func refresh() -> Bool {
        let rev = engine.revision
        guard rev != revision else { return false }
        revision = rev
        var out: [TrackView] = []
        for i in 0..<dalnok_track_count(h) {
            let tid = dalnok_track_at(h, i)
            var ti = DalnokTrackInfo()
            guard dalnok_track_info(h, tid, &ti) == DALNOK_OK else { continue }
            var clips: [ClipView] = []
            for k in 0..<ti.clip_count {
                var ci = DalnokClipInfo()
                guard dalnok_clip_info(h, dalnok_track_clip_at(h, tid, k), &ci) == DALNOK_OK else { continue }
                clips.append(ClipView(id: ci.id, track: ci.track, media: ci.media, start: ci.start, offset: ci.offset,
                                      length: ci.length, mediaFrames: ci.media_frames, offline: ci.offline,
                                      name: fixedString(ci.name)))
            }
            out.append(TrackView(id: tid, name: fixedString(ti.name), color: Theme.trackColor(Int(ti.color)),
                                 gainDb: ti.gain_db, pan: ti.pan, muted: ti.muted, clips: clips))
        }
        tracks = out
        onChange?()
        return true
    }

    func track(_ id: DalnokTrackId) -> TrackView? { tracks.first { $0.id == id } }
    func clip(_ id: DalnokClipId) -> ClipView? {
        for t in tracks { if let c = t.clips.first(where: { $0.id == id }) { return c } }
        return nil
    }

    // MARK: Edits (each is an engine command)

    func setGain(_ t: DalnokTrackId, db: Float) { dalnok_track_set_gain_db(h, t, db); refresh() }
    func setPan(_ t: DalnokTrackId, _ p: Float) { dalnok_track_set_pan(h, t, p); refresh() }
    func setMute(_ t: DalnokTrackId, _ m: Bool) { dalnok_track_set_mute(h, t, m); refresh() }
    func moveClip(_ c: DalnokClipId, track: DalnokTrackId, start: Int64) { dalnok_clip_move(h, c, track, start); refresh() }
    func setRegion(_ c: DalnokClipId, start: Int64, offset: Int64, length: Int64) {
        dalnok_clip_set_region(h, c, start, offset, length); refresh()
    }
    func removeClip(_ c: DalnokClipId) { dalnok_clip_remove(h, c); refresh() }
    @discardableResult
    func split(_ c: DalnokClipId, at frame: Int64) -> Bool {
        let ok = dalnok_clip_split(h, c, frame, nil) == DALNOK_OK
        refresh()
        return ok
    }
    func undo() { engine.undo(); refresh() }
    func redo() { engine.redo(); refresh() }

    /// Decodes off the main thread, then adds one track per file as a single undo step.
    func importFiles(_ urls: [URL], completion: (() -> Void)? = nil) {
        let rate = engine.sampleRate
        Task {
            var decoded: [DecodedMedia] = []
            for url in urls {
                do {
                    decoded.append(try await Task.detached(priority: .userInitiated) {
                        try DecodedMedia.load(url: url, sampleRate: rate)
                    }.value)
                } catch {
                    onMessage?("Couldn't import \(url.lastPathComponent): \(error)")
                }
            }
            if !decoded.isEmpty {
                engine.group(decoded.count == 1 ? "Import Audio" : "Import \(decoded.count) Files") {
                    for m in decoded {
                        let media = engine.poolAdd(m)
                        let t = dalnok_track_add(h, m.url.deletingPathExtension().lastPathComponent)
                        dalnok_clip_add(h, t, media, 0, 0, 0)
                    }
                }
                refresh()
            }
            completion?()
        }
    }

    // MARK: Project

    func newProject() { engine.newProject(); projectURL = nil; refresh() }

    func open(_ url: URL) throws {
        let missing = try engine.load(from: url)
        projectURL = url
        refresh()
        onMessage?(missing > 0 ? "\(missing) audio file\(missing == 1 ? "" : "s") missing — clips shown offline"
                                : "Opened \(url.lastPathComponent)")
    }

    func save(to url: URL) throws {
        try engine.save(to: url)
        projectURL = url
        onMessage?("Saved \(url.lastPathComponent)")
        onChange?()
    }
}
