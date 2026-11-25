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
    /// Meters (read-only, dBFS over −90…+12): the input after its gain, then the signal after each slot.
    static let inputLevel = typeId(slots)
    static func levelId(_ s: Int) -> UInt32 { inputLevel + 1 + UInt32(s) }
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
            entries = StudioPreset.factory.map { p in (p.name, { [weak self] in self?.studioRig.apply(p) }) }
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

    // Guitar Studio: the device panel's view of the shared rig controller.
    func studioChain() -> [StudioModule] { studioRig.chain() }
    func writeStudioChain(_ chain: [StudioModule]) { studioRig.write(chain) }
    func toggleStudioModule(_ i: Int) { studioRig.toggle(i) }
    func moveStudioModule(from: Int, to: Int) { studioRig.move(from: from, to: to) }
    func removeStudioModule(_ i: Int) { studioRig.remove(i) }
    func addStudioModule(_ type: Int) { studioRig.add(type) }
    func studioAddMenu() -> NSMenu? { studioRig.addMenu() }
    func studioModuleMenu(_ i: Int) -> NSMenu? { studioRig.moduleMenu(i) }
    func studioModuleItems() -> [NSMenuItem] { studioRig.moduleItems() }
    static var appliedPresets: [Int32: (name: String, state: String)] { StudioRig.appliedPresets }
    func studioState() -> String { studioRig.state() }
    func studioPresetStatus() -> (name: String, edited: Bool)? { studioRig.presetStatus() }
}

/// One Guitar Studio instance's rig, read and written through its parameters: the device panel, its slot strip and the
/// plug-in window's rig editor all edit through this. Every structural edit posts `changed` (object: the plug-in slot)
/// so each view of the same instance follows.
@MainActor
final class StudioRig {
    static let changed = Notification.Name("DalnokStudioRigChanged")
    let engine: Engine
    let slot: Int32
    /// Shows a status message (the main window's flash).
    var onMessage: ((String) -> Void)?
    init(engine: Engine, slot: Int32) { self.engine = engine; self.slot = slot }
    private var h: OpaquePointer { engine.handle }

    func parameter(_ id: UInt32) -> DalnokPluginParameter? {
        var p = DalnokPluginParameter()
        return dalnok_plugin_parameter(h, slot, Int32(id), &p) == DALNOK_OK ? p : nil // index == id
    }
    func value(_ id: UInt32) -> Double { parameter(id)?.value ?? 0 }
    /// A meter's level as 0 (−60 dB or less) to 1 (0 dBFS).
    func level(_ id: UInt32) -> Double { max(0, min(1, (value(id) * 102 - 90 + 60) / 60)) }
    func set(_ id: UInt32, _ value: Double) { dalnok_plugin_set_parameter(h, slot, id, max(0, min(1, value))) }
    func text(_ id: UInt32, at value: Double) -> String? {
        var buf = [CChar](repeating: 0, count: 64)
        guard dalnok_plugin_parameter_text(h, slot, id, value, &buf, 64) == DALNOK_OK else { return nil }
        return String(cString: buf)
    }

    private func module(at s: Int) -> StudioModule {
        let knobs = Dictionary(uniqueKeysWithValues: (0..<StudioLayout.knobs).map { ($0, value(StudioLayout.knobId(s, $0))) })
        return StudioModule(type: StudioLayout.type(value(StudioLayout.typeId(s))), on: value(StudioLayout.onId(s)) >= 0.5, knobs: knobs)
    }
    /// The modules in slot order (empty slots skipped), with every knob's position.
    func chain() -> [StudioModule] { (0..<StudioLayout.slots).map(module(at:)).filter { $0.type != 0 } }
    /// The engine slot of each module in `chain()`.
    func slots() -> [Int] { (0..<StudioLayout.slots).filter { StudioLayout.type(value(StudioLayout.typeId($0))) != 0 } }

    /// One module's knobs as the engine names and prints them (unused knobs are hidden by the engine).
    struct Knob { let id: UInt32; let name: String; let display: String; let value: Double; let defaultValue: Double; let steps: Int }
    func knobs(slot s: Int) -> [Knob] {
        let prefix = "\(s + 1) \(StudioLayout.catalog[StudioLayout.type(value(StudioLayout.typeId(s)))].name) "
        return (0..<StudioLayout.knobs).compactMap { k in
            guard let p = parameter(StudioLayout.knobId(s, k)), !p.hidden else { return nil }
            let title = fixedString(p.title)
            return Knob(id: p.id, name: title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title,
                        display: fixedString(p.display), value: p.value, defaultValue: p.default_value, steps: Int(p.step_count))
        }
    }

    /// Writes `chain` into slots 1… and empties the rest. Each slot is set to Empty and then to its module, so the
    /// module starts from its defaults and only the given knobs change. Slots already holding exactly that module
    /// with all its knobs are left alone (nothing restarts while playing).
    func write(_ chain: [StudioModule]) {
        let current = (0..<StudioLayout.slots).map(module(at:))
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

    private func changed(_ message: String) {
        NotificationCenter.default.post(name: Self.changed, object: NSNumber(value: slot))
        onMessage?(message)
    }
    func edit(_ message: String, _ change: (inout [StudioModule]) -> Void) {
        var next = chain()
        change(&next)
        write(next)
        changed(message)
    }
    func toggle(_ i: Int) {
        let c = chain()
        guard c.indices.contains(i) else { return }
        edit("\(c[i].name) \(c[i].on ? "off" : "on")") { $0[i].on.toggle() }
    }
    func move(from: Int, to: Int) {
        let c = chain()
        guard c.indices.contains(from), c.indices.contains(to), from != to else { return }
        edit("Moved \(c[from].name) to slot \(to + 1)") { $0.insert($0.remove(at: from), at: to) }
    }
    func remove(_ i: Int) {
        let c = chain()
        guard c.indices.contains(i) else { return }
        edit("Removed \(c[i].name)") { $0.remove(at: i) }
    }
    func add(_ type: Int) {
        guard chain().count < StudioLayout.slots else { return }
        edit("Added \(StudioLayout.catalog[type].name)") { $0.append(StudioModule(type: type, on: true, knobs: [:])) }
    }
    func replace(_ i: Int, with type: Int) {
        let c = chain()
        guard c.indices.contains(i) else { return }
        edit("Replaced \(c[i].name) with \(StudioLayout.catalog[type].name)") { $0[i] = StudioModule(type: type, on: true, knobs: [:]) }
    }
    func apply(_ preset: StudioPreset) {
        write(preset.modules)
        set(StudioLayout.input, (preset.input + 24) / 48)
        set(StudioLayout.output, (preset.output + 36) / 48)
        Self.appliedPresets[slot] = (preset.name, state())
        changed("Loaded \(preset.name)")
    }

    /// The module catalog by category; `pick` gets the module type.
    func catalogMenu(_ title: String, _ pick: @escaping (Int) -> Void) -> NSMenu {
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
        return menu
    }
    /// Add Module ▸ by category (nil when all eight slots are used).
    func addMenu() -> NSMenu? {
        chain().count < StudioLayout.slots ? catalogMenu("Add Module") { [weak self] in self?.add($0) } : nil
    }
    /// One module's menu: switch, move, replace, remove (the strip, the rig editor and the device menu share it).
    func moduleMenu(_ i: Int) -> NSMenu? {
        let c = chain()
        guard c.indices.contains(i) else { return nil }
        let m = c[i]
        let sub = NSMenu(title: m.name)
        sub.autoenablesItems = false
        func edit(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: run)
            item.isEnabled = enabled
            sub.addItem(item)
        }
        edit(m.on ? "Turn Off" : "Turn On") { [weak self] in self?.toggle(i) }
        edit("Move Earlier", enabled: i > 0) { [weak self] in self?.move(from: i, to: i - 1) }
        edit("Move Later", enabled: i < c.count - 1) { [weak self] in self?.move(from: i, to: i + 1) }
        let replace = NSMenuItem(title: "Replace With", action: nil, keyEquivalent: "")
        replace.submenu = catalogMenu("Replace With") { [weak self] type in self?.replace(i, with: type) }
        sub.addItem(replace)
        sub.addItem(.separator())
        edit("Remove") { [weak self] in self?.remove(i) }
        return sub
    }
    /// Factory rigs, for a menu.
    func presetMenu() -> NSMenu {
        let menu = NSMenu(title: "Factory Rigs")
        for p in StudioPreset.factory { menu.addItem(ClosureMenuItem(title: p.name) { [weak self] in self?.apply(p) }) }
        return menu
    }

    /// Device menu entries: Add Module ▸ (by category) and Modules ▸ (each module: switch, move, replace, remove).
    func moduleItems() -> [NSMenuItem] {
        let c = chain()
        let add = NSMenuItem(title: "Add Module", action: nil, keyEquivalent: "")
        add.submenu = addMenu()
        if add.submenu == nil {
            add.isEnabled = false
            add.title = "Add Module (all \(StudioLayout.slots) slots used)"
        }
        let modules = NSMenu(title: "Modules")
        modules.autoenablesItems = false
        for (i, m) in c.enumerated() {
            let item = NSMenuItem(title: "\(i + 1) · \(m.name)\(m.on ? "" : " (off)")", action: nil, keyEquivalent: "")
            item.submenu = moduleMenu(i)
            modules.addItem(item)
        }
        if c.isEmpty { let none = NSMenuItem(title: "No modules yet", action: nil, keyEquivalent: ""); none.isEnabled = false; modules.addItem(none) }
        let parent = NSMenuItem(title: "Modules", action: nil, keyEquivalent: "")
        parent.submenu = modules
        return [add, parent]
    }

    // MARK: Which factory rig is loaded

    /// The rig last applied to each Guitar Studio (by plug-in slot) and the state it left, so the strip can name it
    /// and mark it edited. Kept for the session only: a saved project's rig is simply its modules.
    nonisolated(unsafe) static var appliedPresets: [Int32: (name: String, state: String)] = [:]
    func state() -> String {
        let n = dalnok_plugin_get_state(h, slot, nil, 0)
        var b = [CChar](repeating: 0, count: n + 1)
        dalnok_plugin_get_state(h, slot, &b, b.count)
        return String(decoding: b.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
    func presetStatus() -> (name: String, edited: Bool)? {
        guard let p = Self.appliedPresets[slot] else { return nil }
        return (p.name, state() != p.state)
    }
}
