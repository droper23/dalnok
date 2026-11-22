// Onboarding and migration UI: welcome ("Coming from…"), project finder with
// import preview, import report, and the concept guide.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

// MARK: - Shared bits

@MainActor
private func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = Theme.text) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: s)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.isSelectable = false
    return l
}

/// Solid themed background so controls render correctly (including off-screen captures).
@MainActor
private func backed(_ content: NSView) -> NSView {
    let bg = NSView()
    bg.wantsLayer = true
    bg.layer?.backgroundColor = Theme.panel.cgColor
    bg.appearance = Theme.appearance
    content.translatesAutoresizingMaskIntoConstraints = false
    bg.addSubview(content)
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: bg.topAnchor), content.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        content.leadingAnchor.constraint(equalTo: bg.leadingAnchor), content.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
    ])
    return bg
}

/// Shows a secondary window (Welcome, Settings, Concept Guide) centered on the screen Dalnok's main window is on.
/// It is laid out first, and centered again on the next turn of the run loop if its size settled after showing, so it
/// never stays at its creation origin (the screen's bottom-left corner) or drifts there as its content grows.
@MainActor
func showCentered(_ w: NSWindow) {
    func place() {
        let screen = (NSApp.delegate as? AppDelegate)?.main?.window?.screen ?? NSScreen.main ?? w.screen
        guard let vf = screen?.visibleFrame else { w.center(); return }
        let f = w.frame
        w.setFrameOrigin(NSPoint(x: (vf.midX - f.width / 2).rounded(), y: (vf.midY - f.height / 2).rounded()))
    }
    w.contentView?.layoutSubtreeIfNeeded()
    place()
    // The window can still change size as it comes on screen or as text settles (fonts with other metrics): keep it
    // centred while it does.
    let token = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { _ in
        MainActor.assumeIsolated { place() }
    }
    w.makeKeyAndOrderFront(nil)
    place()
    DispatchQueue.main.async { place() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NotificationCenter.default.removeObserver(token) }
}

@MainActor
private func panelWindow(_ title: String, size: NSSize) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                     backing: .buffered, defer: false)
    w.autorecalculatesKeyViewLoop = true // Tab follows the layout (keyboard-only use)
    w.title = title
    w.appearance = Theme.appearance
    w.backgroundColor = Theme.panel
    w.isReleasedWhenClosed = false
    return w
}

/// A project file found on disk that Dalnok can import.
struct FoundProject {
    let url: URL
    let daw: SourceDAW
    let modified: Date
}

enum ProjectScanner {
    /// Spotlight search for Logic/Ableton/REAPER projects in the user's home folder.
    /// Skips app bundles, Ableton "Backup" copies, and Logic backup alternatives.
    static func scan() async -> [FoundProject] {
        await Task.detached(priority: .userInitiated) { () -> [FoundProject] in
            let query = "kMDItemFSName == '*.logicx' || kMDItemFSName == '*.als' || kMDItemFSName == '*.rpp'"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = ["-onlyin", NSHomeDirectory(), query]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let paths = String(decoding: out, as: UTF8.self).split(separator: "\n").map(String.init)
            var found: [FoundProject] = []
            for path in paths {
                if path.contains("/Backup/") || path.contains("/Library/") || path.contains(".Trash") || path.contains("Project File Backups") { continue }
                let url = URL(fileURLWithPath: path)
                guard let daw = SourceDAW.allCases.first(where: { $0.fileExtensions.contains(url.pathExtension.lowercased()) }) else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                found.append(FoundProject(url: url, daw: daw, modified: date))
            }
            return found.sorted { $0.modified > $1.modified }
        }.value
    }
}

/// Parses the engine's import report JSON.
struct ImportReport {
    let app: String, version: String
    let tracks: Int, clips: Int, media: Int, missing: Int
    let skipped: [(key: String, count: Int)]
    let notes: [String]
    let unavailablePlugins: [String]

    init?(json: String, unavailablePlugins: [String] = []) {
        guard let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        app = d["app"] as? String ?? ""
        version = d["version"] as? String ?? ""
        let imp = d["imported"] as? [String: Any] ?? [:]
        tracks = imp["tracks"] as? Int ?? 0
        clips = imp["clips"] as? Int ?? 0
        media = imp["media"] as? Int ?? 0
        missing = imp["missingMedia"] as? Int ?? 0
        skipped = (d["skipped"] as? [String: Any] ?? [:]).compactMap { k, v in (v as? Int).map { (k, $0) } }.sorted { $0.1 > $1.1 }
        notes = d["notes"] as? [String] ?? []
        self.unavailablePlugins = unavailablePlugins
    }

    var summary: String {
        "\(tracks) track\(tracks == 1 ? "" : "s"), \(clips) clip\(clips == 1 ? "" : "s"), \(media) audio file\(media == 1 ? "" : "s")"
            + (missing > 0 ? " (\(missing) missing)" : "")
    }

    /// Grouped plain-language lines for "Not imported yet".
    var notImported: [String] {
        var groups: [String: (count: Int, detail: String)] = [:]
        for (k, n) in skipped {
            let e = Migration.explain(k)
            groups[e.title, default: (0, e.detail)].count += n
        }
        return groups.sorted { $0.value.count > $1.value.count }.map { "\($0.value.count) × \($0.key) — \($0.value.detail)" }
    }
}

// MARK: - Import report sheet

@MainActor
final class ImportReportController {
    static func present(_ report: ImportReport, source: URL, over window: NSWindow, onGuide: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Imported “\(source.deletingPathExtension().lastPathComponent)” from \(report.app)"
        var text = "Brought over: \(report.summary).\n"
        if !report.unavailablePlugins.isEmpty {
            text += "\nPlug-ins that could not be loaded:\n" + report.unavailablePlugins.prefix(8).map { "• " + $0 }.joined(separator: "\n") + "\n"
            if report.unavailablePlugins.count > 8 { text += "• And \(report.unavailablePlugins.count - 8) more; see the device panel.\n" }
        }
        let not = report.notImported
        if !not.isEmpty { text += "\nNot imported yet:\n" + not.prefix(8).map { "• " + $0 }.joined(separator: "\n") + "\n" }
        if !report.notes.isEmpty { text += "\n" + report.notes.prefix(3).joined(separator: "\n") }
        text += "\n\nThe import is a new, unsaved Dalnok project — your original isn't changed."
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Concept Guide…")
        alert.beginSheetModal(for: window) { resp in
            if resp == .alertSecondButtonReturn { MainActor.assumeIsolated { onGuide() } }
        }
    }
}

// MARK: - Concept guide

@MainActor
final class ConceptGuideController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = panelWindow("Concept Guide", size: NSSize(width: 760, height: 560))
    private let picker = NSSegmentedControl(labels: SourceDAW.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = NSTableView()
    private(set) var rows: [Concept] = []

    override init() {
        super.init()
        let intro = label("How your old DAW's ideas map to Dalnok. Planned items show when they arrive.", color: Theme.textDim)
        picker.target = self
        picker.action = #selector(reload)
        picker.selectedSegment = SourceDAW.allCases.firstIndex(of: SourceDAW.preferred ?? .logic) ?? 0
        search.placeholderString = "Search terms"
        search.delegate = self
        for (id, title, w) in [("term", "Their term", 190.0), ("dalnok", "In Dalnok", 270.0), ("status", "Status", 210.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            c.minWidth = 120
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [intro, picker, search, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        search.widthAnchor.constraint(equalToConstant: 260).isActive = true
        window.contentView = backed(stack)
        reload()
    }

    func show(daw: SourceDAW? = nil, query: String = "") {
        if let daw, let i = SourceDAW.allCases.firstIndex(of: daw) { picker.selectedSegment = i }
        search.stringValue = query
        reload()
        showCentered(window)
    }

    @objc func reload() {
        let daw = SourceDAW.allCases[max(0, picker.selectedSegment)]
        let q = search.stringValue.lowercased()
        rows = Migration.concepts.filter { $0.daw == daw && (q.isEmpty || "\($0.term) \($0.dalnok) \($0.note)".lowercased().contains(q)) }
        table.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    private static let cellFont = Theme.ui(12.5)
    private func cellText(_ c: Concept, _ column: String) -> String {
        switch column {
        case "term": c.term
        case "dalnok": c.dalnok + (c.note.isEmpty ? "" : "  ·  \(c.note)")
        default: c.status.label
        }
    }
    /// Long entries wrap: each row is as tall as its tallest cell.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let c = rows[row]
        let tallest = tableView.tableColumns.map { col -> CGFloat in
            (cellText(c, col.identifier.rawValue) as NSString).boundingRect(
                with: NSSize(width: max(40, col.width - 10), height: 400), options: [.usesLineFragmentOrigin],
                attributes: [.font: Self.cellFont]).height
        }.max() ?? 16
        return ceil(tallest) + 9
    }
    func tableViewColumnDidResize(_ notification: Notification) {
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let c = rows[row]
        let text: String
        var color = Theme.text
        switch col?.identifier.rawValue {
        case "term": text = c.term
        case "dalnok": text = c.dalnok + (c.note.isEmpty ? "" : "  ·  \(c.note)")
        default:
            text = c.status.label
            color = c.status == .available ? Theme.hex(0x5FB39B) : { if case .partial = c.status { return Theme.accent } else { return Theme.textDim } }()
        }
        let l = NSTextField(wrappingLabelWithString: text)
        l.textColor = color
        l.font = Self.cellFont
        l.toolTip = text
        l.preferredMaxLayoutWidth = max(40, (col?.width ?? 200) - 10)
        l.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSView()
        cell.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            l.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            l.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            l.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
        ])
        return cell
    }
}

// MARK: - Welcome / migration assistant

@MainActor
final class WelcomeController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window = panelWindow("Welcome to Dalnok", size: NSSize(width: 760, height: 560))
    private let main: MainWindowController
    private let content = NSStackView()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private(set) var projects: [FoundProject] = []
    private var shown: [FoundProject] = []
    private var filter: SourceDAW?
    private let dateFormat: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; return f }()

    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingDone") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingDone") }
    }

    init(main: MainWindowController) {
        self.main = main
        super.init()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        window.contentView = backed(content)
    }

    func show() {
        showChooseDAW()
        showCentered(window)
    }

    private func reset(_ views: [NSView]) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach { content.addArrangedSubview($0) }
        content.layoutSubtreeIfNeeded()
        window.recalculateKeyViewLoop() // each step's buttons get a fresh Tab order
    }

    // Step 1: where are you coming from?
    func showChooseDAW() {
        let title = label("Where are you coming from?", size: 22, weight: .semibold)
        let sub = label("Dalnok will use familiar shortcuts and words, and help you bring your projects over. You can change this any time in Help ▸ Migration Assistant.", color: Theme.textDim)
        var buttons: [NSView] = []
        for daw in SourceDAW.allCases {
            let b = NSButton(title: "  " + daw.title, image: NSImage(systemSymbolName: daw.symbol, accessibilityDescription: nil)!,
                             target: self, action: #selector(pickDAW(_:)))
            b.identifier = .init(daw.rawValue)
            b.bezelStyle = .regularSquare
            b.font = .systemFont(ofSize: 15, weight: .medium)
            b.imagePosition = .imageLeading
            b.widthAnchor.constraint(equalToConstant: 220).isActive = true
            b.heightAnchor.constraint(equalToConstant: 56).isActive = true
            buttons.append(b)
        }
        let other = NSButton(title: "Something else / start fresh", target: self, action: #selector(pickDAW(_:)))
        other.identifier = .init("none")
        other.isBordered = false // a quiet secondary choice under the three big ones
        other.attributedTitle = NSAttributedString(string: "Something else, or start fresh →",
                                                   attributes: [.font: Theme.ui(13, .medium), .foregroundColor: Theme.accent])
        let row = NSStackView(views: buttons)
        row.spacing = 12
        // This step is short: centre it in the window (the next step's table uses the full height).
        let above = NSView(), below = NSView()
        reset([above, title, sub, row, other, below])
        above.heightAnchor.constraint(equalTo: below.heightAnchor).isActive = true
        content.setCustomSpacing(18, after: sub)
        content.setCustomSpacing(14, after: row)
    }

    @objc func pickDAW(_ sender: NSButton) {
        choose(SourceDAW(rawValue: sender.identifier?.rawValue ?? ""))
    }

    /// Applies the choice (shortcut preset), then shows the project finder.
    func choose(_ daw: SourceDAW?) {
        SourceDAW.preferred = daw
        Migration.applyKeymap(daw, to: NSApp.mainMenu)
        filter = daw
        Self.hasCompleted = true
        showFinder()
    }

    // Step 2: bring your projects
    func showFinder() {
        let dawName = filter?.title ?? "other DAWs"
        let title = label("Bring your \(dawName) projects", size: 22, weight: .semibold)
        let sub = label("Audio, clip edits, fades, levels and mutes come over. MIDI, plugins and automation are listed in the import report and will import as Dalnok gains them. Originals are never changed.", color: Theme.textDim)
        let cols: [(String, String, CGFloat)] = [("name", "Project", 300), ("daw", "From", 110), ("date", "Modified", 120), ("folder", "Folder", 160)]
        if table.tableColumns.isEmpty {
            for (id, t, w) in cols {
                let c = NSTableColumn(identifier: .init(id))
                c.title = t
                c.width = w
                table.addTableColumn(c)
            }
            table.dataSource = self
            table.delegate = self
            table.rowHeight = 24
            table.target = self
            table.doubleAction = #selector(importSelected)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 712).isActive = true
        preview.textColor = Theme.textDim
        preview.font = .systemFont(ofSize: 12)
        preview.preferredMaxLayoutWidth = 700
        importButton.target = self
        importButton.action = #selector(importSelected)
        importButton.keyEquivalent = "\r"
        importButton.isEnabled = false
        let other = NSButton(title: "Choose a File or Stems Folder…", target: self, action: #selector(chooseFile))
        let guide = NSButton(title: "Concept Guide", target: self, action: #selector(openGuide))
        let done = NSButton(title: "Start with an Empty Project", target: self, action: #selector(finish))
        let buttons = NSStackView(views: [importButton, other, guide, NSView(), done])
        buttons.widthAnchor.constraint(equalToConstant: 712).isActive = true
        status.textColor = Theme.textDim
        status.stringValue = "Searching your Mac for projects…"
        reset([title, sub, status, scroll, preview, buttons])
        Task { await rescan() }
    }

    func rescan() async {
        projects = await ProjectScanner.scan()
        shown = filter.map { f in projects.filter { $0.daw == f } + projects.filter { $0.daw != f } } ?? projects
        table.reloadData()
        let counts = SourceDAW.allCases.map { d in "\(projects.filter { $0.daw == d }.count) \(d.title)" }.joined(separator: ", ")
        status.stringValue = projects.isEmpty ? "No Logic, Ableton or REAPER projects found in your home folder." : "Found \(counts) projects."
    }

    @objc func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.message = "Choose a Logic, Ableton, REAPER or Final Cut Pro XML project — or a folder of stems."
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.importURL(url) }
        }
    }

    @objc func importSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        importURL(shown[row].url)
    }

    private func importURL(_ url: URL) {
        window.orderOut(nil)
        main.importProject(url)
    }

    @objc func openGuide() { main.showConceptGuide(nil) }
    @objc func finish() { Self.hasCompleted = true; window.orderOut(nil) }

    // Table
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let p = shown[row]
        let text: String
        switch col?.identifier.rawValue {
        case "name": text = p.url.deletingPathExtension().lastPathComponent
        case "daw": text = p.daw.title
        case "date": text = dateFormat.string(from: p.modified)
        default: text = p.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
        let l = NSTextField(labelWithString: text)
        l.lineBreakMode = .byTruncatingMiddle
        l.textColor = col?.identifier.rawValue == "name" ? Theme.text : Theme.textDim
        return l
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        importButton.isEnabled = row >= 0
        guard row >= 0, row < shown.count else { preview.stringValue = ""; return }
        let url = shown[row].url
        preview.stringValue = "Checking what will come over…"
        Task.detached(priority: .userInitiated) {
            var report = [CChar](repeating: 0, count: 65_536), err = [CChar](repeating: 0, count: 512)
            let ok = dalnok_project_import_report(url.path, &report, report.count, &err, err.count) == DALNOK_OK
            let text = ok ? cString(report) : ""
            let message = ok ? nil : cString(err)
            await MainActor.run { [weak self] in
                guard let self, self.table.selectedRow == row else { return }
                if let r = ImportReport(json: text) {
                    let not = r.notImported.prefix(3).joined(separator: "; ")
                    self.preview.stringValue = "Will bring over \(r.summary)." + (not.isEmpty ? "" : " Not yet: \(not).")
                } else {
                    self.preview.stringValue = "Can't import this one: \(message ?? "unknown error")"
                }
            }
        }
    }
}
