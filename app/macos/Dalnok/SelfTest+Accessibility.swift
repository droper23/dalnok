// Self-test steps (Accessibility): a VoiceOver and keyboard-only pass over every window. For each window it walks the
// accessibility tree (every control VoiceOver lands on must have a name) and follows the Tab key loop from the
// window's start (every control a mouse can use must be reachable by Tab alone, and the loop must close).
// `DALNOK_A11Y_ONLY=1` runs just this pass (fast iteration); `DALNOK_A11Y_REPORT=1` prints every finding.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

extension SelfTest {
    struct A11yAudit {
        var unlabeled: [String] = []   // interactive elements VoiceOver would announce without a name
        var unreachable: [String] = [] // enabled, visible controls Tab never reaches
        var keyViews = 0               // stops in the Tab loop
        var loopCloses = false         // Tab comes back to where it started
        var focusTrap: String?         // a view Tab can't leave
    }

    static let interactiveRoles: Set<NSAccessibility.Role> = [.button, .checkBox, .radioButton, .slider, .popUpButton, .menuButton,
                                                             .textField, .incrementor, .comboBox, .disclosureTriangle]

    /// A short description of a view or accessibility element for reports.
    func describe(_ e: Any) -> String {
        let name = String(describing: type(of: e))
        var label = ""
        if let el = e as? NSAccessibilityElementProtocol & NSObjectProtocol {
            let o = el as AnyObject
            label = (o.accessibilityLabel?() ?? nil) ?? (o.accessibilityTitle?() ?? nil) ?? ""
        }
        if let v = e as? NSView, let win = v.window, let cv = win.contentView {
            let f = v.convert(v.bounds, to: cv)
            return "\(name) \"\(label)\" at \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
        }
        return "\(name) \"\(label)\""
    }

    /// Is this view something a mouse user can operate (so a keyboard user must reach it too)?
    func operable(_ v: NSView) -> Bool {
        guard !v.isHiddenOrHasHiddenAncestor, v.bounds.width > 2, v.bounds.height > 2, v.window != nil else { return false }
        if let c = v as? NSControl {
            guard c.isEnabled else { return false }
            if let t = c as? NSTextField { return t.isEditable } // labels aren't operable
            if c is NSTableView || c is NSOutlineView { return true }
            if c is NSScroller || c is NSSegmentedControl && c.superview is NSTableCellView { return false }
            return true
        }
        return v.acceptsFirstResponder && !(v is NSTextView) && !(v is NSClipView)
    }

    func audit(_ win: NSWindow, root: NSView? = nil) -> A11yAudit {
        var out = A11yAudit()
        guard let content = root ?? win.contentView else { return out }
        content.layoutSubtreeIfNeeded()
        // 1. VoiceOver: every interactive element has a name (label, title, or a title element).
        var seenAX = Set<ObjectIdentifier>()
        func walk(_ el: Any, depth: Int) {
            guard depth < 60, let obj = el as? NSObject, seenAX.insert(ObjectIdentifier(obj)).inserted else { return }
            if let ax = obj as? NSAccessibilityElementProtocol {
                let o = ax as AnyObject
                let role = o.accessibilityRole?() ?? nil
                let isElement = (obj as? NSView)?.isAccessibilityElement() ?? (o.isAccessibilityElement?() ?? true)
                let hidden = (obj as? NSView)?.isHiddenOrHasHiddenAncestor ?? false
                // A cell is named by itself or by its control (VoiceOver reads them as one element).
                let control = (obj as? NSCell)?.controlView
                let cellHidden = control?.isHiddenOrHasHiddenAncestor ?? false
                if !hidden, !cellHidden, isElement, let role, Self.interactiveRoles.contains(role) {
                    func named(_ x: String?) -> String? { x.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
                    let label = named(o.accessibilityLabel?() ?? nil) ?? named(control?.accessibilityLabel()) ?? ""
                    let title = named(o.accessibilityTitle?() ?? nil) ?? named(control?.accessibilityTitle()) ?? ""
                    let titled = (o.accessibilityTitleUIElement?() ?? nil) != nil || control?.accessibilityTitleUIElement() != nil
                    let placeholder = (o.accessibilityPlaceholderValue?() ?? nil) ?? ""
                    if label.trimmingCharacters(in: .whitespaces).isEmpty && title.trimmingCharacters(in: .whitespaces).isEmpty
                        && !titled && placeholder.isEmpty {
                        out.unlabeled.append("\(role.rawValue) " + describe(control ?? obj))
                    }
                }
                for c in (o.accessibilityChildren?() ?? nil) ?? [] { walk(c, depth: depth + 1) }
            }
            if let v = obj as? NSView { for s in v.subviews { walk(s, depth: depth + 1) } }
        }
        walk(content, depth: 0)
        // 2. Keyboard: follow Tab from the window's start until it comes back.
        win.makeFirstResponder(nil)
        var stops: [NSResponder] = []
        func current() -> NSResponder? {
            guard let r = win.firstResponder else { return nil }
            if let tv = r as? NSTextView, tv.isFieldEditor, let d = tv.delegate as? NSResponder { return d }
            return r
        }
        var last: NSResponder?, repeats = 0
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: win.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                   isARepeat: false, keyCode: 48)!
        for i in 0..<600 {
            // The first press starts the loop; after that a real Tab key event, so views and field editors handle it.
            // A text field's editor runs Tab through its delegate (which may claim it) as typing would; anything else
            // leaves Tab to the window, which moves along the key view loop.
            if let tv = win.firstResponder as? NSTextView, tv.isFieldEditor { tv.doCommand(by: #selector(NSResponder.insertTab(_:))) }
            else { win.selectNextKeyView(nil) }
            _ = tab
            guard let r = current(), r !== win else { continue }
            if r === last { repeats += 1; if repeats > 2 { out.focusTrap = describe(r); break }; continue }
            repeats = 0; last = r
            if let first = stops.first, r === first { out.loopCloses = true; break }
            if stops.contains(where: { $0 === r }) { out.loopCloses = true; break } // a loop that skips the start
            stops.append(r)
        }
        out.keyViews = stops.count
        let reached = Set(stops.map { ObjectIdentifier($0) })
        func inside(_ v: NSView) -> Bool { // reached itself, or inside something reached that operates it (a table cell)
            var p: NSView? = v
            while let x = p { if reached.contains(ObjectIdentifier(x)) { return true }; p = x.superview }
            return false
        }
        func holdsReached(_ v: NSView) -> Bool { // a scroll view is reached through what it scrolls
            reached.contains(ObjectIdentifier(v)) || v.subviews.contains(where: holdsReached)
        }
        func scan(_ v: NSView) {
            if root == nil || v.isDescendant(of: content) {
                if operable(v) && !inside(v) && !(v is NSScrollView && holdsReached(v)) && !(v.superview.map(inside) ?? false) && !(v.enclosingScrollView.map { reached.contains(ObjectIdentifier($0.documentView ?? $0)) } ?? false) {
                    out.unreachable.append(describe(v))
                }
            }
            if v is NSTableView { return } // rows are reached through the table
            for s in v.subviews { scan(s) }
        }
        scan(content)
        win.makeFirstResponder(nil)
        return out
    }

    /// Audits one window and turns the findings into checks.
    func a11yCheck(_ name: String, _ win: NSWindow?, root: NSView? = nil) {
        guard let win else { return check(false, "a11y: \(name) opens") }
        if let sheet = win.attachedSheet { // a sheet left by an earlier step would own the keyboard
            print("A11Y-NOTE \(name): closing a leftover sheet (\(sheet.title))")
            win.endSheet(sheet)
        }
        let a = audit(win, root: root)
        let report = ProcessInfo.processInfo.environment["DALNOK_A11Y_REPORT"] != nil
        print("A11Y-INFO fka=\(NSApp.isFullKeyboardAccessEnabled) auto=\(win.autorecalculatesKeyViewLoop) initial=\(win.initialFirstResponder.map { describe($0) } ?? "nil") visible=\(win.isVisible)")
        print("A11Y \(name) [\(Theme.activeStyle) \(Theme.activeVariant)]: \(a.keyViews) Tab stops, loop \(a.loopCloses ? "closes" : "open"), unlabeled \(a.unlabeled.count), unreachable \(a.unreachable.count)")
        if report {
            for u in a.unlabeled { print("A11Y-UNLABELED \(name): \(u)") }
            for u in a.unreachable { print("A11Y-UNREACHABLE \(name): \(u)") }
        }
        check(a.unlabeled.isEmpty, "VoiceOver: every control in \(name) has a name (\(a.unlabeled.prefix(3).joined(separator: "; ")))")
        check(a.unreachable.isEmpty, "keyboard: Tab reaches every control in \(name) (\(a.unreachable.prefix(3).joined(separator: "; ")))",
              needs: .fullKeyboardAccess)
        check(a.focusTrap == nil && a.keyViews > 0 && a.loopCloses, "keyboard: Tab cycles through \(name) and comes back (\(a.keyViews) stops\(a.focusTrap.map { ", stuck on \($0)" } ?? ""))",
              needs: .fullKeyboardAccess)
    }

    func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = [], in win: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: win.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    /// Things only a keyboard can show: clips chosen with ⌥←/⌥→, the launcher grid driven by arrows and Space, and Tab
    /// leaving a focused control even when a preset binds Tab to a command.
    func keyboardOnlyChecks(_ main: NSWindow) async {
        let e = s.engine, h = e.handle
        // Select Next/Previous Clip (split a clip first if no track has two).
        var split = false
        if !s.tracks.contains(where: { $0.clips.count >= 2 }), let c = s.tracks.first(where: { !$0.clips.isEmpty })?.clips.first {
            w.timeline.selectedClip = c.id
            e.seek(c.start + c.length / 2)
            await wait(0.3) // the seek lands on the next device block
            split = perform("Split at Playhead")
        }
        defer { if split { _ = perform("Undo") } }
        if let (i, t) = s.tracks.enumerated().first(where: { $0.element.clips.count >= 2 }) {
            let sorted = t.clips.sorted { $0.start < $1.start }
            w.headers.select(t.id)
            w.timeline.selectedClip = sorted[0].id
            check(perform("Select Next Clip") && w.timeline.selectedClip == sorted[1].id, "Edit > Select Next Clip (⌥→) selects the next clip on the track")
            check(perform("Select Previous Clip") && w.timeline.selectedClip == sorted[0].id, "Edit > Select Previous Clip (⌥←) goes back")
            w.timeline.selectedClip = nil
            e.seek(sorted[1].start)
            check(perform("Select Next Clip") && w.timeline.selectedClip == sorted[1].id, "with nothing selected it starts at the playhead")
            _ = i
        } else { check(false, "a track with two clips for clip selection") }
        // The launcher grid from the keyboard.
        let showed = MainWindowController.showLauncher
        if !showed { w.toggleLauncher(nil) }
        main.contentView?.layoutSubtreeIfNeeded()
        let lv = w.launcher
        guard let (row, track) = s.tracks.enumerated().first(where: { !$0.element.isBus && !$0.element.clips.isEmpty }).map({ ($0.offset, $0.element) }) else {
            return check(false, "a track with clips for the launcher keys")
        }
        let filled = s.slotClip(track.id, 6) != nil
        if !filled { s.copyToSlot(track.clips[0].id, 6) }
        e.pause(); e.seek(0)
        let armed = track.armed
        if armed { s.setArmed(track.id, false) }
        main.makeFirstResponder(nil)
        CommittingWindow.navigating = true // as Tab does: land on the grid directly
        main.makeFirstResponder(lv)
        CommittingWindow.navigating = false
        check(main.firstResponder === lv, "keyboard: the launcher grid takes keyboard focus")
        for _ in 0..<10 { lv.keyDown(with: key(123, "\u{F702}", in: main)) } // ← to the first slot
        for _ in 0..<10 { lv.keyDown(with: key(126, "\u{F700}", in: main)) } // ↑ to the first track
        for _ in 0..<6 { lv.keyDown(with: key(124, "\u{F703}", in: main)) }
        for _ in 0..<row { lv.keyDown(with: key(125, "\u{F701}", in: main)) }
        check(lv.cursor.row == row && lv.cursor.slot == 6, "keyboard: arrows move the launcher cursor (\(lv.cursor))")
        let space = key(49, " ", in: main)
        check(NSApp.mainMenu?.performKeyEquivalent(with: space) == false, "keyboard: Space goes to the focused grid, not Play")
        lv.keyDown(with: space)
        check(dalnok_launcher_playing(h, track.id) == 6 || dalnok_launcher_queued(h, track.id, nil) == 6, "keyboard: Space launches the slot under the cursor")
        lv.keyDown(with: key(53, "\u{1b}", in: main))
        check(dalnok_launcher_queued(h, track.id, nil) == -1 || dalnok_launcher_playing(h, track.id) == -1, "keyboard: Esc stops every clip")
        dalnok_launcher_stop_all(h); e.pause(); e.seek(0)
        let tab = key(48, "\t", in: main)
        check(NSApp.mainMenu?.performKeyEquivalent(with: tab) == false, "keyboard: Tab moves focus on from the grid even if a preset binds Tab")
        main.makeFirstResponder(w.transport)
        if let firstButton = w.transport.subviews.first(where: { $0 is NSButton && $0.canBecomeKeyView }) {
            main.makeFirstResponder(firstButton)
            check(NSApp.mainMenu?.performKeyEquivalent(with: tab) == false, "keyboard: Tab moves on from a focused button")
        }
        main.makeFirstResponder(nil)
        if armed { s.setArmed(track.id, true) }
        if !filled { _ = perform("Undo") }
        if !showed { w.toggleLauncher(nil) }
    }

    /// Every window, opened the way a user opens it.
    func accessibilityPass() async {
        guard let main = w.window else { return check(false, "a11y: main window") }
        let showed = (MainWindowController.showMixer, MainWindowController.showLauncher, MainWindowController.showDevicePanel)
        if !showed.0 { w.toggleMixer(nil) }
        if !showed.1 { w.toggleLauncher(nil) }
        if !showed.2 { w.toggleDevicePanel(nil) }
        if let t = s.tracks.first?.id { w.headers.select(t) }
        await wait(0.4)
        a11yCheck("the main window", main)
        await keyboardOnlyChecks(main)
        if !showed.0 { w.toggleMixer(nil) }
        if !showed.1 { w.toggleLauncher(nil) }
        if !showed.2 { w.toggleDevicePanel(nil) }

        w.toggleCompositionOverview(nil); await wait(0.3)
        a11yCheck("the Composition Overview", main, root: w.overview)
        w.toggleCompositionOverview(nil); await wait(0.3)

        w.showCommandPalette(nil); await wait(0.3)
        a11yCheck("the command palette", w.palette.panel)
        w.palette.panel.orderOut(nil)

        w.showSettings(nil); await wait(0.3)
        a11yCheck("Settings", w.settings.window)
        w.settings.show(.shortcuts); await wait(0.3)
        a11yCheck("Settings > Shortcuts", w.settings.window)
        w.settings.window?.orderOut(nil)

        w.showPlugins(nil); await wait(0.3)
        a11yCheck("the plug-in browser", w.pluginManager.window)
        w.pluginManager.window?.orderOut(nil)

        if let t = s.tracks.first(where: { !$0.isBus })?.id, let slot = try? s.addPlugin(t, path: "dalnok:compressor") {
            w.openPluginControls(track: t, slot: slot); await wait(0.3)
            a11yCheck("a plug-in window", w.pluginWindows[slot]?.window)
            w.pluginWindows[slot]?.window?.close()
            s.removePlugin(t, slot)
        }

        if let midi = s.tracks.first(where: \.isInstrument)?.clips.first?.id {
            w.timeline.selectedClip = midi
            w.openPianoRoll(nil); await wait(0.3)
            a11yCheck("the piano roll", w.pianoRoll.window)
            w.pianoRoll.window?.orderOut(nil)
        }

        if let folder = s.tracks.lazy.flatMap(\.clips).first(where: { $0.folder != 0 })?.folder {
            w.compEditor.show(folder: folder); await wait(0.3)
            a11yCheck("the take folder editor", w.compEditor.window)
            w.compEditor.window?.orderOut(nil)
        }
        w.showConceptGuide(nil); await wait(0.3)
        a11yCheck("the Concept Guide", w.conceptGuide.window)
        w.conceptGuide.window.orderOut(nil)
        w.showMigrationAssistant(nil); await wait(0.3)
        a11yCheck("Welcome (Coming from…)", w.welcome.window)
        w.welcome.window.orderOut(nil)
        w.shortcutChooser.show(); await wait(0.3)
        a11yCheck("the first-launch shortcut chooser", w.shortcutChooser.window)
        w.shortcutChooser.window.orderOut(nil)
        w.showTapeDeck(nil); await wait(0.3)
        a11yCheck("the tape machine", w.tapeDeck?.window)
        w.tapeDeck?.window?.orderOut(nil)
        main.makeKeyAndOrderFront(nil)
    }
}
