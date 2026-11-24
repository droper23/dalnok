// Dalnok Sampler and Dalnok Drums in the device chain: load samples from the unit's menu or by dropping audio files on
// it (the Sampler takes one; Drums fill their pads in order from the first empty one, or every pad from the first
// when all are full). The unit's subtitle names what is loaded.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine
import UniformTypeIdentifiers

extension DeviceView {
    var isSampler: Bool { pluginPath.hasSuffix("sampler") || pluginPath.hasSuffix("drums") }
    var isDrums: Bool { pluginPath.hasSuffix("drums") }
    static let padNames = ["Kick", "Rim", "Snare", "Clap", "Snare 2", "Low Tom", "Closed Hat", "Mid Tom",
                           "Pedal Hat", "Tom", "Open Hat", "High Tom", "Crash", "High Tom 2", "Ride", "Pad 16"]
    var zoneCount: Int { isDrums ? 16 : 1 }

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
    func sampleMenuItems(_ m: NSMenu) {
        if !isDrums {
            let name = (samplePath(0) as NSString).lastPathComponent
            m.addItem(ClosureMenuItem(title: name.isEmpty ? "Load Sample…" : "Replace Sample (\(name))…", action: { [weak self] in self?.chooseSample(zone: 0) }))
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
        if !isDrums { return loadSample(urls[0], zone: 0) }
        var zone = (0..<16).first { samplePath($0).isEmpty } ?? 0
        var loaded = 0
        for url in urls where zone < 16 { if loadSample(url, zone: zone) { loaded += 1 }; zone += 1 }
        session.onMessage?(loaded == 1 ? "Loaded \(urls[0].lastPathComponent)" : "Loaded \(loaded) samples onto pads")
        return loaded > 0
    }
}
