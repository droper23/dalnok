// The Library's Files place (the owner: "a file browser, like in Ableton"): the current project's folder, Music,
// Desktop, Downloads and Home, plus folders the owner adds. Folders unfold in place (read when opened); the list shows
// what Dalnok can take: audio files, Dalnok projects and the projects the importers read (ADR-0006). The search field
// searches, off the main thread and capped, the project's folder, added folders and the places opened this session
// (walking Desktop or Downloads unasked would raise macOS's privacy prompts). Click an audio file to hear it (Preview, remembered);
// drag a file onto the arrangement to import it; double-click or Return imports it, opens a project, or unfolds a folder.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// What the Files place lists and how a file is taken.
enum LibraryFiles {
    enum Kind { case audio, project, foreignProject }

    nonisolated static func kind(_ url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if ext == "dalnok" { return .project }
        if MainWindowController.foreignExtensions.contains(ext) { return .foreignProject }
        if let t = UTType(filenameExtension: ext), t.conforms(to: .audio) { return .audio }
        return nil
    }

    /// Folders the owner added (+ or right-click ▸ Add Folder…), remembered by path.
    static var userFolders: [URL] {
        get { (UserDefaults.standard.stringArray(forKey: "libraryFolders") ?? []).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "libraryFolders") }
    }

    /// The places, in order: the project's folder (when saved), the standard folders that exist, then the owner's.
    static func places(projectFolder: URL?) -> [(title: String, url: URL, removable: Bool)] {
        let fm = FileManager.default
        var out: [(String, URL, Bool)] = []
        if let p = projectFolder { out.append(("Current Project", p, false)) }
        for (title, dir) in [("Music", FileManager.SearchPathDirectory.musicDirectory), ("Desktop", .desktopDirectory), ("Downloads", .downloadsDirectory)] {
            if let u = fm.urls(for: dir, in: .userDomainMask).first, fm.fileExists(atPath: u.path) { out.append((title, u, false)) }
        }
        out.append(("Home", fm.homeDirectoryForCurrentUser, false))
        for u in userFolders where !out.contains(where: { $0.1.standardizedFileURL == u.standardizedFileURL }) {
            out.append((u.lastPathComponent, u, true))
        }
        return out
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]

    /// One folder's listing: sub-folders first, then the files Dalnok can take, each by name. Packages that are
    /// projects (.logicx, .fcpxmld) are files; other packages are skipped.
    nonisolated static func list(_ folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var dirs: [URL] = [], files: [URL] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false, isPackage = v?.isPackage ?? false
            if isDir && !isPackage { dirs.append(u) }
            else if kind(u) != nil { files.append(u) }
        }
        let byName = { (a: URL, b: URL) in a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending }
        return dirs.sorted(by: byName) + files.sorted(by: byName)
    }

    /// Files under `roots` whose names contain `query` (case-insensitive): at most `limit`, after looking at no more
    /// than `budget` items, so a search of Home stays quick.
    nonisolated static func search(_ query: String, in roots: [URL], limit: Int = 300, budget: Int = 30_000) -> [URL] {
        var found: [URL] = [], seen = 0, visited = Set<String>()
        let rootPaths = Set(roots.map(\.standardizedFileURL.path))
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in e {
                // Another place inside this one (Music inside Home) is searched on its own.
                if rootPaths.contains(u.standardizedFileURL.path) { e.skipDescendants(); continue }
                seen += 1
                if seen > budget || found.count >= limit { return found }
                guard kind(u) != nil, u.lastPathComponent.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil,
                      visited.insert(u.standardizedFileURL.path).inserted else { continue }
                found.append(u)
            }
        }
        return found
    }
}

/// Plays a file to audition it (its own player on the system output, never the engine's audio thread).
@MainActor
final class LibraryPreview {
    static let shared = LibraryPreview()
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "libraryPreview") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "libraryPreview") }
    }
    private var player: AVAudioPlayer?
    private(set) var playing: URL?
    func play(_ url: URL) {
        stop()
        guard Self.enabled, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.volume = 0.8
        p.play()
        player = p
        playing = url
    }
    func stop() { player?.stop(); player = nil; playing = nil }
}
