// Audio ▸ Plug-ins…: every VST3, CLAP and Audio Unit plugin Dalnok can see, with its scan status.
// Opening the window reads metadata only. "Scan Plug-ins" loads each plugin in a separate dalnok-scan
// process (ADR-0009), so a plugin that crashes or hangs is listed as such instead of crashing Dalnok.
// Hosting (loading a plugin onto a track) is later Phase 4 work.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class PluginManagerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Plugin {
        let name, vendor, format, kind, version, status, error: String
        let cached: Bool
    }
    private(set) var all: [Plugin] = []
    private(set) var rows: [Plugin] = []
    let table = NSTableView()
    let search = NSSearchField()
    let summary = NSTextField(labelWithString: "")
    let scanButton = NSButton(title: "Scan Plug-ins", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    private(set) var scanning = false

    static var scannerPath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("dalnok-scan").path
    }
    static var cachePath: String {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Dalnok/PluginCache.json").path
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Plug-ins"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 320)
        super.init(window: window)

        for (id, title, width) in [("name", "Name", 230.0), ("kind", "Type", 90.0), ("format", "Format", 60.0),
                                   ("vendor", "Vendor", 170.0), ("status", "Status", 220.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        search.placeholderString = "Search plug-ins, vendors, types"
        search.delegate = self
        scanButton.target = self
        scanButton.action = #selector(scan(_:))
        scanButton.toolTip = "Loads each plug-in in a separate process to read what it is. A plug-in that crashes or hangs is listed, not fatal."
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        summary.font = Theme.ui(11)
        summary.textColor = Theme.textDim
        summary.lineBreakMode = .byTruncatingTail
        let bar = NSStackView(views: [search, spinner, scanButton])
        bar.spacing = 8
        let stack = NSStackView(views: [bar, scroll, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        for v in [bar, scroll] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.panel.cgColor
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        if all.isEmpty { loadMetadata() }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Fast: metadata and the AU registry only, merged with any cached scan results.
    func loadMetadata() {
        let n = dalnok_plugins_scan(nil, true, nil, 0)
        var buf = [CChar](repeating: 0, count: n + 1)
        dalnok_plugins_scan(nil, true, &buf, buf.count)
        all = Self.parse(cString(buf), cache: Self.cachedStatuses())
        apply()
    }

    @objc func scan(_ sender: Any?) {
        guard !scanning else { return }
        guard FileManager.default.isExecutableFile(atPath: Self.scannerPath) else {
            summary.stringValue = "The plug-in scanner (dalnok-scan) is missing next to the app."
            return
        }
        scanning = true
        scanButton.isEnabled = false
        spinner.startAnimation(nil)
        summary.stringValue = "Scanning… each plug-in loads in its own process (up to 10 s each)."
        let scanner = Self.scannerPath, cache = Self.cachePath
        Task.detached {
            var buf = [CChar](repeating: 0, count: 1 << 22)
            dalnok_plugins_validate(scanner, cache, nil, false, true, nil, 10_000, false, &buf, buf.count)
            let text = cString(buf)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.all = Self.parse(text, cache: [:])
                self.scanning = false
                self.scanButton.isEnabled = true
                self.spinner.stopAnimation(nil)
                self.apply()
            }
        }
    }

    static func parse(_ text: String, cache: [String: (String, String)]) -> [Plugin] {
        let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? []
        return list.map { p in
            let scan = p["scan"] as? [String: Any]
            let key = "\(p["format"] as? String ?? ""):\(p["path"] as? String ?? "")"
            let status = scan?["status"] as? String ?? cache[key]?.0 ?? "not scanned"
            return Plugin(name: p["name"] as? String ?? "?", vendor: p["vendor"] as? String ?? "", format: (p["format"] as? String ?? "").uppercased(),
                          kind: p["kind"] as? String ?? "unknown", version: p["version"] as? String ?? "", status: status,
                          error: scan?["error"] as? String ?? cache[key]?.1 ?? "", cached: scan?["cached"] as? Bool ?? false)
        }
    }

    /// Statuses from the last scan, so reopening the window shows them without rescanning.
    static func cachedStatuses() -> [String: (String, String)] {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = doc["entries"] as? [String: [String: Any]] else { return [:] }
        return entries.compactMapValues { e in
            (e["scan"] as? [String: Any]).map { ($0["status"] as? String ?? "?", $0["error"] as? String ?? "") }
        }
    }

    private func apply() {
        let q = search.stringValue.lowercased()
        rows = all.filter { q.isEmpty || "\($0.name) \($0.vendor) \($0.kind) \($0.format)".lowercased().contains(q) }
        if let sort = table.sortDescriptors.first, let key = sort.key {
            rows.sort { a, b in
                let x = value(a, key), y = value(b, key)
                return sort.ascending ? x.localizedStandardCompare(y) == .orderedAscending : x.localizedStandardCompare(y) == .orderedDescending
            }
        }
        table.reloadData()
        let count = { (s: String) in self.all.filter { $0.status == s }.count }
        let instruments = all.filter { $0.kind == "instrument" }.count, effects = all.filter { $0.kind == "effect" }.count
        var text = "\(all.count) plug-ins: \(instruments) instruments, \(effects) effects"
        let scanned = count("ok") + count("failed") + count("crashed") + count("timeout")
        if scanned > 0 { text += " · scanned: \(count("ok")) ok, \(count("failed")) failed, \(count("crashed")) crashed, \(count("timeout")) timed out" }
        else { text += " · not scanned yet (types come from metadata only)" }
        text += " · Loading plug-ins onto tracks is not available yet."
        summary.stringValue = text
    }
    private func value(_ p: Plugin, _ key: String) -> String {
        switch key { case "kind": p.kind; case "format": p.format; case "vendor": p.vendor; case "status": p.status; default: p.name }
    }

    func controlTextDidChange(_ obj: Notification) { apply() }
    func filter(_ text: String) { search.stringValue = text; apply() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { apply() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let p = rows[row]
        var color = Theme.text
        let text: String
        switch col?.identifier.rawValue {
        case "kind": text = p.kind; color = p.kind == "unknown" ? Theme.textFaint : Theme.textDim
        case "format": text = p.format; color = Theme.textDim
        case "vendor": text = p.vendor; color = Theme.textDim
        case "status":
            text = p.status + (p.error.isEmpty ? "" : " — \(p.error)")
            color = p.status == "ok" ? Theme.hex(0x5FB39B) : p.status == "not scanned" ? Theme.textFaint : Theme.clipRed
        default: text = p.name + (p.version.isEmpty ? "" : "  \(p.version)")
        }
        let l = NSTextField(labelWithString: text)
        l.textColor = color
        l.font = Theme.ui(12)
        l.lineBreakMode = .byTruncatingTail
        l.toolTip = text
        return l
    }
}
