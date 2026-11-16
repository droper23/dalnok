// Read-only view of the engine's project model, rebuilt when its revision changes.
// All edits go through engine commands (undoable); nothing is mirrored here.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AtriumEngine

struct ClipView {
    let id: AtriumClipId
    let track: AtriumTrackId
    let media: AtriumMediaId
    let start: Int64
    let offset: Int64
    let length: Int64
    let mediaFrames: Int64
    let offline: Bool
    let name: String
    var end: Int64 { start + length }
}

struct TrackView {
    let id: AtriumTrackId
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
        for i in 0..<atrium_track_count(h) {
            let tid = atrium_track_at(h, i)
            var ti = AtriumTrackInfo()
            guard atrium_track_info(h, tid, &ti) == ATRIUM_OK else { continue }
            var clips: [ClipView] = []
            for k in 0..<ti.clip_count {
                var ci = AtriumClipInfo()
                guard atrium_clip_info(h, atrium_track_clip_at(h, tid, k), &ci) == ATRIUM_OK else { continue }
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

    func track(_ id: AtriumTrackId) -> TrackView? { tracks.first { $0.id == id } }
    func clip(_ id: AtriumClipId) -> ClipView? {
        for t in tracks { if let c = t.clips.first(where: { $0.id == id }) { return c } }
        return nil
    }

    // MARK: Edits (each is an engine command)

    func setGain(_ t: AtriumTrackId, db: Float) { atrium_track_set_gain_db(h, t, db); refresh() }
    func setPan(_ t: AtriumTrackId, _ p: Float) { atrium_track_set_pan(h, t, p); refresh() }
    func setMute(_ t: AtriumTrackId, _ m: Bool) { atrium_track_set_mute(h, t, m); refresh() }
    func moveClip(_ c: AtriumClipId, track: AtriumTrackId, start: Int64) { atrium_clip_move(h, c, track, start); refresh() }
    func setRegion(_ c: AtriumClipId, start: Int64, offset: Int64, length: Int64) {
        atrium_clip_set_region(h, c, start, offset, length); refresh()
    }
    func removeClip(_ c: AtriumClipId) { atrium_clip_remove(h, c); refresh() }
    @discardableResult
    func split(_ c: AtriumClipId, at frame: Int64) -> Bool {
        let ok = atrium_clip_split(h, c, frame, nil) == ATRIUM_OK
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
                        let t = atrium_track_add(h, m.url.deletingPathExtension().lastPathComponent)
                        atrium_clip_add(h, t, media, 0, 0, 0)
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
