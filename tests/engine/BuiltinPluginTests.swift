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
}
