// Factory starting points, stored as complete built-in states so previous settings never leak into a preset.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

struct GuitarPreset {
    let name: String
    let plugin: String
    let values: [Double]

    func state() throws -> String {
        let parameters = Dictionary(uniqueKeysWithValues: values.enumerated().map { (String($0.offset), $0.element) })
        let data = try JSONSerialization.data(withJSONObject: ["plugin": plugin, "version": 1, "values": parameters], options: [.sortedKeys])
        return data.base64EncodedString()
    }

    static func factory(for path: String) -> [GuitarPreset] {
        let plugin = path.hasPrefix("dalnok:") ? String(path.dropFirst(7)) : path
        func preset(_ name: String, _ defaults: [Double], _ overrides: [Int: Double] = [:]) -> GuitarPreset {
            var values = defaults
            for (id, value) in overrides { values[id] = value }
            return GuitarPreset(name: name, plugin: plugin, values: values)
        }
        switch plugin {
        case "guitar-tune":
            // Writable parameters 0...6. Meter values are deliberately not persisted.
            let defaults: [Double] = [80, 80, 45, 440, 0, 0, 100]
            return [preset("Natural Lead", defaults),
                    preset("Tight Lead", defaults, [0: 100, 1: 15, 2: 0]),
                    preset("Gentle", defaults, [0: 50, 1: 150, 2: 35])]
        case "guitar-studio":
            // Parameter order matches GuitarStudio::params. Every preset resets the entire chain.
            let defaults: [Double] = [0, -70, 20, 0, 30, 0, 0, 0, 0, 100, 0.7, 2, 0, 4, 0, 375, 30, 0, 1.8, 5000, 12, -6, 100]
            return [preset("Clean Glass", defaults, [1: -75, 2: 25, 3: 0, 4: 20, 5: -1, 6: 0, 7: 2, 8: 0, 12: 15, 17: 0, 20: 15, 21: -6]),
                    preset("Edge Crunch", defaults, [1: -65, 2: 10, 3: 1, 4: 45, 5: 1, 6: 2, 7: -1, 8: 1, 12: 0, 17: 0, 20: 8, 21: -4]),
                    preset("Singing Lead", defaults, [1: -60, 2: 20, 3: 2, 4: 60, 5: 0, 6: 3, 7: -2, 8: 2, 12: 0, 15: 375, 16: 32, 17: 20, 18: 2.2, 20: 16, 21: -2])]
        default: return []
        }
    }
}

extension DeviceView {
    func guitarPresetMenu() -> NSMenuItem? {
        let presets = GuitarPreset.factory(for: pluginPath)
        guard !presets.isEmpty else { return nil }
        let submenu = NSMenu(title: "Factory Presets")
        submenu.autoenablesItems = false
        for preset in presets {
            let item = ClosureMenuItem(title: preset.name) { [weak self] in self?.applyGuitarPreset(preset) }
            item.isEnabled = loaded
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Factory Presets", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func applyGuitarPreset(_ preset: GuitarPreset) {
        guard let state = try? preset.state(), dalnok_plugin_set_state(session.engine.handle, slot, state) == DALNOK_OK else {
            session.onMessage?("Couldn't load the \(preset.name) preset.")
            return
        }
        session.refresh()
        refreshValues()
        session.onMessage?("Loaded \(preset.name)")
    }
}
