// Settings: every preference in one window, grouped by what it affects (General, Appearance, Audio & MIDI,
// Recording, Plug-ins, Keyboard Shortcuts). Changes apply at once; the theme switches live.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class SettingsController: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    enum Pane: Int, CaseIterable {
        case general, appearance, audio, recording, plugins, shortcuts
        var title: String {
            switch self {
            case .general: "General"
            case .appearance: "Appearance"
            case .audio: "Audio & MIDI"
            case .recording: "Recording"
            case .plugins: "Plug-ins"
            case .shortcuts: "Keyboard Shortcuts"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .audio: "hifispeaker"
            case .recording: "record.circle"
            case .plugins: "puzzlepiece.extension"
            case .shortcuts: "keyboard"
            }
        }
    }

    // General
    let comingFrom = NSPopUpButton(frame: .zero, pullsDown: false)
    let copyAudio = NSButton(checkboxWithTitle: "Copy audio into the project folder when saving", target: nil, action: nil)
    let automationMode = NSPopUpButton(frame: .zero, pullsDown: false)
    // Appearance
    let themePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let appearanceNote = NSTextField(wrappingLabelWithString: "")
    let relaunch = NSButton(title: "Relaunch Now", target: nil, action: nil)
    let barsAndBeats = NSButton(checkboxWithTitle: "Bars and beats (otherwise minutes and seconds)", target: nil, action: nil)
    let secondaryClock = NSButton(checkboxWithTitle: "Show a small second clock under the position display", target: nil, action: nil)
    let trackHeight = NSSlider(value: 88, minValue: 48, maxValue: 400, target: nil, action: nil)
    private let trackHeightValue = NSTextField(labelWithString: "")
    // Audio & MIDI
    let outputPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    let inputPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    let inputMonitoring = NSButton(checkboxWithTitle: "Hear armed tracks' inputs while recording (input monitoring)", target: nil, action: nil)
    private let midiInputs = NSTextField(wrappingLabelWithString: "")
    // Recording
    let countIn = NSButton(checkboxWithTitle: "Count in one bar before recording", target: nil, action: nil)
    let metronome = NSButton(checkboxWithTitle: "Metronome click", target: nil, action: nil)
    // Plug-ins
    let deviceMeters = NSButton(checkboxWithTitle: "Show input and output meters on plug-ins (Graphite)", target: nil, action: nil)
    /// How worn the plug-in units look (Graphite): 0 new … 1 well used.
    let wear = NSSlider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let wearValue = NSTextField(labelWithString: "")
    /// The keyboard-shortcut editor, shown in its own pane.
    let shortcuts = ShortcutEditorController()

    private var paneViews: [Pane: NSView] = [:]
    private var sidebarButtons: [NSButton] = []
    private let paneHost = NSView()
    private(set) var pane: Pane = .general
    private var main: MainWindowController? { (NSApp.delegate as? AppDelegate)?.main }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.panel.cgColor
        window.contentView = content
        // Sidebar.
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 10, right: 10)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = Theme.window.cgColor
        for p in Pane.allCases {
            let b = NSButton(title: "  " + p.title, image: NSImage(systemSymbolName: p.symbol, accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: #selector(paneChosen(_:)))
            b.tag = p.rawValue
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.alignment = .left
            b.font = Theme.ui(12.5, .medium)
            b.contentTintColor = Theme.textDim
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            b.widthAnchor.constraint(equalToConstant: 170).isActive = true
            b.setAccessibilityLabel(p.title)
            sidebarButtons.append(b)
            sidebar.addArrangedSubview(b)
        }
        for v in [sidebar, paneHost] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 190),
            paneHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), paneHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneHost.topAnchor.constraint(equalTo: content.topAnchor), paneHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        buildPanes()
        // The shortcut editor lives in this window: its sheets and focus belong here now.
        if let editorContent = shortcuts.window?.contentView {
            shortcuts.window?.contentView = NSView()
            paneViews[.shortcuts] = editorContent
        }
        shortcuts.window = window
        select(.general)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ pane: Pane? = nil) {
        if let pane { select(pane) }
        refresh()
        showWindow(nil)
        if window?.isVisible == false { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    func windowWillClose(_ notification: Notification) { shortcuts.windowWillClose(notification) }

    @objc private func paneChosen(_ sender: NSButton) { Pane(rawValue: sender.tag).map(select) }
    func select(_ p: Pane) {
        pane = p
        paneHost.subviews.forEach { $0.removeFromSuperview() }
        guard let v = paneViews[p] else { return }
        v.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor), v.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
            v.topAnchor.constraint(equalTo: paneHost.topAnchor), v.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
        ])
        for b in sidebarButtons {
            let on = b.tag == p.rawValue
            b.layer?.backgroundColor = on ? Theme.selection.withAlphaComponent(0.35).cgColor : nil
            b.contentTintColor = on ? Theme.text : Theme.textDim
        }
        window?.title = p == .general ? "Settings" : "Settings: \(p.title)"
    }

    // MARK: Building

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.ui(12, .medium)
        l.textColor = Theme.text
        l.alignment = .right
        return l
    }
    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = Theme.ui(11)
        l.textColor = Theme.textDim
        l.preferredMaxLayoutWidth = 420
        return l
    }
    private func smallButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 8
        s.alignment = .centerY
        return s
    }
    /// A pane: a title, then rows of (label, control, optional explanation) in a form grid.
    private func pane(_ title: String, _ intro: String, _ rows: [(String, NSView, String?)]) -> NSView {
        let v = NSView()
        let heading = NSTextField(labelWithString: title)
        heading.font = Theme.ui(20, .semibold)
        heading.textColor = Theme.text
        let sub = note(intro)
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 14
        for (name, control, explain) in rows {
            grid.addRow(with: [label(name), control])
            if let explain { grid.addRow(with: [NSGridCell.emptyContentView, note(explain)]) }
            if let r = grid.row(at: grid.numberOfRows - 1) as NSGridRow? { r.bottomPadding = 10 }
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 150
        grid.rowAlignment = .firstBaseline
        for v2 in [heading, sub, grid] as [NSView] { v2.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(v2) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 28), heading.topAnchor.constraint(equalTo: v.topAnchor, constant: 22),
            sub.leadingAnchor.constraint(equalTo: heading.leadingAnchor), sub.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -28),
            grid.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10), grid.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -28),
        ])
        return v
    }

    private func buildPanes() {
        // General
        comingFrom.addItem(withTitle: "Not chosen")
        comingFrom.addItems(withTitles: SourceDAW.allCases.map(\.title))
        comingFrom.target = self; comingFrom.action = #selector(comingFromChanged(_:))
        copyAudio.target = self; copyAudio.action = #selector(copyChanged(_:))
        copyAudio.toolTip = "Keeps saved projects easier to move between computers."
        automationMode.addItems(withTitles: ["Read", "Touch", "Latch"])
        automationMode.target = self; automationMode.action = #selector(automationChanged(_:))
        paneViews[.general] = pane("General", "How Dalnok saves, writes automation and speaks your old DAW's language.", [
            ("Coming from", comingFrom, "The command palette and Concept Guide also answer to that DAW's words for things."),
            ("Projects", copyAudio, nil),
            ("Automation", automationMode, "Read plays automation. Touch writes while you hold a control during playback; Latch keeps writing until the transport stops."),
            ("Welcome", smallButton("Show the Welcome Guide", #selector(showWelcome)), nil),
        ])
        // Appearance
        for s in Theme.Style.allCases { themePicker.addItem(withTitle: s.title) }
        themePicker.target = self; themePicker.action = #selector(themeChanged(_:))
        relaunch.bezelStyle = .rounded
        relaunch.controlSize = .small
        relaunch.target = self; relaunch.action = #selector(relaunchTapped(_:))
        relaunch.toolTip = "Quit and reopen Dalnok with the new appearance (you'll be asked to save changes first)"
        appearanceNote.font = Theme.ui(11); appearanceNote.textColor = Theme.textDim
        appearanceNote.preferredMaxLayoutWidth = 380
        barsAndBeats.target = self; barsAndBeats.action = #selector(barsChanged(_:))
        secondaryClock.target = self; secondaryClock.action = #selector(clockChanged(_:))
        trackHeight.target = self; trackHeight.action = #selector(trackHeightChanged(_:))
        trackHeight.widthAnchor.constraint(equalToConstant: 200).isActive = true
        trackHeightValue.font = Theme.mono(11); trackHeightValue.textColor = Theme.textDim
        paneViews[.appearance] = pane("Appearance", "The look of Dalnok and how the arrangement is laid out.", [
            ("Theme", themePicker, nil),
            ("", row([appearanceNote, relaunch]), nil),
            ("Ruler and clock", barsAndBeats, nil),
            ("", secondaryClock, "Real time when the main display shows bars, and bars when it shows real time."),
            ("Track height", row([trackHeight, trackHeightValue, smallButton("Reset All Tracks", #selector(resetTrackHeights))]),
             "Drag a track header's bottom edge to size one track (double-click it for the default), or ⌥-scroll over the tracks to size them all."),
            ("Motion", note("Animations follow System Settings ▸ Accessibility ▸ Display ▸ Reduce motion."), nil),
        ])
        // Audio & MIDI
        for p in [outputPopup, inputPopup] { p.menu?.delegate = self; p.widthAnchor.constraint(equalToConstant: 320).isActive = true }
        outputPopup.menu?.title = "Output Device"
        inputPopup.menu?.title = "Recording Input"
        midiInputs.font = Theme.ui(12); midiInputs.textColor = Theme.text
        midiInputs.preferredMaxLayoutWidth = 380
        paneViews[.audio] = pane("Audio & MIDI", "Where Dalnok plays to and records from.", [
            ("Output", outputPopup, nil),
            ("Recording input", inputPopup, "A device with inputs and outputs; Dalnok compensates for the latency it reports."),
            ("MIDI inputs", midiInputs, "Every connected MIDI input plays the armed instrument track."),
        ])
        // Recording
        countIn.target = self; countIn.action = #selector(countInChanged(_:))
        metronome.target = self; metronome.action = #selector(metronomeChanged(_:))
        inputMonitoring.target = self; inputMonitoring.action = #selector(monitoringChanged(_:))
        paneViews[.recording] = pane("Recording", "What happens when you press Record.", [
            ("Before recording", countIn, nil),
            ("Click", metronome, "Also on the control bar (K)."),
            ("Monitoring", inputMonitoring, "Use headphones to avoid feedback."),
        ])
        // Plug-ins
        deviceMeters.target = self; deviceMeters.action = #selector(metersChanged(_:))
        deviceMeters.toolTip = "Thin level meters on each plug-in's faceplate in the device panel"
        wear.target = self; wear.action = #selector(wearChanged(_:))
        wear.isContinuous = true
        wear.toolTip = "Scratches and grime on the metal, dust and smudges on the displays' glass"
        wear.setAccessibilityLabel("Plug-in wear")
        wear.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let newLabel = NSTextField(labelWithString: "New"), usedLabel = NSTextField(labelWithString: "Well used")
        for l in [newLabel, usedLabel, wearValue] { l.font = Theme.ui(10.5); l.textColor = Theme.textDim }
        wearValue.font = Theme.mono(10.5)
        paneViews[.plugins] = pane("Plug-ins", "How plug-ins look in the device panel, and where they come from.", [
            ("Meters", deviceMeters, nil),
            ("Wear", row([newLabel, wear, usedLabel, wearValue]), "Scratches and grime on the metal; dust, smudges and an aged VU face behind the glass."),
            ("Displays", smallButton("Reset Display Choices", #selector(resetDisplays)), "Back to the display Dalnok picks for each plug-in (right-click a unit ▸ Display to choose one)."),
            ("Library", smallButton("Open Plug-in Manager…", #selector(openPlugins)), "Scan, validate, favourite and tag your VST3, CLAP and Audio Unit plug-ins."),
        ])
    }

    // MARK: State

    func refresh() {
        comingFrom.selectItem(at: SourceDAW.preferred.flatMap { SourceDAW.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        copyAudio.state = MainWindowController.copyAudioOnSave ? .on : .off
        automationMode.selectItem(at: AutomationWriter.mode.rawValue)
        themePicker.selectItem(at: Theme.Style.allCases.firstIndex(of: Theme.preferredStyle) ?? 0)
        appearanceNote.stringValue = Theme.preferredStyle == Theme.activeStyle
            ? "Graphite is crisp and focused. Warm Analog brings a softer studio palette."
            : "The appearance changes when recording stops, or relaunch now."
        relaunch.isHidden = Theme.preferredStyle == Theme.activeStyle
        barsAndBeats.state = TimelineView.barsAndBeats ? .on : .off
        secondaryClock.state = TransportBar.showsSecondaryClock ? .on : .off
        trackHeight.doubleValue = Double(Theme.trackHeight)
        trackHeightValue.stringValue = "\(Int(Theme.trackHeight)) pt"
        outputPopup.removeAllItems(); outputPopup.addItem(withTitle: main?.outputDeviceDescription() ?? "Output")
        inputPopup.removeAllItems(); inputPopup.addItem(withTitle: main?.recordingDevice?.name ?? "No recording input")
        let sources = Engine.midiSources().map(\.name)
        midiInputs.stringValue = sources.isEmpty ? "None connected" : sources.joined(separator: ", ")
        inputMonitoring.state = MainWindowController.inputMonitoring ? .on : .off
        countIn.state = MainWindowController.countIn ? .on : .off
        metronome.state = MainWindowController.metronomeOn ? .on : .off
        deviceMeters.state = Faceplate.showMeters ? .on : .off
        wear.doubleValue = Faceplate.wear
        wearValue.stringValue = String(format: "%.0f%%", Faceplate.wear * 100)
    }

    /// The device pull-downs list what the main window's menus list, built fresh each time they open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let main else { return }
        let source = NSMenu(title: menu.title)
        main.menuNeedsUpdate(source)
        let title = menu.items.first?.title ?? menu.title
        menu.removeAllItems()
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "") // a pull-down's title
        for item in source.items {
            if item.isSeparatorItem { menu.addItem(.separator()); continue }
            guard let action = item.action else {
                let info = NSMenuItem(title: item.title, action: nil, keyEquivalent: ""); info.isEnabled = false; menu.addItem(info); continue
            }
            let target = item.target ?? main
            let copy = ClosureMenuItem(title: item.title) { [weak self] in
                NSApp.sendAction(action, to: target, from: item)
                self?.refresh()
            }
            copy.state = item.state
            copy.isEnabled = item.isEnabled
            copy.toolTip = item.toolTip
            menu.addItem(copy)
        }
    }

    // MARK: Actions

    @objc func comingFromChanged(_ sender: Any?) {
        let i = comingFrom.indexOfSelectedItem
        SourceDAW.preferred = i > 0 ? SourceDAW.allCases[i - 1] : nil
    }
    @objc func copyChanged(_ sender: Any?) { MainWindowController.copyAudioOnSave = copyAudio.state == .on }
    @objc func automationChanged(_ sender: Any?) {
        let sel: Selector = [#selector(MainWindowController.automationRead(_:)), #selector(MainWindowController.automationTouch(_:)),
                             #selector(MainWindowController.automationLatch(_:))][max(0, min(2, automationMode.indexOfSelectedItem))]
        if let main { NSApp.sendAction(sel, to: main, from: self) }
    }
    @objc private func showWelcome() { main?.welcome.show() }
    @objc func relaunchTapped(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.relaunchOnQuit = true
        NSApp.terminate(nil) // a cancelled save prompt clears the flag (AppDelegate.applicationShouldTerminate)
    }
    @objc func themeChanged(_ sender: Any?) {
        let i = themePicker.indexOfSelectedItem
        guard Theme.Style.allCases.indices.contains(i) else { return }
        Theme.preferredStyle = Theme.Style.allCases[i]
        // Live: the windows rebuild in the new style (while recording, the change waits for a relaunch).
        _ = (NSApp.delegate as? AppDelegate)?.switchTheme(to: Theme.preferredStyle)
        refresh()
    }
    @objc func barsChanged(_ sender: Any?) {
        if (barsAndBeats.state == .on) != TimelineView.barsAndBeats, let main { main.toggleBarsAndBeats(nil) }
    }
    @objc func clockChanged(_ sender: Any?) { TransportBar.showsSecondaryClock = secondaryClock.state == .on }
    @objc func trackHeightChanged(_ sender: Any?) {
        main?.setTrackHeight(CGFloat(trackHeight.doubleValue.rounded()))
        trackHeightValue.stringValue = "\(Int(Theme.trackHeight)) pt"
    }
    @objc private func resetTrackHeights() {
        main?.setTrackHeight(Theme.baseTrackHeight)
        refresh()
    }
    @objc func monitoringChanged(_ sender: Any?) {
        if (inputMonitoring.state == .on) != MainWindowController.inputMonitoring { main?.toggleInputMonitoring(nil) }
        refresh()
    }
    @objc func countInChanged(_ sender: Any?) {
        if (countIn.state == .on) != MainWindowController.countIn { main?.toggleCountIn(nil) }
        refresh()
    }
    @objc func metronomeChanged(_ sender: Any?) {
        if (metronome.state == .on) != MainWindowController.metronomeOn { main?.toggleMetronome(nil) }
        refresh()
    }
    @objc func metersChanged(_ sender: Any?) { Faceplate.showMeters = deviceMeters.state == .on }
    @objc func wearChanged(_ sender: Any?) {
        Faceplate.wear = wear.doubleValue
        wearValue.stringValue = String(format: "%.0f%%", Faceplate.wear * 100)
    }
    @objc private func resetDisplays() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("faceplate.display.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        main?.devicePanel.rebuildAll()
    }
    @objc private func openPlugins() { main?.showPlugins(nil) }
}
