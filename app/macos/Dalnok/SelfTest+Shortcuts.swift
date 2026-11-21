// Self-test steps (Shortcuts), split out of SelfTest.swift (A-18). The harness (check, perform, mouse) lives there.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import DalnokEngine

extension SelfTest {
    // MARK: Track header scrolling (regression: scrolling over the headers did nothing or moved a knob)

    func scrollEvent(dy: Int32, at window: CGPoint) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: 0, wheel3: 0) else { return nil }
        cg.flags = [] // not whatever modifiers the system thinks are held (⌥/⌘ would zoom instead)
        if let win = w.window { cg.location = CGPoint(x: win.frame.minX + window.x, y: (NSScreen.screens.first?.frame.height ?? 0) - (win.frame.minY + window.y)) }
        return NSEvent(cgEvent: cg)
    }

    func trackHeaderScrolling() async {
        let e = s.engine
        var added = 0
        w.window?.layoutIfNeeded()
        let visible = max(w.timeline.bounds.height, 400)
        while CGFloat(s.tracks.count) * Theme.trackHeight < visible * 2, added < 40 { s.addTrack("Scroll \(added)"); added += 1 }
        w.window?.layoutIfNeeded()
        await wait(0.1)
        print("INFO  header scrolling: timeline \(w.timeline.bounds.height) pt, \(s.tracks.count) tracks, max offset \(w.timeline.maxScrollY), hidden \(w.timeline.isHidden)")
        w.timeline.scrollY = 0
        guard let row = w.headers.rows.first, let ev = scrollEvent(dy: -60, at: .zero) else {
            check(false, "header scrolling: rows and scroll events exist"); return
        }
        let before = row.gain.db
        w.headers.scrollWheel(with: ev)
        check(w.timeline.scrollY > 0, "scrolling over the track headers scrolls the tracks (\(w.timeline.scrollY) pt)")
        check(w.headers.scrollY == w.timeline.scrollY && w.launcher.scrollY == w.timeline.scrollY,
              "headers, launcher and arrangement share one vertical offset")
        let y = w.timeline.scrollY
        row.gain.scrollWheel(with: ev)
        check(row.gain.db == before && w.timeline.scrollY > y, "scrolling over a header knob scrolls instead of changing gain")
        // Hit-testing: the view under the cursor in the header column hands scrolling to the column.
        if let content = w.window?.contentView {
            let p = w.headers.convert(CGPoint(x: w.headers.bounds.midX, y: w.headers.bounds.midY), to: nil)
            var v = content.hitTest(content.convert(p, from: nil)), reaches = false
            while let x = v { if x === w.headers { reaches = true; break }; v = x.superview }
            check(reaches, "the view under the cursor over the headers belongs to the header column")
        }
        w.timeline.scrollY = 1e6
        w.timeline.clampScrollY()
        check(w.timeline.scrollY == w.timeline.maxScrollY && w.headers.scrollY == w.timeline.scrollY, "vertical scrolling stops at the last track")
        for _ in 0..<added { e.undo() }
        s.refresh(onDisplayTick: true); w.window?.layoutIfNeeded()
        check(w.timeline.scrollY <= w.timeline.maxScrollY && w.headers.scrollY == w.timeline.scrollY,
              "removing tracks keeps the viewport valid and aligned (\(w.timeline.scrollY))")
        w.timeline.scrollY = 0
    }

    // MARK: Keyboard shortcuts (registry, presets, conflicts, dispatch, editor)

    func keyEvent(_ chars: String, code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: w.window!.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    func shortcutSystem() async {
        let r = ShortcutRegistry.shared
        w.window?.makeKeyAndOrderFront(nil)
        r.selectPreset("dalnok")
        // Parsing and text forms.
        let samples = ["cmd+shift+t", "kp*", "ctrl+space", "f9", "opt+x", "cmd+=", "shift+up", "cmd+["]
        let parsed = samples.compactMap(KeyCombo.init(parsing:))
        check(parsed.count == samples.count && parsed.allSatisfy { KeyCombo(parsing: $0.storage) == $0 },
              "shortcut text round-trips (\(parsed.map(\.description).joined(separator: " ")))")
        check(KeyCombo(parsing: "⇧⌘T") == KeyCombo(parsing: "cmd+shift+t") && KeyCombo(parsing: "Cmd Shift Z")?.description == "⇧⌘Z",
              "symbol and word forms parse to the same shortcut")
        // Every command is registered once, with a category; the brief's named commands exist.
        let ids = r.actions.map(\.id)
        check(Set(ids).count == ids.count && r.actions.count > 70 && r.actions.allSatisfy { !$0.category.isEmpty },
              "registry: \(r.actions.count) commands, unique ids, all categorized")
        let named = ["transport.play_pause", "transport.record", "track.create_audio", "track.create_midi", "track.delete",
                     "edit.split_at_playhead", "mixer.toggle", "plugin.open_browser", "plugin.bypass_track", "view.toggle_analog_mode",
                     "midi.quantize", "edit.undo", "view.full_screen", "app.keyboard_shortcuts"]
        check(named.allSatisfy { r.action($0) != nil }, "named commands are registered (\(named.filter { r.action($0) == nil }))")
        // No preset has conflicts; presets change the menu.
        for p in ShortcutPreset.all {
            r.selectPreset(p.id)
            let c = r.allConflicts()
            check(c.isEmpty, "\(p.title) preset has no conflicts \(c.map { "\($0.0): \($0.1.map(\.id))" })")
        }
        r.selectPreset("ableton")
        check(menuItem("Split at Playhead")?.keyEquivalent == "e" && r.keys("view.clip_launcher") == [KeyCombo("tab")],
              "Ableton preset: Split ⌘E, launcher Tab")
        r.selectPreset("cubase")
        check(r.keys("transport.record").contains(KeyCombo("kp*")) && r.action("transport.record")?.item?.keyEquivalent == "",
              "Cubase preset: Record on keypad * (dispatched by the registry, not the menu)")
        r.selectPreset("dalnok")
        // Owner override: shown in the menu, persisted, dispatched by a real key event; the old key is free.
        let combo = KeyCombo("y", [.command, .option, .shift])
        r.setKeys("transport.metronome", [combo])
        check(menuItem("Metronome")?.keyEquivalent == "y" && menuItem("Metronome")?.keyEquivalentModifierMask == [.command, .option, .shift],
              "a changed shortcut appears in the menu")
        let stored = UserDefaults.standard.dictionary(forKey: ShortcutRegistry.overridesKey) as? [String: [String]]
        check(stored?["transport.metronome"] == ["opt+shift+cmd+y"], "the change is saved (\(stored ?? [:]))")
        r.attach(NSApp.mainMenu)
        check(r.keys("transport.metronome") == [combo], "it survives re-reading the menu (as after a relaunch)")
        let m0 = MainWindowController.metronomeOn
        _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("y", code: 16, [.command, .option, .shift]))
        check(MainWindowController.metronomeOn != m0, "⌥⇧⌘Y toggles the metronome")
        _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("k", code: 40))
        check(MainWindowController.metronomeOn != m0, "K no longer toggles it")
        r.add(KeyCombo("f8"), to: "transport.metronome")
        _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent(String(UnicodeScalar(NSF8FunctionKey)!), code: 100))
        check(MainWindowController.metronomeOn == m0, "a second shortcut (F8) runs the same command")
        // Conflicts: detected, then resolved by reassigning.
        r.add(combo, to: "transport.loop")
        check(r.conflicts(for: combo, in: .global).count == 2 && !r.allConflicts().isEmpty, "giving the key to Cycle too is reported as a conflict")
        r.reassign(combo, to: "transport.loop")
        check(r.keys("transport.loop").contains(combo) && !r.keys("transport.metronome").contains(combo) && r.allConflicts().isEmpty,
              "reassigning moves the key and clears the conflict")
        // Context: ↑ selects the previous track in the arrangement and transposes in the piano roll; not a conflict.
        check(r.resolve(KeyCombo("up"), context: .arrangement)?.id == "track.select_previous" &&
              r.resolve(KeyCombo("up"), context: .pianoRoll)?.id == "midi.transpose_up" && r.allConflicts().isEmpty,
              "the same key does different things in the arrangement and the piano roll")
        check(ShortcutRegistry.reservedBySystem(KeyCombo("space", .command)) != nil, "⌘Space is flagged as belonging to macOS")
        // While renaming a track, ⌃ and ⌥ keys edit and type; only ⌘ shortcuts run (regression: ⌃F/⌃H/⌥' were taken).
        if let row = w.headers.rows.first {
            let fades0 = s.engine.undoName
            row.beginRename()
            await wait(0.1)
            check(MainWindowController.isTyping, "renaming puts a field editor in charge")
            _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("h", code: 4, .control))
            _ = NSApp.mainMenu?.performKeyEquivalent(with: keyEvent("'", code: 39, .option))
            check(s.tracks.count > 0 && s.engine.undoName == fades0 && s.hiddenCount == 0, "⌃H and ⌥' reach the text field, not Hide Track or Add Marker")
            row.cancelRename()
            await wait(0.1)
            // Clicking outside the name field commits the typed name (as Return does).
            let oldName = s.track(row.trackId)?.name ?? ""
            row.beginRename()
            await wait(0.1)
            (w.window?.firstResponder as? NSTextView)?.string = "Renamed By Click"
            let outside = w.timeline.convert(CGPoint(x: w.timeline.bounds.midX, y: w.timeline.bounds.maxY - 4), to: nil)
            w.window?.sendEvent(mouse(.leftMouseDown, outside)); w.window?.sendEvent(mouse(.leftMouseUp, outside))
            await wait(0.1)
            check(s.track(row.trackId)?.name == "Renamed By Click" && !MainWindowController.isTyping, "clicking outside a track name being edited keeps the new name")
            s.renameTrack(row.trackId, oldName)
        }
        // A dialog owns Return and Escape: shortcuts stay out of its way (regression: Return ran Go to Start under an alert).
        let alert = NSAlert(); alert.messageText = "Shortcut test"; alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: w.window!) { _ in }
        await wait(0.3)
        let returnKey = keyEvent("\r", code: 36)
        check(ShortcutRegistry.dialogInFront && !r.handle(returnKey), "with a sheet open, Return is left to the dialog")
        w.window?.endSheet(alert.window)
        await wait(0.2)
        check(!ShortcutRegistry.dialogInFront, "after the sheet closes, shortcuts work again")
        // Export and import round-trip.
        if let data = r.exportData() {
            r.restoreAll()
            let res = try? r.importData(data)
            check(res?.skipped == 0 && r.keys("transport.loop").contains(combo) && r.keys("transport.metronome").contains(KeyCombo("f8")),
                  "export then import restores the changes (\(res.map { "\($0.applied) applied" } ?? "failed"))")
        } else { check(false, "shortcuts export") }
        // Track navigation commands.
        if s.tracks.count >= 2 {
            w.headers.select(s.tracks[0].id)
            check(perform("Select Next Track") && w.selectedTrack == s.tracks[1].id, "Track ▸ Select Next Track")
            check(perform("Select Previous Track") && w.selectedTrack == s.tracks[0].id, "Track ▸ Select Previous Track")
        }
        // The editor: search by name and by key, record, resolve a conflict, restore.
        check(perform("Keyboard Shortcuts…") && w.shortcutsEditor.window?.isVisible == true, "Dalnok ▸ Keyboard Shortcuts… opens the editor")
        let ed = w.shortcutsEditor
        ed.search.stringValue = "split"; ed.reload()
        check(ed.visibleActionIds.contains("edit.split_at_playhead") && !ed.visibleActionIds.contains("transport.play_pause"), "editor search by name")
        ed.search.stringValue = combo.description; ed.reload()
        check(ed.visibleActionIds == ["transport.loop"], "editor search by key (\(combo.description) → \(ed.visibleActionIds))")
        ed.search.stringValue = ""; ed.reload()
        if let metro = r.action("transport.metronome") {
            ed.select(metro)
            ed.beginRecording(replacing: true)
            check(ShortcutRegistry.capturing && ed.window?.firstResponder === ed.recorder, "recording captures the keyboard")
            let m1 = MainWindowController.metronomeOn
            _ = ed.recorder.performKeyEquivalent(with: keyEvent("j", code: 38, [.command, .option]))
            check(r.keys("transport.metronome") == [KeyCombo("j", [.command, .option])] && MainWindowController.metronomeOn == m1 && !ShortcutRegistry.capturing,
                  "a recorded ⌥⌘J replaces the shortcut and runs nothing")
            ed.select(metro)
            ed.beginRecording(replacing: false)
            _ = ed.recorder.performKeyEquivalent(with: keyEvent("k", code: 40, [.command, .option])) // ⌥⌘K: Keyboard Shortcuts…
            check(ed.pending == KeyCombo("k", [.command, .option]) && !r.keys("transport.metronome").contains(ed.pending!),
                  "recording a key in use asks before taking it")
            ed.resolveTake()
            check(r.keys("transport.metronome").contains(KeyCombo("k", [.command, .option])) && r.keys("app.keyboard_shortcuts").isEmpty,
                  "Use It Here takes the key from the other command")
        }
        ed.restoreAll()
        check(r.overrides.isEmpty && r.action("transport.metronome")?.item?.keyEquivalent == "k" && r.action("app.keyboard_shortcuts")?.item?.keyEquivalent == "k",
              "Restore All Defaults brings back the preset (\(r.overrides.keys.sorted()), metronome \(r.display("transport.metronome")), shortcuts \(r.display("app.keyboard_shortcuts")))")
        ed.window?.close()
        if MainWindowController.metronomeOn != m0 { _ = perform("Metronome", exact: true) } // through the command, so the engine follows
        check(MainWindowController.metronomeOn == m0, "metronome back to where it was")
    }
}
