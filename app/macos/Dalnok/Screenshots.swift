// --screenshots <dir>: renders the documentation/parity-page screenshots from
// the real app (no mockups): empty state, arrangement during playback, palette.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
enum Screenshots {
    static func png(_ view: NSView, _ url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    static func run(app: AppDelegate, files: [URL], dir: URL) {
        SelfTest.running = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = app.main!
        w.window?.setContentSize(NSSize(width: 1280, height: 720))
        Task {
            try? await Task.sleep(for: .seconds(0.3))
            png(w.window!.contentView!, dir.appendingPathComponent("empty-state.png"))
            await withCheckedContinuation { cont in app.session.importFiles(files) { cont.resume() } }
            // Show fades: a slow equal-power fade-in and fade-out on the last clip.
            if let pad = app.session.tracks.last?.clips.first {
                let sr = Int64(app.engine.sampleRate)
                app.session.setFades(pad.id, fadeIn: 3 * sr, fadeOut: 4 * sr, curve: DALNOK_FADE_EQUAL_POWER)
            }
            w.timeline.selectedClip = app.session.tracks.last?.clips.first?.id
            app.engine.seek(Int64(app.engine.sampleRate * 2))
            app.engine.play()
            try? await Task.sleep(for: .seconds(1.2))
            png(w.window!.contentView!, dir.appendingPathComponent("arrangement.png"))
            app.engine.pause()
            w.showCommandPalette(nil)
            w.palette.filter("sp")
            try? await Task.sleep(for: .seconds(0.3))
            if let panel = NSApp.windows.first(where: { $0 is KeyPanel }), let v = panel.contentView {
                png(v, dir.appendingPathComponent("command-palette.png"))
            }
            exit(0)
        }
    }
}
