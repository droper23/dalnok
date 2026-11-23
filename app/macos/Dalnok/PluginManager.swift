// Audio ▸ Plug-ins… (⌥⌘P): the plug-in browser. Every VST3, CLAP and Audio Unit plug-in Dalnok can see, organised by
// what it does (Instruments, Audio Effects, MIDI Effects and their categories), with fuzzy search, format and vendor
// filters, favourites, recently and frequently used plug-ins, your own collections and tags, and scan status.
// Double-click (or Return) inserts on the selected track; drag a plug-in onto a track header or the device panel.
// Opening the window reads metadata only. "Scan Plug-ins" loads each plug-in in a separate dalnok-scan process
// (ADR-0009), so a plug-in that crashes or hangs is listed as such instead of crashing Dalnok.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

extension NSPasteboard.PasteboardType {
    /// A plug-in being dragged from the browser: its add path ("au:…", "dalnok:…", a .vst3 or .clap bundle).
    static let dalnokPlugin = NSPasteboard.PasteboardType("org.dalnok.plugin")
    /// A device-panel unit being dragged to a new place in its chain: its slot id.
    static let dalnokSlot = NSPasteboard.PasteboardType("org.dalnok.slot")
}

/// Favourites, recents, use counts, collections and tags: the owner's library data (user defaults, by add path).
enum PluginLibrary {
    private static var d: UserDefaults { .standard }
    static var favorites: Set<String> {
        get { Set(d.stringArray(forKey: "plugins.favorites") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "plugins.favorites") }
    }
    static var recent: [String] {
        get { d.stringArray(forKey: "plugins.recent") ?? [] }
        set { d.set(Array(newValue.prefix(20)), forKey: "plugins.recent") }
    }
    static var useCount: [String: Int] {
        get { d.dictionary(forKey: "plugins.useCount") as? [String: Int] ?? [:] }
        set { d.set(newValue, forKey: "plugins.useCount") }
    }
    static var collections: [String: [String]] {
        get { d.dictionary(forKey: "plugins.collections") as? [String: [String]] ?? [:] }
        set { d.set(newValue, forKey: "plugins.collections") }
    }
    static var tags: [String: [String]] {
        get { d.dictionary(forKey: "plugins.tags") as? [String: [String]] ?? [:] }
        set { d.set(newValue, forKey: "plugins.tags") }
    }
    static let keys = ["plugins.favorites", "plugins.recent", "plugins.useCount", "plugins.collections", "plugins.tags"]
    /// Called after a plug-in was inserted.
    static func used(_ path: String) {
        recent = [path] + recent.filter { $0 != path }
        var c = useCount; c[path, default: 0] += 1; useCount = c
    }
}

@MainActor
final class PluginManagerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Plugin {
        let name, vendor, format, kind, version, status, error, path: String
        let cached: Bool
        var categories: [String] = []
        var group: PluginGroup = .effects
        var category = "Other Effects"
        /// What Dalnok's engine is given to load it.
        var addPath: String { format == "AU" ? "au:" + path : format == "DALNOK" ? "dalnok:" + path : path }
        var failed: Bool { ["failed", "crashed", "timeout"].contains(status) }
    }
    /// Sidebar entries.
    enum Source: Equatable {
        case all, favorites, recent, mostUsed, collection(String), group(PluginGroup), category(PluginGroup, String), problems
    }
    private enum SideRow { case header(String), source(Source, String, Int) }

    private(set) var all: [Plugin] = []
    private(set) var rows: [Plugin] = []
    let table = NSTableView()
    let sidebar = NSTableView()
    let search = NSSearchField()
    let summary = NSTextField(labelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let tagsField = NSTextField()
    let formatControl = NSSegmentedControl(labels: ["All", "VST3", "AU", "CLAP"], trackingMode: .selectOne, target: nil, action: nil)
    let vendorPopup = NSPopUpButton()
    let sortPopup = NSPopUpButton()
    let collectionPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    let scanButton = NSButton(title: "Scan Plug-ins", target: nil, action: nil)
    let addButton = NSButton(title: "Insert on Track", target: nil, action: nil)
    /// Adds the plug-in at an add path to the selected track; returns an error message on failure.
    var onAdd: ((String) -> String?)?
    /// Brackets several adds into one undo step.
    var onBeginGroup: ((String) -> Void)?, onEndGroup: (() -> Void)?
    var selectedTrackName: (() -> String?)?
    let spinner = NSProgressIndicator()
    private(set) var scanning = false
    private var sideRows: [SideRow] = []
    private(set) var source: Source = .all

    static var scannerPath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent().appendingPathComponent("dalnok-scan").path
    }
    static var cachePath: String {
        if let dev = ProcessInfo.processInfo.environment["DALNOK_PLUGIN_CACHE"] { return dev } // developer checks
        return (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Dalnok/PluginCache.json").path
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.autorecalculatesKeyViewLoop = true // Tab follows the layout (keyboard-only use)
        window.title = "Plug-ins"
        window.appearance = Theme.appearance
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 420)
        super.init(window: window)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let window else { return }
        // Sidebar
        let sc = NSTableColumn(identifier: .init("side")); sc.width = 200
        sidebar.addTableColumn(sc)
        sidebar.headerView = nil
        sidebar.dataSource = self; sidebar.delegate = self
        sidebar.rowHeight = 22
        // The theme's own surface and selection, not the system's source list and accent (the audit: grey in Atelier).
        sidebar.style = .plain
        sidebar.backgroundColor = .clear
        sidebar.setAccessibilityLabel("Plug-in categories")
        sidebar.menu = sidebarMenu()
        let sideScroll = NSScrollView(); sideScroll.documentView = sidebar; sideScroll.hasVerticalScroller = true; sideScroll.drawsBackground = false
        sideScroll.widthAnchor.constraint(equalToConstant: 220).isActive = true
        // Main table
        for (id, title, width) in [("fav", "", 26.0), ("name", "Name", 220.0), ("category", "Category", 150.0), ("vendor", "Vendor", 130.0),
                                   ("format", "Format", 60.0), ("status", "Status", 120.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            if Theme.activeStyle == .atelier { // the header in the plate's face (the system header ignores a cell font)
                c.headerCell.attributedStringValue = NSAttributedString(string: title, attributes: [.font: Theme.ui(11, .semibold), .foregroundColor: Theme.textDim])
            }
            c.width = width
            if id != "fav" { c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
            table.addTableColumn(c)
        }
        table.dataSource = self; table.delegate = self
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.gridStyleMask = .solidHorizontalGridLineMask // ruled rows
        table.gridColor = Theme.ink(Theme.look.mixer == .instrument ? 0.16 : 0.06)
        table.rowHeight = 22
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle // every column fits: no clipped Status
        table.doubleAction = #selector(addSelected(_:))
        table.allowsMultipleSelection = true // several plug-ins inserted at once, in list order
        table.target = self
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setAccessibilityLabel("Plug-ins")
        table.menu = rowMenu()
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false

        search.placeholderString = "Search name, vendor, category, tag or capability (fuzzy)"
        search.delegate = self
        search.setAccessibilityLabel("Search plug-ins")
        formatControl.selectedSegment = 0
        formatControl.target = self; formatControl.action = #selector(filtersChanged)
        formatControl.setToolTip("Only this plug-in format", forSegment: 1)
        vendorPopup.target = self; vendorPopup.action = #selector(filtersChanged)
        vendorPopup.setAccessibilityLabel("Vendor")
        sortPopup.addItems(withTitles: ["Sort by Name", "Sort by Category", "Sort by Vendor", "Sort by Most Used"])
        sortPopup.target = self; sortPopup.action = #selector(filtersChanged)
        sortPopup.setAccessibilityLabel("Sort")
        collectionPopup.setAccessibilityLabel("Collections")
        scanButton.target = self; scanButton.action = #selector(scan(_:))
        scanButton.toolTip = "Loads each plug-in in a separate process to read what it is. A plug-in that crashes or hangs is listed, not fatal."
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let bar = NSStackView(views: [search, formatControl, vendorPopup, sortPopup, spinner, scanButton])
        bar.spacing = 8
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)

        summary.font = Theme.ui(11); summary.textColor = Theme.textDim
        summary.lineBreakMode = .byTruncatingTail
        detail.font = Theme.ui(11.5); detail.textColor = Theme.text
        tagsField.placeholderString = "Tags (comma separated)"
        tagsField.target = self; tagsField.action = #selector(tagsEdited)
        tagsField.toolTip = "Your own tags for this plug-in; search finds them"
        tagsField.setAccessibilityLabel("Tags")
        tagsField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        collectionPopup.addItem(withTitle: "Add to Collection")
        collectionPopup.target = self
        collectionPopup.toolTip = "Put the selected plug-in in one of your collections"
        addButton.target = self; addButton.action = #selector(addSelected(_:))
        addButton.keyEquivalent = "\r"
        addButton.isEnabled = false
        let actions = NSStackView(views: [detail, NSView(), tagsField, collectionPopup, addButton])
        actions.spacing = 8
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let right = NSStackView(views: [bar, scroll, actions, summary])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
        for v in [bar, scroll, actions, summary] { v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        let split = NSStackView(views: [sideScroll, right])
        split.spacing = 12
        split.alignment = .top
        sideScroll.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        right.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.panel.cgColor
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            split.topAnchor.constraint(equalTo: content.topAnchor, constant: 12), split.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content
        if Theme.activeStyle == .atelier { // the parchment, as in the main window (never takes clicks)
            let paper = PaperGrainView(frame: content.bounds)
            paper.autoresizingMask = [.width, .height]
            content.addSubview(paper)
        }
    }

    func show() {
        if all.isEmpty { loadMetadata() }
        if window?.isVisible != true { window?.center() }
        Atelier.unifyFonts(in: window?.contentView)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }

    /// Fast: metadata and the AU registry only, merged with any cached scan results (the browser and the Library).
    static func metadata() -> [Plugin] {
        let n = dalnok_plugins_scan(nil, true, nil, 0)
        var buf = [CChar](repeating: 0, count: n + 1)
        dalnok_plugins_scan(nil, true, &buf, buf.count)
        return parse(cString(buf), cache: cachedStatuses())
    }
    func loadMetadata() {
        all = Self.metadata()
        reloadSidebar()
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
                self.reloadSidebar()
                self.apply()
            }
        }
    }

    static func parse(_ text: String, cache: [String: (String, String)]) -> [Plugin] {
        let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? []
        let cachedCategories = self.cachedCategories()
        return list.map { p in
            let scan = p["scan"] as? [String: Any]
            let format = (p["format"] as? String ?? "").uppercased(), path = p["path"] as? String ?? ""
            let key = "\(p["format"] as? String ?? ""):\(path)"
            let status = scan?["status"] as? String ?? cache[key]?.0 ?? "not scanned"
            var plugin = Plugin(name: p["name"] as? String ?? "?", vendor: p["vendor"] as? String ?? "", format: format,
                                kind: p["kind"] as? String ?? "unknown", version: p["version"] as? String ?? "", status: status,
                                error: scan?["error"] as? String ?? cache[key]?.1 ?? "", path: path,
                                cached: scan?["cached"] as? Bool ?? false)
            plugin.categories = p["categories"] as? [String] ?? []
            if plugin.categories.isEmpty { plugin.categories = cachedCategories[key] ?? [] } // from an earlier out-of-process scan
            let c = PluginTaxonomy.classify(name: plugin.name, kind: plugin.kind, format: format, path: path, categories: plugin.categories)
            plugin.group = c.group
            plugin.category = c.category
            return plugin
        }
    }

    /// Statuses from the last scan, so reopening the window shows them without rescanning.
    /// Developer report (--plugin-report): every installed plug-in with what it declares and how Dalnok sorts it.
    static func writeReport(to out: String) -> Int {
        let n = dalnok_plugins_scan(nil, true, nil, 0)
        var buf = [CChar](repeating: 0, count: n + 1)
        dalnok_plugins_scan(nil, true, &buf, buf.count)
        let list = parse(cString(buf), cache: cachedStatuses())
        var lines = ["format\tname\tvendor\tkind\tdeclared\tgroup\tcategory\tdisplay"]
        for p in list.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            let display = p.group == .effects ? FaceplateDisplay.kind(name: p.name, path: p.path, instrument: false, declared: p.categories).rawValue : p.group == .instruments ? "scope" : "-"
            lines.append([p.format, p.name, p.vendor, p.kind, p.categories.joined(separator: "|"), p.group.rawValue, p.category, display].joined(separator: "\t"))
        }
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        return list.count
    }

    /// Categories an earlier scan read from inside each plug-in (VST3 subcategories, CLAP features), by "format:path".
    static func cachedCategories() -> [String: [String]] {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = doc["entries"] as? [String: [String: Any]] else { return [:] }
        return entries.compactMapValues { e in
            for c in ((e["result"] as? [String: Any])?["classes"] as? [[String: Any]]) ?? [] {
                if let f = c["features"] as? [String] { return f }
                if c["category"] as? String == "Audio Module Class" {
                    return (c["subCategories"] as? String ?? "").split(separator: "|").map(String.init)
                }
            }
            return nil
        }
    }

    static func cachedStatuses() -> [String: (String, String)] {
        guard let data = FileManager.default.contents(atPath: cachePath),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = doc["entries"] as? [String: [String: Any]] else { return [:] }
        return entries.compactMapValues { e in
            (e["scan"] as? [String: Any]).map { ($0["status"] as? String ?? "?", $0["error"] as? String ?? "") }
        }
    }

    // MARK: Sidebar

    private func count(_ s: Source) -> Int { all.filter { inSource($0, s) }.count }
    func inSource(_ p: Plugin, _ s: Source) -> Bool {
        switch s {
        case .all: true
        case .favorites: PluginLibrary.favorites.contains(p.addPath)
        case .recent: PluginLibrary.recent.contains(p.addPath)
        case .mostUsed: (PluginLibrary.useCount[p.addPath] ?? 0) > 0
        case .collection(let n): PluginLibrary.collections[n]?.contains(p.addPath) == true
        case .group(let g): p.group == g
        case .category(let g, let c): p.group == g && p.category == c
        case .problems: p.failed
        }
    }
    func reloadSidebar() {
        var r: [SideRow] = [.header("LIBRARY")]
        for (s, t) in [(Source.all, "All Plug-ins"), (.favorites, "Favourites"), (.recent, "Recently Used"), (.mostUsed, "Most Used")] {
            r.append(.source(s, t, count(s)))
        }
        let cols = PluginLibrary.collections.keys.sorted()
        r.append(.header("COLLECTIONS"))
        for c in cols { r.append(.source(.collection(c), c, count(.collection(c)))) }
        for g in PluginGroup.allCases {
            let n = count(.group(g))
            guard n > 0 else { continue }
            r.append(.header(g.rawValue.uppercased()))
            r.append(.source(.group(g), "All \(g.rawValue)", n))
            for c in g.categories { let k = count(.category(g, c)); if k > 0 { r.append(.source(.category(g, c), c, k)) } }
        }
        let bad = count(.problems)
        if bad > 0 { r.append(.header("PROBLEMS")); r.append(.source(.problems, "Failed Validation", bad)) }
        sideRows = r
        sidebar.reloadData()
        if let i = sideRows.firstIndex(where: { if case .source(let s, _, _) = $0 { return s == source }; return false }) {
            sidebar.selectRowIndexes([i], byExtendingSelection: false)
        }
        // Vendor filter and collections menu follow the library.
        let vendor = vendorPopup.titleOfSelectedItem
        vendorPopup.removeAllItems()
        vendorPopup.addItem(withTitle: "All Vendors")
        vendorPopup.addItems(withTitles: Set(all.map(\.vendor).filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        if let vendor, vendorPopup.itemTitles.contains(vendor) { vendorPopup.selectItem(withTitle: vendor) }
        collectionPopup.removeAllItems()
        collectionPopup.addItem(withTitle: "Add to Collection")
        for c in cols { let it = NSMenuItem(title: c, action: #selector(addToCollection(_:)), keyEquivalent: ""); it.target = self; collectionPopup.menu?.addItem(it) }
        let new = NSMenuItem(title: "New Collection…", action: #selector(newCollection), keyEquivalent: ""); new.target = self
        collectionPopup.menu?.addItem(.separator()); collectionPopup.menu?.addItem(new)
    }
    func select(source s: Source) {
        source = s
        if let i = sideRows.firstIndex(where: { if case .source(let x, _, _) = $0 { return x == s }; return false }) {
            sidebar.selectRowIndexes([i], byExtendingSelection: false)
        }
        apply()
    }
    private func sidebarMenu() -> NSMenu {
        let m = NSMenu()
        let new = NSMenuItem(title: "New Collection…", action: #selector(newCollection), keyEquivalent: ""); new.target = self
        let del = NSMenuItem(title: "Delete Collection", action: #selector(deleteCollection), keyEquivalent: ""); del.target = self
        m.addItem(new); m.addItem(del)
        return m
    }

    // MARK: Filtering, fuzzy search and sorting

    /// Fuzzy score: every word of the query must appear in the plug-in's text, as a substring (best) or, for the
    /// name, as letters in order ("vtl" finds "Vital"). Nil = no match.
    func score(_ p: Plugin, _ query: String) -> Int? { Self.score(p, query) }
    static func score(_ p: Plugin, _ query: String) -> Int? {
        let q = query.lowercased().split(separator: " ").map(String.init)
        guard !q.isEmpty else { return 0 }
        let name = p.name.lowercased()
        let tags = PluginLibrary.tags[p.addPath] ?? []
        let hay = ([p.name, p.vendor, p.category, p.group.rawValue, p.format, p.kind] + p.categories + tags).joined(separator: " ").lowercased()
        var total = 0
        for t in q {
            if name.hasPrefix(t) { total += 100 }
            else if name.contains(t) { total += 60 }
            else if hay.contains(t) { total += 30 }
            else if Self.subsequence(t, of: name) { total += 10 }
            else { return nil }
        }
        return total
    }
    static func subsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle { while true { guard let h = it.next() else { return false }; if h == c { break } } }
        return true
    }

    private func apply() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let format = formatControl.selectedSegment > 0 ? formatControl.label(forSegment: formatControl.selectedSegment) : nil
        let vendor = vendorPopup.indexOfSelectedItem > 0 ? vendorPopup.titleOfSelectedItem : nil
        var scored: [(Plugin, Int)] = all.compactMap { p in
            guard inSource(p, source), format.map({ p.format == $0 }) ?? true, vendor.map({ p.vendor == $0 }) ?? true,
                  let s = score(p, q) else { return nil }
            return (p, s)
        }
        let uses = PluginLibrary.useCount
        let byName: (Plugin, Plugin) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let sort = table.sortDescriptors.first, let key = sort.key {
            scored.sort { a, b in
                let x = value(a.0, key), y = value(b.0, key)
                let r = x.localizedStandardCompare(y)
                return r == .orderedSame ? byName(a.0, b.0) : (sort.ascending ? r == .orderedAscending : r == .orderedDescending)
            }
        } else if source == .recent {
            let order = PluginLibrary.recent
            scored.sort { (order.firstIndex(of: $0.0.addPath) ?? 99) < (order.firstIndex(of: $1.0.addPath) ?? 99) }
        } else {
            switch sortPopup.indexOfSelectedItem {
            case 1: scored.sort { ($0.0.group.rawValue, $0.0.category, $0.0.name.lowercased()) < ($1.0.group.rawValue, $1.0.category, $1.0.name.lowercased()) }
            case 2: scored.sort { ($0.0.vendor.lowercased(), $0.0.name.lowercased()) < ($1.0.vendor.lowercased(), $1.0.name.lowercased()) }
            case 3: scored.sort { (uses[$0.0.addPath] ?? 0, $1.0.name.lowercased()) > (uses[$1.0.addPath] ?? 0, $0.0.name.lowercased()) }
            default: scored.sort { byName($0.0, $1.0) }
            }
            if !q.isEmpty { scored.sort { $0.1 > $1.1 } } // stable: best matches first, then the chosen order
        }
        rows = scored.map(\.0)
        table.reloadData()
        let st = { (s: String) in self.all.filter { $0.status == s }.count }
        var text = "\(rows.count) of \(all.count) plug-ins"
        let scanned = st("ok") + st("failed") + st("crashed") + st("timeout")
        if scanned > 0 { text += " · scanned: \(st("ok")) ok, \(st("failed")) failed, \(st("crashed")) crashed, \(st("timeout")) timed out" }
        else { text += " · not scanned yet (categories come from metadata and names)" }
        text += " · VST3, Audio Unit and CLAP plug-ins can be added to tracks. Double-click or drag onto a track."
        summary.stringValue = text
        updateAddButton()
    }
    private func value(_ p: Plugin, _ key: String) -> String {
        switch key { case "category": "\(p.group.rawValue) \(p.category)"; case "format": p.format; case "vendor": p.vendor; case "status": p.status; default: p.name }
    }
    @objc func filtersChanged() { apply() }
    func controlTextDidChange(_ obj: Notification) { if (obj.object as? NSSearchField) === search { apply() } }
    func filter(_ text: String) { search.stringValue = text; apply() }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { apply() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === sidebar ? sideRows.count : rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard tableView === sidebar else { return false }
        if case .header = sideRows[row] { return true }; return false
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === sidebar else { return true }
        if case .header = sideRows[row] { return false }; return true
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { LibraryRowView() }
    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebar {
            switch sideRows[row] {
            case .header(let t):
                // Wrapped in a plain view: a group row restyles a bare label in the system face.
                let l = NSTextField(labelWithString: t); l.font = Theme.ui(10, .semibold); l.textColor = Theme.textDim
                let v = NSView(); l.translatesAutoresizingMaskIntoConstraints = false; v.addSubview(l)
                NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2), l.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
                v.setAccessibilityElement(false); l.setAccessibilityRole(.staticText)
                return v
            case .source(_, let t, let n):
                let l = NSTextField(labelWithString: "\(t)  \(n)")
                l.font = Theme.ui(12); l.textColor = Theme.text; l.lineBreakMode = .byTruncatingTail
                return l
            }
        }
        let p = rows[row]
        if col?.identifier.rawValue == "fav" {
            let fav = PluginLibrary.favorites.contains(p.addPath)
            let b = NSButton(image: NSImage(systemSymbolName: fav ? "star.fill" : "star", accessibilityDescription: fav ? "Favorite" : "Not a favorite")!,
                             target: self, action: #selector(favoriteButton(_:)))
            b.isBordered = false
            b.contentTintColor = fav ? Theme.hex(0xE8B64A) : Theme.textFaint
            b.tag = row
            b.toolTip = fav ? "Remove from Favourites" : "Add to Favourites"
            return b
        }
        var color = Theme.text
        let text: String
        switch col?.identifier.rawValue {
        case "category": text = p.category; color = Theme.textDim
        case "format": text = p.format; color = Theme.textDim
        case "vendor": text = p.vendor; color = Theme.textDim
        case "status":
            // Built-in plug-ins are part of Dalnok: nothing to scan (the audit: "Not scanned" read as a problem).
            let builtIn = p.format == "DALNOK"
            text = builtIn ? "Built in" : p.status == "ok" ? "Installed" : p.status == "not scanned" ? "Not scanned" : "Failed: \(p.status)" + (p.error.isEmpty ? "" : " — \(p.error)")
            color = builtIn || p.status == "ok" ? Theme.hex(0x5FB39B) : p.status == "not scanned" ? Theme.textFaint : Theme.clipRed
        default: text = p.name + (p.version.isEmpty ? "" : "  \(p.version)")
        }
        let l = NSTextField(labelWithString: text)
        l.textColor = color
        l.font = Theme.ui(12)
        l.lineBreakMode = .byTruncatingTail
        l.toolTip = text
        return l
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === sidebar {
            let r = sidebar.selectedRow
            if r >= 0, case .source(let s, _, _) = sideRows[r] { source = s; apply() }
            return
        }
        updateAddButton()
    }
    /// Drag a plug-in onto a track header or the device panel to insert it there.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === table, row < rows.count, !rows[row].failed else { return nil }
        let item = NSPasteboardItem()
        item.setString(rows[row].addPath, forType: .dalnokPlugin)
        item.setString(rows[row].name, forType: .string)
        return item
    }

    var selected: Plugin? { table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil }
    /// Every selected row, in list order.
    var selectedPlugins: [Plugin] { table.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0] } }
    func updateAddButton() {
        let row = selected
        let track = selectedTrackName?()
        let n = selectedPlugins.filter { !$0.failed }.count
        addButton.isEnabled = n > 0 && track != nil
        addButton.title = (n > 1 ? "Insert \(n) on " : "Insert on ") + (track ?? "Track")
        addButton.toolTip = row == nil ? "Select a plug-in" : row!.failed ? "\(row!.name) failed validation, so Dalnok won't load it"
            : track == nil ? "Select a track in the arrangement first" : "Add \(row!.name) to \(track!)"
        tagsField.isEnabled = row != nil
        collectionPopup.isEnabled = row != nil
        if let p = row {
            detail.stringValue = "\(p.name) · \(p.vendor.isEmpty ? "unknown vendor" : p.vendor) · \(p.format)\(p.version.isEmpty ? "" : " \(p.version)") · \(p.group.rawValue) ▸ \(p.category)"
                + (p.categories.isEmpty ? "" : " · declares: " + p.categories.joined(separator: ", "))
                + (sameElsewhere(p).isEmpty ? "" : " · also as " + sameElsewhere(p).joined(separator: ", "))
            tagsField.stringValue = (PluginLibrary.tags[p.addPath] ?? []).joined(separator: ", ")
        } else { detail.stringValue = ""; tagsField.stringValue = "" }
    }
    /// The same plug-in in other formats (duplicates are listed once per format).
    private func sameElsewhere(_ p: Plugin) -> [String] {
        all.filter { $0.name == p.name && $0.vendor == p.vendor && $0.format != p.format }.map(\.format)
    }
    @objc func addSelected(_ sender: Any?) {
        let many = selectedPlugins.filter { !$0.failed }
        if many.count > 1 { // one undo step for the lot (the add callback's own groups nest inside it)
            onBeginGroup?("Add \(many.count) Plug-ins")
            let errors = many.compactMap { p in onAdd?(p.addPath).map { "\(p.name): \($0)" } }
            onEndGroup?()
            many.forEach { PluginLibrary.used($0.addPath) }
            summary.stringValue = errors.isEmpty ? "Added \(many.count) plug-ins to \(selectedTrackName?() ?? "the track")."
                                                 : "Couldn’t add " + errors.joined(separator: "; ")
            if !errors.isEmpty { NSSound.beep() }
            reloadSidebar()
            return
        }
        guard let p = selected else { return }
        if p.failed { summary.stringValue = "\(p.name) failed validation (\(p.status)); rescan after updating it."; return }
        if let error = onAdd?(p.addPath) { summary.stringValue = "Couldn’t add \(p.name): \(error)"; NSSound.beep() }
        else {
            PluginLibrary.used(p.addPath)
            summary.stringValue = "Added \(p.name) to \(selectedTrackName?() ?? "the track")."
            reloadSidebar()
        }
    }
    /// Selects the first row whose name matches (tests and keyboard users).
    func selectRow(named name: String) {
        if let i = rows.firstIndex(where: { $0.name == name }) { table.selectRowIndexes([i], byExtendingSelection: false); updateAddButton() }
    }

    // MARK: Favourites, collections, tags

    @objc func favoriteButton(_ sender: NSButton) {
        guard sender.tag < rows.count else { return }
        toggleFavorite(rows[sender.tag])
    }
    func toggleFavorite(_ p: Plugin) {
        var f = PluginLibrary.favorites
        if f.contains(p.addPath) { f.remove(p.addPath) } else { f.insert(p.addPath) }
        PluginLibrary.favorites = f
        reloadSidebar(); apply()
    }
    @objc func tagsEdited() {
        guard let p = selected else { return }
        let tags = tagsField.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var t = PluginLibrary.tags
        t[p.addPath] = tags.isEmpty ? nil : tags
        PluginLibrary.tags = t
    }
    func addToCollection(_ name: String, _ p: Plugin) {
        var c = PluginLibrary.collections
        if !(c[name] ?? []).contains(p.addPath) { c[name, default: []].append(p.addPath) }
        PluginLibrary.collections = c
        reloadSidebar()
    }
    @objc func addToCollection(_ sender: NSMenuItem) { if let p = selected { addToCollection(sender.title, p); summary.stringValue = "Added \(p.name) to \(sender.title)." } }
    @objc func newCollection() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "New Collection"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = "Collection name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard r == .alertFirstButtonReturn, !name.isEmpty, let self else { return }
            var c = PluginLibrary.collections
            if c[name] == nil { c[name] = [] }
            PluginLibrary.collections = c
            if let p = self.selected { self.addToCollection(name, p) } else { self.reloadSidebar() }
        }
    }
    @objc func deleteCollection() {
        let r = sidebar.clickedRow >= 0 ? sidebar.clickedRow : sidebar.selectedRow
        guard r >= 0, case .source(.collection(let name), _, _) = sideRows[r] else { return NSSound.beep() }
        var c = PluginLibrary.collections; c[name] = nil; PluginLibrary.collections = c
        if source == .collection(name) { source = .all }
        reloadSidebar(); apply()
    }
    private func rowMenu() -> NSMenu {
        let m = NSMenu()
        for (t, s) in [("Insert on Selected Track", #selector(addSelected(_:))), ("Toggle Favorite", #selector(favoriteClicked)),
                       ("Remove from This Collection", #selector(removeFromCollection))] {
            let it = NSMenuItem(title: t, action: s, keyEquivalent: ""); it.target = self; m.addItem(it)
        }
        return m
    }
    @objc private func favoriteClicked() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        if r >= 0, r < rows.count { toggleFavorite(rows[r]) }
    }
    @objc private func removeFromCollection() {
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, r < rows.count, case .collection(let name) = source else { return NSSound.beep() }
        var c = PluginLibrary.collections; c[name]?.removeAll { $0 == rows[r].addPath }; PluginLibrary.collections = c
        reloadSidebar(); apply()
    }
}

extension NSPasteboard {
    /// Every plug-in on the pasteboard, in order (several rows of the Library or the Plug-ins window dragged at once).
    var dalnokPluginPaths: [String] { (pasteboardItems ?? []).compactMap { $0.string(forType: .dalnokPlugin) } }
}
