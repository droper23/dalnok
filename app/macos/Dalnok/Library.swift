// View ▸ Library (⌥Y): plug-ins and projects at the window's left edge, in the spirit of Logic's Library and Ableton's
// browser. Places at the top (every plug-in, favourites, recently used, recent projects) and the owner's collections
// (+ makes one; right-click a plug-in to file it). Below: tabs for audio effects, instruments and MIDI effects, a
// search field (the browser's fuzzy search) and the categories of `PluginTaxonomy` with disclosure triangles.
// Drag a plug-in onto a track header, the device chain or the Inspector; double-click or Return inserts it on the
// selected track. The list is read from the same metadata as Audio ▸ Plug-ins (no plug-in code is loaded).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class LibraryPanel: SidePanelView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    typealias Plugin = PluginManagerController.Plugin
    static let defaultWidth: CGFloat = 256
    static let widthRange: ClosedRange<CGFloat> = 200...360
    static var storedWidth: CGFloat {
        get { let w = UserDefaults.standard.double(forKey: "libraryWidth"); return w > 0 ? min(max(w, widthRange.lowerBound), widthRange.upperBound) : defaultWidth }
        set { UserDefaults.standard.set(Double(newValue), forKey: "libraryWidth") }
    }
    enum Place: Equatable { case all, favorites, recent, projects, files, collection(String) }

    /// Inserts the plug-in at an add path on the selected track; returns an error message on failure.
    var onInsert: ((String) -> String?)?
    var onOpenProject: ((URL) -> Void)?
    /// A file from the Files place, taken by double-click or Return: imported (audio, foreign projects) or opened.
    var onTakeFile: ((URL) -> Void)?
    /// The saved project's folder, the Files place's first entry.
    var projectFolder: () -> URL? = { nil }
    let previewToggle = Theme.checkbox("Preview audio on click")
    private var searchToken = 0
    var onMessage: ((String) -> Void)?
    let resizeEdge = PanelResizeEdge(direction: 1)

    let search = NSSearchField()
    let tabs = RuledTabs(labels: ["Effects", "Instruments", "MIDI"], trackingMode: .selectOne, target: nil, action: nil)
    let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let placesStack = NSStackView()
    private let collectionsStack = NSStackView()
    private let addCollection = FocusableButton(title: "+", target: nil, action: nil)
    private let figure = LibraryFigure()
    private var figureHeight: NSLayoutConstraint!
    private(set) var placeButtons: [(Place, LibraryPlaceButton)] = []

    private(set) var all: [Plugin] = []
    private(set) var loaded = false
    private(set) var place: Place = .all
    private(set) var roots: [LibraryNode] = []
    private var expanded: Set<String> = []

    init() {
        super.init(edge: .right)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Library")
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func head(_ s: String) -> PanelHead { PanelHead(s) }

    private func build() {
        resizeEdge.currentWidth = { [weak self] in self?.bounds.width ?? LibraryPanel.defaultWidth }
        placesStack.orientation = .vertical
        placesStack.alignment = .leading
        placesStack.spacing = 1
        for (p, title, symbol) in [(Place.all, "Plug-ins", "puzzlepiece.extension"), (.favorites, "Favourites", "star"),
                                   (.recent, "Recently Used", "clock"), (.projects, "Projects", "folder"), (.files, "Files", "internaldrive")] {
            let b = LibraryPlaceButton(title: title, symbol: symbol)
            b.onPress = { [weak self] in self?.choose(p) }
            placesStack.addArrangedSubview(b)
            placeButtons.append((p, b))
        }
        collectionsStack.orientation = .vertical
        collectionsStack.alignment = .leading
        collectionsStack.spacing = 1
        addCollection.isBordered = false
        addCollection.font = Theme.ui(15, .medium)
        addCollection.contentTintColor = Theme.look.mixer == .instrument && !Theme.palette.light ? Theme.window : Theme.textDim
        addCollection.target = self
        addCollection.action = #selector(newCollection)
        addCollection.toolTip = "New collection (right-click a plug-in to add it)"
        addCollection.setAccessibilityLabel("New collection")
        let collectionsHead = head("Collections")
        collectionsHead.addSubview(addCollection)
        addCollection.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            addCollection.trailingAnchor.constraint(equalTo: collectionsHead.trailingAnchor, constant: -4),
            addCollection.centerYAnchor.constraint(equalTo: collectionsHead.centerYAnchor, constant: -1),
        ])

        tabs.target = self
        tabs.action = #selector(tabChosen)
        tabs.selectedSegment = 0
        tabs.segmentDistribution = .fillEqually
        tabs.controlSize = .small
        tabs.font = Theme.ui(11)
        tabs.setAccessibilityLabel("Plug-in kind")
        search.placeholderString = "Search plug-ins"
        search.delegate = self
        search.controlSize = .small
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search the library")
        if Theme.look.mixer == .instrument {
            // The serif's tall ascenders were clipped by the small field: a regular field with the text set to fit it.
            search.controlSize = .regular
            search.font = Theme.title(12, .regular)
        }

        let col = NSTableColumn(identifier: .init("item"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = Theme.look.mixer == .instrument ? 24 : 22
        outline.indentationPerLevel = 10
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(activateRow)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setAccessibilityLabel("Library items")
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false

        previewToggle.target = self
        previewToggle.action = #selector(previewToggled)
        previewToggle.state = LibraryPreview.enabled ? .on : .off
        previewToggle.font = Theme.look.mixer == .instrument ? Theme.title(12) : Theme.ui(11)
        previewToggle.toolTip = "Click an audio file to hear it"
        previewToggle.isHidden = true
        let top = NSStackView(views: [head("Places"), placesStack, collectionsHead, collectionsStack, head("Browser"), tabs, previewToggle, search])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 5
        top.setCustomSpacing(10, after: placesStack)
        top.setCustomSpacing(10, after: collectionsStack)
        top.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 4, right: 14)
        for v in [top, scroll, figure, resizeEdge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        for v in top.arrangedSubviews { v.widthAnchor.constraint(equalTo: top.widthAnchor, constant: -26).isActive = true }
        figureHeight = figure.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: topAnchor), top.leadingAnchor.constraint(equalTo: leadingAnchor), top.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: figure.topAnchor),
            figure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), figure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            figure.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6), figureHeight,
            resizeEdge.trailingAnchor.constraint(equalTo: trailingAnchor), resizeEdge.topAnchor.constraint(equalTo: topAnchor),
            resizeEdge.bottomAnchor.constraint(equalTo: bottomAnchor), resizeEdge.widthAnchor.constraint(equalToConstant: 5),
        ])
        rebuildCollections()
        syncPlaces()
    }

    override func layout() {
        super.layout()
        // The figure (Atelier: Fig. 1, the diapason) only where it leaves the list room to breathe.
        let h: CGFloat = Theme.look.mixer == .instrument && bounds.height > 620 ? 118 : 0
        if figureHeight.constant != h { figureHeight.constant = h; figure.isHidden = h == 0 }
    }

    /// Reads the plug-in list (metadata only) the first time the panel is shown, or again after a scan.
    func load(force: Bool = false) {
        guard force || !loaded else { return }
        loaded = true
        all = PluginManagerController.metadata()
        reload()
    }

    // MARK: Places and collections

    func choose(_ p: Place) {
        place = p
        syncPlaces()
        reload()
    }
    private func syncPlaces() {
        for (p, b) in placeButtons { b.isSelected = p == place }
        for case let b as LibraryPlaceButton in collectionsStack.arrangedSubviews { b.isSelected = place == .collection(b.label) }
        tabs.isEnabled = place != .projects
        tabs.isHidden = place == .files
        previewToggle.isHidden = place != .files
        if place != .files { LibraryPreview.shared.stop() }
        search.placeholderString = place == .projects ? "Search projects" : place == .files ? "Search opened folders" : "Search plug-ins"
    }
    func rebuildCollections() {
        collectionsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let names = PluginLibrary.collections.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names {
            let b = LibraryPlaceButton(title: name, symbol: "folder")
            b.count = PluginLibrary.collections[name]?.count ?? 0
            b.onPress = { [weak self] in self?.choose(.collection(name)) }
            b.menuProvider = { [weak self] in self?.collectionMenu(name) }
            collectionsStack.addArrangedSubview(b)
        }
        if names.isEmpty {
            let hint = NSTextField(labelWithString: "None yet: + makes one")
            hint.font = Theme.look.mixer == .instrument ? Theme.note(12) : Theme.ui(11)
            hint.textColor = Theme.textDim
            collectionsStack.addArrangedSubview(hint)
        }
        syncPlaces()
    }
    @objc func newCollection() {
        var n = 1
        while PluginLibrary.collections["Collection \(n)"] != nil { n += 1 }
        var c = PluginLibrary.collections; c["Collection \(n)"] = []; PluginLibrary.collections = c
        rebuildCollections()
        choose(.collection("Collection \(n)"))
        onMessage?("New collection: right-click a plug-in to add it, or right-click the collection to rename it")
    }
    private func collectionMenu(_ name: String) -> NSMenu {
        let m = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameCollection(_:)), keyEquivalent: "")
        rename.representedObject = name; rename.target = self
        let remove = NSMenuItem(title: "Delete Collection", action: #selector(deleteCollection(_:)), keyEquivalent: "")
        remove.representedObject = name; remove.target = self
        m.addItem(rename); m.addItem(remove)
        return m
    }
    @objc private func renameCollection(_ sender: NSMenuItem) {
        guard let old = sender.representedObject as? String, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Collection"
        let field = NSTextField(string: old)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            MainActor.assumeIsolated {
                let new = field.stringValue.trimmingCharacters(in: .whitespaces)
                guard r == .alertFirstButtonReturn, !new.isEmpty, new != old, PluginLibrary.collections[new] == nil else { return }
                var c = PluginLibrary.collections; c[new] = c.removeValue(forKey: old); PluginLibrary.collections = c
                if self?.place == .collection(old) { self?.place = .collection(new) }
                self?.rebuildCollections(); self?.reload()
            }
        }
    }
    @objc private func deleteCollection(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var c = PluginLibrary.collections; c[name] = nil; PluginLibrary.collections = c
        if place == .collection(name) { place = .all }
        rebuildCollections(); reload()
    }

    // MARK: Filtering

    var group: PluginGroup { [.effects, .instruments, .midi][max(0, tabs.selectedSegment)] }
    @objc private func tabChosen() { reload() }
    func controlTextDidChange(_ obj: Notification) { reload() }

    private func inPlace(_ p: Plugin) -> Bool {
        switch place {
        case .all, .projects, .files: return true
        case .favorites: return PluginLibrary.favorites.contains(p.addPath)
        case .recent: return PluginLibrary.recent.contains(p.addPath)
        case .collection(let name): return PluginLibrary.collections[name]?.contains(p.addPath) ?? false
        }
    }

    /// The plug-ins shown: the place, the tab and the search, best match first when searching.
    func filtered() -> [Plugin] {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        let scored: [(Plugin, Int)] = all.compactMap { p in
            guard p.group == group, inPlace(p), !p.failed, let s = PluginManagerController.score(p, q) else { return nil }
            return (p, s)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }.map(\.0)
    }

    func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces)
        if place == .files { return reloadFiles(q) }
        if place == .projects {
            let urls = NSDocumentController.shared.recentDocumentURLs
            roots = urls.filter { q.isEmpty || $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(q) }.map { LibraryNode(project: $0) }
        } else {
            let list = filtered()
            var byCategory: [String: [Plugin]] = [:]
            for p in list { byCategory[p.category, default: []].append(p) }
            roots = group.categories.compactMap { c in byCategory[c].map { LibraryNode(category: c, children: $0.map(LibraryNode.init(plugin:))) } }
        }
        outline.reloadData()
        let open = !q.isEmpty || place != .all // a search or a small place shows its plug-ins at once
        for n in roots where n.category != nil && (open || expanded.contains(n.category!)) { outline.expandItem(n) }
    }

    // MARK: Files

    private func reloadFiles(_ q: String) {
        searchToken += 1
        let places = LibraryFiles.places(projectFolder: projectFolder())
        if q.isEmpty {
            roots = places.map { LibraryNode(folder: $0.url, title: $0.title, removable: $0.removable) } + [LibraryNode(action: "Add Folder…")]
            outline.reloadData()
            return
        }
        // Searching: every place's tree, off the main thread; the latest search wins.
        // The project, the owner's folders, and the standard places opened in this session: walking Desktop or
        // Downloads unasked would raise macOS's privacy prompts (and Home is large).
        let token = searchToken
        let dirs = places.filter { $0.removable || $0.title == "Current Project" || openedPlaces.contains($0.url.standardizedFileURL) }.map(\.url)
        roots = []; outline.reloadData()
        Task.detached(priority: .userInitiated) {
            let found = LibraryFiles.search(q, in: dirs)
            await MainActor.run { [weak self] in
                guard let self, self.searchToken == token, self.place == .files else { return }
                self.roots = found.map { LibraryNode(file: $0) }
                self.outline.reloadData()
                self.onFilesSearched?(found.count)
            }
        }
    }
    /// Standard places unfolded in this session (searched too).
    private var openedPlaces = Set<URL>()
    /// After a file search lands (self-test).
    var onFilesSearched: ((Int) -> Void)?
    @objc private func previewToggled() {
        LibraryPreview.enabled = previewToggle.state == .on
        if !LibraryPreview.enabled { LibraryPreview.shared.stop() }
    }
    @objc func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            MainActor.assumeIsolated {
                guard r == .OK else { return }
                for u in panel.urls { self?.addFolder(u) }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
    func addFolder(_ url: URL) {
        var f = LibraryFiles.userFolders
        if !f.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { f.append(url); LibraryFiles.userFolders = f }
        if place != .files { choose(.files) } else { reload() }
    }
    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        LibraryFiles.userFolders = LibraryFiles.userFolders.filter { $0.standardizedFileURL != url.standardizedFileURL }
        reload()
    }
    @objc private func showInFinder(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard place == .files else { return }
        let n = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? LibraryNode : nil
        if let u = n?.file, LibraryFiles.kind(u) == .audio, LibraryPreview.enabled { LibraryPreview.shared.play(u) } else { LibraryPreview.shared.stop() }
    }

    // MARK: Outline

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? LibraryNode else { return roots.count }
        n.loadFolder()
        return n.children.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? LibraryNode)?.children[index] ?? roots[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? LibraryNode).map { $0.category != nil || $0.folder != nil } ?? false }
    func outlineViewItemDidExpand(_ n: Notification) {
        if let f = (n.userInfo?["NSObject"] as? LibraryNode)?.folder, roots.contains(where: { $0.folder == f }) { openedPlaces.insert(f.standardizedFileURL) }
        if let c = (n.userInfo?["NSObject"] as? LibraryNode)?.category, search.stringValue.isEmpty, place == .all { expanded.insert(c) }
    }
    func outlineViewItemDidCollapse(_ n: Notification) {
        if let c = (n.userInfo?["NSObject"] as? LibraryNode)?.category { expanded.remove(c) }
    }
    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let r = LibraryRowView()
        r.category = (item as? LibraryNode)?.category
        return r
    }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? LibraryNode else { return nil }
        let atelier = Theme.look.mixer == .instrument
        let cell = NSTableCellView()
        let t = NSTextField(labelWithString: n.title)
        t.lineBreakMode = .byTruncatingTail
        t.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(t)
        cell.textField = t
        var trailing: NSView = cell
        if let c = n.category {
            t.font = atelier ? Theme.title(13, .semibold) : Theme.ui(12, .semibold)
            // Long names ("Restoration / Noise Reduction") step down in size to fit rather than lose their end.
            let room = o.bounds.width - o.indentationPerLevel - 64
            if room > 60, let f = t.font {
                var size = f.pointSize
                while size > 10, (n.title as NSString).size(withAttributes: [.font: NSFont(descriptor: f.fontDescriptor, size: size) ?? f]).width > room { size -= 0.5 }
                t.font = NSFont(descriptor: f.fontDescriptor, size: size) ?? f
            }
            t.textColor = Theme.text
            let count = NSTextField(labelWithString: "\(n.children.count)")
            count.font = atelier ? Theme.note(12) : Theme.mono(10.5)
            count.textColor = atelier ? Atelier.gold : Theme.textDim
            count.translatesAutoresizingMaskIntoConstraints = false
            count.setAccessibilityElement(false)
            cell.addSubview(count)
            NSLayoutConstraint.activate([count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                         count.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            trailing = count
            cell.setAccessibilityLabel("\(c), \(n.children.count) plug-ins")
        } else {
            t.font = atelier ? Theme.title(12.5) : Theme.ui(12)
            t.textColor = Theme.text
            if let p = n.plugin {
                cell.toolTip = "\(p.name) · \(p.vendor) · \(p.format). Drag onto a track or the device chain; double-click inserts on the selected track."
                cell.setAccessibilityLabel("\(p.name), \(p.vendor)")
            } else if let u = n.project { cell.toolTip = u.path; cell.setAccessibilityLabel("Project \(n.title)")
            } else if let u = n.file {
                let kind = LibraryFiles.kind(u)
                cell.toolTip = u.path + (kind == .audio ? "\nClick to hear it; drag onto the arrangement or double-click to import." : "\nDouble-click to open it.")
                cell.setAccessibilityLabel("\(kind == .audio ? "Audio file" : "Project") \(n.title)")
                let badge = NSTextField(labelWithString: u.pathExtension.lowercased())
                badge.font = atelier ? Theme.note(11) : Theme.mono(10)
                badge.textColor = atelier ? Atelier.gold : Theme.textDim
                badge.translatesAutoresizingMaskIntoConstraints = false
                badge.setAccessibilityElement(false)
                cell.addSubview(badge)
                NSLayoutConstraint.activate([badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                                             badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                trailing = badge
            } else if let u = n.folder {
                t.font = atelier ? Theme.title(12.5, .semibold) : Theme.ui(12, .medium)
                cell.toolTip = u.path
                cell.setAccessibilityLabel("Folder \(n.title)")
            } else if n.action != nil {
                t.textColor = atelier ? Atelier.vermilion : Theme.accent
                cell.setAccessibilityLabel("Add a folder to the library")
            }
        }
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), t.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            t.trailingAnchor.constraint(lessThanOrEqualTo: trailing === cell ? cell.trailingAnchor : trailing.leadingAnchor, constant: -4),
        ])
        return cell
    }
    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        if let u = (item as? LibraryNode)?.file { return u as NSURL } // onto the arrangement: imported there
        guard let p = (item as? LibraryNode)?.plugin else { return nil }
        let it = NSPasteboardItem()
        it.setString(p.addPath, forType: .dalnokPlugin)
        return it
    }

    /// Double-click or Return: insert the plug-in on the selected track, open the project, or fold a category.
    @objc func activateRow() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0, let n = outline.item(atRow: row) as? LibraryNode else { return }
        if n.action != nil { return addFolder() }
        if let u = n.file { LibraryPreview.shared.stop(); onTakeFile?(u); return }
        if let p = n.plugin {
            if let err = onInsert?(p.addPath) { onMessage?("Couldn’t add \(p.name): \(err)") }
        } else if let u = n.project {
            onOpenProject?(u)
        } else if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { activateRow() } else { super.keyDown(with: event) }
    }
}

// MARK: Context menu (favourite, collections)

extension LibraryPanel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if place == .files {
            let n = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? LibraryNode : nil
            if let u = n?.file ?? n?.folder {
                let show = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
                show.representedObject = u; show.target = self; menu.addItem(show)
            }
            if n?.removable == true, let u = n?.folder {
                let rm = NSMenuItem(title: "Remove Folder from Library", action: #selector(removeFolder(_:)), keyEquivalent: "")
                rm.representedObject = u; rm.target = self; menu.addItem(rm)
            }
            let add = NSMenuItem(title: "Add Folder…", action: #selector(addFolder as () -> Void), keyEquivalent: "")
            add.target = self; menu.addItem(add)
            return
        }
        guard outline.clickedRow >= 0, let p = (outline.item(atRow: outline.clickedRow) as? LibraryNode)?.plugin else { return }
        let fav = PluginLibrary.favorites.contains(p.addPath)
        let f = NSMenuItem(title: fav ? "Remove from Favourites" : "Add to Favourites", action: #selector(toggleFavorite(_:)), keyEquivalent: "")
        f.representedObject = p.addPath; f.target = self
        menu.addItem(f)
        let insert = NSMenuItem(title: "Insert on Selected Track", action: #selector(activateRow), keyEquivalent: "")
        insert.target = self
        menu.addItem(insert)
        let names = PluginLibrary.collections.keys.sorted()
        if !names.isEmpty { menu.addItem(.separator()) }
        for name in names {
            let inIt = PluginLibrary.collections[name]?.contains(p.addPath) ?? false
            let it = NSMenuItem(title: inIt ? "Remove from \(name)" : "Add to \(name)", action: #selector(toggleCollection(_:)), keyEquivalent: "")
            it.representedObject = [name, p.addPath]; it.target = self
            menu.addItem(it)
        }
    }
    @objc func toggleFavorite(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        var f = PluginLibrary.favorites
        if f.contains(path) { f.remove(path) } else { f.insert(path) }
        PluginLibrary.favorites = f
        reload()
    }
    @objc func toggleCollection(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        addToCollection(pair[0], pair[1], toggle: true)
    }
    func addToCollection(_ name: String, _ path: String, toggle: Bool = false) {
        var c = PluginLibrary.collections
        var list = c[name] ?? []
        if let i = list.firstIndex(of: path) { if toggle { list.remove(at: i) } } else { list.append(path) }
        c[name] = list
        PluginLibrary.collections = c
        rebuildCollections()
        reload()
    }
}

/// An item in the outline: a category (with plug-ins), a plug-in, or a recent project.
final class LibraryNode {
    let title: String
    let category: String?
    let plugin: PluginManagerController.Plugin?
    let project: URL?
    /// Files place: a folder (read when first unfolded), a file, or the "Add Folder…" row.
    let folder: URL?, file: URL?, action: String?
    let removable: Bool
    private(set) var children: [LibraryNode]
    private var folderLoaded = false
    init(category: String, children: [LibraryNode]) { title = category; self.category = category; plugin = nil; project = nil; folder = nil; file = nil; action = nil; removable = false; self.children = children }
    init(plugin: PluginManagerController.Plugin) { title = plugin.name; category = nil; self.plugin = plugin; project = nil; folder = nil; file = nil; action = nil; removable = false; children = [] }
    init(project: URL) { title = project.deletingPathExtension().lastPathComponent; category = nil; plugin = nil; self.project = project; folder = nil; file = nil; action = nil; removable = false; children = [] }
    init(folder: URL, title: String? = nil, removable: Bool = false) {
        self.title = title ?? folder.lastPathComponent; category = nil; plugin = nil; project = nil; self.folder = folder; file = nil; action = nil; self.removable = removable; children = []
    }
    init(file: URL) { title = file.lastPathComponent; category = nil; plugin = nil; project = nil; folder = nil; self.file = file; action = nil; removable = false; children = [] }
    init(action: String) { title = action; category = nil; plugin = nil; project = nil; folder = nil; file = nil; self.action = action; removable = false; children = [] }
    /// Reads a folder's listing the first time it is unfolded.
    func loadFolder() {
        guard let folder, !folderLoaded else { return }
        folderLoaded = true
        children = LibraryFiles.list(folder).map { u in
            (try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } == true
                ? LibraryNode(folder: u) : LibraryNode(file: u)
        }
    }
}

/// A place or collection: symbol, title, count; selected with the theme's highlight.
@MainActor
final class LibraryPlaceButton: NSButton {
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled && isEnabled && !isHiddenOrHasHiddenAncestor }
    var onPress: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    var count: Int? { didSet { applyTitle() } }
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; applyTitle() }; setAccessibilityValue(isSelected ? "selected" : nil) } }
    let label: String
    init(title: String, symbol: String) {
        label = title
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        alignment = .left
        imagePosition = .imageLeading
        image = AtelierGlyphs.image(symbol, size: 15) ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        imageHugsTitle = true
        target = self
        action = #selector(pressed)
        setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Theme.look.mixer == .instrument ? 24 : 22).isActive = true
        applyTitle()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func applyTitle() {
        let atelier = Theme.look.mixer == .instrument
        let s = NSMutableAttributedString(string: "  " + label, attributes: [.font: atelier ? Theme.title(13.5, isSelected ? .semibold : .regular) : Theme.ui(12, isSelected ? .semibold : .regular),
                                                                            .foregroundColor: Theme.text])
        if let count, count > 0 {
            s.append(NSAttributedString(string: "  \(count)", attributes: [.font: atelier ? Theme.note(12) : Theme.mono(10.5), .foregroundColor: atelier ? Atelier.gold : Theme.textDim]))
        }
        attributedTitle = s
        invalidateIntrinsicContentSize()
        contentTintColor = isSelected && atelier ? Atelier.vermilion : Theme.textDim
    }
    @objc private func pressed() { onPress?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    /// Drawn here rather than by the button cell: the cell cached its title layout while the panel slid open from zero
    /// width, and names stayed blank until clicked (the owner's report). The symbol sits in a fixed column, so every
    /// name starts at the same x with the same gap.
    static let iconColumn: CGFloat = 18, textInset: CGFloat = 28
    override var intrinsicContentSize: NSSize {
        let t = NSMutableAttributedString(attributedString: attributedTitle)
        while t.string.hasPrefix(" ") { t.deleteCharacters(in: NSRange(location: 0, length: 1)) }
        return NSSize(width: ceil(Self.textInset + t.size().width + 8), height: super.intrinsicContentSize.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let atelier = Theme.look.mixer == .instrument
        if isSelected {
            if atelier, let ctx = NSGraphicsContext.current?.cgContext {
                Theme.laneHighlight.setFill(); bounds.fill()
                Atelier.rule(ctx, CGPoint(x: 0.5, y: 2), CGPoint(x: 0.5, y: bounds.height - 2), weight: Atelier.heavy, color: Atelier.vermilion)
            } else {
                Theme.ink(0.09).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: Theme.look.mixer == .glass ? 8 : 4, yRadius: Theme.look.mixer == .glass ? 8 : 4).fill()
            }
        }
        if let image {
            let tint = contentTintColor ?? Theme.textDim
            let s = image.size, r = NSRect(x: 4 + (Self.iconColumn - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
            let tinted = NSImage(size: s, flipped: false) { rect in
                image.draw(in: rect); tint.set(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let t = NSMutableAttributedString(attributedString: attributedTitle)
        let trimmed = t.string.prefix { $0 == " " }.count
        if trimmed > 0 { t.deleteCharacters(in: NSRange(location: 0, length: trimmed)) }
        let size = t.size()
        t.draw(with: NSRect(x: Self.textInset, y: (bounds.height - size.height) / 2, width: max(0, bounds.width - Self.textInset - 4), height: size.height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if window?.firstResponder === self, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(1); ctx.stroke(bounds.insetBy(dx: 1, dy: 1))
        }
    }
}

/// Outline rows: the theme's selection instead of the system's accent.
final class LibraryRowView: NSTableRowView {
    /// The category of a category row: its disclosure triangle is named after it (VoiceOver read an unnamed button).
    var category: String?
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let c = category, let b = subview as? NSButton, b.identifier == NSOutlineView.disclosureButtonIdentifier {
            b.setAccessibilityLabel("Show or hide \(c)")
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        MainActor.assumeIsolated {
            if Theme.look.mixer == .instrument, let ctx = NSGraphicsContext.current?.cgContext {
                Theme.laneHighlight.setFill(); bounds.fill()
                Atelier.rule(ctx, CGPoint(x: 0, y: bounds.maxY - 0.5), CGPoint(x: bounds.width, y: bounds.maxY - 0.5), weight: Atelier.hair, color: Atelier.vermilion)
            } else {
                Theme.ink(isEmphasized ? 0.14 : 0.08).setFill()
                NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4).fill()
            }
        }
    }
}

/// Atelier's figure at the foot of the library: Fig. 1, the diapason (tuning fork and sine). Decorative.
@MainActor
final class LibraryFigure: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityElement(false) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 40, let ctx = NSGraphicsContext.current?.cgContext else { return }
        Atelier.rule(ctx, CGPoint(x: 0, y: 0.5), CGPoint(x: bounds.width, y: 0.5), weight: Atelier.hair, color: Theme.ink(0.45))
        Atelier.diapason(ctx, bounds.insetBy(dx: 4, dy: 8), figure: "Fig. 1")
    }
}

/// Tabs drawn as ruled cells in Atelier: the choices set in the serif, the chosen one on a wash with a red rule under
/// it (the audit: the system's segmented control broke the page). Elsewhere the system's control. Behaviour unchanged.
@MainActor
final class RuledTabs: NSSegmentedControl {
    override func draw(_ dirtyRect: NSRect) {
        guard Theme.look.mixer == .instrument, let ctx = NSGraphicsContext.current?.cgContext else { return super.draw(dirtyRect) }
        let r = bounds.insetBy(dx: 0.5, dy: 1.5)
        let w = r.width / CGFloat(max(1, segmentCount))
        for i in 0..<segmentCount {
            let cell = CGRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: w, height: r.height)
            let on = selectedSegment == i
            if on { Theme.laneHighlight.setFill(); cell.fill() }
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.title(12, on ? .semibold : .regular), .foregroundColor: Theme.text]
            let label = (self.label(forSegment: i) ?? "") as NSString, s = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: cell.midX - s.width / 2, y: cell.midY - s.height / 2), withAttributes: attrs)
            if on {
                let y = isFlipped ? cell.maxY - 1.5 : cell.minY + 1.5
                Atelier.rule(ctx, CGPoint(x: cell.minX + 6, y: y), CGPoint(x: cell.maxX - 6, y: y), weight: Atelier.heavy, color: Atelier.vermilion)
            }
            if i > 0 { Atelier.rule(ctx, CGPoint(x: cell.minX, y: cell.minY + 3), CGPoint(x: cell.minX, y: cell.maxY - 3), weight: Atelier.hair, color: Theme.ink(0.5)) }
        }
        Atelier.box(ctx, r, weight: Atelier.hair, color: Theme.ink(0.7))
        if window?.firstResponder === self { ctx.setStrokeColor(NSColor.keyboardFocusIndicatorColor.cgColor); ctx.setLineWidth(1); ctx.stroke(r.insetBy(dx: -1.5, dy: -1.5)) }
    }
}
