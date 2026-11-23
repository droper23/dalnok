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
    let copyAudio = SettingsController.checkbox("Copy audio into the project folder when saving")
    let automationMode = NSPopUpButton(frame: .zero, pullsDown: false)
    // Appearance
    let themePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Light or dark version of themes that have both (Prism, Atelier): Match System, Light, Dark.
    let variantPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    static let variantChoices = ["system", "light", "dark"]
    let appearanceNote = NSTextField(wrappingLabelWithString: "")
    let relaunch = NSButton(title: "Relaunch Now", target: nil, action: nil)
    let barsAndBeats = SettingsController.checkbox("Bars and beats (otherwise minutes and seconds)")
    let secondaryClock = SettingsController.checkbox("Show a small second clock under the position display")
    let trackHeight = NSSlider(value: 88, minValue: 48, maxValue: 400, target: nil, action: nil)
    let clipBounce = NSSlider(value: 0.65, minValue: 0, maxValue: 1, target: nil, action: nil)
    let showHints = SettingsController.checkbox("Describe the control under the pointer below the project name")
    private let trackHeightValue = NSTextField(labelWithString: "")
    // Audio & MIDI
    let outputPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    let inputPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    let inputMonitoring = SettingsController.checkbox("Armed tracks play their input (auto input monitoring)")
    private let midiInputs = NSTextField(wrappingLabelWithString: "")
    // Recording
    let countIn = SettingsController.checkbox("Count in one bar before recording")
    let metronome = SettingsController.checkbox("Metronome click")
    // Plug-ins
    let deviceMeters = SettingsController.checkbox("Show input and output meters on plug-ins (Graphite)")
    let isolatePlugins = SettingsController.checkbox("Run plug-ins in separate processes")
    /// How worn the plug-in units look (Graphite): 0 new … 1 well used.
    let wear = NSSlider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
    let peakHold = NSSlider(value: 1.5, minValue: 0, maxValue: 3, target: nil, action: nil)
    private let peakHoldValue = NSTextField(labelWithString: "")
    let vuBallistics = NSPopUpButton(frame: .zero, pullsDown: false)
    let bypassShrink = NSSlider(value: 0.045, minValue: 0, maxValue: 0.1, target: nil, action: nil)
    let bypassDim = NSSlider(value: 0.12, minValue: 0, maxValue: 0.5, target: nil, action: nil)
    let bypassMotion = NSSlider(value: 0.5, minValue: 0.1, maxValue: 1.5, target: nil, action: nil)
    let lightFade = NSSlider(value: 0.7, minValue: 0, maxValue: 2, target: nil, action: nil)
    let readoutsFade = SettingsController.checkbox("Readouts fade with the other lights (otherwise they switch off at once)")
    let selectionGlow = SettingsController.checkbox("Outline the selected plug-in")
    let gainRings = SettingsController.checkbox("Gain knobs light up with their track's level")
    private var sliderValues: [NSSlider: (NSTextField, (Double) -> String)] = [:]
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
        window.autorecalculatesKeyViewLoop = true // Tab follows the layout (keyboard-only use)
        window.title = "Settings"
        window.appearance = Theme.appearance
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.panel.cgColor
        window.contentView = content
        defer {
            if Theme.activeStyle == .atelier { // the parchment over the whole sheet (never takes clicks)
                let paper = PaperGrainView(frame: content.bounds)
                paper.autoresizingMask = [.width, .height]
                content.addSubview(paper)
            }
        }
        let atelier = Theme.look.mixer == .instrument
        // Sidebar.
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 10, right: 10)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = Theme.window.cgColor
        for p in Pane.allCases {
            // Symbols centred in one fixed-width box, so every title starts at the same x (the audit: ragged labels).
            let b = NSButton(title: "  " + p.title, image: Self.fixedSymbol(p.symbol, width: 20),
                             target: self, action: #selector(paneChosen(_:)))
            b.tag = p.rawValue
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.alignment = .left
            b.font = atelier ? Theme.title(13.5) : Theme.ui(12.5, .medium)
            b.contentTintColor = Theme.textDim
            b.wantsLayer = true
            b.layer?.cornerRadius = atelier ? 0 : 6
            if atelier { // the chosen section is marked by a red rule at its edge (no rounded pill)
                let rule = CALayer()
                rule.name = "rule"
                rule.backgroundColor = Atelier.vermilion.cgColor
                rule.frame = CGRect(x: 0, y: 4, width: 2, height: 22)
                rule.isHidden = true
                b.layer?.addSublayer(rule)
            }
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
        Atelier.unifyFonts(in: window?.contentView)
        // Placed before it shows: showWindow made it visible first, so the old check never centered it and it opened at
        // its creation origin, the screen's bottom-left corner.
        guard let window else { return }
        if window.isVisible { window.makeKeyAndOrderFront(nil) } else { showCentered(window) }
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
            b.layer?.backgroundColor = on ? (Theme.look.mixer == .instrument ? Theme.laneHighlight : Theme.selection.withAlphaComponent(0.35)).cgColor : nil
            b.layer?.sublayers?.first { $0.name == "rule" }?.isHidden = !on
            b.contentTintColor = on ? Theme.text : Theme.textDim
        }
        window?.title = p == .general ? "Settings" : "Settings: \(p.title)"
    }

    // MARK: Building

    /// A check box in the sheet's label style (the audit: two were set larger, in another face).
    static func checkbox(_ title: String) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.font = Theme.look.mixer == .instrument ? Theme.title(13) : Theme.ui(12)
        return b
    }
    /// An SF Symbol drawn centred in a box of fixed width, so a column of icon buttons lines its titles up.
    static func fixedSymbol(_ name: String, width: CGFloat) -> NSImage {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? NSImage()
        let h = max(16, symbol.size.height)
        let img = NSImage(size: NSSize(width: width, height: h), flipped: false) { r in
            symbol.draw(in: NSRect(x: (r.width - symbol.size.width) / 2, y: (r.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
            return true
        }
        img.isTemplate = true
        return img
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.look.mixer == .instrument ? Theme.title(13) : Theme.ui(12, .medium)
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
        b.font = Theme.ui(11)
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
        let v = FlippedView()
        let heading = NSTextField(labelWithString: title)
        heading.font = Theme.ui(20, .semibold)
        heading.textColor = Theme.text
        let sub = note(intro)
        let grid = NSGridView()
        grid.rowSpacing = 6
        grid.columnSpacing = 14
        for (name, control, explain) in rows {
            let l = label(name)
            // VoiceOver names the control by its row label (unless it already has its own name).
            if (control.accessibilityLabel() ?? "").isEmpty { control.setAccessibilityTitleUIElement(l) }
            grid.addRow(with: [l, control])
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
            grid.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -24),
        ])
        // Long panes scroll.
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        v.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = v
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            v.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return scroll
    }
    /// A slider with its value printed beside it (and optional end captions).
    private func slider(_ s: NSSlider, _ sel: Selector, width: CGFloat = 200, _ format: @escaping (Double) -> String,
                        from: String? = nil, to: String? = nil) -> NSView {
        s.target = self; s.action = sel
        s.isContinuous = true
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        let value = NSTextField(labelWithString: "")
        value.font = Theme.mono(10.5); value.textColor = Theme.textDim
        sliderValues[s] = (value, format)
        var views: [NSView] = []
        func caption(_ t: String) -> NSTextField { let l = NSTextField(labelWithString: t); l.font = Theme.ui(10.5); l.textColor = Theme.textDim; return l }
        if let from { views.append(caption(from)) }
        views.append(s)
        if let to { views.append(caption(to)) }
        views.append(value)
        return row(views)
    }
    private func showSliderValues() { for (s, (label, format)) in sliderValues { label.stringValue = format(s.doubleValue) } }

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
        variantPicker.addItems(withTitles: ["Match System", "Light", "Dark"])
        variantPicker.target = self; variantPicker.action = #selector(variantChanged(_:))
        variantPicker.setAccessibilityLabel("Light or dark version")
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
            ("Light or dark", variantPicker, "Prism and Atelier come in light and dark versions; Graphite and Warm Analog are dark."),
            ("", row([appearanceNote, relaunch]), nil),
            ("Ruler and clock", barsAndBeats, nil),
            ("", secondaryClock, "Real time when the main display shows bars, and bars when it shows real time."),
            ("Track meters", gainRings, nil),
            ("Track height", row([trackHeight, trackHeightValue, smallButton("Reset All Tracks", #selector(resetTrackHeights))]),
             "Drag a track header's bottom edge to size one track (double-click it for the default), or ⌥-scroll over the tracks to size them all."),
            ("Clip bounce", slider(clipBounce, #selector(clipBounceChanged(_:)), { String(format: "%.0f%%", $0 * 100) }, from: "Calm", to: "Bouncy"),
             "How lively dragged, dropped, new and deleted clips move: the lift, the spring between grid steps, the lean and the settle."),
            ("Hints", showHints, "Like a hover tooltip without the wait: every button, knob and clip edge says what it does."),
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
        isolatePlugins.target = self; isolatePlugins.action = #selector(isolationChanged(_:))
        isolatePlugins.toolTip = "Each third-party plug-in runs in its own process, so a crash or hang can't take Dalnok down"
        deviceMeters.toolTip = "Thin level meters on each plug-in's faceplate in the device panel"
        wear.toolTip = "Scratches and grime on the metal, dust and smudges on the displays' glass"
        wear.setAccessibilityLabel("Plug-in wear")
        vuBallistics.addItems(withTitles: ["Standard VU (300 ms)", "Fast (100 ms)"])
        vuBallistics.target = self; vuBallistics.action = #selector(vuChanged(_:))
        for (b, sel) in [(readoutsFade, #selector(readoutsChanged(_:))), (selectionGlow, #selector(selectionChanged(_:))),
                         (gainRings, #selector(gainRingsChanged(_:))), (showHints, #selector(showHintsChanged(_:)))] { b.target = self; b.action = sel }
        let pct: (Double) -> String = { String(format: "%.0f%%", $0 * 100) }, secs: (Double) -> String = { String(format: "%.1f s", $0) }
        paneViews[.plugins] = pane("Plug-ins", "How plug-ins look and behave in the device panel, and where they come from.", [
            ("Meters", deviceMeters, nil),
            ("Peak hold", slider(peakHold, #selector(peakHoldChanged(_:)), secs), "How long the IN/OUT meters hold their highest LED."),
            ("VU needle", vuBallistics, "The standard movement settles in about 300 ms; the fast one follows transients more closely."),
            ("Wear", slider(wear, #selector(wearChanged(_:)), pct, from: "New", to: "Well used"),
             "Scratches and grime on the metal; dust, smudges and an aged VU face behind the glass."),
            ("Bypassed: shrink", slider(bypassShrink, #selector(bypassChanged(_:)), pct), "How far a turned-off unit sits back."),
            ("Bypassed: dim", slider(bypassDim, #selector(bypassChanged(_:)), pct), "How much darker a turned-off unit looks."),
            ("Bypass motion", slider(bypassMotion, #selector(bypassChanged(_:)), secs), "How long the unit takes to sit back or come forward."),
            ("Lights fade", slider(lightFade, #selector(bypassChanged(_:)), secs), "How long LEDs, screens and lamps take to go out or warm up (0 s: at once)."),
            ("Readouts", readoutsFade, nil),
            ("Selection", selectionGlow, nil),
            ("Displays", smallButton("Reset Display Choices", #selector(resetDisplays)), "Back to the display Dalnok picks for each plug-in (right-click a unit ▸ Display to choose one)."),
            ("Library", smallButton("Open Plug-in Manager…", #selector(openPlugins)), "Scan, validate, favourite and tag your VST3, CLAP and Audio Unit plug-ins."),
            ("Safety", isolatePlugins, "A plug-in that crashes or stops responding is switched off and reported instead of stopping Dalnok; Load restarts it. Applies to plug-ins loaded from now on. Each plug-in's editor opens in its own window beside the plug-in window."),
            ("", smallButton("Restore Plug-in Defaults", #selector(restorePluginDefaults)), nil),
        ])
    }

    // MARK: State

    func refresh() {
        comingFrom.selectItem(at: SourceDAW.preferred.flatMap { SourceDAW.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
        copyAudio.state = MainWindowController.copyAudioOnSave ? .on : .off
        automationMode.selectItem(at: AutomationWriter.mode.rawValue)
        themePicker.selectItem(at: Theme.Style.allCases.firstIndex(of: Theme.preferredStyle) ?? 0)
        variantPicker.selectItem(at: Self.variantChoices.firstIndex(of: Theme.variantPreference) ?? 0)
        variantPicker.isEnabled = Theme.preferredStyle.variants.count > 1
        appearanceNote.stringValue = Theme.preferredStyle == Theme.activeStyle
            ? Theme.activeStyle.summary + "."
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
        isolatePlugins.state = Engine.isolatePlugins ? .on : .off
        isolatePlugins.isEnabled = Engine.pluginHostAvailable
        wear.doubleValue = Faceplate.wear
        clipBounce.doubleValue = Double(ClipLift.bounce)
        showHints.state = MainWindowController.showsHints ? .on : .off
        peakHold.doubleValue = Faceplate.peakHold
        vuBallistics.selectItem(at: Faceplate.fastVU ? 1 : 0)
        bypassShrink.doubleValue = Faceplate.bypassShrink
        bypassDim.doubleValue = Faceplate.bypassDim
        bypassMotion.doubleValue = Faceplate.bypassMotion
        lightFade.doubleValue = Faceplate.lightFade
        readoutsFade.state = Faceplate.readoutsFade ? .on : .off
        selectionGlow.state = Faceplate.selectionGlow ? .on : .off
        gainRings.state = GainKnob.showsLevel ? .on : .off
        showSliderValues()
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
    @objc func variantChanged(_ sender: Any?) {
        let i = variantPicker.indexOfSelectedItem
        guard Self.variantChoices.indices.contains(i) else { return }
        Theme.variantPreference = Self.variantChoices[i]
        _ = (NSApp.delegate as? AppDelegate)?.switchTheme(to: Theme.activeStyle)
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
    @objc func isolationChanged(_ sender: Any?) { Engine.isolatePlugins = isolatePlugins.state == .on }
    @objc func showHintsChanged(_ sender: Any?) { MainWindowController.showsHints = showHints.state == .on }
    @objc func clipBounceChanged(_ sender: Any?) { ClipLift.bounce = CGFloat(clipBounce.doubleValue); showSliderValues() }
    @objc func wearChanged(_ sender: Any?) { Faceplate.wear = wear.doubleValue; showSliderValues() }
    @objc func peakHoldChanged(_ sender: Any?) { Faceplate.peakHold = peakHold.doubleValue; showSliderValues() }
    @objc func vuChanged(_ sender: Any?) { Faceplate.fastVU = vuBallistics.indexOfSelectedItem == 1 }
    @objc func bypassChanged(_ sender: Any?) {
        Faceplate.bypassShrink = bypassShrink.doubleValue
        Faceplate.bypassDim = bypassDim.doubleValue
        Faceplate.bypassMotion = bypassMotion.doubleValue
        Faceplate.lightFade = lightFade.doubleValue
        showSliderValues()
    }
    @objc func readoutsChanged(_ sender: Any?) { Faceplate.readoutsFade = readoutsFade.state == .on }
    @objc func selectionChanged(_ sender: Any?) { Faceplate.selectionGlow = selectionGlow.state == .on }
    @objc func gainRingsChanged(_ sender: Any?) { GainKnob.showsLevel = gainRings.state == .on }
    @objc private func restorePluginDefaults() {
        for key in Faceplate.preferenceKeys { UserDefaults.standard.removeObject(forKey: key) }
        NotificationCenter.default.post(name: Faceplate.wearChanged, object: nil)
        NotificationCenter.default.post(name: Faceplate.metersChanged, object: nil)
        refresh()
    }
    @objc private func resetDisplays() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("faceplate.display.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        main?.devicePanel.rebuildAll()
    }
    @objc private func openPlugins() { main?.showPlugins(nil) }
}
