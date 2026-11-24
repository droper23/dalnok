// Built-in plug-ins (ADR-0011): Dalnok Channel EQ.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

/// Independent reference for the Channel EQ peak band (04 - Research/Logic Effect Parity.md).
private func referencePeak(hz: Double, gainDb: Double, q: Double, rate: Double, coupleMode: Int?) -> ([Double], [Double]) {
    let shown = (0..<128).map { Double(String(format: "%.2g", pow(10, -1 + 3 * Double($0) / 127)))! }
    let qd = shown.min { abs($0 - q) < abs($1 - q) }!
    var k = 1.0
    if let mode = coupleMode {
        let (strength, asym): (Double, Double) = [0: (0.5, 1), 1: (1, 1), 2: (2, 1), -1: (1, 3), -2: (2, 3), -3: (0.5, 3)][mode] ?? (1, 1)
        let s = gainDb >= 0 ? strength : strength * asym, g = abs(gainDb)
        k = 1 + s * g * (0.06 + 0.005625 * g)
    }
    let half = Double.pi * min(hz / rate, 0.49), w = 2 * half
    let qGrid = pow(10, (300 * log10(qd * k)).rounded() / 300), qEff = qGrid * half / tan(half)
    let A = pow(10, abs(gainDb) / 40), alpha = sin(w) * A / (2 * qEff), c = -2 * cos(w)
    var b = [1 + alpha * A, c, 1 - alpha * A], a = [1 + alpha / A, c, 1 - alpha / A]
    if gainDb < 0 { swap(&b, &a) }
    return (b.map { $0 / a[0] }, a.map { $0 / a[0] })
}

private func filter(_ x: [Float], _ b: [Double], _ a: [Double]) -> [Double] {
    var y = [Double](repeating: 0, count: x.count)
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    for i in x.indices {
        let v = Double(x[i]), o = b[0] * v + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
        x2 = x1; x1 = v; y2 = y1; y1 = o; y[i] = o
    }
    return y
}

/// Cut-filter reference: sections as measured from Logic renders (04 - Research/Logic Effect Parity.md), built with
/// the bilinear transform (low cut = high-pass, high cut = low-pass). First-order corners scale in Hz, second-order corners in tan(pi f / fs).
private func referenceCut(high: Bool, hz: Double, rate: Double, first: Double?, sections: [(Double, Double)]) -> [([Double], [Double])] {
    var out: [([Double], [Double])] = []
    if let r = first {
        let k = tan(Double.pi * (high ? hz / r : hz * r) / rate)
        out.append(high ? ([k, k, 0].map { $0 / (1 + k) }, [1, (k - 1) / (1 + k), 0]) : ([1, -1, 0].map { $0 / (1 + k) }, [1, (k - 1) / (1 + k), 0]))
    }
    let k0 = tan(Double.pi * hz / rate)
    for (r, q) in sections {
        let k = high ? k0 / r : k0 * r, k2 = k * k, d = 1 + k / q + k2
        let b = high ? [k2, 2 * k2, k2] : [1.0, -2, 1]
        out.append((b.map { $0 / d }, [1, 2 * (k2 - 1) / d, (1 - k / q + k2) / d]))
    }
    return out
}

/// RBJ shelf with the slope capped as Logic does: min(Q, 2, 4.56 - 0.12 |gain|).
private func referenceShelf(high: Bool, hz: Double, gainDb: Double, q: Double, rate: Double) -> ([Double], [Double]) {
    let A = pow(10, gainDb / 40), s = min(q, 2, 4.56 - 0.12 * abs(gainDb)), w = 2 * Double.pi * hz / rate
    let cs = cos(w), t = sqrt(max(0, (A * A + 1) / s - (A - 1) * (A - 1))) * sin(w)
    let sg = high ? -1.0 : 1
    let b = [A * ((A + 1) - sg * (A - 1) * cs + t), sg * 2 * A * ((A - 1) - sg * (A + 1) * cs), A * ((A + 1) - sg * (A - 1) * cs - t)]
    let a = [(A + 1) + sg * (A - 1) * cs + t, -sg * 2 * ((A - 1) + sg * (A + 1) * cs), (A + 1) + sg * (A - 1) * cs - t]
    return (b.map { $0 / a[0] }, a.map { $0 / a[0] })
}

private func cascade(_ x: [Float], _ sections: [([Double], [Double])]) -> [Double] {
    var y = x.map(Double.init)
    for (b, a) in sections {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in y.indices {
            let v = y[i], o = b[0] * v + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
            x2 = x1; x1 = v; y2 = y1; y1 = o; y[i] = o
        }
    }
    return y
}

@Suite struct BuiltinPlugins {
    func logNorm(_ v: Double, _ lo: Double, _ hi: Double) -> Double { log(v / lo) / log(hi / lo) }

    @Test func channelEqIsListedAndTransparentAtDefaults() throws {
        let n = dalnok_plugins_scan(nil, false, nil, 0)
        var buf = [CChar](repeating: 0, count: n + 1)
        dalnok_plugins_scan(nil, false, &buf, buf.count)
        let list = try #require(try JSONSerialization.jsonObject(with: Data(cstr(buf).utf8)) as? [[String: Any]])
        #expect(list.contains { $0["format"] as? String == "dalnok" && $0["path"] as? String == "channel-eq" })

        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e, t, 0, &info) == DALNOK_OK && info.loaded && name(info.name) == "Dalnok Channel EQ")
        #expect(dalnok_plugin_parameter_count(e, slot) == 36)
        let wet = renderStereo(e, 4_800)
        #expect(zip(wet.0, dry.0).allSatisfy { $0 == $1 } && zip(wet.1, dry.1).allSatisfy { $0 == $1 },
                "all bands at 0 dB pass the signal unchanged")
    }

    @Test(arguments: [(1000.0, 9.0, 2.0, true), (1000.0, -12.0, 1.0, true), (3000.0, 6.0, 0.71, false), (15000.0, 18.0, 2.8, true)])
    func channelEqPeakMatchesTheReferenceDesign(hz: Double, gain: Double, q: Double, couple: Bool) {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
        // Peak 3 is parameters 16-19 (Logic's slot numbers); 41 is Gain-Q coupling (mode stays Asymmetric Medium).
        #expect(dalnok_plugin_set_parameter(e, slot, 17, logNorm(hz, 20, 20_000)) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, 18, (gain + 24) / 48) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, 19, logNorm(q, 0.1, 100)) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, 41, couple ? 1 : 0) == DALNOK_OK)
        let wet = renderStereo(e, 4_800)
        let (b, a) = referencePeak(hz: hz, gainDb: gain, q: q, rate: 48_000, coupleMode: couple ? -1 : nil)
        let expected = filter(dry.0, b, a)
        let worst = zip(wet.0, expected).map { abs(Double($0) - $1) }.max() ?? 1
        #expect(worst < 2e-6, "peak \(hz) Hz \(gain) dB Q \(q) couple \(couple) differs by \(worst)")
        #expect(wet.0 == wet.1, "stereo channels are processed identically")
    }

    // Measured Logic cascades: (band, Hz, slope code, Q, first-order ratio, [(corner ratio, Q)]).
    static let cutCases: [(Bool, Double, Double, Double, Double?, [(Double, Double)])] = [
        (false, 200, 4, 0.71, nil, [(1, 1.31367135), (0.999560393, 0.541650157)]),     // 24 dB/Oct at the default Q
        (true, 5000, 3, 1, 0.642290879, [(1, 1.1892)]),                               // 18 dB/Oct high cut
        (false, 1000, 6, 2, nil, [(1, 4), (0.999959259, 0.707113858), (0.999974542, 0.707101702)]), // Q above 1 scales
        (false, 200, 2, 0.3, nil, [(0.32931717, 0.299999989)]),                       // 12 dB/Oct below Q 0.71
        (false, 300, 1, 5, 0.999931, []),                                             // 6 dB/Oct ignores Q
    ]

    @Test(arguments: 0..<5)
    func channelEqCutsMatchTheMeasuredCascades(index: Int) {
        let (high, hz, code, q, first, sections) = Self.cutCases[index]
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
        let base: UInt32 = high ? 28 : 0
        #expect(dalnok_plugin_set_parameter(e, slot, base, 1) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, base + 1, logNorm(hz, 20, 20_000)) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, base + 2, code / 8) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, base + 3, logNorm(q, 0.1, 100)) == DALNOK_OK)
        let wet = renderStereo(e, 4_800)
        let expected = cascade(dry.0, referenceCut(high: high, hz: hz, rate: 48_000, first: first, sections: sections))
        let worst = zip(wet.0, expected).map { abs(Double($0) - $1) }.max() ?? 1
        #expect(worst < 1e-5, "cut \(high ? "high" : "low") \(hz) Hz code \(code) Q \(q) differs by \(worst)")
    }

    @Test(arguments: [(false, 200.0, 12.0, 10.0), (true, 5000.0, -24.0, 4.0), (false, 1000.0, 6.0, 0.71)])
    func channelEqShelvesMatchTheReference(high: Bool, hz: Double, gain: Double, q: Double) {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let dry = renderStereo(e, 4_800)
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
        let base: UInt32 = high ? 24 : 4
        #expect(dalnok_plugin_set_parameter(e, slot, base, 1) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, base + 1, logNorm(hz, 20, 20_000)) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, base + 2, (gain + 24) / 48) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, base + 3, logNorm(q, 0.1, 100)) == DALNOK_OK)
        let wet = renderStereo(e, 4_800)
        let (b, a) = referenceShelf(high: high, hz: hz, gainDb: gain, q: q, rate: 48_000)
        let worst = zip(wet.0, filter(dry.0, b, a)).map { abs(Double($0) - $1) }.max() ?? 1
        #expect(worst < 2e-6, "shelf \(high ? "high" : "low") \(hz) Hz \(gain) dB Q \(q) differs by \(worst)")
    }

    @Test func channelEqReportsItsExactResponse() {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
        dalnok_plugin_set_parameter(e, slot, 17, logNorm(1_000, 20, 20_000)) // peak 3: 1 kHz, +12 dB, Q 1
        dalnok_plugin_set_parameter(e, slot, 18, (12.0 + 24) / 48)
        dalnok_plugin_set_parameter(e, slot, 19, logNorm(1, 0.1, 100))
        let hz: [Double] = [50, 400, 1_000, 2_500, 15_000]
        var db = [Double](repeating: 0, count: hz.count)
        #expect(dalnok_plugin_response(e, slot, hz, Int32(hz.count), &db) == DALNOK_OK)
        let (b, a) = referencePeak(hz: 1_000, gainDb: 12, q: 1, rate: 48_000, coupleMode: -1)
        for (f, got) in zip(hz, db) {
            let w = 2 * Double.pi * f / 48_000
            func mag(_ c: [Double]) -> Double { hypot(c[0] + c[1] * cos(w) + c[2] * cos(2 * w), -(c[1] * sin(w) + c[2] * sin(2 * w))) }
            let want = 20 * log10(mag(b) / mag(a))
            #expect(abs(got - want) < 1e-9, "response at \(f) Hz: \(got) dB, expected \(want)")
        }
        #expect(abs(db[2] - 12) < 1e-6 && abs(db[0]) < 0.1)
        // Hosted plug-ins that can't compute it say so.
        #expect(dalnok_plugin_response(e, 999, hz, 1, &db) == DALNOK_ERR_INVALID_ARG)
    }

    @Test func channelEqDescribesAnyValue() {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
        var cats = [CChar](repeating: 0, count: 64)
        #expect(dalnok_plugin_categories(e, slot, &cats, 64) == 5 && cstr(cats) == "Fx|EQ", "declares \(cstr(cats))")
        var text = [CChar](repeating: 0, count: 64)
        #expect(dalnok_plugin_parameter_text(e, slot, 1, 1, &text, 64) == DALNOK_OK && cstr(text) == "20000") // low cut Hz
        #expect(dalnok_plugin_parameter_text(e, slot, 2, 0.5, &text, 64) == DALNOK_OK && cstr(text) == "24 dB/Oct")
        #expect(dalnok_plugin_parameter_text(e, slot, 0, 0, &text, 64) == DALNOK_OK && cstr(text) == "Off")
        #expect(dalnok_plugin_parameter_text(e, slot, 99, 0, &text, 64) == DALNOK_ERR_NOT_FOUND)
        var p = DalnokPluginParameter()
        dalnok_plugin_parameter(e, slot, 1, &p)
        #expect(abs(p.value - p.default_value) < 1e-12, "describing a value leaves the parameter alone")
    }

    @Test func channelEqStateSurvivesSaveAndReopen() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
        dalnok_plugin_set_parameter(e, slot, 18, (12.0 + 24) / 48)  // Peak 3 +12 dB
        dalnok_plugin_set_parameter(e, slot, 6, (-6.0 + 24) / 48)   // Low shelf -6 dB
        dalnok_plugin_set_parameter(e, slot, 0, 1)                  // Low cut on
        dalnok_plugin_set_parameter(e, slot, 32, (3.0 + 24) / 48)   // Master +3 dB
        let before = renderStereo(e, 4_800)
        #expect(before.0.allSatisfy { $0.isFinite } && before.0.contains { abs($0) > 1e-3 })
        var err = [CChar](repeating: 0, count: 256)
        let project = tempDir().appendingPathComponent("eq.dalnok")
        #expect(dalnok_project_save(e, project.path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        #expect(dalnok_project_load(e2, project.path, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e2, dalnok_track_at(e2, 0), 0, &info) == DALNOK_OK && info.loaded)
        let after = renderStereo(e2, 4_800)
        #expect(after.0 == before.0 && after.1 == before.1, "reopened project renders identically")
        // A state for another plug-in is rejected and leaves the settings alone.
        #expect(dalnok_plugin_set_state(e2, info.id, Data(#"{"plugin":"other","values":{}}"#.utf8).base64EncodedString()) != DALNOK_OK)
        #expect(renderStereo(e2, 4_800).0 == before.0)
    }

    /// Folding (API 40): a view state of the unit in the device chain. Saved with the project, undoable, run as a
    /// catalog command, and it changes nothing in the audio.
    @Test func foldingIsSavedUndoableAndSilent() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        let slot = dalnok_plugin_add(e, t, "dalnok:channel-eq", nil, nil, 0)
        #expect(slot != 0 && !dalnok_plugin_folded(e, t, slot))
        let before = renderStereo(e, 4_800)
        #expect(dalnok_plugin_set_folded(e, t, slot, true) == DALNOK_OK && dalnok_plugin_folded(e, t, slot))
        #expect(dalnok_plugin_set_folded(e, t, slot, true) != DALNOK_OK, "folding twice is refused")
        #expect(renderStereo(e, 4_800).0 == before.0, "bit-identical output folded")
        var name = [CChar](repeating: 0, count: 64)
        _ = dalnok_undo_name(e, &name, 64)
        #expect(cstr(name) == "Fold Plug-in")
        #expect(dalnok_undo(e) && !dalnok_plugin_folded(e, t, slot), "undo unfolds")
        var out = [CChar](repeating: 0, count: 256)
        #expect(dalnok_command_run(e, "plugin.setFolded", "{\"track\": \(t), \"slot\": \(slot), \"folded\": true}", &out, 256) == DALNOK_OK, "\(cstr(out))")
        #expect(dalnok_plugin_folded(e, t, slot))
        let path = tempDir().appendingPathComponent("fold-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK)
        let e2 = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e2) }
        var missing: Int32 = 0
        #expect(dalnok_project_load(e2, path, &missing, nil, 0) == DALNOK_OK)
        var info = DalnokPluginSlotInfo()
        let t2 = dalnok_track_at(e2, 0)
        #expect(dalnok_track_plugin_info(e2, t2, 0, &info) == DALNOK_OK && dalnok_plugin_folded(e2, t2, info.id), "saved and reopened folded")
        #expect(!dalnok_project_dirty(e2))
    }
}

/// Plug-in copy and paste between tracks (API 47) and empty tracks becoming instrument tracks.
@Suite struct PluginCopyTests {
    func slots(_ e: OpaquePointer, _ t: DalnokTrackId) -> [DalnokPluginSlotInfo] {
        (0..<dalnok_track_plugin_count(e, t)).map { i in var s = DalnokPluginSlotInfo(); _ = dalnok_track_plugin_info(e, t, i, &s); return s }
    }
    func value(_ e: OpaquePointer, _ slot: Int32, _ id: UInt32) -> Double {
        for i in 0..<dalnok_plugin_parameter_count(e, slot) {
            var p = DalnokPluginParameter()
            if dalnok_plugin_parameter(e, slot, i, &p) == DALNOK_OK, p.id == id { return p.value }
        }
        return -1
    }

    @Test func pastedPluginsKeepTheirStateAndProcessTheSame() {
        let (e, a) = audioSession(); defer { dalnok_engine_destroy(e) }
        let first = dalnok_plugin_add(e, a, "dalnok:channel-eq", nil, nil, 0)
        let second = dalnok_plugin_add(e, a, "dalnok:channel-eq", nil, nil, 0)
        #expect(dalnok_plugin_set_parameter(e, first, 18, 0.875) == DALNOK_OK) // peak 3 at +18 dB
        let b = dalnok_track_add(e, "B")
        let tail = dalnok_plugin_add(e, b, "dalnok:channel-eq", nil, nil, 0)
        var src = [second, first] // any order: pasted in their chain order
        var out = [Int32](repeating: 0, count: 4)
        #expect(dalnok_plugins_copy(e, a, &src, 2, b, 0, &out, 4) == 2)
        #expect(undoName(e) == "Paste Plug-ins")
        let pasted = slots(e, b).map(\.id)
        #expect(pasted == [out[0], out[1], tail], "pasted at index 0, in chain order, before the existing unit")
        #expect(abs(value(e, out[0], 18) - 0.875) < 1e-9 && abs(value(e, out[1], 18) - value(e, second, 18)) < 1e-9,
                "the copies carry the originals' settings")
        #expect(slots(e, a).map(\.id) == [first, second], "the source chain is unchanged")
        dalnok_undo(e)
        #expect(slots(e, b).map(\.id) == [tail], "one undo removes every pasted unit")
        #expect(dalnok_plugins_copy(e, a, &src, 2, 999, -1, nil, 0) == 0, "no such track")
    }

    @Test func emptyAudioTrackBecomesAnInstrumentTrackForAMidiClip() {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "New")
        var info = DalnokTrackInfo()
        let c = dalnok_midi_clip_add(e, t, 0, 48_000)
        #expect(c != 0)
        #expect(dalnok_track_info(e, t, &info) == DALNOK_OK && info.kind == Int32(DALNOK_TRACK_INSTRUMENT.rawValue) && info.armed)
        var note = DalnokNote(start: 0, length: 24_000, pitch: 69, velocity: 127)
        _ = dalnok_midi_clip_set_notes(e, c, &note, 1)
        #expect(rms(render(e, 0, 9_600)[4_800...]) > 0.01, "the built-in synth plays the clip")
        dalnok_undo(e); dalnok_undo(e)
        #expect(dalnok_track_info(e, t, &info) == DALNOK_OK && info.kind == Int32(DALNOK_TRACK_AUDIO.rawValue) && !info.armed,
                "undo makes it an empty audio track again")
        // A track with audio stays an audio track.
        let (f, audio) = audioSession(); defer { dalnok_engine_destroy(f) }
        #expect(dalnok_midi_clip_add(f, audio, 0, 48_000) == 0)
    }
}
