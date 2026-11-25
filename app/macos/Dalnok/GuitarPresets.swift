// Guitar Tune's factory presets, and Guitar Studio's module chain: its layout, factory rigs, and the device menu
// that adds, reorders, replaces, switches and removes modules.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

/// A Guitar Tune starting point, stored as a complete built-in state so earlier settings never leak into it.
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
        guard plugin == "guitar-tune" else { return [] }
        // Writable parameters 0...6. Meter values are deliberately not persisted.
        let defaults: [Double] = [80, 80, 45, 440, 0, 0, 100]
        func preset(_ name: String, _ overrides: [Int: Double] = [:]) -> GuitarPreset {
            var values = defaults
            for (id, value) in overrides { values[id] = value }
            return GuitarPreset(name: name, plugin: plugin, values: values)
        }
        return [preset("Natural Lead"), preset("Tight Lead", [0: 100, 1: 15, 2: 0]), preset("Gentle", [0: 50, 1: 150, 2: 35])]
    }
}

/// Guitar Studio's parameters (engine/src/fx/guitar_studio.hpp): input, output, then eight slots of module, switch
/// and six knobs. The catalog is in the engine's order; the self-test checks the names against the engine.
enum StudioLayout {
    static let slots = 8, knobs = 6
    static let input: UInt32 = 0, output: UInt32 = 1
    static func typeId(_ s: Int) -> UInt32 { UInt32(2 + s * (2 + knobs)) }
    static func onId(_ s: Int) -> UInt32 { typeId(s) + 1 }
    static func knobId(_ s: Int, _ k: Int) -> UInt32 { typeId(s) + 2 + UInt32(k) }
    static let catalog: [(name: String, category: String)] = [
        ("Empty", ""), ("Noise Gate", "Dynamics"), ("Compressor", "Dynamics"),
        ("Boost", "Drive"), ("Overdrive", "Drive"), ("Distortion", "Drive"), ("Fuzz", "Drive"),
        ("Amp Clean", "Amp & Cabinet"), ("Amp Crunch", "Amp & Cabinet"), ("Amp Lead", "Amp & Cabinet"), ("Cabinet", "Amp & Cabinet"),
        ("EQ", "Filter & EQ"), ("Wah", "Filter & EQ"),
        ("Chorus", "Modulation"), ("Flanger", "Modulation"), ("Phaser", "Modulation"), ("Tremolo", "Modulation"), ("Vibrato", "Modulation"),
        ("Delay", "Time"), ("Reverb", "Time"), ("Spring", "Time"),
    ]
    static let categories = ["Dynamics", "Drive", "Amp & Cabinet", "Filter & EQ", "Modulation", "Time"]
    static func type(named name: String) -> Int { catalog.firstIndex { $0.name == name } ?? 0 }
    static func normalized(_ type: Int) -> Double { Double(type) / Double(catalog.count - 1) }
    static func type(_ normalized: Double) -> Int { max(0, min(catalog.count - 1, Int((normalized * Double(catalog.count - 1)).rounded()))) }
}

/// One module in a chain: its type, switch, and knob positions (normalized 0-1; a missing knob keeps its default).
struct StudioModule: Equatable {
    var type: Int
    var on = true
    var knobs: [Int: Double] = [:]
    init(_ name: String, on: Bool = true, _ dial: [Int: Double] = [:]) { // dial: knob positions 0-10, like a pedal
        type = StudioLayout.type(named: name)
        self.on = on
        knobs = dial.mapValues { $0 / 10 }
    }
    init(type: Int, on: Bool, knobs: [Int: Double]) { self.type = type; self.on = on; self.knobs = knobs }
    var name: String { StudioLayout.catalog[type].name }
}

/// A complete Guitar Studio rig. Applying one writes every slot (unused slots become empty) and both gains.
struct StudioPreset {
    let name: String
    var input = 0.0, output = 0.0 // dB
    let modules: [StudioModule]

    static let factory: [StudioPreset] = [
        StudioPreset(name: "Clean Chorus", modules: [
            StudioModule("Compressor", [0: 4.4, 4: 3, 5: 10]),
            StudioModule("Amp Clean", [0: 3, 2: 4.5, 3: 6, 4: 5.5]),
            StudioModule("Cabinet", [0: 5, 1: 3, 2: 2]),
            StudioModule("Chorus", [1: 5, 4: 4]),
            StudioModule("Reverb", [0: 6.1, 5: 2]),
        ]),
        StudioPreset(name: "Blues Crunch", modules: [
            StudioModule("Noise Gate", [0: 3.5]),
            StudioModule("Overdrive", [0: 3.5, 1: 5.5, 2: 7.2]),
            StudioModule("Amp Crunch", [0: 3.5, 2: 6, 3: 5.5]),
            StudioModule("Cabinet", [0: 5, 1: 2.5]),
            StudioModule("Spring", [0: 5, 3: 2.5]),
        ]),
        StudioPreset(name: "Rock Rhythm", modules: [
            StudioModule("Noise Gate", [0: 5]),
            StudioModule("Amp Crunch", [0: 6.5, 1: 6, 2: 6.5, 3: 5.5, 4: 6]),
            StudioModule("Cabinet", [0: 10, 1: 2, 2: 1]),
            StudioModule("Reverb", [0: 4.5, 1: 3, 5: 1.2]),
        ]),
        StudioPreset(name: "High-Gain Lead", modules: [
            StudioModule("Noise Gate", [0: 5.7, 1: 4]),
            StudioModule("Overdrive", [0: 1, 1: 6, 2: 8]),
            StudioModule("Amp Lead", [0: 7.5, 1: 5.5, 2: 6.5, 3: 5.5, 4: 6]),
            StudioModule("Cabinet", [0: 10, 1: 3]),
            StudioModule("Delay", [0: 6.6, 1: 3.2, 5: 2.5]),
            StudioModule("Reverb", [0: 6.5, 5: 2]),
        ]),
        StudioPreset(name: "Ambient Swell", modules: [
            StudioModule("Compressor", [0: 4, 4: 3]),
            StudioModule("Amp Clean", [0: 2.5, 3: 4.5]),
            StudioModule("Cabinet", [0: 5, 2: 4]),
            StudioModule("Chorus", [0: 3, 1: 6, 4: 3.5]),
            StudioModule("Delay", [0: 7.4, 1: 6, 2: 4, 3: 3, 4: 6, 5: 4]),
            StudioModule("Reverb", [0: 8.3, 1: 9, 2: 4, 5: 5]),
        ]),
        StudioPreset(name: "Surf Spring", modules: [
            StudioModule("Amp Clean", [0: 4, 1: 4, 3: 7, 4: 6]),
            StudioModule("Cabinet", [0: 0, 1: 2]),
            StudioModule("Tremolo", [0: 7.3, 1: 5]),
            StudioModule("Spring", [0: 6.5, 2: 7, 3: 4.5]),
        ]),
        StudioPreset(name: "Funk Wah", modules: [
            StudioModule("Compressor", [0: 3.6, 1: 6, 2: 3, 4: 4]),
            StudioModule("Wah", [0: 2, 1: 6, 3: 7]),
            StudioModule("Amp Clean", [0: 3.5, 2: 5.5, 3: 6]),
            StudioModule("Cabinet", [0: 5, 1: 2]),
            StudioModule("Phaser", [0: 3, 1: 4, 5: 3]),
        ]),
        StudioPreset(name: "Fuzz Psych", modules: [
            StudioModule("Fuzz", [0: 7, 1: 6, 2: 3, 3: 6]),
            StudioModule("Amp Crunch", [0: 2.5, 2: 5]),
            StudioModule("Cabinet", [0: 10, 1: 4]),
            StudioModule("Flanger", [0: 3, 3: 7, 5: 4]),
            StudioModule("Delay", [0: 6.8, 1: 4.5, 4: 8, 5: 3]),
        ]),
    ]
}

extension DeviceView {
    func guitarPresetMenu() -> NSMenuItem? {
        var entries: [(String, () -> Void)] = []
        if isGuitarStudio {
            entries = StudioPreset.factory.map { p in (p.name, { [weak self] in self?.applyStudioPreset(p) }) }
        } else {
            entries = GuitarPreset.factory(for: pluginPath).map { p in (p.name, { [weak self] in self?.applyGuitarPreset(p) }) }
        }
        guard !entries.isEmpty else { return nil }
        let submenu = NSMenu(title: "Factory Presets")
        submenu.autoenablesItems = false
        for (name, run) in entries {
            let item = ClosureMenuItem(title: name, action: run)
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

    private func applyStudioPreset(_ preset: StudioPreset) {
        writeStudioChain(preset.modules)
        let h = session.engine.handle
        dalnok_plugin_set_parameter(h, slot, StudioLayout.input, (preset.input + 24) / 48)
        dalnok_plugin_set_parameter(h, slot, StudioLayout.output, (preset.output + 36) / 48)
        studioChanged("Loaded \(preset.name)")
    }

    // MARK: Guitar Studio modules

    private func studioValue(_ id: UInt32) -> Double {
        var p = DalnokPluginParameter()
        return dalnok_plugin_parameter(session.engine.handle, slot, Int32(id), &p) == DALNOK_OK ? p.value : 0 // index == id
    }

    /// The modules in slot order (empty slots skipped), with every knob's position.
    func studioChain() -> [StudioModule] {
        (0..<StudioLayout.slots).compactMap { s in
            let type = StudioLayout.type(studioValue(StudioLayout.typeId(s)))
            guard type != 0 else { return nil }
            let knobs = Dictionary(uniqueKeysWithValues: (0..<StudioLayout.knobs).map { ($0, studioValue(StudioLayout.knobId(s, $0))) })
            return StudioModule(type: type, on: studioValue(StudioLayout.onId(s)) >= 0.5, knobs: knobs)
        }
    }

    /// Writes `chain` into slots 1… and empties the rest. Each slot is set to Empty and then to its module, so the
    /// module starts from its defaults and only the given knobs change. Slots already holding exactly that module
    /// with all its knobs are left alone (nothing restarts while playing).
    func writeStudioChain(_ chain: [StudioModule]) {
        let h = session.engine.handle
        let current = (0..<StudioLayout.slots).map { s -> StudioModule in
            let knobs = Dictionary(uniqueKeysWithValues: (0..<StudioLayout.knobs).map { ($0, studioValue(StudioLayout.knobId(s, $0))) })
            return StudioModule(type: StudioLayout.type(studioValue(StudioLayout.typeId(s))), on: studioValue(StudioLayout.onId(s)) >= 0.5, knobs: knobs)
        }
        for s in 0..<StudioLayout.slots {
            let m = s < chain.count ? chain[s] : StudioModule(type: 0, on: true, knobs: [:])
            if m.knobs.count == StudioLayout.knobs, current[s] == m { continue }
            if m.type == 0, current[s].type == 0 { continue }
            if m.type == current[s].type, m.knobs.count == StudioLayout.knobs, m.knobs == current[s].knobs { // only the switch
                dalnok_plugin_set_parameter(h, slot, StudioLayout.onId(s), m.on ? 1 : 0)
                continue
            }
            dalnok_plugin_set_parameter(h, slot, StudioLayout.typeId(s), 0)
            guard m.type != 0 else { continue }
            dalnok_plugin_set_parameter(h, slot, StudioLayout.typeId(s), StudioLayout.normalized(m.type))
            dalnok_plugin_set_parameter(h, slot, StudioLayout.onId(s), m.on ? 1 : 0)
            for (k, v) in m.knobs { dalnok_plugin_set_parameter(h, slot, StudioLayout.knobId(s, k), max(0, min(1, v))) }
        }
    }

    private func studioChanged(_ message: String) {
        session.refresh()
        reloadParameters()
        session.onMessage?(message)
    }

    /// Device menu entries: Add Module ▸ (by category) and Modules ▸ (each module: switch, move, replace, remove).
    func studioModuleItems() -> [NSMenuItem] {
        let chain = studioChain()
        func catalogMenu(_ title: String, _ pick: @escaping (Int) -> Void) -> NSMenuItem {
            let menu = NSMenu(title: title)
            for category in StudioLayout.categories {
                let sub = NSMenu(title: category)
                for (type, entry) in StudioLayout.catalog.enumerated() where entry.category == category {
                    sub.addItem(ClosureMenuItem(title: entry.name) { pick(type) })
                }
                let item = NSMenuItem(title: category, action: nil, keyEquivalent: "")
                item.submenu = sub
                menu.addItem(item)
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }
        let add = catalogMenu("Add Module") { [weak self] type in
            guard let self else { return }
            self.writeStudioChain(chain + [StudioModule(type: type, on: true, knobs: [:])])
            self.studioChanged("Added \(StudioLayout.catalog[type].name)")
        }
        if chain.count >= StudioLayout.slots {
            add.isEnabled = false
            add.title = "Add Module (all \(StudioLayout.slots) slots used)"
        }
        let modules = NSMenu(title: "Modules")
        modules.autoenablesItems = false
        for (i, m) in chain.enumerated() {
            let sub = NSMenu(title: m.name)
            sub.autoenablesItems = false
            func edit(_ title: String, enabled: Bool = true, message: String, _ change: @escaping (inout [StudioModule]) -> Void) {
                let item = ClosureMenuItem(title: title) { [weak self] in
                    var next = chain
                    change(&next)
                    self?.writeStudioChain(next)
                    self?.studioChanged(message)
                }
                item.isEnabled = enabled
                sub.addItem(item)
            }
            edit(m.on ? "Turn Off" : "Turn On", message: "\(m.name) \(m.on ? "off" : "on")") { $0[i].on.toggle() }
            edit("Move Earlier", enabled: i > 0, message: "Moved \(m.name) earlier") { $0.swapAt(i, i - 1) }
            edit("Move Later", enabled: i < chain.count - 1, message: "Moved \(m.name) later") { $0.swapAt(i, i + 1) }
            sub.addItem(catalogMenu("Replace With") { [weak self] type in
                guard let self else { return }
                var next = chain
                next[i] = StudioModule(type: type, on: true, knobs: [:])
                self.writeStudioChain(next)
                self.studioChanged("Replaced \(m.name) with \(StudioLayout.catalog[type].name)")
            })
            sub.addItem(.separator())
            edit("Remove", message: "Removed \(m.name)") { $0.remove(at: i) }
            let item = NSMenuItem(title: "\(i + 1) · \(m.name)\(m.on ? "" : " (off)")", action: nil, keyEquivalent: "")
            item.submenu = sub
            modules.addItem(item)
        }
        if chain.isEmpty { let none = NSMenuItem(title: "No modules yet", action: nil, keyEquivalent: ""); none.isEnabled = false; modules.addItem(none) }
        let parent = NSMenuItem(title: "Modules", action: nil, keyEquivalent: "")
        parent.submenu = modules
        return [add, parent]
    }
}
