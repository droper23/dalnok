// Command palette (⌘K): fuzzy search over every menu command, with its
// location and shortcut, so nothing is hidden. Executes through the real menu
// item (same validation and target as a click).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

struct PaletteEntry {
    let item: NSMenuItem?   // nil for informational entries (planned features)
    let title: String
    let path: String        // e.g. "Edit"
    let shortcut: String    // e.g. "⌘T"
    var aliases: [String] = []          // other DAWs' words for this command
    var run: (@MainActor () -> Void)? = nil
    var enabled: Bool { item?.isEnabled ?? (run != nil) }
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
                var aliases = Migration.aliases[it.title] ?? []
                aliases += Migration.concepts.filter { $0.dalnok == it.title }.map { "\($0.daw.title): \($0.term)" }
                out.append(PaletteEntry(item: it, title: it.title, path: path.joined(separator: " ▸ "),
                                        shortcut: shortcutString(it), aliases: aliases))
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

    /// Every menu command plus planned features from other DAWs (which open the Concept Guide).
    @MainActor
    static func allEntries(openGuide: @escaping @MainActor (Concept) -> Void) -> [PaletteEntry] {
        var out = entries()
        for c in Migration.concepts where c.status != .available {
            out.append(PaletteEntry(item: nil, title: "\(c.term) (\(c.daw.title))", path: c.status.label, shortcut: "",
                                    aliases: [c.dalnok], run: { openGuide(c) }))
        }
        return out
    }

    /// Rewrites other DAWs' nouns ("region", "item") to Dalnok's ("clip").
    static func normalize(_ query: String) -> String {
        query.lowercased().split(separator: " ").map { Migration.synonyms[String($0)] ?? String($0) }.joined(separator: " ")
    }

    /// Best score for an entry: its title, any alias, or its menu path.
    static func score(_ query: String, entry e: PaletteEntry) -> (score: Int, via: String?) {
        let q = normalize(query)
        var best = (max(score(q, e.title), score(query, e.title)) * 3, nil as String?)
        for a in e.aliases {
            let sc = max(score(q, a), score(query, a)) * 2
            if sc > best.0 { best = (sc, a) }
        }
        let p = score(q, e.path + " " + e.title)
        if p > best.0 { best = (p, nil) }
        return best
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
        // Strong preference for titles that start with the query ("sp" → "Split…"), then for the query
        // appearing as a whole word or word prefix ("tempo" → "Add Tempo Change"). Letters scattered across
        // unrelated words ("tempo" in "sysTEM sPeakers…") score low so real matches lead.
        let text = String(t), needle = String(q)
        if text.hasPrefix(needle) { score += 20 }
        if let r = text.range(of: needle) {
            score += 15
            if r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter { score += 15 }
        } else if q.count >= 3 {
            score /= 3
        }
        return score
    }
}

@MainActor
final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private(set) var panel: KeyPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private var all: [PaletteEntry] = []
    private(set) var results: [PaletteEntry] = []
    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                         styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.autorecalculatesKeyViewLoop = true // Tab follows the layout (keyboard-only use)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = Theme.appearance
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

    var onOpenGuide: (@MainActor (Concept) -> Void)?
    private(set) var matchedVia: [String?] = []

    private var generation = 0
    func show(over window: NSWindow) {
        generation += 1
        all = PaletteIndex.allEntries(openGuide: { [weak self] c in self?.onOpenGuide?(c) })
        field.stringValue = ""
        filter("")
        let f = window.frame
        let origin = NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - f.height * 0.18 - panel.frame.height)
        panel.setFrameOrigin(Motion.reduced ? origin : NSPoint(x: origin.x, y: origin.y + 8))
        panel.alphaValue = Motion.reduced ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        Motion.views(Motion.standard) {
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(origin)
        }
        // Spotlight-style: the panel also grows from 97 % as it drops in.
        if !Motion.reduced, let l = panel.contentView?.layer {
            Motion.centerAnchor(l)
            let grow = CASpringAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.97
            grow.toValue = 1
            grow.damping = 18
            grow.stiffness = 320
            grow.duration = grow.settlingDuration
            l.add(grow, forKey: "grow")
        }
    }

    func close() {
        guard panel.isVisible else { return }
        generation += 1
        if Motion.reduced { return panel.orderOut(nil) }
        let p = panel, closing = generation
        Motion.views(Motion.quick) { p.animator().alphaValue = 0 }
        // Order out after the fade unless the palette was reopened meanwhile.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.quick + 0.03) { [weak self] in
            guard let self, self.generation == closing else { return }
            p.orderOut(nil)
        }
    }

    func filter(_ query: String) {
        field.stringValue = query
        struct Hit { let entry: PaletteEntry; let score: Int; let order: Int; let via: String?
            var rank: Int { entry.item != nil && entry.enabled ? 1 : 0 } }
        var hits: [Hit] = []
        for (i, e) in all.enumerated() {
            let r = PaletteIndex.score(query, entry: e)
            if r.score > 0 && (!query.isEmpty || e.item != nil) { hits.append(Hit(entry: e, score: r.score, order: i, via: r.via)) }
        }
        // Enabled menu commands first, then relevance, then menu order.
        hits.sort { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            if a.score != b.score { return a.score > b.score }
            return a.order < b.order
        }
        // Once there are real matches, leave out weak scattered ones.
        if let top = hits.first?.score { hits = hits.filter { $0.score * 4 >= top } }
        results = hits.map { $0.entry }
        matchedVia = hits.map { $0.via }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { return }
        let entry = results[row]
        close()
        if entry.item == nil { entry.run?(); return }
        guard let menu = entry.item?.menu, let item = entry.item else { return }
        menu.update()
        guard item.isEnabled else { NSSound.beep(); return }
        menu.performActionForItem(at: menu.index(of: item))
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
        let via = row < matchedVia.count ? matchedVia[row] : nil
        let path = NSTextField(labelWithString: via.map { "“\($0)” · " + e.path } ?? e.path)
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
