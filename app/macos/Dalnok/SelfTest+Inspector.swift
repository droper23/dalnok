// Self-test: the side panels (View ▸ Library, View ▸ Inspector). Toggling from the View menu (remembered), the
// Inspector's edits reaching the engine as one undo step each and following the selection, the engine, meters and
// automation; the Library's search, tabs, places and collections; a plug-in dragged from the Library onto a track.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

extension SelfTest {
    func sidePanels() async {
        _ = s.engine
        guard let main = w.window else { return check(false, "side panels: main window") }
        let shown = (MainWindowController.showLibrary, MainWindowController.showInspector)
        defer {
            if MainWindowController.showLibrary != shown.0 { w.toggleLibrary(nil) }
            if MainWindowController.showInspector != shown.1 { w.toggleInspector(nil) }
        }
        // Toggling: View ▸ Library and View ▸ Inspector, each remembered in the preferences.
        if MainWindowController.showLibrary { w.toggleLibrary(nil) }
        if MainWindowController.showInspector { w.toggleInspector(nil) }
        main.contentView?.layoutSubtreeIfNeeded()
        check(w.library.isHidden && w.inspector.isHidden && w.library.frame.width < 1 && w.inspector.frame.width < 1, "side panels start closed")
        check(perform("Library", exact: true) && MainWindowController.showLibrary && UserDefaults.standard.bool(forKey: "showLibrary"),
              "View > Library opens the library and remembers it")
        check(perform("Inspector", exact: true) && MainWindowController.showInspector && UserDefaults.standard.bool(forKey: "showInspector"),
              "View > Inspector opens the inspector and remembers it")
        main.contentView?.layoutSubtreeIfNeeded()
        check(!w.library.isHidden && abs(w.library.frame.width - LibraryPanel.storedWidth) < 1, "the library takes its width (\(w.library.frame.width))")
        check(!w.inspector.isHidden && abs(w.inspector.frame.width - InspectorPanel.storedWidth) < 1, "the inspector takes its width (\(w.inspector.frame.width))")
        check(menuItem("Library", exact: true)?.state == .on && menuItem("Inspector", exact: true)?.state == .on, "the View menu ticks both panels")
        check(w.transport.libraryButton.isActive && w.transport.inspectorButton.isActive, "the control bar's panel buttons light")
        check(main.minSize.width >= MainWindowController.baseMinWidth + LibraryPanel.storedWidth + InspectorPanel.storedWidth - 1,
              "the window's minimum width makes room for both panels (\(main.minSize.width))")
        check(w.timeline.frame.width >= 200, "the timeline keeps room between the panels (\(w.timeline.frame.width) pt)")
        // Resize: drag the inspector's inner edge left by 40 pt; the width is stored and clamped.
        let before = InspectorPanel.storedWidth
        w.inspector.resizeEdge.onDrag?(before + 40); w.inspector.resizeEdge.onEnd?()
        main.contentView?.layoutSubtreeIfNeeded()
        check(abs(w.inspector.frame.width - (before + 40)) < 1 && abs(InspectorPanel.storedWidth - (before + 40)) < 1, "dragging the inspector's edge resizes it and remembers the width")
        w.inspector.resizeEdge.onDrag?(2_000)
        check(InspectorPanel.storedWidth == InspectorPanel.widthRange.upperBound, "the width is clamped")
        w.inspector.resizeEdge.onDrag?(before); w.inspector.resizeEdge.onEnd?()
        // The toggles from the control bar's buttons.
        w.transport.libraryButton.performClick(nil)
        check(!MainWindowController.showLibrary && w.library.isHidden, "the control bar's Library button closes it")
        w.transport.libraryButton.performClick(nil)
        check(MainWindowController.showLibrary && !w.library.isHidden, "and opens it again")

        await inspectorEdits(main)
        await libraryBrowsing(main)
        await illustratedControls()
    }

    /// View ▸ Illustrated Controls: Atelier only; larger controls after a rebuild, and back.
    private func illustratedControls() async {
        guard Theme.activeStyle == .atelier else {
            check(menuItem("Illustrated Controls")?.isEnabled == false || !(w.validateMenuItem(menuItem("Illustrated Controls") ?? NSMenuItem())), "Illustrated Controls is Atelier's only")
            return
        }
        let was = Illustrated.on
        check(perform("Illustrated Controls") && Illustrated.on != was, "View > Illustrated Controls switches the drawings' size")
        await wait(0.3)
        w.window?.contentView?.layoutSubtreeIfNeeded()
        if Illustrated.on {
            check(ChannelStrip.width > 92 && (w.inspector.volume.frame.width > 58 || w.inspector.isHidden), "illustrated: wider strips and larger dials")
        }
        check(s.tracks.count > 0 && !w.timeline.isHidden, "the project survives the rebuild")
        check(perform("Illustrated Controls") && Illustrated.on == was, "and back")
        await wait(0.3)
    }

    /// Undo only the step named, so a failed check never undoes someone else's setup.
    @discardableResult private func undo(_ name: String) -> Bool {
        guard s.engine.undoName == name else { check(false, "the last undo step is \"\(name)\" (it is \"\(s.engine.undoName)\")"); return false }
        return perform("Undo")
    }

    private func inspectorEdits(_ main: NSWindow) async {
        let e = s.engine
        guard let t = s.tracks.first(where: { !$0.isBus && !$0.isInstrument && !$0.clips.isEmpty }) else { return check(false, "an audio track for the inspector") }
        let ins = w.inspector
        w.headers.select(t.id)
        check(ins.track == t.id && ins.nameLabel.stringValue == t.name, "the inspector shows the selected track (\(ins.nameLabel.stringValue))")
        if let other = s.tracks.first(where: { $0.id != t.id }) {
            w.headers.select(other.id)
            check(ins.track == other.id && ins.nameLabel.stringValue == other.name, "selecting another track refreshes the inspector")
            w.headers.select(t.id)
        }
        // Volume dial: a drag is one undo step.
        let g0 = s.track(t.id)?.gainDb ?? 0
        let k = ins.volume
        let a = k.convert(CGPoint(x: k.bounds.midX, y: k.bounds.midY), to: nil)
        k.mouseDown(with: mouse(.leftMouseDown, a))
        for i in 1...6 { k.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x, y: a.y - CGFloat(i) * 8))) }
        k.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: a.x, y: a.y - 48)))
        s.refresh(onDisplayTick: true)
        let g1 = s.track(t.id)?.gainDb ?? 0
        check(g1 < g0 - 1, "dragging the inspector's volume dial lowers the track (\(g0) → \(g1) dB)")
        check(ins.volumeValue.stringValue == FaderControl.format(g1), "the volume read-out follows (\(ins.volumeValue.stringValue))")
        check(e.undoName == "Volume" && perform("Undo") && abs((s.track(t.id)?.gainDb ?? 0) - g0) < 0.01, "the volume drag is one undo step")
        // Pan dial.
        let p = ins.pan
        let pa = p.convert(CGPoint(x: p.bounds.midX, y: p.bounds.midY), to: nil)
        p.mouseDown(with: mouse(.leftMouseDown, pa))
        for i in 1...5 { p.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: pa.x, y: pa.y + CGFloat(i) * 8))) }
        p.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: pa.x, y: pa.y + 40)))
        s.refresh(onDisplayTick: true)
        check((s.track(t.id)?.pan ?? 0) > 0.1, "dragging the pan dial pans right (\(s.track(t.id)?.pan ?? 0))")
        check(e.undoName == "Pan" && perform("Undo") && abs(s.track(t.id)?.pan ?? 1) < 0.001, "the pan drag is one undo step")
        // Chips: mute, solo and phase invert, each one undo step.
        func click(_ c: ToggleChip) {
            let m = c.convert(CGPoint(x: c.bounds.midX, y: c.bounds.midY), to: nil)
            c.mouseDown(with: mouse(.leftMouseDown, m)); c.mouseUp(with: mouse(.leftMouseUp, m))
            s.refresh(onDisplayTick: true)
        }
        click(ins.mute)
        check(s.track(t.id)?.muted == true && ins.mute.isOn, "the inspector's M mutes the track")
        check(undo("Mute") && s.track(t.id)?.muted == false && !ins.mute.isOn, "undo unmutes, and the inspector follows")
        click(ins.solo)
        check(s.track(t.id)?.solo == true, "S solos")
        undo("Solo")
        click(ins.phase)
        check(s.track(t.id)?.phaseInvert == true && ins.phase.isOn && e.undoName == "Invert Phase", "Ø inverts the phase (one undo step)")
        check(undo("Invert Phase") && s.track(t.id)?.phaseInvert == false && !ins.phase.isOn, "undo restores the phase")
        // Changes made elsewhere reach the inspector (it caches nothing).
        s.setGain(t.id, db: -9); s.refresh(onDisplayTick: true)
        check(abs(ins.volume.db - -9) < 0.05 && ins.volumeValue.stringValue == FaderControl.format(-9), "a change elsewhere moves the inspector's dial (\(ins.volume.db))")
        s.setGain(t.id, db: 0); s.refresh(onDisplayTick: true)
        undo("Volume"); undo("Volume")
        // Output, sends and inserts.
        check(perform("New Bus") && s.tracks.last?.isBus == true, "a bus for the inspector's routing")
        guard let bus = s.tracks.last?.id else { return }
        w.headers.select(t.id)
        ins.reload()
        ins.output.selectItem(withTag: Int(bus)); ins.output.sendAction(ins.output.action, to: ins.output.target)
        check(s.track(t.id)?.output == bus, "the inspector's Output routes the track to the bus")
        check(undo("Set Output") && s.track(t.id)?.output == 0, "undo puts it back on the master")
        if let item = ins.addSend.itemArray.first(where: { $0.tag == Int(bus) }), let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
            check(s.track(t.id)?.sends.first?.bus == bus && ins.sendRows.count == 1, "+ Send adds a lettered send (A)")
            if let row = ins.sendRows.first {
                let f = row.fader
                let fa = f.convert(CGPoint(x: f.bounds.width * 0.8, y: f.bounds.midY), to: nil)
                f.mouseDown(with: mouse(.leftMouseDown, fa))
                for i in 1...6 { f.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: fa.x - CGFloat(i) * 10, y: fa.y))) }
                f.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: fa.x - 60, y: fa.y)))
                s.refresh(onDisplayTick: true)
                let db = s.track(t.id)?.sends.first?.db ?? 0
                check(db < -3, "dragging the send's level lowers it (\(db) dB)")
                check(e.undoName == "Send" && perform("Undo") && abs(s.track(t.id)?.sends.first?.db ?? -1) < 0.01, "the send drag is one undo step")
            }
            undo("Send") // the send
        } else { check(false, "+ Send lists the bus") }
        check(undo("New Bus") && !s.tracks.contains { $0.id == bus }, "undo removes the bus")
        // Monitor (audio tracks): Input Monitoring on and off.
        ins.monitor.selectItem(at: 1); ins.monitor.sendAction(ins.monitor.action, to: ins.monitor.target)
        check(s.track(t.id)?.inputMonitor == true, "Monitor: Input turns Input Monitoring on")
        ins.monitor.selectItem(at: 0); ins.monitor.sendAction(ins.monitor.action, to: ins.monitor.target)
        check(s.track(t.id)?.inputMonitor == false, "Monitor: Off turns it off")
        // Inserts: a plug-in dropped on the inspector, its row numbered, the lamp bypasses it (one undo step).
        ins.onDropPlugin?("dalnok:channel-eq", t.id)
        s.refresh(onDisplayTick: true)
        ins.reload()
        check(s.track(t.id)?.effects.count == 1 && ins.insertRows.count == 1 && e.undoName == "Add Plug-in",
              "a plug-in dropped on the inspector becomes insert 01 (one undo step)")
        main.contentView?.layoutSubtreeIfNeeded()
        if let row = ins.insertRows.first, row.window != nil {
            check(row.open.attributedTitle.string.hasPrefix("01 · "), "inserts are numbered like plates (\(row.open.attributedTitle.string))")
            click(row.bypass)
            check(s.track(t.id)?.effects.first?.bypassed == true && row.bypass.isOn, "the insert's lamp bypasses it")
            check(undo(s.engine.undoName.isEmpty ? "-" : s.engine.undoName) && s.track(t.id)?.effects.first?.bypassed == false, "undo turns it back on")
        } else { check(false, "the insert row is on screen") }
        undo("Add Plug-in") // the insert
        check(s.track(t.id)?.effects.isEmpty == true && ins.insertRows.isEmpty, "undo removes the insert from the inspector")
        // A long chain: the list shows 6 and offers the rest; Atelier's figure folds the middle into one lettered range.
        for _ in 0..<9 { ins.onDropPlugin?("dalnok:channel-eq", t.id) }
        s.refresh(onDisplayTick: true)
        ins.reload()
        check(s.track(t.id)?.effects.count == 9 && ins.insertRows.count == InspectorPanel.insertsShown, "nine inserts: the list shows \(InspectorPanel.insertsShown) (\(ins.insertRows.count))")
        ins.showAllInsertsForTest()
        check(ins.insertRows.count == 9, "Show all 9 lists every insert (\(ins.insertRows.count))")
        if Theme.look.mixer == .instrument {
            let folded = ins.figure.rows.contains { if case .folded(let r) = $0 { return r == 3...7 } else { return false } }
            check(ins.figure.rows.count == 5 && folded, "the signal-path figure folds inserts D–H into one range (\(ins.figure.rows.count) rows)")
        }
        for _ in 0..<9 { undo("Add Plug-in") }
        check(s.track(t.id)?.effects.isEmpty == true, "the nine inserts undo away")
        // Live: the meter during playback, and automation moving the dial.
        let pts = [DalnokAutoPoint(frame: 0, value: -18), DalnokAutoPoint(frame: Int64(e.sampleRate * 60), value: -18)]
        check(s.setAutomation(t.id, 0, pts), "volume automation for the live check")
        e.seek(t.clips.first?.start ?? 0)
        e.play()
        await wait(0.6)
        let level = max(ins.meter.levelDb.0, ins.meter.levelDb.1)
        let auto = ins.volume.db
        e.pause()
        check(level > -80, "the inspector's meter moves during playback (\(level) dB)")
        check(abs(auto - -18) < 0.2 && ins.volumeValue.stringValue == FaderControl.format(-18), "automation moves the inspector's dial (\(auto) dB)")
        undo(s.engine.undoName) // the automation lane
        e.seek(0)
        // Every inspector control is labelled.
        let unlabelled = ins.subviewsDeep.filter { v in
            guard v.isAccessibilityElement(), !v.isHiddenOrHasHiddenAncestor, v is NSControl else { return false }
            return (v.accessibilityLabel() ?? "").isEmpty && (v as? NSButton)?.title.isEmpty != false && (v as? NSTextField)?.isEditable != false
        }
        check(unlabelled.isEmpty, "every inspector control has an accessible name (\(unlabelled.map { String(describing: type(of: $0)) }))")
    }

    private func libraryBrowsing(_ main: NSWindow) async {
        let lib = w.library
        let saved = (PluginLibrary.favorites, PluginLibrary.collections)
        defer { PluginLibrary.favorites = saved.0; PluginLibrary.collections = saved.1; lib.rebuildCollections(); lib.choose(.all) }
        lib.load()
        lib.choose(.all)
        lib.tabs.selectedSegment = 0; lib.reload()
        lib.search.stringValue = ""; lib.reload()
        let all = lib.filtered()
        check(!all.isEmpty && all.allSatisfy { $0.group == .effects }, "the Effects tab lists audio effects (\(all.count))")
        check(lib.roots.allSatisfy { r in PluginGroup.effects.categories.contains(r.category ?? "") }, "categories come from the plug-in taxonomy")
        lib.search.stringValue = "compressor"; lib.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let found = lib.filtered()
        check(found.contains { $0.name == "Dalnok Compressor" } && found.count < all.count, "search narrows the list (\(found.count) for \"compressor\")")
        check(lib.roots.allSatisfy { lib.outline.isItemExpanded($0) }, "search opens the matching categories")
        lib.search.stringValue = "zzqxv no such plug-in"; lib.reload()
        check(lib.filtered().isEmpty && lib.roots.isEmpty, "a search with no match shows nothing")
        lib.search.stringValue = ""
        lib.tabs.selectedSegment = 1; lib.reload()
        check(lib.filtered().allSatisfy { $0.group == .instruments } && !lib.filtered().isEmpty, "the Instruments tab lists instruments")
        lib.tabs.selectedSegment = 0; lib.reload()
        // Typing in the search field never fires the bare-key shortcuts (Y, I, X…).
        main.makeFirstResponder(lib.search)
        let y = key(16, "y", in: main), i = key(34, "i", in: main)
        check(MainWindowController.isTyping && NSApp.mainMenu?.performKeyEquivalent(with: y) == false && NSApp.mainMenu?.performKeyEquivalent(with: i) == false,
              "typing Y or I in the library's search doesn't toggle the panels")
        check(MainWindowController.showLibrary && MainWindowController.showInspector, "both panels are still open after typing")
        main.makeFirstResponder(nil)
        // A clicked list keeps keyboard focus; Space must still reach the transport (AppKit gives it to the list first).
        main.makeFirstResponder(lib.outline)
        let space = key(49, " ", in: main), down = key(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), in: main)
        let wasPlaying = s.engine.isPlaying
        main.sendEvent(space)
        check(s.engine.isPlaying != wasPlaying && main.firstResponder === lib.outline, "Space plays with the library's list focused")
        main.sendEvent(space)
        check(s.engine.isPlaying == wasPlaying, "and Space pauses again")
        check(!CommittingWindow.shortcutFirst(down, responder: lib.outline), "arrow keys stay with the focused list")
        main.makeFirstResponder(lib.search)
        check(!CommittingWindow.shortcutFirst(space, responder: main.firstResponder), "Space still types in the library's search")
        main.makeFirstResponder(nil)
        // Places and collections.
        guard let comp = all.first(where: { $0.name == "Dalnok Compressor" }) ?? all.first else { return check(false, "a plug-in for places") }
        var fav = PluginLibrary.favorites; fav.insert(comp.addPath); PluginLibrary.favorites = fav
        lib.choose(.favorites)
        check(lib.filtered().map(\.addPath) == [comp.addPath], "Favourites lists the favourite (\(lib.filtered().map(\.name)))")
        let before = PluginLibrary.collections.count
        lib.newCollection()
        guard case .collection(let name) = lib.place else { return check(false, "+ makes and selects a collection") }
        check(PluginLibrary.collections.count == before + 1 && lib.filtered().isEmpty, "+ makes an empty collection and shows it (\(name))")
        lib.addToCollection(name, comp.addPath)
        check(lib.filtered().map(\.addPath) == [comp.addPath], "a plug-in filed in the collection appears there")
        lib.choose(.all)
        // Drag from the library onto a track header: the outline writes the plug-in's add path; the header inserts it.
        guard let t = s.tracks.first(where: { !$0.isBus && !$0.isInstrument }) else { return check(false, "a track for the drag") }
        lib.search.stringValue = "Dalnok Channel EQ"; lib.reload()
        guard let node = lib.roots.first?.children.first, let item = lib.outlineView(lib.outline, pasteboardWriterForItem: node) as? NSPasteboardItem,
              let path = item.string(forType: .dalnokPlugin) else { return check(false, "the library offers a plug-in to drag") }
        let n0 = s.track(t.id)?.plugins.count ?? 0
        w.headers.onDropPlugin?(path, t.id)
        check((s.track(t.id)?.plugins.count ?? 0) == n0 + 1 && s.track(t.id)?.plugins.last?.name == "Dalnok Channel EQ" && s.engine.undoName == "Add Plug-in",
              "dragging a plug-in from the library onto a track adds it (one undo step)")
        undo("Add Plug-in")
        // Double-click inserts on the selected track.
        w.headers.select(t.id)
        let row = lib.outline.row(forItem: node)
        lib.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        lib.activateRow()
        check((s.track(t.id)?.plugins.count ?? 0) == n0 + 1, "double-click (Return) in the library inserts on the selected track")
        undo("Add Plug-in")
        lib.search.stringValue = ""; lib.reload()
        await libraryFiles(lib)
    }

    /// The Files place: an added folder unfolds to its sub-folder and sound file; a file drags as a file URL; Return
    /// imports it (one undo step); the search finds it off the main thread; removing the folder forgets it.
    private func libraryFiles(_ lib: LibraryPanel) async {
        let folders = LibraryFiles.userFolders, preview = LibraryPreview.enabled
        defer { LibraryFiles.userFolders = folders; LibraryPreview.enabled = preview; lib.choose(.all) }
        LibraryPreview.enabled = false // no sound from the self-test
        let dir = workdir.appendingPathComponent("Library Files Test", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Takes"), withIntermediateDirectories: true)
        let sound = dir.appendingPathComponent("Zqx Glass.aiff")
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff"), to: sound)
        try? Data("not audio".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        lib.addFolder(dir)
        check(lib.place == .files && lib.tabs.isHidden && !lib.previewToggle.isHidden, "Add Folder opens the Files place (tabs give way to Preview)")
        guard let node = lib.roots.first(where: { $0.folder?.standardizedFileURL == dir.standardizedFileURL }) else {
            return check(false, "the added folder is listed in Files (\(lib.roots.map(\.title)))")
        }
        check(lib.roots.last?.action != nil && lib.roots.contains { $0.title == "Home" }, "Files lists Home and ends with Add Folder…")
        lib.outline.expandItem(node)
        check(node.children.map(\.title) == ["Takes", "Zqx Glass.aiff"] && node.children.first?.folder != nil,
              "a folder unfolds to its sub-folders, then the files Dalnok takes (\(node.children.map(\.title)))")
        guard let file = node.children.last else { return }
        let dragged = (lib.outlineView(lib.outline, pasteboardWriterForItem: file) as? NSURL) as URL?
        check(dragged?.resolvingSymlinksInPath().path == sound.resolvingSymlinksInPath().path, "an audio file drags as its file URL (\(dragged?.path ?? "none"))")
        let count = s.tracks.count
        lib.outline.selectRowIndexes(IndexSet(integer: lib.outline.row(forItem: file)), byExtendingSelection: false)
        lib.activateRow()
        for _ in 0..<40 where s.tracks.count == count { try? await Task.sleep(for: .milliseconds(50)) }
        check(s.tracks.count == count + 1 && s.engine.undoName == "Import Audio", "Return on an audio file imports it as a track (\(s.engine.undoName))")
        if s.tracks.count == count + 1 { undo("Import Audio") }
        // Search: every place's tree, off the main thread.
        var hits = -1
        lib.onFilesSearched = { hits = $0 }
        lib.search.stringValue = "zqx glass"; lib.reload()
        for _ in 0..<100 where hits < 0 { try? await Task.sleep(for: .milliseconds(50)) }
        check(lib.roots.contains { $0.file?.standardizedFileURL == sound.standardizedFileURL }, "the Files search finds the file (\(hits) hits)")
        lib.onFilesSearched = nil
        lib.search.stringValue = ""; lib.reload()
        LibraryFiles.userFolders = LibraryFiles.userFolders.filter { $0.standardizedFileURL != dir.standardizedFileURL }
        lib.reload()
        check(!lib.roots.contains { $0.folder?.standardizedFileURL == dir.standardizedFileURL }, "a removed folder leaves the Files place")
        try? FileManager.default.removeItem(at: dir)
    }
}
