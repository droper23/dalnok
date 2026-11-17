// Dalnok ▸ Keyboard Shortcuts… (⌥⌘K): browse every command by category, search by name, description or key,
// record new shortcuts, resolve conflicts, switch presets, and save, import or export shortcut sets.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers

/// Records one key combination. While it has focus, key presses (⌘ combinations included) come here and run
/// nothing; Escape cancels; clicking elsewhere cancels.
@MainActor
final class ShortcutRecorder: NSView {
    var onRecord: ((KeyCombo) -> Void)?
    var onCancel: (() -> Void)?
    private let label = NSTextField(labelWithString: "Type a shortcut… (Esc cancels)")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        label.font = Theme.ui(11, .medium)
        label.textColor = Theme.text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityRole(.textField)
        setAccessibilityLabel("Shortcut recorder")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { ShortcutRegistry.capturing = true; return true }
    override func resignFirstResponder() -> Bool {
        if ShortcutRegistry.capturing { ShortcutRegistry.capturing = false; onCancel?() }
        return true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection(KeyCombo.relevant).isEmpty {
            ShortcutRegistry.capturing = false; onCancel?(); return
        }
        guard let k = KeyCombo(event: event) else { NSSound.beep(); return }
        ShortcutRegistry.capturing = false
        onRecord?(k)
    }
}

@MainActor
final class ShortcutEditorController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Row { case header(String), action(ShortcutAction) }
    private let registry = ShortcutRegistry.shared
    let presetPopup = NSPopUpButton()
    let categoryPopup = NSPopUpButton()
    let search = NSSearchField()
    let table = NSTableView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let conflictsLabel = NSTextField(labelWithString: "")
    // Detail pane
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailText = NSTextField(wrappingLabelWithString: "")
    private let keysStack = NSStackView()
    let addButton = NSButton(title: "Add Shortcut", target: nil, action: nil)
    let restoreButton = NSButton(title: "Restore Default", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let resolveStack = NSStackView()
    let recorder = ShortcutRecorder()
    private var rows: [Row] = []
    private(set) var selected: ShortcutAction?
    /// A recorded key waiting for the owner to resolve a conflict.
    private(set) var pending: KeyCombo?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Keyboard Shortcuts"
        w.minSize = NSSize(width: 640, height: 460)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        reloadPresets()
        reload()
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func button(_ title: String, _ sel: Selector, help: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.toolTip = help
        return b
    }

    private func build() {
        guard let content = window?.contentView else { return }
        presetPopup.target = self; presetPopup.action = #selector(presetChosen)
        presetPopup.toolTip = "Start from another DAW's layout. Choosing a preset replaces your changes (you're asked first)."
        presetPopup.setAccessibilityLabel("Shortcut preset")
        let top = NSStackView(views: [NSTextField(labelWithString: "Preset:"), presetPopup, NSView(),
                                      button("Save As…", #selector(saveAs), help: "Save these shortcuts as a named set"),
                                      button("Import…", #selector(importSet), help: "Load a shortcut set file"),
                                      button("Export…", #selector(exportSet), help: "Save these shortcuts to a file"),
                                      button("Restore All Defaults", #selector(restoreAll), help: "Undo every change you made to this preset")])
        top.spacing = 8
        note.font = Theme.ui(10.5); note.textColor = .secondaryLabelColor
        search.placeholderString = "Search commands, descriptions or keys (e.g. split, ⌘T, cmd+shift+z)"
        search.delegate = self
        search.setAccessibilityLabel("Search shortcuts")
        categoryPopup.target = self; categoryPopup.action = #selector(filterChanged)
        categoryPopup.setAccessibilityLabel("Category")
        conflictsLabel.font = Theme.ui(10.5, .medium); conflictsLabel.textColor = .systemOrange
        let filters = NSStackView(views: [search, categoryPopup, conflictsLabel])
        filters.spacing = 8
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        for (id, title, width) in [("command", "Command", 340.0), ("keys", "Shortcut", 170.0), ("context", "Where", 110.0)] {
            let c = NSTableColumn(identifier: .init(id)); c.title = title; c.width = width; table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.doubleAction = #selector(recordReplacing)
        table.target = self
        table.setAccessibilityLabel("Commands")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder

        detailTitle.font = Theme.ui(13, .semibold)
        detailText.font = Theme.ui(11); detailText.textColor = .secondaryLabelColor
        keysStack.spacing = 6
        addButton.target = self; addButton.action = #selector(recordAdding); addButton.controlSize = .small; addButton.bezelStyle = .rounded
        addButton.toolTip = "Record another shortcut for this command"
        restoreButton.target = self; restoreButton.action = #selector(restoreOne); restoreButton.controlSize = .small; restoreButton.bezelStyle = .rounded
        restoreButton.toolTip = "Go back to this preset's shortcut for the command"
        recorder.isHidden = true
        recorder.widthAnchor.constraint(equalToConstant: 220).isActive = true
        recorder.heightAnchor.constraint(equalToConstant: 22).isActive = true
        recorder.onRecord = { [weak self] k in self?.recorded(k) }
        recorder.onCancel = { [weak self] in self?.endRecording() }
        message.font = Theme.ui(11); message.textColor = .labelColor
        resolveStack.spacing = 6
        let keysRow = NSStackView(views: [NSTextField(labelWithString: "Shortcuts:"), keysStack, recorder, addButton, restoreButton])
        keysRow.spacing = 8
        let detail = NSStackView(views: [detailTitle, detailText, keysRow, message, resolveStack])
        detail.orientation = .vertical; detail.alignment = .leading; detail.spacing = 6

        let root = NSStackView(views: [top, note, filters, scroll, detail])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            top.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            note.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            detail.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            message.widthAnchor.constraint(equalTo: detail.widthAnchor),
            detailText.widthAnchor.constraint(equalTo: detail.widthAnchor),
            detail.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        showDetail(nil)
    }

    // MARK: Data

    private func reloadPresets() {
        presetPopup.removeAllItems()
        for p in ShortcutPreset.all { presetPopup.addItem(withTitle: p.title); presetPopup.lastItem?.representedObject = p.id }
        let users = registry.userPresets.keys.sorted()
        if !users.isEmpty { presetPopup.menu?.addItem(.separator()) }
        for u in users { presetPopup.addItem(withTitle: u); presetPopup.lastItem?.representedObject = "user:" + u }
        if let i = presetPopup.itemArray.firstIndex(where: { $0.representedObject as? String == registry.presetId }) { presetPopup.selectItem(at: i) }
        let p = registry.currentPreset
        var text = p.note
        if !p.unavailable.isEmpty { text += "  Not in Dalnok yet: " + p.unavailable.joined(separator: ", ") + "." }
        if !registry.overrides.isEmpty { text += "  You changed \(registry.overrides.count) command\(registry.overrides.count == 1 ? "" : "s")." }
        note.stringValue = text
        let cats = ["All Categories", "Conflicts Only", "Changed by You"] + Self.categoryOrder.filter { c in registry.actions.contains { $0.category == c } }
            + Set(registry.actions.map(\.category)).subtracting(Self.categoryOrder).sorted()
        let current = categoryPopup.titleOfSelectedItem
        categoryPopup.removeAllItems(); categoryPopup.addItems(withTitles: cats)
        if let current, cats.contains(current) { categoryPopup.selectItem(withTitle: current) }
    }
    static let categoryOrder = ["Transport", "Recording", "Tracks", "Editing", "Clips", "MIDI Editing", "Timeline and Navigation",
                                "Mixer", "Plug-ins", "Automation", "Project", "Views and Windows", "Application", "Help"]

    /// Commands matching the search (name, description, keywords, category, or the key itself).
    func matches(_ a: ShortcutAction, _ q: String) -> Bool {
        if q.isEmpty { return true }
        let ql = q.lowercased()
        if let k = KeyCombo(parsing: q), q.count > 1 || !q.first!.isLetter, registry.keys(a.id).contains(k) { return true }
        let keyText = registry.keys(a.id).map { $0.description.lowercased() + " " + $0.storage }.joined(separator: " ")
        let hay = ([a.title, a.detail, a.category, a.menuPath, keyText] + a.keywords).joined(separator: " ").lowercased()
        return ql.split(separator: " ").allSatisfy { hay.contains($0) }
    }

    func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let filter = categoryPopup.titleOfSelectedItem ?? "All Categories"
        let conflicted = Set(registry.allConflicts().flatMap { $0.1.map(\.id) })
        conflictsLabel.stringValue = conflicted.isEmpty ? "" : "\(registry.allConflicts().count) conflicting key\(registry.allConflicts().count == 1 ? "" : "s")"
        var list = registry.actions.filter { matches($0, q) }
        switch filter {
        case "All Categories": break
        case "Conflicts Only": list = list.filter { conflicted.contains($0.id) }
        case "Changed by You": list = list.filter { registry.overrides[$0.id] != nil }
        default: list = list.filter { $0.category == filter }
        }
        let order = Self.categoryOrder
        let grouped = Dictionary(grouping: list, by: \.category)
        let cats = grouped.keys.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }
        rows = cats.flatMap { c in [Row.header(c)] + grouped[c]!.map(Row.action) }
        conflictIds = conflicted
        table.reloadData()
        if let sel = selected, let i = rows.firstIndex(where: { if case .action(let a) = $0 { return a.id == sel.id }; return false }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        showDetail(selected)
    }
    private var conflictIds = Set<String>()
    var visibleActionIds: [String] { rows.compactMap { if case .action(let a) = $0 { return a.id }; return nil } }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .header = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .header = rows[row] { return false }; return true }
    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        switch rows[row] {
        case .header(let c):
            guard col == nil || col?.identifier.rawValue == "command" else { return nil }
            cell.stringValue = c.uppercased(); cell.font = Theme.ui(10.5, .semibold); cell.textColor = .secondaryLabelColor
        case .action(let a):
            switch col?.identifier.rawValue {
            case "command":
                cell.stringValue = a.title
                cell.toolTip = a.detail.isEmpty ? a.menuPath : a.detail
                if registry.overrides[a.id] != nil { cell.font = Theme.ui(12, .semibold) }
            case "keys":
                let d = registry.display(a.id)
                cell.stringValue = d.isEmpty ? "—" : d
                cell.font = Theme.mono(11.5)
                if conflictIds.contains(a.id) { cell.textColor = .systemOrange; cell.toolTip = "Another command uses this key in the same place." }
                else if d.isEmpty { cell.textColor = .tertiaryLabelColor }
            default:
                cell.stringValue = a.context.title; cell.textColor = .secondaryLabelColor
            }
        }
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        guard r >= 0, case .action(let a) = rows[r] else { return }
        select(a)
    }
    func select(_ a: ShortcutAction?) {
        selected = a
        pending = nil
        endRecording()
        showDetail(a)
    }

    private func showDetail(_ a: ShortcutAction?) {
        keysStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resolveStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let a else {
            detailTitle.stringValue = "Select a command"
            detailText.stringValue = "Double-click a command to give it a new shortcut. The same key can do different things in the arrangement and the piano roll."
            addButton.isEnabled = false; restoreButton.isEnabled = false
            if pending == nil { message.stringValue = "" }
            return
        }
        detailTitle.stringValue = a.title
        detailText.stringValue = [a.detail, "Menu: \(a.menuPath)", "Works: \(a.context.title)"].filter { !$0.isEmpty }.joined(separator: "   ·   ")
        for k in registry.keys(a.id) {
            let b = NSButton(title: "\(k.description)  ×", target: self, action: #selector(removeKey(_:)))
            b.bezelStyle = .recessed; b.controlSize = .small; b.font = Theme.mono(11)
            b.identifier = .init(k.storage)
            b.toolTip = "Remove \(k.description) from \(a.title)"
            b.setAccessibilityLabel("Remove shortcut \(k.description)")
            keysStack.addArrangedSubview(b)
        }
        if registry.keys(a.id).isEmpty {
            let none = NSTextField(labelWithString: "None"); none.textColor = .tertiaryLabelColor; keysStack.addArrangedSubview(none)
        }
        addButton.isEnabled = true
        restoreButton.isEnabled = registry.overrides[a.id] != nil
        if pending == nil {
            let clash = registry.keys(a.id).flatMap { k in registry.conflicts(for: k, in: a.context, excluding: a.id).map { "\(k.description) is also \($0.title)" } }
            let shadow = registry.keys(a.id).flatMap { k in registry.shadows(for: k, of: a).map { "\(k.description) does \($0.title) in \($0.context.title)" } }
            message.stringValue = !clash.isEmpty ? "Conflict: " + clash.joined(separator: "; ") + "."
                : shadow.isEmpty ? "" : "Shared by context: " + shadow.joined(separator: "; ") + "."
            message.textColor = clash.isEmpty ? .secondaryLabelColor : .systemOrange
        }
    }

    // MARK: Recording and conflicts

    private var replacing = false
    @objc func recordAdding() { beginRecording(replacing: false) }
    @objc func recordReplacing() {
        guard table.clickedRow >= 0 || selected != nil else { return }
        if table.clickedRow >= 0, case .action(let a) = rows[table.clickedRow] { select(a) }
        beginRecording(replacing: true)
    }
    func beginRecording(replacing: Bool) {
        guard selected != nil else { return }
        self.replacing = replacing
        pending = nil
        resolveStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        message.stringValue = replacing ? "Type the new shortcut; it replaces the current ones." : "Type the extra shortcut."
        message.textColor = .labelColor
        recorder.isHidden = false
        addButton.isHidden = true
        window?.makeFirstResponder(recorder)
    }
    private func endRecording() {
        recorder.isHidden = true
        addButton.isHidden = false
        ShortcutRegistry.capturing = false
    }

    /// A key was typed into the recorder: assign it, or ask how to resolve a conflict.
    func recorded(_ k: KeyCombo) {
        endRecording()
        window?.makeFirstResponder(table)
        guard let a = selected else { return }
        if k.mods.isEmpty, ["delete", "tab", "escape"].contains(k.key) == false, k.key.count == 1, a.context == .global {
            // Single letters fire everywhere except while typing in a text field; allowed, but say so.
            message.stringValue = "\(k.description) without a modifier works whenever you aren't typing in a text field."
        }
        let others = registry.conflicts(for: k, in: a.context, excluding: a.id)
        if let sys = ShortcutRegistry.reservedBySystem(k) {
            message.stringValue = "\(k.description) belongs to macOS (\(sys)); it will probably never reach Dalnok. Assigned anyway."
            message.textColor = .systemOrange
        }
        if others.isEmpty { assign(k); return }
        pending = k
        message.stringValue = "\(k.description) is already used by \(others.map { "\($0.title) (\($0.context.title))" }.joined(separator: ", "))."
        message.textColor = .systemOrange
        resolveStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let take = NSButton(title: "Use It Here (remove it from \(others.count == 1 ? others[0].title : "the others"))", target: self, action: #selector(resolveTake))
        let both = NSButton(title: "Keep Both", target: self, action: #selector(resolveBoth))
        both.toolTip = "Both commands keep the key; the most specific one for where you are runs."
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(resolveCancel))
        for b in [take, both, cancel] { b.bezelStyle = .rounded; b.controlSize = .small; resolveStack.addArrangedSubview(b) }
    }
    private func assign(_ k: KeyCombo) {
        guard let a = selected else { return }
        if replacing { registry.setKeys(a.id, [k]) } else { registry.add(k, to: a.id) }
        let note = message.stringValue
        pending = nil
        reloadPresets(); reload()
        if note.contains("macOS") || note.contains("text field") { message.stringValue = note }
        else { message.stringValue = "\(a.title): \(registry.display(a.id))"; message.textColor = .labelColor }
    }
    @objc func resolveTake() {
        guard let k = pending, let a = selected else { return }
        if replacing { registry.setKeys(a.id, []) }
        registry.reassign(k, to: a.id)
        pending = nil
        reloadPresets(); reload()
    }
    @objc func resolveBoth() { guard let k = pending else { return }; assign(k) }
    @objc func resolveCancel() { pending = nil; message.stringValue = ""; showDetail(selected) }

    @objc func removeKey(_ sender: NSButton) {
        guard let a = selected, let id = sender.identifier?.rawValue, let k = KeyCombo(parsing: id) else { return }
        registry.remove(k, from: a.id)
        reloadPresets(); reload()
    }
    @objc func restoreOne() { guard let a = selected else { return }; registry.restore(a.id); reloadPresets(); reload() }

    // MARK: Presets and files

    /// Choosing a preset discards your changes, so it asks first when there are any.
    @objc func presetChosen() {
        guard let id = presetPopup.selectedItem?.representedObject as? String, id != registry.presetId || !registry.overrides.isEmpty else { return }
        let apply = { [weak self] in self?.registry.selectPreset(id); self?.reloadPresets(); self?.reload() }
        guard !registry.overrides.isEmpty, let window, !SelfTest.running else { return apply() }
        let alert = NSAlert()
        alert.messageText = "Switch to \(presetPopup.titleOfSelectedItem ?? "this preset")?"
        alert.informativeText = "Your \(registry.overrides.count) changed shortcut\(registry.overrides.count == 1 ? "" : "s") will be replaced. Use Save As… first to keep them."
        alert.addButton(withTitle: "Switch"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { apply() } else { self?.reloadPresets() }
        }
    }
    @objc func restoreAll() {
        guard !registry.overrides.isEmpty else { return }
        let apply = { [weak self] in self?.registry.restoreAll(); self?.reloadPresets(); self?.reload() }
        guard let window, !SelfTest.running else { return apply() }
        let alert = NSAlert()
        alert.messageText = "Restore all of \(registry.currentPreset.title)'s shortcuts?"
        alert.informativeText = "This removes your \(registry.overrides.count) change\(registry.overrides.count == 1 ? "" : "s")."
        alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { apply() } }
    }
    @objc func saveAs() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Shortcut Set"
        alert.informativeText = "It appears in the Preset menu."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = "My Shortcuts"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard r == .alertFirstButtonReturn, !name.isEmpty else { return }
            self?.registry.saveUserPreset(name); self?.reloadPresets(); self?.reload()
        }
    }
    @objc func exportSet() {
        guard let window, let data = registry.exportData() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Dalnok Shortcuts.json"
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
    @objc func importSet() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            do {
                let res = try self.registry.importData(Data(contentsOf: url))
                self.reloadPresets(); self.reload()
                self.message.stringValue = "Imported \(res.applied) command\(res.applied == 1 ? "" : "s")" + (res.skipped > 0 ? "; skipped \(res.skipped) Dalnok doesn't have." : ".")
            } catch { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc func filterChanged() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func windowWillClose(_ notification: Notification) { endRecording() }
    override func cancelOperation(_ sender: Any?) {
        if !recorder.isHidden { endRecording(); return }
        window?.performClose(nil)
    }
}
