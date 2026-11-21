// Self-test steps (first run and navigation): the start page and its templates, the control bar's view buttons, the
// hint line, the undo toast, gliding zoom and the new-lane glow. The harness (check, perform, mouse) is SelfTest.swift.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

extension SelfTest {
    /// Runs on an empty project (File ▸ New): the start page, then a template, then undo back to the start page.
    func startPage() async {
        let e = s.engine
        let page = w.emptyState
        check(page.cards.count == ProjectTemplate.all.count && ProjectTemplate.all.count == 6, "start page shows \(page.cards.count) templates")
        check(page.subviewsDeep.compactMap { $0 as? NSButton }.filter { $0.toolTip.map { $0.hasPrefix("/") } ?? false }.isEmpty,
              "an automated run lists no recent projects (names stay private)")
        let ways = page.subviewsDeep.compactMap { $0 as? NSButton }
        check(ways.allSatisfy { $0.action != nil && $0.target != nil }, "every start page button has an action")
        if let b = ways.first(where: { $0.accessibilityLabel() == "Empty Instrument Track" }) {
            b.performClick(nil)
            check(s.tracks.count == 1 && s.tracks.first?.isInstrument == true, "start page's Empty Instrument Track adds one")
            _ = perform("Undo")
        } else { check(false, "start page offers Empty Instrument Track") }

        guard let beat = page.cards.first(where: { $0.template.id == "beat" }) else { return check(false, "a Make a Beat template") }
        Motion.override = true
        defer { Motion.override = false }
        beat.performClick(nil)
        let want = beat.template.tracks.map(\.name)
        check(s.tracks.map(\.name) == want && s.tracks.allSatisfy(\.isInstrument),
              "Make a Beat adds \(want.joined(separator: ", ")) (got \(s.tracks.map(\.name).joined(separator: ", ")))")
        check(e.undoName == "New Make a Beat Project", "a template is one undo step (\(e.undoName))")
        check(w.headers.selectedTrack == s.tracks.first?.id, "the template's first track is selected")
        check(w.toast.text.hasPrefix("Make a Beat: 4 tracks"), "a toast confirms the template (\(w.toast.text))")
        check(Set(w.timeline.laneFlash.keys) == Set(s.tracks.map(\.id)), "new lanes glow (\(w.timeline.laneFlash.count) of \(s.tracks.count))")
        await wait(0.6)
        check(page.isHidden && !w.timeline.isHidden, "the arrangement replaces the start page")
        await wait(0.4)
        check(w.timeline.laneFlash.isEmpty, "and settle after \(TimelineView.laneFlashSeconds) s")

        // Undo names what it undid, and takes the project back to the start page.
        check(perform("Undo"), "menu Edit > Undo after a template")
        check(s.tracks.isEmpty, "undo removes the template's tracks")
        check(w.toast.text == "Undo New Make a Beat Project", "undo toast names the step (\(w.toast.text))")
        await wait(0.6)
        check(!page.isHidden, "the start page returns for the empty project")
        _ = perform("Redo")
        check(w.toast.text == "Redo New Make a Beat Project" && s.tracks.count == 4, "redo toast and tracks (\(w.toast.text))")
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
        if let c = s.tracks.first(where: { !$0.clips.isEmpty })?.clips.first, let p = w.timeline.windowPoint(ofClip: c.id, zone: "body") {
            let ev = mouse(.mouseMoved, p)
            w.timeline.mouseMoved(with: ev); w.pointerMoved(ev)
            check(w.hoverHint?.contains("drag to move") == true, "hovering a clip explains it (\(w.hoverHint ?? "none"))")
        }
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

        // Count-in: big beat numbers over the arrangement.
        w.countInOverlay.show(3, beat: 0.5)
        check(w.countInOverlay.shown == 3, "count-in overlay shows the beat")
        w.countInOverlay.show(nil, beat: 0)
        check(w.countInOverlay.shown == nil, "and hides after the count-in")
    }
}
