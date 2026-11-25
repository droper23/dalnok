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
        let sharp = GuitarTuneDisplay.Reading(hz: 440 * pow(2, 0.6 / 12), cents: 60, confidence: 97)
        check(sharp.note == "A♯4" && sharp.target == "A4", "Guitar Tune shows the target as well as the note played (\(sharp.note) → \(sharp.target))")
        check(GuitarTuneDisplay.Reading(hz: 440, cents: 2, confidence: 97).status == "✓ IN TUNE", "within 3 cents reads IN TUNE (not colour alone)")
        check(GuitarTuneDisplay.Reading(hz: 440, cents: 30, confidence: 97, tolerance: 20).status.contains("BEND"),
              "outside the Bend Tolerance it says the bend is left alone")
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
        if let tuner { // a tracking reading, for the snapshot (live input isn't available here)
            tuner.update(.init(hz: 196 * pow(2, -0.12 / 12), cents: -12, confidence: 95, tolerance: 45))
            tuner.display()
            try? w.snapshot(to: workdir.appendingPathComponent("guitar-tune-tracking.png"))
            check(tuner.reading.target == "G3", "the tracking display names its target (G3)")
        }
        check(dalnok_plugin_set_parameter(s.engine.handle, slot, 0, 0.42) == DALNOK_OK, "Guitar Tune correction amount edits")
        device.refreshValues()
        check(abs((device.current(0)?.value ?? -1) - 0.42) < 1e-6, "Guitar Tune controls re-query the engine")
        checkGuitarPresets(device)
        let studioSlot = (try? s.addPlugin(track, path: "dalnok:guitar-studio")) ?? 0
        check(studioSlot != 0, "Guitar Studio inserts after Guitar Tune")
        defer { if studioSlot != 0 { s.removePlugin(track, studioSlot) } }
        if let studio = w.devicePanel.devices.first(where: { $0.slot == studioSlot }) {
            try? w.snapshot(to: workdir.appendingPathComponent("guitar-tune.png"))
            checkStudioModules(studio)
            checkStudioPresets(studio)
            checkGuitarEditors(track: track, tune: slot, studio: studio)
        } else { check(false, "Guitar Studio device appears") }
    }

    /// The plug-in windows' own editors: Guitar Studio's stage of hardware units and Guitar Tune's rack, driven with
    /// real mouse events, and snapshots of every unit design.
    private func checkGuitarEditors(track: DalnokTrackId, tune: Int32, studio d: DeviceView) {
        let h = s.engine.handle
        func save(_ v: NSView, _ name: String) {
            v.layoutSubtreeIfNeeded()
            let scale: CGFloat = 2
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale), pixelsHigh: Int(v.bounds.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = v.bounds.size
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: workdir.appendingPathComponent(name))
        }
        func event(_ v: NSView, _ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, mods: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: v.convert(p, to: nil), modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: v.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        }
        /// Drags `v` from its centre by `dy` points up (window coordinates).
        func dragUp(_ v: NSView, _ dy: CGFloat) {
            let start = v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil)
            func at(_ type: NSEvent.EventType, _ y: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: start.x, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: v.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            v.mouseDown(with: at(.leftMouseDown, start.y))
            for k in 1...8 { v.mouseDragged(with: at(.leftMouseDragged, start.y + dy * CGFloat(k) / 8)) }
            v.mouseUp(with: at(.leftMouseUp, start.y + dy))
        }
        func click(_ v: NSView, _ p: CGPoint? = nil, clicks: Int = 1) {
            let c = p ?? CGPoint(x: v.bounds.midX, y: v.bounds.midY)
            v.mouseDown(with: event(v, .leftMouseDown, c, clicks: clicks))
            v.mouseUp(with: event(v, .leftMouseUp, c, clicks: clicks))
        }

        // Guitar Studio.
        w.openPluginWindow(track: track, slot: d.slot)
        guard let pw = w.pluginWindows[d.slot], let editor = pw.builtinEditor as? GuitarStudioEditor else {
            return check(false, "Guitar Studio's window shows its own editor")
        }
        defer { pw.window?.close() }
        check(pw.tabs.selectedSegment == 0 && !editor.isHidden && editor.window === pw.window, "Open shows Guitar Studio's editor first")
        let rig = editor.rig
        rig.apply(StudioPreset.factory[0])
        editor.tick()
        editor.layoutSubtreeIfNeeded()
        let stage = editor.stage
        if let picker = rig.quickAddMenu() {
            let choices = picker.items.filter { $0.action != nil }.map(\.title)
            check(choices == StudioLayout.categories.flatMap { category in StudioLayout.catalog.filter { $0.category == category }.map(\.name) },
                  "Guitar Studio's single-level picker offers every module in category order")
            check(picker.items.filter { $0.action == nil && !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled },
                  "picker category headings cannot be selected")
        } else { check(false, "picker is available with free slots") }
        check(stage.modules.map(\.name) == rig.chain().map(\.name), "every module is on the stage in signal order (\(stage.modules.map(\.name)))")
        check(stage.modules.count >= 2 && stage.modules[0].roundLeft && !stage.modules[1].roundLeft, "neighbouring modules snap together")
        // A round screen dragged up raises the engine's value; double-click returns it to the default.
        if let m = stage.modules.first, let dial = m.dials.first {
            let id = StudioLayout.knobId(m.slot, 0)
            rig.set(id, 0.2); editor.tick()
            dragUp(dial, 40)
            check(rig.value(id) > 0.3, "dragging \(m.name)'s first control up turns it up (0.2 → \(rig.value(id)))")
            click(dial, clicks: 2)
            check(abs(rig.value(id) - dial.defaultValue) < 1e-6, "double-clicking a control resets it")
            check(dial.accessibilityRole() == .slider && (dial.accessibilityValue() as? String)?.isEmpty == false, "VoiceOver: controls are sliders with the plug-in's text")
        }
        // The power button switches the module, and the device panel's strip follows.
        if let m = stage.modules.first {
            click(m.power)
            check(!rig.chain()[0].on && d.studioStrip?.chain[0].on == false, "the power button switches \(m.name) off, in the device panel too")
            editor.tick()
            click(stage.modules[0].power)
            check(rig.chain()[0].on, "and on again")
        }
        // Dragging a module's body past its neighbours moves it there; the others close up.
        let before = rig.chain().map(\.name)
        if stage.modules.count >= 3 {
            let m = stage.modules[0], target = stage.modules[2]
            let grab = m.convert(CGPoint(x: m.bounds.midX, y: 30), to: nil)
            let drop = target.convert(CGPoint(x: target.bounds.maxX - 20, y: 30), to: nil) // just past its centre, on its row
            func at(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: m.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            m.mouseDown(with: at(.leftMouseDown, grab))
            for k in 1...12 { m.mouseDragged(with: at(.leftMouseDragged, CGPoint(x: grab.x + (drop.x - grab.x) * CGFloat(k) / 12, y: grab.y + (drop.y - grab.y) * CGFloat(k) / 12))) }
            m.mouseUp(with: at(.leftMouseUp, drop))
            editor.tick()
            let after = rig.chain().map(\.name)
            check(after == [before[1], before[2], before[0]] + before.dropFirst(3), "dragging module 1 past module 3 moves it there (\(after))")
            check(stage.modules.map(\.name) == after, "and the stage follows")
            rig.move(from: 2, to: 0)
        }
        check(!stage.add.isHidden, "an Add Module socket ends a rig with free slots")
        d.moveStudioModule(from: 0, to: 1)
        editor.tick()
        check(stage.modules.map(\.name) == rig.chain().map(\.name), "moving a module in the device panel reorders the editor")
        for m in stage.modules { m.update(time: 1.7, level: 0.75, input: 0.7) } // lit, for the snapshot (no live input here)
        save(editor, "guitar-studio-editor.png")
        // Every module's screen, eight at a time.
        let sets: [[String]] = [
            ["Noise Gate", "Compressor", "Boost", "Overdrive", "Distortion", "Fuzz", "Wah", "Chorus"],
            ["Flanger", "Phaser", "Tremolo", "Vibrato", "Amp Clean", "Amp Crunch", "Amp Lead", "Cabinet"],
            ["EQ", "Delay", "Reverb", "Spring", "Cabinet", "Cabinet"],
        ]
        for (n, names) in sets.enumerated() {
            rig.write(names.map { StudioModule($0) })
            if n == 2 { rig.set(StudioLayout.knobId(4, 0), 0.5); rig.set(StudioLayout.knobId(5, 0), 0) }
            editor.tick()
            editor.layoutSubtreeIfNeeded()
            check(stage.modules.map(\.name) == names, "set \(n + 1): every module appears (\(stage.modules.map(\.name)))")
            check(stage.add.isHidden == (names.count == 8), "the Add Module socket shows only with a free slot")
            for m in stage.modules { m.update(time: 1.7, level: 0.75, input: 0.7) }
            save(editor, "guitar-studio-units-\(n + 1).png")
        }
        rig.apply(StudioPreset.factory[0])
        editor.tick()

        // Guitar Tune.
        w.openPluginWindow(track: track, slot: tune)
        guard let tw = w.pluginWindows[tune], let tuner = tw.builtinEditor as? GuitarTuneEditor else {
            return check(false, "Guitar Tune's window shows its own editor")
        }
        defer { tw.window?.close() }
        tuner.layoutSubtreeIfNeeded()
        let amount = tuner.dials.first { $0.id == 0 }?.view
        if let amount {
            dalnok_plugin_set_parameter(h, tune, 0, 0.2)
            tuner.tick()
            dragUp(amount, 40)
            var p = DalnokPluginParameter()
            dalnok_plugin_parameter(h, tune, 0, &p)
            check(p.value > 0.3, "dragging Guitar Tune's Amount knob turns it up (\(p.value))")
        } else { check(false, "Guitar Tune's editor has its Amount knob") }
        check(tuner.dials.count == 7, "Guitar Tune's editor has all seven controls")
        save(tuner, "guitar-tune-editor-idle.png")
        tuner.preview(.init(hz: 196 * pow(2, -0.12 / 12), cents: -12, confidence: 95, tolerance: 45))
        save(tuner, "guitar-tune-editor-tracking.png")
        tuner.preview(.init(hz: 440, cents: 1.5, confidence: 98, tolerance: 45))
        save(tuner, "guitar-tune-editor-intune.png")
    }

    /// Guitar Studio: the default rig, its faceplate, and every module edit through the real device menu.
    private func checkStudioModules(_ d: DeviceView) {
        let h = s.engine.handle, undoName = s.engine.undoName
        func names() -> [String] { d.studioChain().map(\.name) }
        func fire(_ path: [String]) -> Bool {
            var menu: NSMenu? = d.deviceMenu(), item: NSMenuItem?
            for title in path {
                item = menu?.items.first { $0.title == title }
                menu = item?.submenu
            }
            guard let item, item.isEnabled, let action = item.action else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        func title(_ id: UInt32) -> String { d.current(id).map { fixedString($0.title) } ?? "(hidden)" }
        let engineNames = StudioLayout.catalog.indices.map { t -> String in
            var buf = [CChar](repeating: 0, count: 64)
            dalnok_plugin_parameter_text(h, d.slot, StudioLayout.typeId(0), StudioLayout.normalized(t), &buf, 64)
            return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        check(engineNames == StudioLayout.catalog.map(\.name), "the app's module catalog matches the engine's")
        check(names() == ["Noise Gate", "Compressor", "Amp Crunch", "Cabinet", "Delay", "Reverb"], "a new Guitar Studio is a complete rig (\(names()))")
        checkStudioStrip(d)
        let ids = d.controlIds
        check(ids.first == StudioLayout.input && ids.last == StudioLayout.output && ids.contains(StudioLayout.knobId(2, 0))
              && !ids.contains(StudioLayout.typeId(0)) && !ids.contains(StudioLayout.knobId(6, 0)),
              "the faceplate shows every module's controls in chain order, between input and output")
        check(title(StudioLayout.knobId(2, 0)) == "3 Amp Crunch Gain", "controls are labelled by slot and module (\(title(StudioLayout.knobId(2, 0))))")
        let reverb = d.studioChain()[5]
        check(fire(["Add Module", "Time", "Spring"]) && names().last == "Spring" && names().count == 7, "Add Module ▸ Time ▸ Spring adds it at the end")
        check(title(StudioLayout.knobId(6, 0)) == "7 Spring Decay" && d.controlIds.contains(StudioLayout.knobId(6, 0)), "the new module's controls appear")
        check(fire(["Modules", "7 · Spring", "Move Earlier"]) && names()[5] == "Spring" && names()[6] == "Reverb", "Move Earlier swaps it with the reverb")
        check(d.studioChain()[6].knobs == reverb.knobs, "moving keeps every knob of the module it passes")
        check(fire(["Modules", "6 · Spring", "Replace With", "Modulation", "Flanger"]) && names()[5] == "Flanger"
              && title(StudioLayout.knobId(5, 0)) == "6 Flanger Rate", "Replace With ▸ Flanger swaps the module and its controls")
        check(fire(["Modules", "6 · Flanger", "Turn Off"]) && !d.studioChain()[5].on
              && d.deviceMenu().items.first { $0.title == "Modules" }?.submenu?.items.contains { $0.title == "6 · Flanger (off)" } == true,
              "Turn Off switches the module off and the menu says so")
        check(fire(["Modules", "6 · Flanger (off)", "Remove"]) && names() == ["Noise Gate", "Compressor", "Amp Crunch", "Cabinet", "Delay", "Reverb"],
              "Remove closes the gap")
        check(fire(["Add Module", "Modulation", "Chorus"]) && fire(["Add Module", "Drive", "Fuzz"]) && names().count == 8
              && !fire(["Add Module", "Time", "Delay"]), "all eight slots fill, then Add Module is unavailable")
        check(fire(["Modules", "8 · Fuzz", "Remove"]) && fire(["Modules", "7 · Chorus", "Remove"]) && names().count == 6, "remove the extra modules")
        check(s.engine.undoName == undoName, "module edits leave the undo history alone (plug-in settings, like knob moves)")
    }

    /// The slot strip: the rig in order, drag to reorder, click a light to switch, VoiceOver actions; pedal labels.
    private func checkStudioStrip(_ d: DeviceView) {
        func names() -> [String] { d.studioChain().map(\.name) }
        check(PedalLabel.studio("3 Amp Crunch Gain") == "3 GAIN" && PedalLabel.studio("1 Noise Gate Threshold") == "1 THRESH"
              && PedalLabel.studio("4 Cabinet High-cut") == "4 HI CUT"
              && PedalLabel.short("Correction Amount") == "AMOUNT" && PedalLabel.short("Bend Tolerance") == "BEND", "pedal labels are the slot and the knob (no truncated module names)")
        guard let strip = d.studioStrip else { return check(false, "Guitar Studio shows its slot strip") }
        w.window?.layoutIfNeeded()
        let before = names()
        check(strip.chain.map(\.name) == before && strip.bounds.width > 300, "the strip shows the rig in signal order (\(strip.chain.map(\.name)), \(strip.bounds.width) pt)")
        check(strip.accessibilityChildren()?.count == before.count + 1, "VoiceOver: one button per module and Add Module")
        var c = strip.cells
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { strip.convert(CGPoint(x: x, y: y), to: nil) }
        strip.mouseDown(with: mouse(.leftMouseDown, at(c[0].midX, c[0].midY)))
        strip.mouseDragged(with: mouse(.leftMouseDragged, at((c[1].midX + c[2].midX) / 2, c[0].midY)))
        strip.mouseDragged(with: mouse(.leftMouseDragged, at(c[2].midX, c[0].midY)))
        strip.mouseUp(with: mouse(.leftMouseUp, at(c[2].midX, c[0].midY)))
        check(names() == [before[1], before[2], before[0]] + before.dropFirst(3), "dragging slot 1 onto slot 3 moves it there (\(names()))")
        check(strip.chain.map(\.name) == names(), "the strip follows the move")
        c = strip.cells
        let lightAt = strip.light(c[2])
        strip.mouseDown(with: mouse(.leftMouseDown, at(lightAt.midX, lightAt.midY)))
        strip.mouseUp(with: mouse(.leftMouseUp, at(lightAt.midX, lightAt.midY)))
        check(!d.studioChain()[2].on, "clicking a module's light switches it off")
        strip.mouseDown(with: mouse(.leftMouseDown, at(lightAt.midX, lightAt.midY)))
        strip.mouseUp(with: mouse(.leftMouseUp, at(lightAt.midX, lightAt.midY)))
        check(d.studioChain()[2].on, "and on again")
        func act(_ i: Int, _ name: String) -> Bool {
            guard let e = strip.accessibilityChildren()?[i] as? NSAccessibilityElement,
                  let a = e.accessibilityCustomActions()?.first(where: { $0.name == name }) else { return false }
            return a.handler?() ?? false
        }
        check(act(2, "Move Earlier") && act(1, "Move Earlier") && names() == before, "VoiceOver's Move Earlier puts it back (\(names()))")
        try? w.snapshot(to: workdir.appendingPathComponent("guitar-studio-strip.png"))
    }

    /// Guitar Studio's factory rigs: each replaces the whole chain, and applying one again gives the identical state.
    private func checkStudioPresets(_ d: DeviceView) {
        let h = s.engine.handle, undoName = s.engine.undoName
        func state() -> String {
            let n = dalnok_plugin_get_state(h, d.slot, nil, 0)
            var b = [CChar](repeating: 0, count: n + 1)
            dalnok_plugin_get_state(h, d.slot, &b, b.count)
            return String(decoding: b.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        func apply(_ name: String) -> Bool {
            guard let item = d.deviceMenu().items.first(where: { $0.title == "Factory Presets" })?.submenu?.items.first(where: { $0.title == name }),
                  let action = item.action else { return false }
            return NSApp.sendAction(action, to: item.target, from: item)
        }
        check(StudioPreset.factory.count >= 6, "Guitar Studio offers \(StudioPreset.factory.count) factory rigs")
        for preset in StudioPreset.factory {
            check(apply(preset.name), "apply \(preset.name) through the real menu")
            let chain = d.studioChain()
            let matches = chain.count == preset.modules.count && zip(chain, preset.modules).allSatisfy { got, want in
                got.type == want.type && got.on == want.on && want.knobs.allSatisfy { abs((got.knobs[$0.key] ?? -1) - $0.value) < 1e-9 }
            }
            check(matches, "\(preset.name) sets exactly its modules and knobs (\(chain.map(\.name)))")
            let first = state()
            dalnok_plugin_set_parameter(h, d.slot, StudioLayout.knobId(0, 0), 0.123)
            check(apply(StudioPreset.factory[0].name) && apply(preset.name) && state() == first, "\(preset.name) replaces every setting")
        }
        check(s.engine.undoName == undoName, "presets leave the undo history alone")
        check(apply("High-Gain Lead"), "end on a full rig for the snapshot")
        d.refreshValues()
        check(d.studioStrip?.preset?.name == "High-Gain Lead" && d.studioStrip?.preset?.edited == false, "the strip names the loaded rig")
        let knob = StudioLayout.knobId(0, 0), was = d.current(knob)?.value ?? 0
        dalnok_plugin_set_parameter(h, d.slot, knob, was > 0.5 ? 0.2 : 0.8)
        d.refreshValues()
        check(d.studioStrip?.preset?.edited == true, "and marks it edited after a knob moves")
        dalnok_plugin_set_parameter(h, d.slot, knob, was)
        d.refreshValues()
        try? w.snapshot(to: workdir.appendingPathComponent("guitar-studio.png"))
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
