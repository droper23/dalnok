// Guitar Tune display and host integration checks (uses only generated/self-test session content).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

extension SelfTest {
    func guitarPlugins() {
        let reading = GuitarTuneDisplay.Reading(hz: 440, cents: -12.5, confidence: 98)
        check(reading.note == "A4" && reading.tracking, "Guitar Tune names a detected concert A")
        check(GuitarTuneDisplay.Reading(hz: 82.4069, confidence: 99).note == "E2", "Guitar Tune names the low E string")
        check(!GuitarTuneDisplay.Reading(hz: 440, confidence: 30).tracking, "Guitar Tune hides unreliable pitch")
        check(!GuitarTuneDisplay.Reading(hz: 440, confidence: 99, bypassed: true).tracking, "Guitar Tune hides bypassed telemetry")
        guard let track = s.tracks.first(where: { !$0.isInstrument })?.id else { return check(false, "guitar effects need an audio track") }
        w.headers.select(track)
        let slot = (try? s.addPlugin(track, path: "dalnok:guitar-tune")) ?? 0
        check(slot != 0, "Guitar Tune inserts through Dalnok's plug-in workflow")
        defer { if slot != 0 { s.removePlugin(track, slot) } }
        guard let device = w.devicePanel.devices.first(where: { $0.slot == slot }) else { return check(false, "Guitar Tune device appears") }
        device.pollMeters()
        let tuner = (device.display as? GuitarTuneDisplay) ?? device.subviewsDeep.compactMap { $0 as? GuitarTuneDisplay }.first
        check(tuner != nil, "Guitar Tune has a native pitch display in this look")
        check(device.controlIds.contains(0) && !device.controlIds.contains(7), "Guitar Tune offers correction controls, not editable telemetry")
        check(dalnok_plugin_set_parameter(s.engine.handle, slot, 0, 0.42) == DALNOK_OK, "Guitar Tune correction amount edits")
        device.refreshValues()
        check(abs((device.current(0)?.value ?? -1) - 0.42) < 1e-6, "Guitar Tune controls re-query the engine")
        checkGuitarPresets(device)
        let studioSlot = (try? s.addPlugin(track, path: "dalnok:guitar-studio")) ?? 0
        check(studioSlot != 0, "Guitar Studio inserts after Guitar Tune")
        defer { if studioSlot != 0 { s.removePlugin(track, studioSlot) } }
        if let studio = w.devicePanel.devices.first(where: { $0.slot == studioSlot }) {
            checkGuitarPresets(studio)
            check(studio.current(22) != nil, "Guitar Studio exposes its complete effects chain")
        } else { check(false, "Guitar Studio device appears") }
        try? w.snapshot(to: workdir.appendingPathComponent("guitar-tune.png"))
    }

    private func checkGuitarPresets(_ device: DeviceView) {
        func stateValues() -> [String: Double]? {
            let size = dalnok_plugin_get_state(s.engine.handle, device.slot, nil, 0)
            var buf = [CChar](repeating: 0, count: size + 1)
            dalnok_plugin_get_state(s.engine.handle, device.slot, &buf, buf.count)
            guard let data = Data(base64Encoded: String(cString: buf)),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return json["values"] as? [String: Double]
        }
        let presets = GuitarPreset.factory(for: device.pluginPath)
        check(presets.count == 3, "guitar plug-in offers three factory starting points")
        // Presets change plug-in parameters, which live outside Dalnok's undoable model (like knob moves),
        // so a preset must not add an undo step that would undo something else instead.
        for preset in presets {
            let before = stateValues(), undoName = s.engine.undoName
            let beforeState: String = {
                let n = dalnok_plugin_get_state(s.engine.handle, device.slot, nil, 0)
                var b = [CChar](repeating: 0, count: n + 1)
                dalnok_plugin_get_state(s.engine.handle, device.slot, &b, b.count)
                return String(cString: b)
            }()
            guard let menu = device.deviceMenu().items.first(where: { $0.title == "Factory Presets" })?.submenu,
                  let item = menu.items.first(where: { $0.title == preset.name }), let action = item.action else {
                check(false, "\(preset.name) is reachable in the device menu"); continue
            }
            check(NSApp.sendAction(action, to: item.target, from: item), "apply \(preset.name) through the real menu action")
            let expected = Dictionary(uniqueKeysWithValues: preset.values.enumerated().map { (String($0.offset), $0.element) })
            check(stateValues() == expected, "\(preset.name) replaces every writable parameter")
            check(s.engine.undoName == undoName, "\(preset.name) leaves the undo history alone")
            check(dalnok_plugin_set_state(s.engine.handle, device.slot, beforeState) == DALNOK_OK && stateValues() == before,
                  "the settings before \(preset.name) restore completely")
        }
    }
}
