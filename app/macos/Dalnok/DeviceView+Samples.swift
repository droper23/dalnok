// Dalnok Sampler and Dalnok Drums in the device chain: load samples from the unit's menu or by dropping audio files on
// it (the Sampler takes one, or maps several across the keyboard by the note names in their file names; Drums fill
// their pads in order from the first empty one, or every pad from the first when all are full). The unit's subtitle
// names what is loaded.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine
import UniformTypeIdentifiers

extension DeviceView {
    var isSampler: Bool { pluginPath.hasSuffix("sampler") || pluginPath.hasSuffix("drums") }
    var isDrums: Bool { pluginPath.hasSuffix("drums") }
    static let padNames = ["Kick", "Rim", "Snare", "Clap", "Snare 2", "Low Tom", "Closed Hat", "Mid Tom",
                           "Pedal Hat", "Tom", "Open Hat", "High Tom", "Crash", "High Tom 2", "Ride", "Pad 16"]
    var zoneCount: Int { 16 }
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static func noteName(_ n: Int32) -> String { "\(noteNames[Int(n) % 12])\(Int(n) / 12 - 1)" } // C4 = 60, as the piano roll
    func sampleZone(_ zone: Int) -> DalnokSampleZone? {
        var m = DalnokSampleZone()
        return dalnok_plugin_sample_zone(session.engine.handle, slot, Int32(zone), &m) ? m : nil
    }
    /// The Sampler's loaded zones beyond a lone sample: "C2–B3, root E3" (and velocities when they're split).
    func zoneSummary(_ zone: Int) -> String {
        guard let m = sampleZone(zone) else { return "" }
        var text = m.lo == m.hi ? Self.noteName(m.lo) : "\(Self.noteName(m.lo))–\(Self.noteName(m.hi))"
        if m.root >= 0 { text += ", root \(Self.noteName(m.root))" }
        if m.vlo > 1 || m.vhi < 127 { text += ", velocity \(m.vlo)–\(m.vhi)" }
        return text
    }
    /// Several files on the Sampler: mapped across the keyboard by their names. Returns how many loaded.
    @discardableResult
    func mapSamples(_ urls: [URL]) -> Int {
        var err = [CChar](repeating: 0, count: 1_024)
        let ptrs = urls.map { strdup($0.path) }; defer { ptrs.forEach { free($0) } }
        let n = ptrs.map { UnsafePointer($0) }.withUnsafeBufferPointer {
            dalnok_plugin_map_samples(session.engine.handle, slot, $0.baseAddress, Int32(urls.count), &err, err.count)
        }
        session.refresh()
        let skipped = String(cString: err)
        session.onMessage?(n <= 0 ? "Couldn't map the samples" + (skipped.isEmpty ? "" : ": \(skipped)")
                           : "Mapped \(n) sample\(n == 1 ? "" : "s") across the keyboard" + (skipped.isEmpty ? "" : " (\(skipped))"))
        return Int(n)
    }

    func samplePath(_ zone: Int) -> String {
        var buf = [CChar](repeating: 0, count: 2_048)
        _ = dalnok_plugin_sample_path(session.engine.handle, slot, Int32(zone), &buf, buf.count)
        return String(cString: buf)
    }
    @discardableResult
    func loadSample(_ url: URL, zone: Int) -> Bool {
        var err = [CChar](repeating: 0, count: 512)
        let ok = dalnok_plugin_set_sample(session.engine.handle, slot, Int32(zone), url.path, &err, err.count) == DALNOK_OK
        session.refresh()
        padGrid?.refresh()
        if !ok { session.onMessage?("Couldn't load \(url.lastPathComponent): \(String(cString: err))") }
        return ok
    }
    func chooseSample(zone: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = isDrums ? "Choose a sample for \(Self.padNames[zone]) (note \(36 + zone))" : "Choose a sample to play across the keyboard"
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { () -> Void in _ = self?.loadSample(url, zone: zone) }
        }
    }
    func chooseSamplesToMap() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.message = "Choose samples named by note (Piano_C4.wav, Gtr F#2.aif) to map across the keyboard"
        guard let win = window else { return }
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { () -> Void in _ = self?.mapSamples(urls) }
        }
    }
    func sampleMenuItems(_ m: NSMenu) {
        if !isDrums {
            let loaded = (0..<16).filter { !samplePath($0).isEmpty }
            if loaded.count > 1 { // multi-sampled: the zones, and a way back to one sample
                let sub = NSMenu(title: "Zones")
                for z in loaded {
                    let name = (samplePath(z) as NSString).lastPathComponent
                    let item = NSMenuItem(title: "\(name) — \(zoneSummary(z))", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    sub.addItem(item)
                }
                let parent = NSMenuItem(title: "Zones (\(loaded.count))", action: nil, keyEquivalent: "")
                parent.submenu = sub
                m.addItem(parent)
            }
            let name = (samplePath(0) as NSString).lastPathComponent
            m.addItem(ClosureMenuItem(title: loaded.count > 1 ? "Replace with One Sample…" : name.isEmpty ? "Load Sample…" : "Replace Sample (\(name))…",
                                      action: { [weak self] in self?.chooseSample(zone: 0) }))
            m.addItem(ClosureMenuItem(title: "Map Samples by Note Name…", action: { [weak self] in self?.chooseSamplesToMap() }))
            return
        }
        let sub = NSMenu(title: "Pads")
        for z in 0..<16 {
            let name = (samplePath(z) as NSString).lastPathComponent
            sub.addItem(ClosureMenuItem(title: "\(Self.padNames[z]) (\(36 + z))" + (name.isEmpty ? "" : " — \(name)") + "…",
                                        action: { [weak self] in self?.chooseSample(zone: z) }))
        }
        let parent = NSMenuItem(title: "Load Sample into Pad", action: nil, keyEquivalent: "")
        parent.submenu = sub
        m.addItem(parent)
    }

    /// Drops: audio files only.
    static func audioURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio)) == true }
    }
    func dropSamples(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        if !isDrums { return urls.count == 1 ? loadSample(urls[0], zone: 0) : mapSamples(urls) > 0 }
        var zone = (0..<16).first { samplePath($0).isEmpty } ?? 0
        var loaded = 0
        for url in urls where zone < 16 { if loadSample(url, zone: zone) { loaded += 1 }; zone += 1 }
        session.onMessage?(loaded == 1 ? "Loaded \(urls[0].lastPathComponent)" : "Loaded \(loaded) samples onto pads")
        return loaded > 0
    }
}

/// Dalnok Drums' 16 pads as a 4×4 grid (Drum Rack, Drum Machine Designer): each pad shows its name, note and sample;
/// click to hear it, drop an audio file on it to load it there, right-click to choose one.
final class DrumPadGrid: NSView {
    weak var device: DeviceView?
    private var pads: [NSButton] = []
    init(device: DeviceView) {
        self.device = device
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drum pads")
        let grid = NSGridView()
        grid.rowSpacing = 3
        grid.columnSpacing = 3
        for row in 0..<4 {
            var cells: [NSView] = []
            for col in 0..<4 {
                let pad = 12 - row * 4 + col // bottom row is pad 1, as on hardware
                let b = NSButton(title: "", target: self, action: #selector(hit(_:)))
                b.tag = pad
                b.bezelStyle = .smallSquare
                b.font = Theme.ui(9, .medium)
                b.widthAnchor.constraint(equalToConstant: 62).isActive = true
                b.heightAnchor.constraint(equalToConstant: 30).isActive = true
                pads.append(b)
                cells.append(b)
            }
            grid.addRow(with: cells)
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([grid.leadingAnchor.constraint(equalTo: leadingAnchor), grid.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     grid.topAnchor.constraint(equalTo: topAnchor), grid.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     heightAnchor.constraint(equalToConstant: 4 * 30 + 3 * 3)]) // pads keep their size; rows don't spread
        registerForDraggedTypes([.fileURL])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        guard let d = device else { return }
        for b in pads {
            let file = (d.samplePath(b.tag) as NSString).lastPathComponent
            let name = DeviceView.padNames[b.tag]
            b.title = file.isEmpty ? "\(name)\n—" : "\(name)\n\((file as NSString).deletingPathExtension)"
            b.toolTip = "Pad \(b.tag + 1), note \(36 + b.tag): " + (file.isEmpty ? "empty — drop a sample here" : file) + ". Click to hear it; right-click to choose a sample."
            b.setAccessibilityLabel("\(name) pad, \(file.isEmpty ? "empty" : file)")
            b.alphaValue = file.isEmpty ? 0.55 : 1
        }
    }
    @objc private func hit(_ b: NSButton) {
        guard let d = device else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.control) == true { return d.chooseSample(zone: b.tag) }
        let h = d.session.engine.handle, t = d.trackId, note = UInt8(36 + b.tag)
        guard dalnok_track_preview_note(h, t, note, 110, true) == DALNOK_OK else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { _ = dalnok_track_preview_note(h, t, note, 0, false) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let b = pads.first(where: { $0.convert($0.bounds, to: self).contains(p) }), let d = device else { return nil }
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "Load Sample into \(DeviceView.padNames[b.tag])…", action: { [weak d] in d?.chooseSample(zone: b.tag) }))
        if !d.samplePath(b.tag).isEmpty {
            m.addItem(ClosureMenuItem(title: "Clear \(DeviceView.padNames[b.tag])", action: { [weak self, weak d] in
                guard let d else { return }
                var err = [CChar](repeating: 0, count: 64)
                _ = dalnok_plugin_set_sample(d.session.engine.handle, d.slot, Int32(b.tag), "", &err, err.count)
                d.session.refresh(); self?.refresh()
            }))
        }
        return m
    }
    // Drops: onto the pad under the pointer (several files fill on from there).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { DeviceView.audioURLs(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let d = device else { return false }
        let urls = DeviceView.audioURLs(sender)
        let p = convert(sender.draggingLocation, from: nil)
        guard let b = pads.first(where: { $0.convert($0.bounds, to: self).contains(p) }), !urls.isEmpty else { return false }
        var zone = b.tag
        for url in urls where zone < 16 { d.loadSample(url, zone: zone); zone += 1 }
        refresh()
        return true
    }
}
