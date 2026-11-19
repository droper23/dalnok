// One window per hosted plug-in: its own editor (when it has one) and a generic, searchable parameter
// panel that works for every plug-in. Edits in either reach the audio thread through the engine.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class PluginWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let engine: Engine
    let slot: Int32
    let tabs = NSSegmentedControl(labels: ["Editor", "Parameters"], trackingMode: .selectOne, target: nil, action: nil)
    let editorHost = NSView()
    let table = NSTableView()
    let search = NSSearchField()
    let note = NSTextField(labelWithString: "")
    private let panel = NSView()
    private(set) var editorOpen = false
    private(set) var parameters: [DalnokPluginParameter] = []
    private(set) var rows: [DalnokPluginParameter] = []
    private var pluginIndex: [UInt32: Int32] = [:] // parameter id -> the plugin's own index (hidden ones are skipped)
    private var refreshTimer: Timer?
    var onClose: (() -> Void)?
    /// Shows the selected parameter's automation lane in the arrangement (slot, parameter id, name).
    var onAutomate: ((Int32, UInt32, String) -> Void)?
    let automateButton = NSButton(title: "Automate in Arrangement", target: nil, action: nil)

    /// Isolated plug-ins (ADR-0015): the editor is a window of the plug-in's own process, shown beside this one, which
    /// keeps the parameter panel. The Editor tab brings that window forward.
    let isolated: Bool
    private(set) var hostEditorOpen = false
    private let editorTitle: String

    init(engine: Engine, slot: Int32, title: String, isolated: Bool = false) {
        self.engine = engine
        self.slot = slot
        self.isolated = isolated
        self.editorTitle = title
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.panel
        super.init(window: window)
        window.delegate = self

        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        for (id, title, width) in [("name", "Parameter", 220.0), ("value", "Value", 260.0), ("display", "", 110.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        search.placeholderString = "Search parameters"
        search.delegate = self
        note.font = Theme.ui(11)
        note.textColor = Theme.textDim
        automateButton.bezelStyle = .rounded
        automateButton.controlSize = .small
        automateButton.target = self
        automateButton.action = #selector(automateSelected)
        automateButton.toolTip = "Draw this parameter's automation over the track (View ▸ Show Automation)"
        let top = NSStackView(views: [search, automateButton])
        top.spacing = 8
        let stack = NSStackView(views: [top, scroll, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for v in [top, scroll] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor), stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.topAnchor), stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])

        let content = NSView()
        let bar = NSView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(tabs)
        for v in [bar, editorHost, panel] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 36),
            tabs.centerXAnchor.constraint(equalTo: bar.centerXAnchor), tabs.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            editorHost.topAnchor.constraint(equalTo: bar.bottomAnchor), editorHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editorHost.trailingAnchor.constraint(equalTo: content.trailingAnchor), editorHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            panel.topAnchor.constraint(equalTo: bar.bottomAnchor), panel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor), panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        loadParameters()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if isolated { return showIsolated() }
        let wantsEditor = dalnok_plugin_has_editor(engine.handle, slot) && openEditor()
        tabs.selectedSegment = wantsEditor ? 0 : 1
        tabs.setEnabled(editorOpen, forSegment: 0)
        tabChanged(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshValues() }
        }
    }

    private func showIsolated() {
        tabs.selectedSegment = 1
        tabChanged(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        if dalnok_plugin_has_editor(engine.handle, slot) { showHostEditor() } else { tabs.setEnabled(false, forSegment: 0) }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshValues() }
        }
    }

    /// Opens (or brings forward) an isolated plug-in's editor window, beside this window.
    func showHostEditor() {
        guard isolated, let frame = window?.frame else { return }
        var err = [CChar](repeating: 0, count: 256)
        // Its top-left at this window's top-right, or centered if that would leave the screen.
        let screen = window?.screen?.visibleFrame ?? .infinite
        let x = frame.maxX + 12 < screen.maxX - 200 ? Double(frame.maxX + 12) : .nan
        hostEditorOpen = dalnok_plugin_show_editor_window(engine.handle, slot, editorTitle, x, x.isNaN ? .nan : Double(frame.maxY), &err, 256) == DALNOK_OK
        note.stringValue = hostEditorOpen ? "The editor runs in the plug-in's own process, in its own window."
                                          : "No editor: \(cString(err)). Use the parameters below."
        tabs.setEnabled(hostEditorOpen, forSegment: 0)
    }

    /// The editor asks for a size: resize the window around it.
    private static let resize: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void = { ctx, w, h in
        guard let ctx else { return }
        let me = Unmanaged<PluginWindowController>.fromOpaque(ctx).takeUnretainedValue()
        MainActor.assumeIsolated { me.fitEditor(width: CGFloat(w), height: CGFloat(h)) }
    }

    private func openEditor() -> Bool {
        var w: Int32 = 0, h: Int32 = 0
        var err = [CChar](repeating: 0, count: 256)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let parent = Unmanaged.passUnretained(editorHost).toOpaque()
        guard dalnok_plugin_open_editor(engine.handle, slot, parent, &w, &h, Self.resize, ctx, &err, 256) == DALNOK_OK else {
            note.stringValue = "No editor: \(cString(err)). Use the parameters below."
            return false
        }
        editorOpen = true
        fitEditor(width: CGFloat(w), height: CGFloat(h))
        // Some editors (Apple's Audio Units among them) settle their size after joining the window and don't
        // report it: re-fit to the editor view's own frame once it has had a chance to lay out.
        // Resizable editors (most Audio Units) fill the window and follow it; fixed-size ones are measured once.
        editorHost.clipsToBounds = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editorOpen, let v = self.editorHost.subviews.first else { return }
            if v.autoresizingMask.contains(.width) && v.autoresizingMask.contains(.height) {
                v.frame = self.editorHost.bounds
            } else if abs(v.frame.width - self.editorHost.bounds.width) > 1 || abs(v.frame.height - self.editorHost.bounds.height) > 1 {
                self.fitEditor(width: v.frame.width, height: v.frame.height)
                v.setFrameOrigin(.zero)
            }
        }
        return true
    }

    private func fitEditor(width: CGFloat, height: CGFloat) {
        guard let window, width > 0, height > 0 else { return }
        let frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: max(width, 360), height: height + 36))
        var f = window.frame
        f.origin.y += f.height - frame.height
        f.size = frame.size
        window.setFrame(f, display: true)
    }

    @objc func tabChanged(_ sender: Any?) {
        if isolated { // the editor is the host's window: the tab brings it forward and this window keeps the parameters
            if tabs.selectedSegment == 0 && sender != nil { showHostEditor() }
            tabs.selectedSegment = 1
            editorHost.isHidden = true
            panel.isHidden = false
            refreshValues()
            return
        }
        let showEditor = tabs.selectedSegment == 0 && editorOpen
        editorHost.isHidden = !showEditor
        panel.isHidden = showEditor
        if !showEditor { refreshValues() }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if editorOpen || hostEditorOpen { dalnok_plugin_close_editor(engine.handle, slot) }
        editorOpen = false
        hostEditorOpen = false
        onClose?()
    }

    // MARK: Generic parameter panel

    func loadParameters() {
        pluginIndex = [:]
        parameters = (0..<dalnok_plugin_parameter_count(engine.handle, slot)).compactMap { i in
            var p = DalnokPluginParameter()
            guard dalnok_plugin_parameter(engine.handle, slot, i, &p) == DALNOK_OK, !p.hidden else { return nil }
            pluginIndex[p.id] = i
            return p
        }
        applyFilter()
    }
    func applyFilter() {
        let q = search.stringValue.lowercased()
        rows = parameters.filter { q.isEmpty || fixedString($0.title).lowercased().contains(q) }
        table.reloadData()
        note.stringValue = "\(parameters.count) parameters" + (q.isEmpty ? "" : " · \(rows.count) shown") +
            " · Values go to the audio engine on the next block."
    }
    func filter(_ text: String) { search.stringValue = text; applyFilter() }
    @objc func automateSelected() {
        let i = table.selectedRow >= 0 ? table.selectedRow : (rows.count == 1 ? 0 : -1)
        guard rows.indices.contains(i) else { NSSound.beep(); note.stringValue = "Select a parameter to automate."; return }
        onAutomate?(slot, rows[i].id, fixedString(rows[i].title))
    }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }

    func current(_ id: UInt32) -> DalnokPluginParameter? {
        var p = DalnokPluginParameter()
        guard let i = pluginIndex[id], dalnok_plugin_parameter(engine.handle, slot, i, &p) == DALNOK_OK else { return nil }
        return p
    }

    /// Picks up changes made in the plug-in's own editor.
    func refreshValues() {
        guard !panel.isHidden else { return }
        var changed = IndexSet()
        for (i, old) in rows.enumerated() {
            if let p = current(old.id), p.value != old.value { rows[i] = p; changed.insert(i) }
        }
        if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: [1, 2]) }
    }

    /// Sets a parameter by id (the panel's sliders and tests use this).
    func set(_ id: UInt32, _ value: Double) {
        dalnok_plugin_set_parameter(engine.handle, slot, id, value)
        if let i = rows.firstIndex(where: { $0.id == id }), let p = current(id) {
            rows[i] = p
            table.reloadData(forRowIndexes: [i], columnIndexes: [1, 2])
        }
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard sender.tag >= 0, sender.tag < rows.count else { return }
        set(rows[sender.tag].id, sender.doubleValue)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let p = rows[row]
        switch col?.identifier.rawValue {
        case "value":
            let s = NSSlider(value: p.value, minValue: 0, maxValue: 1, target: self, action: #selector(sliderMoved(_:)))
            s.tag = row
            s.isEnabled = !p.read_only
            s.isContinuous = true
            if p.step_count > 0 { s.numberOfTickMarks = Int(min(p.step_count + 1, 25)); s.allowsTickMarkValuesOnly = true }
            s.setAccessibilityLabel(fixedString(p.title))
            return s
        case "display":
            let l = NSTextField(labelWithString: fixedString(p.display) + (fixedString(p.units).isEmpty || fixedString(p.display).contains(fixedString(p.units)) ? "" : " \(fixedString(p.units))"))
            l.font = Theme.mono(11)
            l.textColor = Theme.textDim
            return l
        default:
            let l = NSTextField(labelWithString: fixedString(p.title))
            l.font = Theme.ui(12)
            l.textColor = p.read_only ? Theme.textFaint : Theme.text
            l.lineBreakMode = .byTruncatingTail
            return l
        }
    }
}
