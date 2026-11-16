// UI-side view of the session. The engine is the audio authority; this mirror
// exists until the engine-side project model + command system land (Phase 1, M2).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AtriumEngine

struct ClipModel {
    let id: AtriumClipId
    let media: AudioMedia
    var start: Int64
    var length: Int64
}

@MainActor
final class TrackModel {
    let id: AtriumTrackId
    var name: String
    var color: NSColor
    var gainDb: Float = 0
    var pan: Float = 0
    var muted = false
    var clips: [ClipModel] = []

    init(id: AtriumTrackId, name: String, color: NSColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

@MainActor
final class Session {
    let engine: Engine
    private(set) var tracks: [TrackModel] = []
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?

    init(engine: Engine) { self.engine = engine }

    var length: Int64 { engine.sessionLength }

    /// Decodes files off the main thread, then adds one track per file.
    func importFiles(_ urls: [URL], completion: (() -> Void)? = nil) {
        let rate = engine.sampleRate
        Task {
            for url in urls {
                do {
                    let media = try await Task.detached(priority: .userInitiated) {
                        try AudioMedia.load(url: url, sampleRate: rate)
                    }.value
                    addTrack(with: media)
                } catch {
                    onError?("Couldn't import \(url.lastPathComponent): \(error)")
                }
            }
            completion?()
        }
    }

    private func addTrack(with media: AudioMedia) {
        let id = engine.addTrack(media.name)
        let track = TrackModel(id: id, name: media.name, color: Theme.trackColor(tracks.count))
        let clipId = engine.addClip(id, media, start: 0)
        track.clips.append(ClipModel(id: clipId, media: media, start: 0, length: media.frames))
        tracks.append(track)
        onChange?()
    }

    func setGain(_ t: TrackModel, db: Float) { t.gainDb = db; engine.setGain(t.id, db: db) }
    func setPan(_ t: TrackModel, _ p: Float) { t.pan = p; engine.setPan(t.id, p) }
    func setMute(_ t: TrackModel, _ m: Bool) { t.muted = m; engine.setMute(t.id, m) }
}
