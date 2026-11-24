// File ▸ Export Queue (a render queue, as in REAPER and Logic's bounce of several ranges): exports are collected —
// the mix or stems, each with its range (the cycle when on, else everything) and format — and rendered one after
// another with Render Queue. The queue belongs to the window and is not saved.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine
import UniformTypeIdentifiers

struct ExportJob {
    let url: URL
    let format: DalnokFileFormat
    let stems: Bool
    let range: (start: Int64, end: Int64)?
    var title: String { (stems ? "Stems → " : "Mix → ") + url.lastPathComponent + (range == nil ? "" : " (cycle)") }
}

extension MainWindowController {
    private var currentRange: (start: Int64, end: Int64)? { session.cycle.on ? (session.cycle.start, session.cycle.end) : nil }

    @objc func queueMixExport(_ sender: Any?) {
        let panel = NSSavePanel()
        let f = Engine.exportFormats[Self.exportFormatIndex]
        panel.allowedContentTypes = [UTType(filenameExtension: f.ext) ?? .audio]
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Mix") + " \(exportQueue.count + 1).\(f.ext)"
        panel.message = "Adds this export (\(f.title)\(session.cycle.on ? ", the cycle range" : "")) to the queue."
        panel.prompt = "Add to Queue"
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { () -> Void in self?.enqueue(ExportJob(url: url, format: f.format, stems: false, range: self?.currentRange)) }
        }
    }
    @objc func queueStemsExport(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Add to Queue"
        let f = Engine.exportFormats[Self.exportFormatIndex]
        panel.message = "Adds stems (\(f.title)) into this folder to the queue."
        panel.beginSheetModal(for: window!) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { () -> Void in self?.enqueue(ExportJob(url: url, format: f.format, stems: true, range: self?.currentRange)) }
        }
    }
    func enqueue(_ job: ExportJob) {
        exportQueue.append(job)
        flash("Queued \(job.title) — \(exportQueue.count) in the queue")
    }
    @objc func clearQueue(_ sender: Any?) { exportQueue.removeAll(); flash("Export queue cleared") }

    /// Renders every queued export in order; returns how many succeeded.
    @discardableResult
    @objc func renderQueue(_ sender: Any?) -> Int {
        guard !exportQueue.isEmpty else { flash("The export queue is empty (File ▸ Export Queue ▸ Add …)"); return 0 }
        let t0 = Date()
        var done = 0, failed: [String] = []
        for job in exportQueue {
            if job.stems {
                let start = job.range?.start ?? 0, frames = (job.range?.end ?? session.engine.sessionLength) - start
                let tail = job.range == nil ? Int64(10 * dalnok_engine_sample_rate(session.engine.handle)) : 0
                var err = [CChar](repeating: 0, count: 512)
                if frames > 0, dalnok_export_stems(session.engine.handle, job.url.path, Int32(job.format.rawValue), start, frames, tail, &err, err.count) > 0 { done += 1 }
                else { failed.append(job.title) }
            } else {
                do { try session.engine.export(to: job.url, format: job.format, range: job.range); done += 1 } catch { failed.append(job.title) }
            }
        }
        exportQueue.removeAll()
        flash(failed.isEmpty ? String(format: "Rendered %d exports in %.1f s", done, Date().timeIntervalSince(t0))
                             : "Rendered \(done); failed: \(failed.joined(separator: ", "))")
        return done
    }
}
