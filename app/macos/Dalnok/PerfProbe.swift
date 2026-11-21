// Developer: `Dalnok <project> --perf <seconds>` plays the project on the real output device, as someone would, and
// reports what a listener and a user feel: audio callbacks that ran over their budget (skips), the worst render time,
// and how long the main thread was busy per run-loop pass (UI lag). Prints one JSON line and quits.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor
final class PerfProbe {
    private var busy: [Double] = [] // ms per run-loop pass
    private var ticks: [Double] = [] // ms per display tick
    private var passStart = 0.0
    private var observer: CFRunLoopObserver?
    static var current: PerfProbe?

    private var playStart = 0.0, slowTicks: [Double] = [] // seconds after play of ticks over 50 ms
    func noteTick(_ ms: Double) { ticks.append(ms); if ms > 50 && playStart > 0 { slowTicks.append(((CACurrentMediaTime() - playStart) * 100).rounded() / 100) } }

    static func isolation(_ app: AppDelegate) -> (UInt64, UInt64, Int) {
        var missed: UInt64 = 0, skips: UInt64 = 0, isolated = 0
        for t in app.main.session.allTracks { for p in t.plugins {
            var st = DalnokPluginIsolationStats()
            if dalnok_plugin_isolation_stats(app.main.session.engine.handle, p.id, &st) == DALNOK_OK { isolated += 1; missed += st.missed_blocks; skips += st.budget_skips }
        } }
        return (missed, skips, isolated)
    }

    static func run(app: AppDelegate, seconds: Double) {
        let p = PerfProbe()
        current = p
        // Let plug-ins finish loading first: loading is measured by load-bench, playback here.
        func whenLoaded(_ go: @escaping @MainActor () -> Void) {
            if app.main.session.pluginLoadProgress == nil { go() } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MainActor.assumeIsolated { whenLoaded(go) } }
            }
        }
        whenLoaded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { p.start(app: app, seconds: seconds) } }
        }
    }

    private func start(app: AppDelegate, seconds: Double) {
        let e = app.main.session.engine
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                     true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { self.passStart = now } else if self.passStart > 0 { self.busy.append((now - self.passStart) * 1000) }
            }
        }
        observer = obs
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        // Silent unless asked: the same work per block (master gain is the last multiply), nothing out of the speakers.
        if ProcessInfo.processInfo.environment["DALNOK_PERF_AUDIBLE"] == nil { _ = dalnok_master_set_gain_db(e.handle, -120) }
        dalnok_engine_reset_stats(e.handle)
        let before = Self.isolation(app)
        playStart = CACurrentMediaTime()
        e.play()
        let t0 = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated {
            let wall = Date().timeIntervalSince(t0)
            var s = DalnokStats(); dalnok_engine_stats(e.handle, &s)
            e.pause()
            if let o = self.observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes) }
            func pct(_ a: [Double], _ q: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * q))] }
            let budget = Double(s.max_frames_per_callback) / e.sampleRate * 1000
            // Isolated plug-ins: blocks a host answered late (missed) or that were passed untouched because the
            // callback's shared budget was spent (budget skips). Both are heard as the effect dropping out.
            var (missed, skips, isolated) = Self.isolation(app)
            missed -= before.0; skips -= before.1
            let tracks = app.main.session.tracks.count, clips = app.main.session.tracks.reduce(0) { $0 + $1.clips.count }
            let out: [String: Any] = [
                "seconds": (wall * 10).rounded() / 10, "tracks": tracks, "clips": clips,
                "callbacks": s.callbacks, "isolated": isolated, "missedBlocks": missed, "budgetSkips": skips, "overloads": s.overloads, "budgetMs": (budget * 100).rounded() / 100,
                "worstRenderMs": (Double(s.max_callback_ns) / 1e4).rounded() / 100,
                "mainPasses": self.busy.count, "mainP50Ms": pct(self.busy, 0.5), "mainP99Ms": pct(self.busy, 0.99),
                "mainMaxMs": self.busy.max() ?? 0, "mainOver50Ms": self.busy.filter { $0 > 50 }.count,
                "tickP50Ms": pct(self.ticks, 0.5), "tickP99Ms": pct(self.ticks, 0.99), "tickMaxMs": self.ticks.max() ?? 0, "slowTicksAt": self.slowTicks,
            ]
            let data = try! JSONSerialization.data(withJSONObject: out.mapValues { v -> Any in
                if let d = v as? Double { return (d * 100).rounded() / 100 }; return v }, options: [.sortedKeys])
            print("PERF " + String(decoding: data, as: UTF8.self))
            fflush(stdout)
            exit(0) // skip the unsaved-changes prompt
        } }
    }
}
