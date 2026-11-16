// Command palette (⌘K): fuzzy search over every menu command, with its
// location and shortcut, so nothing is hidden. Executes through the real menu
// item (same validation and target as a click).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

struct PaletteEntry {
    let item: NSMenuItem
    let title: String
    let path: String     // e.g. "Edit"
    let shortcut: String // e.g. "⌘T"
    var enabled: Bool { item.isEnabled }
}

enum PaletteIndex {
    /// Collects every actionable leaf item, refreshing dynamic menus and validation first.
    @MainActor
    static func entries(in menu: NSMenu? = NSApp.mainMenu, path: [String] = []) -> [PaletteEntry] {
        guard let menu else { return [] }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        var out: [PaletteEntry] = []
        for it in menu.items where !it.isSeparatorItem && !it.isHidden {
            if let sub = it.submenu {
                let name = sub.title.isEmpty ? it.title : sub.title
                out += entries(in: sub, path: path + [name])
            } else if it.action != nil, it.action != #selector(MainWindowController.showCommandPalette(_:)) {
                out.append(PaletteEntry(item: it, title: it.title, path: path.joined(separator: " ▸ "),
                                        shortcut: shortcutString(it)))
            }
        }
        return out
    }

    static func shortcutString(_ it: NSMenuItem) -> String {
        guard !it.keyEquivalent.isEmpty else { return "" }
        let m = it.keyEquivalentModifierMask
        var s = ""
        if m.contains(.control) { s += "⌃" }
        if m.contains(.option) { s += "⌥" }
        if m.contains(.shift) { s += "⇧" }
        if m.contains(.command) { s += "⌘" }
        switch it.keyEquivalent {
        case " ": s += "Space"
        case "\r": s += "↩"
        case "\u{8}", "\u{7f}": s += "⌫"
        default: s += it.keyEquivalent.uppercased()
        }
        return s
    }

    /// Subsequence match with bonuses for word starts and consecutive runs. 0 = no match.
    static func score(_ query: String, _ text: String) -> Int {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 1 }
        let t = Array(text.lowercased())
        var qi = 0, score = 0, run = 0
        for (i, ch) in t.enumerated() where qi < q.count {
            if ch == q[qi] {
                let wordStart = i == 0 || !t[i - 1].isLetter
                score += 1 + (wordStart ? 8 : 0) + run * 4
                run += 1
                qi += 1
            } else {
                run = 0
            }
        }
        guard qi == q.count else { return 0 }
        // Strong preference for titles that start with the query ("sp" → "Split…").
        if String(t).hasPrefix(String(q)) { score += 20 }
        return score
    }
}

@MainActor
final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let panel: KeyPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private var all: [PaletteEntry] = []
    private(set) var results: [PaletteEntry] = []
    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                         styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.onResignKey = { [weak self] in self?.close() }

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = Theme.panelRaised.cgColor
        bg.layer?.cornerRadius = 12
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = Theme.separator.cgColor
        panel.contentView = bg

        field.placeholderString = "Search commands…"
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.text
        field.delegate = self
        field.setAccessibilityLabel("Search commands")

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 30
        table.backgroundColor = .clear
        table.style = .plain
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.action = #selector(runSelected)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true

        let sep = NSBox()
        sep.boxType = .separator
        for v in [field, sep, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: bg.topAnchor, constant: 14),
            field.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            sep.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -6),
        ])
    }

    func show(over window: NSWindow) {
        all = PaletteIndex.entries()
        field.stringValue = ""
        filter("")
        let f = window.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.18 - panel.frame.height))
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func filter(_ query: String) {
        field.stringValue = query
        results = all.enumerated()
            .map { (i, e) in (e, PaletteIndex.score(query, e.title) * 2 + PaletteIndex.score(query, e.path + " " + e.title), i) }
            .filter { $0.1 > 0 }
            .sorted { ($0.0.enabled ? 1 : 0, $0.1, -$0.2) > ($1.0.enabled ? 1 : 0, $1.1, -$1.2) }
            .map(\.0)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return }
        let entry = results[row]
        close()
        guard let menu = entry.item.menu else { return }
        menu.update()
        guard entry.item.isEnabled else { NSSound.beep(); return }
        menu.performActionForItem(at: menu.index(of: entry.item))
    }

    // MARK: Field

    func controlTextDidChange(_ obj: Notification) { filter(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): runSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !results.isEmpty else { return }
        let r = max(0, min(results.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = results[row]
        let cell = NSView()
        let title = NSTextField(labelWithString: e.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = e.enabled ? Theme.text : Theme.textDim.withAlphaComponent(0.5)
        let path = NSTextField(labelWithString: e.path)
        path.font = .systemFont(ofSize: 11)
        path.textColor = Theme.textDim
        let key = NSTextField(labelWithString: e.shortcut)
        key.font = Theme.mono(12, .medium)
        key.textColor = Theme.accent
        for v in [title, path, key] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            path.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            path.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            path.trailingAnchor.constraint(lessThanOrEqualTo: key.leadingAnchor, constant: -8),
            key.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            key.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel("\(e.title), \(e.path)\(e.shortcut.isEmpty ? "" : ", \(e.shortcut)")")
        return cell
    }
}

/// Borderless panels can't become key by default; the palette needs keyboard input.
final class KeyPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
