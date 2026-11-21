// Self-test steps (first run and navigation): the start page, the control bar's view buttons, the
// hint line, the undo toast, gliding zoom and the new-lane glow. The harness (check, perform, mouse) is SelfTest.swift.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

extension SelfTest {
    /// Runs on an empty project (File ▸ New): the start page, its two tracks, and undo back to it.
    func startPage() async {
        let e = s.engine
        let page = w.emptyState
        check(page.cards.count == 2, "new project screen: two ways to add the first track")
        let texts = page.subviewsDeep.compactMap { ($0 as? NSTextField)?.stringValue } + page.subviewsDeep.compactMap { ($0 as? NSButton)?.title }
        check(!texts.contains { $0.contains("⌘") || $0.contains("⌥") }, "the new project screen teaches no shortcuts")
        let buttons = page.subviewsDeep.compactMap { $0 as? NSButton }
        check(buttons.allSatisfy { $0.action != nil && $0.target != nil }, "every new project screen button has an action")
        check(!buttons.contains { $0.toolTip?.hasPrefix("/") == true }, "an automated run lists no recent projects (names stay private)")
        // Project basics: tempo and time signature set the project's, one undo step each; the audio device is shown.
        page.reload()
        check(!page.outputLabel.stringValue.isEmpty && !page.inputLabel.stringValue.isEmpty,
              "the audio output and input are shown (\(page.outputLabel.stringValue) / \(page.inputLabel.stringValue))")
        page.tempoField.stringValue = "96"
        page.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification))
        check(abs(s.bpm - 96) < 1e-9 && w.transport.tempoField.stringValue == "96", "the screen's tempo sets the project's (\(s.bpm))")
        page.meterPopup.selectItem(withTitle: "3/4")
        _ = page.meterPopup.target?.perform(page.meterPopup.action)
        check(s.meter == (3, 4) && w.transport.meterPopup.titleOfSelectedItem == "3/4", "and the time signature (\(s.meter))")
        _ = perform("Undo"); _ = perform("Undo")
        check(abs(s.bpm - 120) < 1e-9 && s.meter == (4, 4), "both undo (\(s.bpm), \(s.meter))")
        guard let audio = page.cards.first(where: { $0.accessibilityLabel() == "Audio Track" }),
              let inst = page.cards.first(where: { $0.accessibilityLabel() == "Instrument Track" }) else {
            return check(false, "the screen offers Audio Track and Instrument Track")
        }
        inst.performClick(nil)
        check(s.tracks.count == 1 && s.tracks.first?.isInstrument == true, "start page's New Instrument Track adds one")
        _ = perform("Undo")

        Motion.override = true
        defer { Motion.override = false }
        audio.performClick(nil)
        check(s.tracks.count == 1 && s.tracks.first?.isInstrument == false, "start page's New Audio Track adds one")
        check(Set(w.timeline.laneFlash.keys) == Set(s.tracks.map(\.id)), "the new lane glows (\(w.timeline.laneFlash.count))")
        await wait(0.6)
        check(page.isHidden && !w.timeline.isHidden, "the arrangement replaces the start page")
        await wait(0.4)
        check(w.timeline.laneFlash.isEmpty, "and settles after \(TimelineView.laneFlashSeconds) s")

        // Undo names what it undid, and takes the project back to the start page.
        let step = e.undoName
        check(perform("Undo"), "menu Edit > Undo after adding a track")
        check(s.tracks.isEmpty, "undo removes the track")
        check(w.toast.text == "Undo \(step)", "undo toast names the step (\(w.toast.text))")
        await wait(0.6)
        check(!page.isHidden, "the start page returns for the empty project")
        _ = perform("Redo")
        check(w.toast.text == "Redo \(step)" && s.tracks.count == 1, "redo toast and track (\(w.toast.text))")
        await wait(1.8)
        check(w.toast.text.isEmpty, "the toast goes away by itself")
        _ = perform("Undo")
    }

    /// The control bar's view buttons, the hint line and gliding zoom (needs clips on screen).
    func navigation() async {
        let t = w.transport
        // View buttons: each toggles its view and lights while the view is open.
        for (button, name, isOn) in [(t.mixerButton, "Mixer", { MainWindowController.showMixer }),
                                     (t.launcherButton, "Clip Launcher", { MainWindowController.showLauncher }),
                                     (t.automationButton, "Automation", { self.w.timeline.showAutomation })] as [(IconButton, String, () -> Bool)] {
            let before = isOn()
            button.performClick(nil)
            check(isOn() != before && button.isActive == isOn(), "\(name) button toggles its view and lights (\(isOn()))")
            button.performClick(nil)
            check(isOn() == before && button.isActive == before, "\(name) button toggles it back")
        }
        await wait(0.4)

        // Hint line: the control under the pointer is described below the project name.
        let wasHints = MainWindowController.showsHints
        MainWindowController.showsHints = true
        let mixerCenter = t.mixerButton.convert(NSPoint(x: t.mixerButton.bounds.midX, y: t.mixerButton.bounds.midY), to: nil)
        w.pointerMoved(mouse(.mouseMoved, mixerCenter)) // what the app-wide mouse-moved monitor calls
        // A message that just appeared (e.g. "Clip launcher: …") keeps the line for its few seconds, then hints return.
        check(w.hoverHint == "Mixer (X)" && [w.hoverHint, w.lastFlashText].contains(t.statusLabel.stringValue),
              "hovering the Mixer button shows its hint (\(w.hoverHint ?? "none"))")
        // A clip the pointer can reach: on screen and not under a panel (CI's smaller screens scroll some lanes away).
        let hoverTimeline = w.timeline, content = w.window?.contentView
        // The widest visible clip, at the middle of its visible part (clear of the trim edges and fade handles).
        let reachable = s.tracks.enumerated().flatMap { i, t in t.clips.map { (i, $0) } }.compactMap { i, c -> (CGFloat, CGPoint)? in
            guard let content else { return nil }
            let r = hoverTimeline.clipRect(c, laneY: hoverTimeline.laneY(i)).intersection(hoverTimeline.visibleRect)
            guard r.width >= 60, r.height >= 24 else { return nil }
            let p = hoverTimeline.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            return content.hitTest(content.convert(p, from: nil)) === hoverTimeline ? (r.width, p) : nil
        }.max { $0.0 < $1.0 }?.1
        if let p = reachable {
            let ev = mouse(.mouseMoved, p)
            w.timeline.mouseMoved(with: ev); w.pointerMoved(ev)
            check(w.hoverHint?.contains("drag to move") == true, "hovering a clip explains it (\(w.hoverHint ?? "none"))")
        } else { print("SKIP  hovering a clip explains it [environment: no clip on screen at this window size]") }
        MainWindowController.showsHints = false
        w.pointerMoved(mouse(.mouseMoved, mixerCenter))
        check(w.hoverHint == nil, "hints off: nothing shown")
        MainWindowController.showsHints = wasHints

        // Zoom glides (keyboard and menu): it keeps the anchor still and lands exactly on the target.
        Motion.override = true
        defer { Motion.override = false }
        let tl = w.timeline
        tl.zoomToFit()
        let f0 = tl.framesPerPoint, x = tl.bounds.midX, anchor = tl.frame(forX: x)
        tl.zoomSmoothly(by: 0.5, around: x)
        check(tl.isGliding || Motion.reduced, "zoom in glides")
        tl.zoomSmoothly(by: 0.5, around: x) // a second press builds on the first's target
        var drift = 0.0
        for _ in 0..<12 { await wait(0.03); drift = max(drift, abs(tl.frame(forX: x) - anchor) / tl.framesPerPoint) }
        await wait(0.3)
        check(!tl.isGliding && abs(tl.framesPerPoint - f0 / 4) < 1e-6 * f0,
              "two zoom-ins glide to a quarter of the frames per point (\(tl.framesPerPoint) vs \(f0 / 4))")
        check(drift < 0.5, "the zoom anchor stays under the same point while gliding (worst \(String(format: "%.3f", drift)) pt)")
        check(perform("Zoom to Fit"), "menu View > Zoom to Fit")
        await wait(0.45)
        check(abs(tl.framesPerPoint - f0) < 1e-6 * f0 && tl.scrollFrame == 0, "zoom to fit glides back to the whole project")
        tl.zoomSmoothly(by: 0.5, around: x)
        tl.zoom(by: 1, around: x) // a gesture takes over
        check(!tl.isGliding && tl.glideTarget == nil, "a pinch or scroll stops a glide")

        // Count-in: an optional toolbar button, lit while on, and big beat numbers over the arrangement.
        let countIn = MainWindowController.countIn
        t.countInButton.performClick(nil)
        check(MainWindowController.countIn != countIn && t.countInButton.isActive == !countIn, "Count-In button toggles count-in and lights")
        t.countInButton.performClick(nil)
        check(MainWindowController.countIn == countIn && t.countInButton.isActive == countIn, "and toggles it back")
        w.countInOverlay.show(3, beat: 0.5)
        check(w.countInOverlay.shown == 3, "count-in overlay shows the beat")
        w.countInOverlay.show(nil, beat: 0)
        check(w.countInOverlay.shown == nil, "and hides after the count-in")
    }
}
