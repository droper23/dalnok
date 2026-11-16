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
    let fadeIn: Int64
    let fadeOut: Int64
    let fadeCurve: Int32
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
    let solo: Bool
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
                                      fadeIn: ci.fade_in, fadeOut: ci.fade_out, fadeCurve: ci.fade_curve,
                                      name: fixedString(ci.name)))
            }
            out.append(TrackView(id: tid, name: fixedString(ti.name), color: Theme.trackColor(Int(ti.color)),
                                 gainDb: ti.gain_db, pan: ti.pan, muted: ti.muted, solo: ti.solo, clips: clips))
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
    func setSolo(_ t: DalnokTrackId, _ on: Bool) { dalnok_track_set_solo(h, t, on); refresh() }
    func moveTrack(_ t: DalnokTrackId, to index: Int) { dalnok_track_move(h, t, Int32(index)); refresh() }
    func renameTrack(_ t: DalnokTrackId, _ name: String) { dalnok_track_rename(h, t, name); refresh() }
    @discardableResult
    func addTrack(_ name: String = "") -> DalnokTrackId { let id = dalnok_track_add(h, name); refresh(); return id }
    func removeTrack(_ t: DalnokTrackId) { dalnok_track_remove(h, t); refresh() }
    func setFades(_ c: DalnokClipId, fadeIn: Int64, fadeOut: Int64, curve: DalnokFadeCurve) {
        dalnok_clip_set_fades(h, c, fadeIn, fadeOut, curve); refresh()
    }

    /// Media ids of offline clips, with the file name each one expects.
    var offlineMedia: [(id: DalnokMediaId, path: String)] {
        var seen = Set<DalnokMediaId>(), out: [(DalnokMediaId, String)] = []
        for c in tracks.flatMap(\.clips) where c.offline && seen.insert(c.media).inserted {
            var b = [CChar](repeating: 0, count: 2048)
            dalnok_pool_path(h, c.media, &b, 2048)
            out.append((c.media, cString(b)))
        }
        return out
    }

    /// Relinks offline media by file name from the given files and/or folders (searched recursively).
    /// Returns (relinked, stillMissing).
    func relink(searching urls: [URL]) async -> (Int, Int) {
        let missing = offlineMedia
        guard !missing.isEmpty else { return (0, 0) }
        var candidates: [String: URL] = [:]
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL { candidates[f.lastPathComponent] = candidates[f.lastPathComponent] ?? f }
            } else {
                candidates[url.lastPathComponent] = url
            }
        }
        // A single chosen file for a single missing file is accepted regardless of its name.
        if missing.count == 1, urls.count == 1, let only = urls.first, !only.hasDirectoryPath,
           candidates[(missing[0].path as NSString).lastPathComponent] == nil {
            candidates[(missing[0].path as NSString).lastPathComponent] = only
        }
        var relinked = 0
        let rate = engine.sampleRate
        for m in missing {
            guard let url = candidates[(m.path as NSString).lastPathComponent] else { continue }
            guard let decoded = try? await Task.detached(priority: .userInitiated, operation: {
                try DecodedMedia.load(url: url, sampleRate: rate)
            }).value else { continue }
            if dalnok_pool_relink(h, m.id, decoded.handle, url.path, nil, 0) == DALNOK_OK { relinked += 1 }
        }
        refresh()
        return (relinked, missing.count - relinked)
    }
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

    private(set) var isOpening = false

    /// Loads in the background; the current project stays usable until the new one is swapped in.
    func open(_ url: URL) async throws {
        isOpening = true
        defer { isOpening = false }
        onMessage?("Opening \(url.lastPathComponent)…")
        let missing = try await engine.loadInBackground(from: url)
        projectURL = url
        refresh()
        onMessage?(missing > 0 ? "\(missing) audio file\(missing == 1 ? "" : "s") missing — File ▸ Relink Missing Audio…"
                                : "Opened \(url.lastPathComponent)")
    }

    /// Imports a Logic/Ableton/REAPER/FCPXML project or stems folder as a new, unsaved project.
    func importForeign(_ url: URL) async throws -> ImportReport? {
        isOpening = true
        defer { isOpening = false }
        onMessage?("Importing \(url.lastPathComponent)…")
        let json = try await engine.importForeign(from: url)
        projectURL = nil
        refresh()
        return ImportReport(json: json)
    }

    func save(to url: URL, copyAudio: Bool = false) throws {
        try engine.save(to: url, copyAudio: copyAudio)
        projectURL = url
        onMessage?("Saved \(url.lastPathComponent)")
        onChange?()
    }
}
