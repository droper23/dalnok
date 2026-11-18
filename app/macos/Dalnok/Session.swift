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
    let gainDb: Float
    let rate: Double
    let pitch: Float
    let preservePitch: Bool
    let processing: Bool
    let name: String
    var notes: [DalnokNote] = [] // MIDI clips only
    var isMidi = false
    var muted = false
    var folder: Int32 = 0 // take folder (comp piece when shown in the arrangement)
    var slot: Int32 = -1  // clip launcher slot (not on the timeline)
    var follow: Int32 = 0, followLoops: Int32 = 1
    var end: Int64 { start + length }
    var isStretched: Bool { abs(rate - 1) > 1e-9 || pitch != 0 }
    var sourceSpan: Int64 { Int64((Double(length) * rate).rounded()) }
}

struct TrackView {
    let id: DalnokTrackId
    let name: String
    let color: NSColor
    let customColor: Int32
    let gainDb: Float
    let pan: Float
    let muted: Bool
    let solo: Bool
    let clips: [ClipView] // z-order
    var isInstrument = false
    var armed = false
    var inputChannel: Int32 = 0
    struct Plugin { let id: Int32; let name: String; let vendor: String; let instrument: Bool; let loaded: Bool; let error: String; let latency: UInt32; let bypassed: Bool; var path = "" }
    var plugins: [Plugin] = []
    var isBus = false
    var output: DalnokTrackId = 0 // 0 = master
    var stack: DalnokTrackId = 0  // summing stack this track is in
    var isStack = false
    var collapsed = false
    var hidden = false // Track ▸ Hide Track (still plays)
    /// Lane height in points set on this track (0: the arrangement's default, Theme.trackHeight).
    var height: CGFloat = 0
    var sends: [DalnokSend] = []
    var volumeAuto: [DalnokAutoPoint] = [], panAuto: [DalnokAutoPoint] = []
    func automation(_ target: Int32) -> [DalnokAutoPoint] { target == 1 ? panAuto : volumeAuto }
    var instrumentName: String? { plugins.first { $0.instrument }?.name }
    var effects: [Plugin] { plugins.filter { !$0.instrument } }
}

@MainActor
final class Session {
    let engine: Engine
    private(set) var tracks: [TrackView] = []
    /// Clips in launcher slots.
    private(set) var slotClips: [ClipView] = []
    func slotClip(_ track: DalnokTrackId, _ slot: Int32) -> ClipView? { slotClips.first { $0.track == track && $0.slot == slot } }
    var scenes: Int32 { dalnok_launcher_scenes(h) }
    @discardableResult func copyToSlot(_ clip: DalnokClipId, _ slot: Int32) -> Bool {
        let ok = dalnok_launcher_copy_clip(h, clip, slot) != 0; refresh(); return ok
    }
    /// Takes inside take folders (not shown in the arrangement), by clip id.
    private(set) var takeClips: [DalnokClipId: ClipView] = [:]
    private var revision: UInt64 = 0 // reset to force a rebuild
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
        takeClips = [:]
        slotClips = []
        for i in 0..<dalnok_track_count(h) {
            let tid = dalnok_track_at(h, i)
            var ti = DalnokTrackInfo()
            guard dalnok_track_info(h, tid, &ti) == DALNOK_OK else { continue }
            var clips: [ClipView] = []
            for k in 0..<ti.clip_count {
                var ci = DalnokClipInfo()
                guard dalnok_clip_info(h, dalnok_track_clip_at(h, tid, k), &ci) == DALNOK_OK else { continue }
                var clip = ClipView(id: ci.id, track: ci.track, media: ci.media, start: ci.start, offset: ci.offset,
                                    length: ci.length, mediaFrames: ci.media_frames, offline: ci.offline,
                                    fadeIn: ci.fade_in, fadeOut: ci.fade_out, fadeCurve: ci.fade_curve,
                                    gainDb: ci.gain_db, rate: ci.rate, pitch: ci.pitch, preservePitch: ci.preserve_pitch,
                                    processing: ci.processing, name: fixedString(ci.name))
                clip.muted = dalnok_clip_muted(h, ci.id)
                clip.folder = ci.folder
                clip.slot = ci.slot
                clip.follow = ci.follow
                clip.followLoops = ci.follow_loops
                if ci.alt { takeClips[ci.id] = clip; continue } // takes live in their folder, not the arrangement
                if ci.slot >= 0 { slotClips.append(clip); continue } // launcher slots, beside the arrangement
                if ci.midi {
                    clip.isMidi = true
                    clip.notes = [DalnokNote](repeating: DalnokNote(), count: Int(ci.note_count))
                    _ = dalnok_midi_clip_notes(h, ci.id, &clip.notes, ci.note_count)
                }
                clips.append(clip)
            }
            var plugins: [TrackView.Plugin] = []
            for k in 0..<dalnok_track_plugin_count(h, tid) {
                var pi = DalnokPluginSlotInfo()
                guard dalnok_track_plugin_info(h, tid, k, &pi) == DALNOK_OK else { continue }
                plugins.append(.init(id: pi.id, name: fixedString(pi.name), vendor: fixedString(pi.vendor), instrument: pi.instrument, loaded: pi.loaded,
                                     error: fixedString(pi.error), latency: pi.latency, bypassed: dalnok_plugin_bypassed(h, tid, pi.id), path: fixedString(pi.path)))
            }
            var sends = [DalnokSend](repeating: DalnokSend(), count: 16)
            let sendCount = Int(dalnok_track_sends(h, tid, &sends, 16))
            out.append(TrackView(id: tid, name: fixedString(ti.name), color: Theme.trackColor(step: Int(ti.color), custom: ti.custom_color),
                                 customColor: ti.custom_color,
                                 gainDb: ti.gain_db, pan: ti.pan, muted: ti.muted, solo: ti.solo, clips: clips,
                                 isInstrument: ti.kind == Int32(DALNOK_TRACK_INSTRUMENT.rawValue), armed: ti.armed,
                                 inputChannel: ti.input_channel, plugins: plugins,
                                 isBus: ti.kind == Int32(DALNOK_TRACK_BUS.rawValue), output: dalnok_track_output(h, tid),
                                 stack: ti.stack, isStack: ti.is_stack, collapsed: ti.collapsed,
                                 sends: Array(sends.prefix(min(sendCount, 16))),
                                 volumeAuto: automationPoints(tid, 0), panAuto: automationPoints(tid, 1)))
        }
        for k in out.indices { out[k].hidden = dalnok_track_hidden(h, out[k].id) }
        for k in out.indices { var ti = DalnokTrackInfo(); dalnok_track_info(h, out[k].id, &ti); out[k].height = CGFloat(ti.height) }
        allTracks = out
        // Tracks inside a closed stack (at any depth) are hidden from the arrangement, headers and mixer.
        let byId = Dictionary(uniqueKeysWithValues: out.map { ($0.id, $0) })
        func hidden(_ t: TrackView) -> Bool {
            var parent = t.stack
            while parent != 0, let p = byId[parent] { if p.collapsed { return true }; parent = p.stack }
            return false
        }
        tracks = out.filter { !hidden($0) && !$0.hidden }
        onChange?()
        return true
    }

    func track(_ id: DalnokTrackId) -> TrackView? { allTracks.first { $0.id == id } }

    // MARK: Lane layout (shared by the arrangement, the track headers and the launcher)

    /// A shown track's lane height: its own, else the arrangement's default (View ▸ Taller/Shorter Tracks).
    func laneHeight(_ index: Int) -> CGFloat {
        guard tracks.indices.contains(index) else { return Theme.trackHeight }
        let h = tracks[index].height
        return h > 0 ? h : Theme.trackHeight
    }
    /// Top of lane `index` below the ruler, before scrolling (index == count: the bottom of the last lane).
    func laneTop(_ index: Int) -> CGFloat {
        let tops = laneTops
        if index <= 0 { return CGFloat(index) * Theme.trackHeight }
        if index < tops.count { return tops[index] }
        return lanesHeight + CGFloat(index - tops.count) * Theme.trackHeight
    }
    /// Total height of all shown lanes.
    var lanesHeight: CGFloat { let tops = laneTops; return tops.isEmpty ? 0 : tops[tops.count - 1] + laneHeight(tops.count - 1) }
    /// The lane at `y` (below the ruler, before scrolling); past the last lane counts on in default-height steps.
    func laneIndex(atY y: CGFloat) -> Int {
        guard y >= 0 else { return Int(floor(y / Theme.trackHeight)) }
        let tops = laneTops
        if let i = tops.lastIndex(where: { $0 <= y }), y < tops[i] + laneHeight(i) { return i }
        let end = lanesHeight
        return tracks.count + Int(floor(max(0, y - end) / Theme.trackHeight))
    }
    private var laneCache: (revision: UInt64, unit: CGFloat, tops: [CGFloat])?
    private var laneTops: [CGFloat] {
        if let c = laneCache, c.revision == revision, c.unit == Theme.trackHeight, c.tops.count == tracks.count { return c.tops }
        var tops: [CGFloat] = [], y: CGFloat = 0
        for i in tracks.indices { tops.append(y); y += laneHeight(i) }
        laneCache = (revision, Theme.trackHeight, tops)
        return tops
    }
    func setTrackHeight(_ t: DalnokTrackId, _ height: CGFloat) { dalnok_track_set_height(h, t, Float(height)); refresh() }
    /// Every track, including members of closed stacks (`tracks` is what's shown).
    private(set) var allTracks: [TrackView] = []
    func members(of stack: DalnokTrackId) -> [TrackView] { allTracks.filter { $0.stack == stack } }
    /// Everything inside a stack at any depth (the members of nested stacks too), in display order.
    func contents(of stack: DalnokTrackId) -> [TrackView] { allTracks.filter { depth(of: $0.id, inside: stack) } }
    private func depth(of track: DalnokTrackId, inside stack: DalnokTrackId) -> Bool {
        var parent = self.track(track)?.stack ?? 0
        while parent != 0 { if parent == stack { return true }; parent = self.track(parent)?.stack ?? 0 }
        return false
    }
    /// How many stacks a track is inside (0 = top level).
    func nesting(_ track: TrackView) -> Int {
        var n = 0, parent = track.stack
        while parent != 0, n < 16 { n += 1; parent = self.track(parent)?.stack ?? 0 }
        return n
    }
    @discardableResult
    func makeStack(_ members: [DalnokTrackId], name: String = "") -> DalnokTrackId {
        let id = dalnok_track_stack_create(h, members, Int32(members.count), name); refresh(); return id
    }
    var hiddenCount: Int { allTracks.filter(\.hidden).count }
    func setHidden(_ t: DalnokTrackId, _ hidden: Bool) { dalnok_track_set_hidden(h, t, hidden); refresh() }
    func showAllTracks() { dalnok_track_set_hidden(h, 0, false); refresh() }
    func setStackCollapsed(_ stack: DalnokTrackId, _ collapsed: Bool) { dalnok_track_stack_set_collapsed(h, stack, collapsed); refresh() }
    func ungroupStack(_ stack: DalnokTrackId) { dalnok_track_stack_ungroup(h, stack); refresh() }
    func clip(_ id: DalnokClipId) -> ClipView? {
        for t in allTracks { if let c = t.clips.first(where: { $0.id == id }) { return c } }
        return nil
    }

    // MARK: Edits (each is an engine command)

    func setClipMuted(_ clip: DalnokClipId, _ muted: Bool) { dalnok_clip_set_muted(h, clip, muted); refresh() }
    func setGain(_ t: DalnokTrackId, db: Float) { dalnok_track_set_gain_db(h, t, db); refresh() }
    var masterGainDb: Float { dalnok_master_gain_db(h) }
    func setMasterGain(_ db: Float) { dalnok_master_set_gain_db(h, db); refresh() }
    // Routing
    @discardableResult func addBus(_ name: String = "") -> DalnokTrackId { let id = dalnok_track_add_bus(h, name); refresh(); return id }
    @discardableResult func setOutput(_ t: DalnokTrackId, _ bus: DalnokTrackId) -> Bool {
        let ok = dalnok_track_set_output(h, t, bus) == DALNOK_OK; refresh(); return ok
    }
    @discardableResult func setSend(_ t: DalnokTrackId, _ bus: DalnokTrackId, db: Float, pre: Bool) -> Bool {
        let ok = dalnok_track_set_send(h, t, bus, db, pre) == DALNOK_OK; refresh(); return ok
    }
    func removeSend(_ t: DalnokTrackId, _ bus: DalnokTrackId) { dalnok_track_remove_send(h, t, bus); refresh() }
    var buses: [TrackView] { allTracks.filter(\.isBus) }
    // Take folders
    func takeFolders(_ track: DalnokTrackId) -> [Int32] {
        let n = dalnok_take_folders(h, track, nil, 0)
        var out = [Int32](repeating: 0, count: Int(n))
        _ = dalnok_take_folders(h, track, &out, n); return out
    }
    func takes(_ folder: Int32) -> [ClipView] {
        let n = dalnok_take_folder_takes(h, folder, nil, 0)
        var ids = [DalnokClipId](repeating: 0, count: Int(n))
        _ = dalnok_take_folder_takes(h, folder, &ids, n)
        return ids.compactMap { takeClips[$0] }
    }
    func comp(_ folder: Int32) -> [DalnokCompSegment] {
        let n = dalnok_take_folder_comp(h, folder, nil, 0)
        var out = [DalnokCompSegment](repeating: DalnokCompSegment(), count: Int(n))
        _ = dalnok_take_folder_comp(h, folder, &out, n); return out
    }
    @discardableResult
    func setComp(_ folder: Int32, _ segments: [DalnokCompSegment]) -> Bool {
        let ok = dalnok_take_folder_set_comp(h, folder, segments, Int32(segments.count)) == DALNOK_OK
        refresh(); return ok
    }
    private func automationPoints(_ t: DalnokTrackId, _ target: Int32) -> [DalnokAutoPoint] {
        let n = dalnok_track_automation(h, t, target, nil, 0)
        guard n > 0 else { return [] }
        var out = [DalnokAutoPoint](repeating: DalnokAutoPoint(), count: Int(n))
        _ = dalnok_track_automation(h, t, target, &out, n)
        return out
    }
    func pluginAutomation(_ t: DalnokTrackId, _ slot: Int32, _ param: UInt32) -> [DalnokAutoPoint] {
        let n = dalnok_plugin_automation(h, t, slot, param, nil, 0)
        guard n > 0 else { return [] }
        var out = [DalnokAutoPoint](repeating: DalnokAutoPoint(), count: Int(n))
        _ = dalnok_plugin_automation(h, t, slot, param, &out, n); return out
    }
    @discardableResult
    func setPluginAutomation(_ t: DalnokTrackId, _ slot: Int32, _ param: UInt32, _ points: [DalnokAutoPoint]) -> Bool {
        let ok = dalnok_plugin_set_automation(h, t, slot, param, points, Int32(points.count)) == DALNOK_OK
        refresh(); return ok
    }
    /// A plug-in parameter's current normalized value.
    func pluginParameterValue(_ slot: Int32, _ param: UInt32) -> Float? {
        let n = dalnok_plugin_parameter_count(h, slot)
        for i in 0..<max(0, n) {
            var p = DalnokPluginParameter()
            if dalnok_plugin_parameter(h, slot, i, &p) == DALNOK_OK, p.id == param { return Float(p.value) }
        }
        return nil
    }
    @discardableResult
    func setAutomation(_ t: DalnokTrackId, _ target: Int32, _ points: [DalnokAutoPoint]) -> Bool {
        let ok = dalnok_track_set_automation(h, t, target, points, Int32(points.count)) == DALNOK_OK
        refresh(); return ok
    }
    /// Automation value at a frame (volume in dB following the fader taper; pan -1..1), or nil if not automated.
    func automationValue(_ t: TrackView, _ target: Int32, at frame: Int64) -> Float? {
        let pts = t.automation(target)
        guard let first = pts.first, let last = pts.last else { return nil }
        if frame <= first.frame { return first.value }
        if frame >= last.frame { return last.value }
        guard let i = pts.firstIndex(where: { $0.frame > frame }), i > 0 else { return last.value }
        let a = pts[i - 1], b = pts[i], f = Float(frame - a.frame) / Float(b.frame - a.frame)
        if target == 1 { return a.value + (b.value - a.value) * f }
        let pa = FaderControl.position(for: a.value), pb = FaderControl.position(for: b.value)
        return FaderControl.db(for: pa + (pb - pa) * Double(f))
    }
    func setPan(_ t: DalnokTrackId, _ p: Float) { dalnok_track_set_pan(h, t, p); refresh() }
    func setMute(_ t: DalnokTrackId, _ m: Bool) { dalnok_track_set_mute(h, t, m); refresh() }
    func setSolo(_ t: DalnokTrackId, _ on: Bool) { dalnok_track_set_solo(h, t, on); refresh() }
    func moveTrack(_ t: DalnokTrackId, to index: Int) { dalnok_track_move(h, t, Int32(index)); refresh() }
    func renameTrack(_ t: DalnokTrackId, _ name: String) { dalnok_track_rename(h, t, name); refresh() }
    func setTrackColor(_ t: DalnokTrackId, rgb: Int32) { dalnok_track_set_color(h, t, rgb); refresh() }
    func recolorGradient() { dalnok_tracks_recolor_gradient(h); refresh() }
    @discardableResult
    func addTrack(_ name: String = "") -> DalnokTrackId { let id = dalnok_track_add(h, name); refresh(); return id }
    func removeTrack(_ t: DalnokTrackId) { dalnok_track_remove(h, t); refresh() }
    @discardableResult
    func addInstrumentTrack(_ name: String = "") -> DalnokTrackId { let id = dalnok_track_add_instrument(h, name); refresh(); return id }
    func setArmed(_ t: DalnokTrackId, _ on: Bool) {
        if dalnok_track_set_armed(h, t, on) != DALNOK_OK { onMessage?("Can't change record arm while recording") }
        refresh()
    }
    func setInput(_ t: DalnokTrackId, _ channel: Int32) { dalnok_track_set_input(h, t, channel); refresh() }
    /// Loads a VST3 onto a track (instrument or insert). Runs plugin code on the main thread.
    func addPlugin(_ t: DalnokTrackId, path: String) throws -> Int32 {
        var err = [CChar](repeating: 0, count: 512)
        let id = dalnok_plugin_add(h, t, path, nil, &err, 512)
        refresh()
        if id == 0 { throw EngineError(description: cString(err)) }
        return id
    }
    func removePlugin(_ t: DalnokTrackId, _ slot: Int32) { dalnok_plugin_remove(h, t, slot); refresh() }
    func pluginBypassed(_ t: DalnokTrackId, _ slot: Int32) -> Bool { dalnok_plugin_bypassed(h, t, slot) }
    /// Moves a plug-in to `index` in the track's chain (one undo step).
    @discardableResult func movePlugin(_ t: DalnokTrackId, _ slot: Int32, to index: Int) -> Bool {
        let ok = dalnok_plugin_move(h, t, slot, Int32(index)) == DALNOK_OK
        refresh()
        return ok
    }
    /// Bypass (footswitch / power button): one undo step.
    func setPluginBypassed(_ t: DalnokTrackId, _ slot: Int32, _ bypassed: Bool) { dalnok_plugin_set_bypassed(h, t, slot, bypassed); refresh() }
    func setPluginControls(_ t: DalnokTrackId, _ slot: Int32, _ ids: [UInt32]) {
        var list = ids
        dalnok_plugin_set_controls(h, t, slot, &list, Int32(list.count))
        refresh()
    }
    @discardableResult
    func addMidiClip(_ t: DalnokTrackId, start: Int64, length: Int64) -> DalnokClipId {
        let id = dalnok_midi_clip_add(h, t, start, length); refresh(); return id
    }
    func setNotes(_ c: DalnokClipId, _ notes: [DalnokNote]) {
        var n = notes
        dalnok_midi_clip_set_notes(h, c, &n, Int32(n.count)); refresh()
    }
    func quantize(_ c: DalnokClipId, grid: Double) {
        if dalnok_midi_quantize(h, c, grid, 1) == DALNOK_OK { onMessage?("Quantized to 1/\(Int(4 / grid)) notes") }
        refresh()
    }
    var bpm: Double { dalnok_tempo_bpm(h) }
    var meter: (Int32, Int32) { var n: Int32 = 4, d: Int32 = 4; dalnok_meter(h, &n, &d); return (n, d) }
    func setTempo(_ bpm: Double, _ num: Int32, _ den: Int32) -> Bool { let ok = dalnok_tempo_set(h, bpm, num, den) == DALNOK_OK; refresh(); return ok }
    var framesPerBeat: Int64 { Int64((engine.sampleRate * 60 / bpm).rounded()) }

    // Markers (sorted by position).
    var markers: [DalnokMarker] {
        (0..<dalnok_marker_count(h)).map { i in var m = DalnokMarker(); _ = dalnok_marker_at(h, i, &m); return m }
    }
    @discardableResult func addMarker(at frame: Int64, name: String = "") -> Int32 { let id = dalnok_marker_add(h, frame, name); refresh(); return id }
    func moveMarker(_ id: Int32, to frame: Int64) { dalnok_marker_move(h, id, max(0, frame)); refresh() }
    func renameMarker(_ id: Int32, _ name: String) { dalnok_marker_rename(h, id, name); refresh() }
    func removeMarker(_ id: Int32) { dalnok_marker_remove(h, id); refresh() }

    // Tempo and meter maps. Beats are quarter notes from the origin; bars are zero-based.
    var tempoPoints: [DalnokTempoPoint] {
        let n = dalnok_tempo_points(h, nil, 0)
        var out = [DalnokTempoPoint](repeating: DalnokTempoPoint(), count: Int(n))
        _ = dalnok_tempo_points(h, &out, n); return out
    }
    var meterPoints: [DalnokMeterPoint] {
        let n = dalnok_meter_points(h, nil, 0)
        var out = [DalnokMeterPoint](repeating: DalnokMeterPoint(), count: Int(n))
        _ = dalnok_meter_points(h, &out, n); return out
    }
    @discardableResult
    func setTempoMap(_ tempo: [DalnokTempoPoint], _ meters: [DalnokMeterPoint]) -> Bool {
        let ok = dalnok_tempo_map_set(h, tempo, Int32(tempo.count), meters, Int32(meters.count)) == DALNOK_OK
        refresh(); return ok
    }
    func beatToFrame(_ beat: Double) -> Double { dalnok_beat_to_frame(h, beat) }
    func frameToBeat(_ frame: Double) -> Double { dalnok_frame_to_beat(h, frame) }
    func barToBeat(_ bar: Int) -> Double { dalnok_bar_to_beat(h, Int32(clamping: bar)) }
    func tempo(atBeat beat: Double) -> Double { dalnok_tempo_at(h, beat) }
    /// Bar (zero-based), position inside it in meter beats (zero-based) and the meter at a quarter-note beat.
    func bar(atBeat beat: Double) -> (bar: Int, beatInBar: Double, num: Int, den: Int) {
        var b: Int32 = 0, n: Int32 = 4, d: Int32 = 4, inBar = 0.0
        dalnok_beat_to_bar(h, beat, &b, &inBar, &n, &d)
        return (Int(b), inBar, Int(n), Int(d))
    }
    /// Cycle (loop) region; not an undo step.
    var cycle: (on: Bool, start: Int64, end: Int64) {
        var on = false, a: Int64 = 0, b: Int64 = 0
        dalnok_cycle_get(h, &on, &a, &b); return (on, a, b)
    }
    @discardableResult
    func setCycle(_ on: Bool, _ start: Int64, _ end: Int64) -> Bool {
        let ok = dalnok_cycle_set(h, on, start, end) == DALNOK_OK
        onCycleChange?()
        return ok
    }
    var onCycleChange: (() -> Void)?
    /// Frames per quarter note at a frame position.
    func framesPerBeat(at frame: Double) -> Double { engine.sampleRate * 60 / tempo(atBeat: frameToBeat(frame)) }
    func setStretch(_ c: DalnokClipId, length: Int64, rate: Double, pitch: Float, preservePitch: Bool) {
        dalnok_clip_set_stretch(h, c, length, rate, pitch, preservePitch); refresh()
    }

    /// Polls background stretch rendering; returns pending count. Forces a refresh when renders land.
    private var lastPending: Int32 = 0
    func pollJobs() -> Int32 {
        let n = dalnok_engine_poll_jobs(h)
        if n != lastPending { lastPending = n; forceRefresh() }
        return n
    }
    func forceRefresh() { revision = 0; refresh() }

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
    func nudgeClips(_ ids: [DalnokClipId], by frames: Int64) -> Bool {
        let ok = ids.withUnsafeBufferPointer { dalnok_clips_nudge(h, $0.baseAddress, Int32($0.count), frames) == DALNOK_OK }
        if ok { refresh() }
        return ok
    }
    func setRegion(_ c: DalnokClipId, start: Int64, offset: Int64, length: Int64) {
        dalnok_clip_set_region(h, c, start, offset, length); refresh()
    }
    func removeClip(_ c: DalnokClipId) { dalnok_clip_remove(h, c); refresh() }
    func removeClips(_ ids: [DalnokClipId]) -> Bool {
        let ok = ids.withUnsafeBufferPointer { dalnok_clips_remove(h, $0.baseAddress, Int32($0.count)) == DALNOK_OK }
        if ok { refresh() }
        return ok
    }
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

    /// Recovery copies are opened as unsaved projects; the snapshot is never overwritten by Save.
    func recover(_ url: URL) async throws {
        isOpening = true
        defer { isOpening = false }
        let missing = try await engine.loadInBackground(from: url, recovering: true)
        projectURL = nil
        refresh()
        onMessage?(missing > 0 ? "Recovered project; \(missing) audio file(s) missing." : "Recovered project. Save it to keep your changes.")
    }

    /// Imports a Logic/Ableton/REAPER/FCPXML project or stems folder as a new, unsaved project.
    func importForeign(_ url: URL) async throws -> ImportReport? {
        isOpening = true
        defer { isOpening = false }
        onMessage?("Importing \(url.lastPathComponent)…")
        let json = try await engine.importForeign(from: url)
        projectURL = nil
        refresh()
        let unavailable = allTracks.flatMap { track in
            track.plugins.filter { !$0.loaded }.map { plugin in
                "\(track.name) — \(plugin.name): \(plugin.error.isEmpty ? "not loaded; settings are kept" : plugin.error)"
            }
        }
        return ImportReport(json: json, unavailablePlugins: unavailable)
    }

    func save(to url: URL, copyAudio: Bool = false) throws {
        try engine.save(to: url, copyAudio: copyAudio)
        projectURL = url
        onMessage?("Saved \(url.lastPathComponent)")
        onChange?()
    }
}
