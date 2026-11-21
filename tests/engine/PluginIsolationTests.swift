// Out-of-process plug-in hosting (ADR-0014, audit A-01) against the test VST3 built by scripts/ci/plugin-isolation.sh.
// Runs when DALNOK_TEST_VST3 names the bundle and DALNOK_PLUGIN_HOST names dalnok-plughost. The failure cases set
// DALNOK_TEST_PROCESS_FAILURE, which every host started afterwards inherits, so the script runs this suite alone.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import AppKit
import Foundation
import Testing

let isolationHost = ProcessInfo.processInfo.environment["DALNOK_PLUGIN_HOST"] ?? ""

@Suite(.serialized, .enabled(if: !testVst3.isEmpty && !isolationHost.isEmpty, "scripts/ci/plugin-isolation.sh"))
struct PluginIsolation {
    func info(_ e: OpaquePointer, _ t: DalnokTrackId, _ index: Int32 = 0) -> DalnokPluginSlotInfo {
        var i = DalnokPluginSlotInfo()
        _ = dalnok_track_plugin_info(e, t, index, &i)
        return i
    }

    /// Pumps `blocks` live blocks; returns the slowest pump in milliseconds.
    func pumpLive(_ e: OpaquePointer, blocks: Int) -> Double {
        var l = [Float](repeating: 0, count: 512), r = l, worst = 0.0
        for _ in 0..<blocks {
            let t = DispatchTime.now().uptimeNanoseconds
            _ = dalnok_engine_pump(e, &l, &r, 512)
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
        }
        return worst
    }

    @Test func isolatedGainNullsAgainstInProcess() throws {
        let (inProcess, t1) = audioSession(); defer { dalnok_engine_destroy(inProcess) }
        dalnok_plugins_set_host(inProcess, nil)
        let (isolated, t2) = audioSession(); defer { dalnok_engine_destroy(isolated) }
        dalnok_plugins_set_host(isolated, isolationHost)
        var err = [CChar](repeating: 0, count: 256)
        let a = dalnok_plugin_add(inProcess, t1, testVst3, gainClass, &err, 256)
        let b = dalnok_plugin_add(isolated, t2, testVst3, gainClass, &err, 256)
        #expect(a != 0 && b != 0, "\(cstr(err))")
        #expect(!info(inProcess, t1).isolated && info(isolated, t2).isolated && info(isolated, t2).loaded && info(isolated, t2).latency == 7)
        let dry = renderStereo(isolated, 4_800)
        _ = dry
        for gain: Float in [0.5, 1] {
            #expect(dalnok_plugin_set_state(inProcess, a, floatState(gain)) == DALNOK_OK)
            #expect(dalnok_plugin_set_state(isolated, b, floatState(gain)) == DALNOK_OK)
            let x = renderStereo(inProcess, 4_800), y = renderStereo(isolated, 4_800)
            #expect(x.0 == y.0 && x.1 == y.1, "isolated output is bit-exact against in-process at gain \(gain)")
        }
        // State and parameters travel over the control channel.
        var state = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_get_state(isolated, b, &state, 256) > 0 && cstr(state) == floatState(1))
        #expect(dalnok_plugin_parameter_count(isolated, b) == dalnok_plugin_parameter_count(inProcess, a))
    }

    /// Overhead of isolation on the live path (audit A-01 verification): per-block time with the gain plug-in
    /// in-process vs isolated, at 64, 128 and 256 frames. Printed for the benchmark record; bounded loosely here.
    @Test func isolationOverheadPerBlock() throws {
        func measure(isolated: Bool, frames: Int) -> (p50: Double, p99: Double) {
            let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
            dalnok_plugins_set_host(e, isolated ? isolationHost : nil)
            _ = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
            dalnok_transport_play(e)
            var l = [Float](repeating: 0, count: frames), r = l, times: [Double] = []
            for i in 0..<3_000 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = dalnok_engine_pump(e, &l, &r, Int32(frames))
                if i >= 500 { times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e3) }
                if i % 400 == 0 { dalnok_transport_seek(e, 0) }
            }
            times.sort()
            return (times[times.count / 2], times[times.count * 99 / 100])
        }
        for frames in [64, 128, 256] {
            let a = measure(isolated: false, frames: frames), b = measure(isolated: true, frames: frames)
            print(String(format: "ISOLATION %d frames: in-process p50 %.1f µs p99 %.1f µs; isolated p50 %.1f µs p99 %.1f µs",
                         frames, a.p50, a.p99, b.p50, b.p99))
            let period = 1e6 * Double(frames) / 48_000
            #expect(b.p50 < period * 0.5, "isolated round trip p50 \(b.p50) µs fits well inside the \(period) µs period")
        }
    }

    @Test func crashMidSessionLeavesTheEngineRunningAndReloads() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        setenv("DALNOK_TEST_PROCESS_FAILURE", "crash", 1); setenv("DALNOK_TEST_PROCESS_AFTER", "4", 1)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        unsetenv("DALNOK_TEST_PROCESS_FAILURE")
        #expect(slot != 0, "\(cstr(err))")
        let saved = tempDir().appendingPathComponent("crash-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, saved, nil, 0) == DALNOK_OK && !dalnok_project_dirty(e))
        dalnok_transport_play(e)
        let worst = pumpLive(e, blocks: 40)
        #expect(worst < 50, "the audio path never stalls on the dead plug-in (worst block \(worst) ms)")
        var waited = 0
        while info(e, t).loaded && waited < 200 { dalnok_engine_collect_garbage(e); usleep(5_000); waited += 1 }
        let failed = info(e, t)
        #expect(!failed.loaded && name(failed.error).contains("crashed"), "reported: \(name(failed.error))")
        #expect(!dalnok_project_dirty(e), "a crash is not an edit: the saved project stays clean")
        #expect(dalnok_track_count(e) == 1 && dalnok_track_plugin_count(e, t) == 1, "the project is intact")
        // While failed, the effect passes the dry signal through.
        let dry = renderStereo(e, 4_800)
        #expect(dalnok_plugin_reload(e, slot, &err, 256) == DALNOK_OK, "\(cstr(err))")
        #expect(info(e, t).loaded && info(e, t).isolated)
        let wet = renderStereo(e, 4_800)
        #expect(wet.0 == dry.0.map { $0 * 0.5 }, "the restarted plug-in processes again (gain 0.5)")
    }

    @Test func hangMidSessionIsBoundedAndReported() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        setenv("DALNOK_TEST_PROCESS_FAILURE", "hang", 1); setenv("DALNOK_TEST_PROCESS_AFTER", "4", 1)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        unsetenv("DALNOK_TEST_PROCESS_FAILURE")
        #expect(slot != 0, "\(cstr(err))")
        dalnok_transport_play(e)
        // 512 frames at 48 kHz is a 10.7 ms period; a hung plug-in may cost at most the shared budget per block (at most 85 % of it).
        let worst = pumpLive(e, blocks: 240)
        // The bound that matters is never overrunning the period.
        #expect(worst < 10.6, "a hung plug-in never makes a live block overrun its 10.7 ms period (worst \(worst) ms)")
        dalnok_engine_collect_garbage(e)
        let failed = info(e, t)
        #expect(!failed.loaded && name(failed.error).contains("stopped responding"), "reported: \(name(failed.error))")
        #expect(dalnok_plugin_reload(e, slot, &err, 256) == DALNOK_OK && info(e, t).loaded, "\(cstr(err))")
    }

    @Test func crashOrHangWhileLoadingFailsTheLoadOnly() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        for mode in ["crash", "hang"] {
            setenv("DALNOK_TEST_INIT_FAILURE", mode, 1)
            var err = [CChar](repeating: 0, count: 256)
            let started = Date()
            let slot = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
            unsetenv("DALNOK_TEST_INIT_FAILURE")
            #expect(slot == 0, "\(mode) during initialization fails the add")
            #expect(cstr(err).contains(mode == "crash" ? "crashed" : "did not finish loading"), "\(mode): \(cstr(err))")
            #expect(Date().timeIntervalSince(started) < 10, "bounded by DALNOK_PLUGIN_LOAD_TIMEOUT_MS")
        }
        #expect(dalnok_track_plugin_count(e, t) == 0 && dalnok_track_count(e) == 1)
    }

    // MARK: Deferred activation through the host (ADR-0014 stage 2; closes the A-08 gap)

    /// A saved project with three test gain VST3s at gain 0.5, made in-process.
    func slowProject() -> (path: String, wet: [Float]) {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, nil)
        for _ in 0..<3 {
            let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
            #expect(slot != 0 && dalnok_plugin_set_state(e, slot, floatState(0.5)) == DALNOK_OK)
        }
        let wet = renderStereo(e, 4_800).0
        let path = tempDir().appendingPathComponent("slow-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK)
        return (path, wet)
    }

    func openDeferred(_ path: String) -> OpaquePointer {
        let e = dalnok_engine_create(48_000)!
        dalnok_plugins_set_host(e, isolationHost)
        var data: OpaquePointer?
        var missing: Int32 = -1
        #expect(dalnok_project_prepare(path, 48_000, &data, &missing, nil, 0) == DALNOK_OK && missing == 0)
        #expect(dalnok_project_apply_deferred(e, data) == DALNOK_OK)
        return e
    }

    func plughostChildren() -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(getpid())", "dalnok-plughost"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
    }

    /// The start request carries the saved state. With states of several MB and hosts busy initializing, sending it
    /// blocked the caller for the whole transfer (1.2 s on a real project), because macOS ignores MSG_DONTWAIT on the
    /// socket pair. Activation calls must stay short with 4 MB states, and the states must arrive intact.
    @Test func largeStatesDoNotBlockActivation() throws {
        setenv("DALNOK_TEST_STATE_PAD", "4000000", 1); defer { unsetenv("DALNOK_TEST_STATE_PAD") }
        let project = slowProject()
        setenv("DALNOK_TEST_INIT_FAILURE", "slow", 1); setenv("DALNOK_TEST_INIT_SLOW_MS", "800", 1)
        defer { unsetenv("DALNOK_TEST_INIT_FAILURE"); unsetenv("DALNOK_TEST_INIT_SLOW_MS") }
        let e = openDeferred(project.path); defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_at(e, 0)
        var worstCall = 0.0, calls = 0
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let left = dalnok_plugins_activate_next(e, nil, nil)
            worstCall = max(worstCall, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            calls += 1
            if left <= 0 { break }
            usleep(2_000)
        }
        print(String(format: "BIGSTATE 3 × 4 MB isolated: worst activate call %.2f ms over %d calls", worstCall, calls))
        #expect(worstCall < 50, "sending a large state never blocks the caller (worst \(worstCall) ms)")
        for i: Int32 in 0..<3 {
            let s = info(e, t, i)
            #expect(s.loaded && s.isolated, "slot \(i): \(name(s.error))")
        }
        let wet = renderStereo(e, 4_800).0
        #expect(zip(wet, project.wet).allSatisfy { abs($0 - $1) < 1e-6 }, "each host restored its state (gain 0.5)")
    }

    /// Every slot's initialization sleeps 1.5 s in its host. Activation calls never block (each returns in well under a
    /// frame), the three hosts load in parallel, and each slot comes up with its saved state.
    @Test func slowPluginsLoadWithoutBlockingTheCaller() throws {
        let project = slowProject()
        setenv("DALNOK_TEST_INIT_FAILURE", "slow", 1); setenv("DALNOK_TEST_INIT_SLOW_MS", "1500", 1)
        defer { unsetenv("DALNOK_TEST_INIT_FAILURE"); unsetenv("DALNOK_TEST_INIT_SLOW_MS") }
        let e = openDeferred(project.path); defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_at(e, 0)
        #expect(dalnok_plugins_pending(e) == 3)
        let started = DispatchTime.now().uptimeNanoseconds
        var worstCall = 0.0, finished: [Int32] = [], calls = 0
        while true {
            var slot: Int32 = 0
            let t0 = DispatchTime.now().uptimeNanoseconds
            let left = dalnok_plugins_activate_next(e, &slot, nil)
            worstCall = max(worstCall, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            calls += 1
            if slot != 0 { finished.append(slot) }
            if left <= 0 { break }
            usleep(2_000) // the app's run-loop turn
        }
        let total = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
        print(String(format: "SLOWLOAD 3 × 1.5 s isolated: total %.2f s, worst activate call %.2f ms over %d calls", total, worstCall, calls))
        #expect(worstCall < 50, "no activation call blocks on a slow plug-in (worst \(worstCall) ms)")
        #expect(total > 1.4 && total < 3.0, "the three hosts initialize in parallel (\(total) s, serial would be 4.5 s)")
        #expect(finished.count == 3 && Set(finished).count == 3)
        for i: Int32 in 0..<3 {
            let s = info(e, t, i)
            #expect(s.loaded && s.isolated && !s.loading, "slot \(i): \(name(s.error))")
            var state = [CChar](repeating: 0, count: 64)
            #expect(dalnok_plugin_get_state(e, s.id, &state, 64) > 0 && cstr(state) == floatState(0.5), "saved state restored in the host")
        }
        #expect(renderStereo(e, 4_800).0 == project.wet, "sounds as the in-process original")
        #expect(!dalnok_project_dirty(e), "loading is not an edit")
    }

    /// Stop while slow hosts are still initializing: returns at once, kills the hosts, keeps every slot's state.
    @Test func stopWhileSlowPluginsLoad() throws {
        let project = slowProject()
        setenv("DALNOK_TEST_INIT_FAILURE", "slow", 1); setenv("DALNOK_TEST_INIT_SLOW_MS", "5000", 1)
        defer { unsetenv("DALNOK_TEST_INIT_FAILURE"); unsetenv("DALNOK_TEST_INIT_SLOW_MS") }
        let e = openDeferred(project.path); defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_at(e, 0)
        var slot: Int32 = 0
        #expect(dalnok_plugins_activate_next(e, &slot, nil) == 3 && slot == 0, "hosts started, none finished")
        #expect((Int32(0)..<3).allSatisfy { info(e, t, $0).loading })
        #expect(plughostChildren() == 3)
        usleep(200_000)
        let t0 = DispatchTime.now().uptimeNanoseconds
        dalnok_plugins_cancel_pending(e)
        let stop = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        print(String(format: "SLOWLOAD stop with 3 hosts initializing: %.2f ms", stop))
        #expect(stop < 100, "Stop does not wait for the plug-ins (\(stop) ms)")
        #expect(plughostChildren() == 0, "the hosts are gone")
        #expect(dalnok_plugins_pending(e) == 0)
        for i: Int32 in 0..<3 {
            let s = info(e, t, i)
            #expect(!s.loaded && !s.loading && name(s.error).contains("cancelled"))
        }
        var state = [CChar](repeating: 0, count: 64)
        let first = info(e, t, 0).id
        #expect(dalnok_plugin_get_state(e, first, &state, 64) > 0 && cstr(state) == floatState(0.5), "state preserved")
        unsetenv("DALNOK_TEST_INIT_FAILURE")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_reload(e, first, &err, 256) == DALNOK_OK && info(e, t, 0).loaded, "\(cstr(err))")
    }

    /// A host that hangs or crashes while loading in the background fails only its slot, without blocking any call.
    @Test func hangOrCrashWhileLoadingInTheBackground() throws {
        let project = slowProject()
        for mode in ["hang", "crash"] {
            setenv("DALNOK_TEST_INIT_FAILURE", mode, 1)
            let e = openDeferred(project.path)
            let t = dalnok_track_at(e, 0)
            var worst = 0.0
            let started = Date()
            while Date().timeIntervalSince(started) < 10 {
                var slot: Int32 = 0
                let t0 = DispatchTime.now().uptimeNanoseconds
                let left = dalnok_plugins_activate_next(e, &slot, nil)
                worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                if left <= 0 { break }
                usleep(2_000)
            }
            unsetenv("DALNOK_TEST_INIT_FAILURE")
            let errors = (Int32(0)..<3).map { name(info(e, t, $0).error) }
            #expect(worst < 50, "\(mode): no call blocks (worst \(worst) ms)")
            #expect(errors.allSatisfy { $0.contains(mode == "hang" ? "did not finish loading" : "crashed") }, "\(mode): \(errors)")
            #expect(dalnok_track_plugin_count(e, t) == 3 && plughostChildren() == 0)
            dalnok_engine_destroy(e)
        }
    }

    // MARK: Editors in the host's window (ADR-0015)

    /// The window server's record of a window: owner process and bounds (no screen-recording permission needed).
    func windowServerEntry(_ number: Int64) -> (pid: Int32, bounds: CGRect, onScreen: Bool)? {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let w = list.first(where: { ($0[kCGWindowNumber as String] as? Int64) == number }),
              let pid = w[kCGWindowOwnerPID as String] as? Int32,
              let b = w[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: b) else { return nil }
        return (pid, rect, w[kCGWindowIsOnscreen as String] as? Bool == true)
    }

    /// Mean colour and spread of a PNG's pixels (0…1).
    func pixels(_ path: String) -> (mean: [Double], spread: Double, size: CGSize)? {
        guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = [0.0, 0.0, 0.0], sq = 0.0
        for i in stride(from: 0, to: data.count, by: 4) { for c in 0..<3 { sum[c] += Double(data[i + c]) / 255 } }
        let n = Double(w * h), mean = sum.map { $0 / n }
        for i in stride(from: 0, to: data.count, by: 4) { for c in 0..<3 { let d = Double(data[i + c]) / 255 - mean[c]; sq += d * d } }
        return (mean, (sq / (3 * n)).squareRoot(), CGSize(width: w, height: h))
    }

    func editorWindow(_ e: OpaquePointer, _ slot: Int32) -> DalnokPluginEditorWindow {
        var w = DalnokPluginEditorWindow()
        #expect(dalnok_plugin_editor_window(e, slot, &w) == DALNOK_OK)
        return w
    }

    /// The test VST3's editor (a green 400 × 300 view that asks to be 480 × 320 and edits its gain to 0.75) opens in
    /// a floating window owned by its host process; the resize, the edit and the audio all cross the boundary.
    @Test func isolatedVst3EditorOpensInTheHostsWindow() throws {
        setenv("DALNOK_TEST_EDITOR", "1", 1); setenv("DALNOK_TEST_EDITOR_RESIZE", "480x320", 1); setenv("DALNOK_TEST_EDITOR_EDIT", "0.75", 1)
        defer { unsetenv("DALNOK_TEST_EDITOR"); unsetenv("DALNOK_TEST_EDITOR_RESIZE"); unsetenv("DALNOK_TEST_EDITOR_EDIT") }
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        let dry = renderStereo(e, 4_800)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        #expect(slot != 0 && info(e, t).isolated, "\(cstr(err))")
        #expect(dalnok_plugin_has_editor(e, slot))
        let dummy = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8); defer { dummy.deallocate() }
        #expect(dalnok_plugin_open_editor(e, slot, dummy, nil, nil, nil, nil, &err, 256) == DALNOK_ERR_UNSUPPORTED)
        #expect(cstr(err).contains("its own window"), "embedding is refused with the reason: \(cstr(err))")
        #expect(dalnok_project_dirty(e) && dalnok_project_save(e, tempDir().appendingPathComponent("ed-\(UUID()).dalnok").path, nil, 0) == DALNOK_OK)
        #expect(!dalnok_project_dirty(e))

        #expect(dalnok_plugin_show_editor_window(e, slot, "Audio — Dalnok Test Gain", 120, 700, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let w = editorWindow(e, slot)
        print(String(format: "EDITOR vst3: content %.0f × %.0f, frame %.0f × %.0f at (%.0f, %.0f), level %lld, pid %d (app %d)",
                     w.content_width, w.content_height, w.width, w.height, w.x, w.y, w.level, w.process_id, getpid()))
        #expect(w.open && w.visible, "shown")
        #expect(w.content_width == 480 && w.content_height == 320, "the editor's resize request reached the window")
        #expect(abs(w.x - 120) < 1 && abs(w.y + w.height - 700) < 1, "placed with its top-left where asked")
        #expect(w.level == Int64(NSWindow.Level.floating.rawValue), "floats above Dalnok's windows")
        #expect(w.process_id > 0 && w.process_id != getpid())
        var ws = windowServerEntry(w.window_number)
        // A panel that joins every Space is briefly reported mid-way through its appear animation (476 × 350).
        for _ in 0..<20 where ws?.bounds.width != 480 { usleep(50_000); ws = windowServerEntry(w.window_number) }
        #expect(ws?.pid == w.process_id, "the window server shows it owned by the host: \(String(describing: ws))")
        // The lock screen shows every window scaled to 90 % about the screen's centre, so bounds only hold unlocked.
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        if locked { print("SKIP  window-server bounds of the editor (the screen is locked)") }
        else {
            #expect(ws?.bounds.width == 480, "the window server shows the resized window: \(String(describing: ws))")
            // A panel left on another Space reports visible but is not on screen; it must join the active Space.
            #expect(ws?.onScreen == true, "the window server shows the editor on the current Space")
        }
        let png = tempDir().appendingPathComponent("vst3-editor-\(UUID().uuidString).png").path
        #expect(dalnok_plugin_editor_snapshot(e, slot, png) == DALNOK_OK)
        let p = pixels(png)
        print("EDITOR vst3 snapshot \(png): \(String(describing: p))")
        // sRGB (0.1, 0.8, 0.3) as drawn; the exact red after colour matching depends on the display's profile.
        #expect(p.map { $0.spread < 0.01 && abs($0.mean[1] - 0.8) < 0.05 && $0.mean[0] < 0.3 && abs($0.mean[2] - 0.3) < 0.05 } == true,
                "the editor's own pixels (solid green) are in the window")
        // The editor's edit (gain 0.75) is a project change and is heard.
        dalnok_engine_collect_garbage(e)
        #expect(dalnok_project_dirty(e), "an edit in the isolated editor marks the project edited")
        let wet = renderStereo(e, 4_800)
        #expect(zip(wet.0, dry.0).allSatisfy { abs($0 - $1 * 0.75) < 1e-6 }, "the editor's edit reaches the audio (gain 0.75)")
        // Showing again keeps one window; closing closes it; it reopens.
        #expect(dalnok_plugin_show_editor_window(e, slot, "Audio — Dalnok Test Gain", .nan, .nan, &err, 256) == DALNOK_OK)
        #expect(editorWindow(e, slot).window_number == w.window_number)
        dalnok_plugin_close_editor(e, slot)
        let closed = editorWindow(e, slot)
        #expect(!closed.open && !closed.visible)
        #expect(dalnok_plugin_show_editor_window(e, slot, "Audio — Dalnok Test Gain", .nan, .nan, &err, 256) == DALNOK_OK)
        #expect(editorWindow(e, slot).open && editorWindow(e, slot).visible, "reopens")
        // Removing the plug-in takes its window with its process.
        #expect(dalnok_plugin_remove(e, t, slot) == DALNOK_OK)
    }

    /// An Apple Audio Unit's own Cocoa editor in the host's window.
    @Test func isolatedAudioUnitEditorOpensInTheHostsWindow() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, "au:aufx:dely:appl", nil, &err, 256)
        #expect(slot != 0 && info(e, t).isolated, "\(cstr(err))")
        #expect(dalnok_plugin_has_editor(e, slot))
        #expect(dalnok_plugin_show_editor_window(e, slot, "Audio — AUDelay", .nan, .nan, &err, 256) == DALNOK_OK, "\(cstr(err))")
        usleep(300_000) // Apple's views settle their layout on the host's next run-loop turns
        let w = editorWindow(e, slot)
        print(String(format: "EDITOR au: content %.0f × %.0f, level %lld, pid %d", w.content_width, w.content_height, w.level, w.process_id))
        #expect(w.open && w.visible && w.content_width >= 200 && w.content_height >= 100)
        #expect(windowServerEntry(w.window_number)?.pid == w.process_id)
        let png = tempDir().appendingPathComponent("au-editor-\(UUID().uuidString).png").path
        #expect(dalnok_plugin_editor_snapshot(e, slot, png) == DALNOK_OK)
        let p = pixels(png)
        print("EDITOR au snapshot \(png): \(String(describing: p))")
        #expect((p?.spread ?? 0) > 0.05, "the Audio Unit drew its controls (pixel spread \(p?.spread ?? 0))")
        // Audio still runs through it while the editor is open.
        let a = renderStereo(e, 4_800)
        #expect(a.0.contains { $0 != 0 })
        dalnok_plugin_close_editor(e, slot)
        #expect(!editorWindow(e, slot).open)
    }

    /// The plug-in's own window has a Controls button in its title bar (owner: one button opens the plug-in's GUI,
    /// and its title bar offers Dalnok's controls). Pressing it in the host reaches Dalnok as
    /// DALNOK_EDITOR_SHOW_CONTROLS for that slot, through the editor key ring.
    @Test func editorTitleBarControlsReachesDalnok() throws {
        setenv("DALNOK_TEST_EDITOR", "1", 1); setenv("DALNOK_TEST_EDITOR_CONTROLS", "1", 1)
        defer { unsetenv("DALNOK_TEST_EDITOR"); unsetenv("DALNOK_TEST_EDITOR_CONTROLS") }
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        #expect(slot != 0 && info(e, t).isolated)
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_plugin_show_editor_window(e, slot, "Audio — Dalnok Test Gain", .nan, .nan, &err, 256) == DALNOK_OK, "\(cstr(err))")
        var k = DalnokEditorKey(), got = false
        let deadline = Date().addingTimeInterval(3)
        while !got && Date() < deadline {
            while dalnok_plugin_take_editor_key(e, &k) { if k.key_code == UInt16(DALNOK_EDITOR_SHOW_CONTROLS) { got = true } }
            usleep(20_000)
        }
        #expect(got && k.slot == slot, "the title bar's Controls arrives as DALNOK_EDITOR_SHOW_CONTROLS for slot \(slot) (got \(got), slot \(k.slot))")
        dalnok_plugin_close_editor(e, slot)
    }

    /// AUSampler's editor changes its own frame while the window lays it out. The host's fit-to-editor pass re-entered
    /// itself through the frame-change notification until AppKit aborted the host (found with real input on the
    /// owner's library). The host must survive, show the editor, and settle on one size.
    @Test func isolatedAuSamplerEditorDoesNotRecurseInLayout() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add_instrument(e, "Sampler")
        dalnok_plugins_set_host(e, isolationHost)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, "au:aumu:samp:appl", nil, &err, 256)
        #expect(slot != 0 && info(e, t).isolated, "\(cstr(err))")
        #expect(dalnok_plugin_show_editor_window(e, slot, "Sampler — AUSampler", .nan, .nan, &err, 256) == DALNOK_OK, "\(cstr(err))")
        usleep(1_500_000) // the editor lays itself out over the host's next run-loop turns
        let w1 = editorWindow(e, slot)
        print(String(format: "EDITOR ausampler: content %.0f × %.0f, frame %.0f × %.0f", w1.content_width, w1.content_height, w1.width, w1.height))
        #expect(info(e, t).loaded, "the host survived opening the editor")
        #expect(w1.open && w1.visible && w1.content_width >= 200 && w1.content_height >= 100)
        #expect(w1.content_width < 1_600, "keeps the width it asked for instead of growing with every pass")
        usleep(500_000)
        let w2 = editorWindow(e, slot)
        #expect(abs(w2.width - w1.width) < 1 && abs(w2.height - w1.height) < 1, "settled on one size")
        dalnok_plugin_close_editor(e, slot)
        #expect(!editorWindow(e, slot).open && info(e, t).loaded)
    }

    // MARK: Isolated plug-ins run at the same time (ADR-0014, default-on)

    /// Four tracks, each with an isolated plug-in that takes 2 ms per 512-frame block. One after another that is 8 ms,
    /// more than the callback's 4.27 ms budget, so most blocks used to pass dry. Started together, their hosts work in
    /// parallel: every block is answered in time and the audio is the plug-ins' (gain 0.5), with nothing skipped.
    @Test func isolatedPluginsOnDifferentTracksProcessInParallel() throws {
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        var x = [Float](repeating: 0, count: 48_000)
        for i in 0..<x.count { x[i] = Float(0.5 * sin(Double(i) * 2 * .pi * 440 / 48_000)) }
        let m = makeMedia([x]); defer { dalnok_media_release(m) }
        let id = dalnok_pool_add(e, m, "")
        dalnok_plugins_set_host(e, isolationHost)
        setenv("DALNOK_TEST_PROCESS_SLOW_US", "2000", 1); defer { unsetenv("DALNOK_TEST_PROCESS_SLOW_US") }
        var slots: [Int32] = []
        for k in 0..<4 {
            let t = dalnok_track_add(e, "T\(k)")
            DalnokEngine.dalnok_clip_add(e, t, id, 0, 0, 0)
            let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
            #expect(slot != 0 && info(e, t).isolated)
            slots.append(slot)
        }
        dalnok_transport_play(e)
        _ = pumpLive(e, blocks: 8) // warm up (hosts paging in)
        func stats() -> (missed: UInt64, skips: UInt64) {
            var missed: UInt64 = 0, skips: UInt64 = 0
            for s in slots {
                var st = DalnokPluginIsolationStats()
                _ = dalnok_plugin_isolation_stats(e, s, &st)
                missed += st.missed_blocks; skips += st.budget_skips
            }
            return (missed, skips)
        }
        let before = stats()
        var l = [Float](repeating: 0, count: 512), r = l, worst = 0.0, peak: Float = 0
        for _ in 0..<60 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = dalnok_engine_pump(e, &l, &r, 512)
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            peak = max(peak, l.map(abs).max() ?? 0)
            usleep(4_000) // leave the hosts idle between blocks, as a device period would
        }
        let after = stats()
        print(String(format: "PARALLEL 4 x 2 ms isolated: worst callback %.2f ms (budget 4.27), missed %llu, skips %llu, peak %.3f",
                     worst, after.missed - before.missed, after.skips - before.skips, peak))
        #expect(after.skips - before.skips <= 2 && after.missed - before.missed <= 2,
                "4 x 2 ms fit one 4.27 ms budget when run together (missed \(after.missed - before.missed), skips \(after.skips - before.skips))")
        #expect(worst < 4.27 + 1.5, "the callback stays within its budget (worst \(worst) ms)")
        // Four mono tracks at -3 dB pan law centre, through gain 0.5 each: about 4 x 0.5 x 0.5 = 1.0 peak.
        #expect(abs(peak - 1.0) < 0.05, "every block carries the plug-ins' output (peak \(peak))")
    }

    /// Some plug-ins do one-off work a moment of audio after they load (an instrument's scripts finishing start-up:
    /// about 36 ms in one block, half a second in). Each isolated process pays it alone, and on the first play it was a
    /// burst of missed blocks. The host now processes 0.75 s of silence before reporting ready, so that work is done
    /// before the first real block. Without the warm-up the same plug-in misses blocks; with it, none.
    @Test func hostWarmUpAbsorbsOneOffStartUpWork() throws {
        setenv("DALNOK_TEST_SLOW_ONCE_AT", "12000", 1); defer { unsetenv("DALNOK_TEST_SLOW_ONCE_AT") } // 0.25 s in
        setenv("DALNOK_TEST_SLOW_ONCE_US", "40000", 1); defer { unsetenv("DALNOK_TEST_SLOW_ONCE_US") }
        func missedOnFirstPlay(warmUpMs: String?) -> (missed: UInt64, loadMs: Double) {
            if let w = warmUpMs { setenv("DALNOK_PLUGHOST_WARMUP_MS", w, 1) } else { unsetenv("DALNOK_PLUGHOST_WARMUP_MS") }
            defer { unsetenv("DALNOK_PLUGHOST_WARMUP_MS") }
            let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
            dalnok_plugins_set_host(e, isolationHost)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
            let loadMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            #expect(slot != 0 && info(e, t).isolated)
            dalnok_transport_play(e)
            var l = [Float](repeating: 0, count: 512), r = l
            for _ in 0..<60 { _ = dalnok_engine_pump(e, &l, &r, 512); usleep(10_000) } // 0.64 s at the device's pace
            var st = DalnokPluginIsolationStats()
            _ = dalnok_plugin_isolation_stats(e, slot, &st)
            return (st.missed_blocks + st.budget_skips, loadMs)
        }
        let cold = missedOnFirstPlay(warmUpMs: "0"), warm = missedOnFirstPlay(warmUpMs: nil)
        print(String(format: "WARM-UP: without %llu missed (load %.0f ms), with %llu missed (load %.0f ms)", cold.missed, cold.loadMs, warm.missed, warm.loadMs))
        #expect(cold.missed >= 2, "without the warm-up the 40 ms of start-up work misses blocks (\(cold.missed))")
        #expect(warm.missed == 0, "with it, the first play misses nothing (\(warm.missed))")
        #expect(warm.loadMs < cold.loadMs + 400, "the warm-up adds little to loading (\(warm.loadMs) vs \(cold.loadMs) ms)")
    }

    /// Isolated plug-ins share one time budget per callback. A fixed 40 % of the period dropped heavy effects on big
    /// projects even though the rest of the block had plenty of time left (512 isolated units: 150 of 1,972 blocks
    /// skipped an effect; in-process the same project kept up). The budget is now what the block's own work leaves.
    /// One plug-in that needs 56 % of every 512-frame block (6 ms of 10.67) must never miss; two in series (12 ms, more
    /// than the period) must not push the block past its period: the second one passes dry instead.
    @Test func isolatedBudgetFollowsWhatTheBlockLeaves() throws {
        setenv("DALNOK_TEST_PROCESS_SLOW_US", "6000", 1); defer { unsetenv("DALNOK_TEST_PROCESS_SLOW_US") }
        let periodMs = 512.0 / 48.0
        func play(units: Int) -> (dropped: UInt64, worstMs: Double) {
            let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
            dalnok_plugins_set_host(e, isolationHost)
            let slots = (0..<units).map { _ in dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0) }
            #expect(slots.allSatisfy { $0 != 0 } && info(e, t).isolated)
            dalnok_transport_play(e)
            var l = [Float](repeating: 0, count: 512), r = l
            var worst = 0.0
            for i in 0..<80 { // 0.85 s at the device's pace
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = dalnok_engine_pump(e, &l, &r, 512)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                if i >= 5 { worst = max(worst, ms) } // after the first few blocks (estimate settled)
                usleep(UInt32(max(0, periodMs - ms) * 1000))
            }
            var dropped: UInt64 = 0
            for s in slots { var st = DalnokPluginIsolationStats(); _ = dalnok_plugin_isolation_stats(e, s, &st); dropped += st.missed_blocks + st.budget_skips }
            return (dropped, worst)
        }
        let one = play(units: 1), two = play(units: 2)
        print(String(format: "BUDGET: one 6 ms unit dropped %llu (worst block %.2f ms); two dropped %llu (worst %.2f ms, period %.2f)",
                     one.dropped, one.worstMs, two.dropped, two.worstMs, periodMs))
        #expect(one.dropped == 0, "a unit using 56 % of the period never drops (\(one.dropped))")
        #expect(two.dropped > 0, "two that need more than the period cannot both run (\(two.dropped))")
        #expect(two.worstMs < periodMs * 0.95, "and the block still ends inside its period (\(two.worstMs) ms)")
    }

    /// The device panel reads every visible control's value and text four times a second (and while drawing). Each read
    /// was a round trip to the host: with 4 isolated units on a busy machine that stalled the main thread for 50 ms or
    /// more, three times a second. One round trip now fetches every parameter, and reads within 80 ms reuse it.
    @Test func parameterReadsShareOneRoundTrip() throws {
        setenv("DALNOK_TEST_MAIN_BUSY", "1", 1); defer { unsetenv("DALNOK_TEST_MAIN_BUSY") }
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        #expect(slot != 0 && info(e, t).isolated)
        let n = dalnok_plugin_parameter_count(e, slot)
        #expect(n > 0)
        // A refresh: every parameter, then every parameter again (values, then their text in a display).
        var worstRefresh = 0.0
        for _ in 0..<6 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<2 { for i in 0..<n { var p = DalnokPluginParameter(); #expect(dalnok_plugin_parameter(e, slot, i, &p) == DALNOK_OK) } }
            worstRefresh = max(worstRefresh, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            usleep(250_000) // the panel's refresh interval
        }
        print(String(format: "PARAMS busy host: %d parameters read twice per refresh, worst refresh %.1f ms", n, worstRefresh))
        // At most one wait on the host's busy main thread (up to 200 ms) per refresh, never one per read.
        #expect(worstRefresh < 250, "a refresh waits on the host at most once (worst \(worstRefresh) ms)")
        // And a value set from Dalnok shows on the next read, not 80 ms later.
        var p = DalnokPluginParameter()
        _ = dalnok_plugin_parameter(e, slot, 0, &p)
        let target = p.value > 0.5 ? 0.1 : 0.9
        #expect(dalnok_plugin_set_parameter(e, slot, p.id, target) == DALNOK_OK)
        _ = dalnok_plugin_parameter(e, slot, 0, &p)
        #expect(abs(p.value - target) < 1e-6, "the next read shows the new value (\(p.value) vs \(target))")
    }

    /// Recovery snapshots (every 30 s with unsaved changes) asked every isolated plug-in for its state on the main
    /// thread: 512 units cost 260 ms each time. An unchanged plug-in now answers with its last state; a change made from
    /// Dalnok is always in the next snapshot. The host here answers slowly (its main thread sleeps 200 ms at a time).
    @Test func recoverySnapshotsReuseUnchangedIsolatedStates() throws {
        setenv("DALNOK_TEST_MAIN_BUSY", "1", 1); defer { unsetenv("DALNOK_TEST_MAIN_BUSY") }
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        #expect(slot != 0 && info(e, t).isolated)
        let dir = tempDir()
        func snapshot(_ name: String) -> (ms: Double, state: String) {
            let url = dir.appendingPathComponent(name + ".dalnok")
            var err = [CChar](repeating: 0, count: 256)
            let t0 = DispatchTime.now().uptimeNanoseconds
            #expect(dalnok_project_save_snapshot(e, url.path, &err, 256) == DALNOK_OK)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let doc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
            let plugins = ((doc?["tracks"] as? [[String: Any]])?.first?["plugins"] as? [[String: Any]]) ?? []
            return (ms, plugins.first?["state"] as? String ?? "")
        }
        let first = snapshot("a")
        // Unchanged: five more snapshots over about half a second, while the host's main thread keeps sleeping 200 ms
        // at a time. Asking the host would have waited on it at least once.
        var second = (ms: 0.0, state: ""), worst = 0.0
        for k in 0..<5 { second = snapshot("b\(k)"); worst = max(worst, second.ms); usleep(100_000) }
        #expect(!first.state.isEmpty && second.state == first.state, "an unchanged plug-in's state is reused as it was")
        #expect(worst < 20, "unchanged snapshots never wait on the host (worst \(worst) ms, first \(first.ms) ms)")
        var p = DalnokPluginParameter()
        #expect(dalnok_plugin_parameter(e, slot, 0, &p) == DALNOK_OK)
        #expect(dalnok_plugin_set_parameter(e, slot, p.id, p.value > 0.5 ? 0.1 : 0.9) == DALNOK_OK)
        var l = [Float](repeating: 0, count: 512), r = l
        dalnok_transport_play(e)
        for _ in 0..<8 { _ = dalnok_engine_pump(e, &l, &r, 512); usleep(10_000) } // the processor applies the change
        let third = snapshot("c")
        print(String(format: "SNAPSHOT busy host: first %.1f ms, unchanged worst %.1f ms, after a change %.1f ms", first.ms, worst, third.ms))
        #expect(third.state != first.state, "a parameter set from Dalnok is in the next snapshot")
    }

    /// Polling plug-ins for editor edits (every display frame in the app) asked each isolated host over its socket and
    /// waited for the answer, so a host whose main thread was busy stalled the caller (60 ms spikes on real projects).
    /// The count now comes from the shared block: polling never waits on a host.
    @Test func pollingEditsNeverWaitsOnABusyHost() throws {
        setenv("DALNOK_TEST_MAIN_BUSY", "1", 1); defer { unsetenv("DALNOK_TEST_MAIN_BUSY") }
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, nil, 0)
        #expect(slot != 0 && info(e, t).isolated)
        var worst = 0.0
        for _ in 0..<20 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            dalnok_engine_collect_garbage(e)
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            usleep(5_000)
        }
        print(String(format: "EDITPOLL busy host: worst collect %.2f ms", worst))
        #expect(worst < 5, "polling for edits does not wait on the busy host (worst \(worst) ms; its main thread sleeps 200 ms at a time)")
        // Every edit compiles a snapshot, which reads each plug-in's latency for delay compensation. That too comes
        // from the shared block now: it asked the host and waited (16-52 ms per plug-in on real projects).
        var worstEdit = 0.0
        for k in 0..<10 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = dalnok_track_add(e, "Edit \(k)")
            worstEdit = max(worstEdit, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        print(String(format: "EDITPOLL busy host: worst structural edit %.2f ms", worstEdit))
        #expect(worstEdit < 20, "an edit does not wait on the busy host (worst \(worstEdit) ms)")
    }

    // MARK: One deadline budget per callback (A-01 stage 2)

    /// Three isolated plug-ins in series all hang mid-session, followed by a healthy one. Each callback waits on the
    /// hung hosts for at most one shared budget (at most 85 % of the period), not one budget per plug-in. The healthy plug-in, which
    /// is skipped when the budget is spent, is never blamed for it.
    @Test func hungPluginsShareOneDeadlinePerCallback() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        setenv("DALNOK_TEST_PROCESS_FAILURE", "hang", 1); setenv("DALNOK_TEST_PROCESS_AFTER", "4", 1)
        var err = [CChar](repeating: 0, count: 256)
        for _ in 0..<3 { #expect(dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256) != 0, "\(cstr(err))") }
        unsetenv("DALNOK_TEST_PROCESS_FAILURE")
        let healthy = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        #expect(healthy != 0)
        dalnok_transport_play(e)
        var l = [Float](repeating: 0, count: 512), r = l, times: [Double] = []
        for i in 0..<300 { // 3.2 s of audio: past the 2 s after which a host that keeps missing is reported
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = dalnok_engine_pump(e, &l, &r, 512)
            _ = i; times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        times.sort()
        let period = 512.0 / 48.0 // ms
        print(String(format: "BUDGET 3 hung + 1 healthy, 512 frames (period %.2f ms): p50 %.2f ms, max %.2f ms", period, times[times.count / 2], times.last!))
        #expect(times.last! < period, "no callback overruns its period (max \(times.last!) ms)")
        // One shared budget is at most 85 % of the period (what the block's own work leaves, see
        // isolatedBudgetFollowsWhatTheBlockLeaves). The tight bound holds at normal speed. Under a sanitizer (p50 several
        // times higher) only the no-overrun bound above is meaningful.
        if times[times.count / 2] < 1 {
            #expect(times.last! < period * 0.9, "the callback never waits more than one shared budget (max \(times.last!) ms)")
        }
        dalnok_engine_collect_garbage(e)
        var i = DalnokPluginSlotInfo()
        _ = dalnok_track_plugin_info(e, t, 3, &i)
        #expect(i.loaded && name(i.error).isEmpty, "the healthy plug-in is not blamed for the budget others used: \(name(i.error))")
        for k: Int32 in 0..<3 {
            var h = DalnokPluginSlotInfo()
            _ = dalnok_track_plugin_info(e, t, k, &h)
            #expect(!h.loaded && name(h.error).contains("stopped responding"), "hung plug-in \(k) is reported: \(name(h.error))")
        }
    }

    /// An editor placed beside Dalnok's plug-in window near the screen's right edge, at its own size or growing after
    /// opening (as many plug-ins do), is kept inside the screen's visible area instead of running off it.
    @Test(arguments: [false, true]) func anEditorThatGrowsAfterOpeningStaysOnScreen(_ later: Bool) throws {
        guard let screen = NSScreen.screens.first else { return }
        // Sized while opening (placed knowing nothing of it), or a moment later.
        setenv("DALNOK_TEST_EDITOR", "1", 1); setenv("DALNOK_TEST_EDITOR_RESIZE", "900x500", 1)
        if later { setenv("DALNOK_TEST_EDITOR_RESIZE_LATER", "1", 1) }
        defer { unsetenv("DALNOK_TEST_EDITOR"); unsetenv("DALNOK_TEST_EDITOR_RESIZE"); unsetenv("DALNOK_TEST_EDITOR_RESIZE_LATER") }
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        let vf = screen.visibleFrame
        // Top-left 300 pt from the right edge: the 900 pt editor would end 600 pt past it.
        #expect(dalnok_plugin_show_editor_window(e, slot, "Audio — Dalnok Test Gain", vf.maxX - 300, vf.maxY - 50, &err, 256) == DALNOK_OK)
        usleep(800_000) // the editor asks for its size a moment later
        var w = DalnokPluginEditorWindow()
        #expect(dalnok_plugin_editor_window(e, slot, &w) == DALNOK_OK)
        print(String(format: "EDITOR grown: frame %.0f × %.0f at (%.0f, %.0f); visible frame %.0f…%.0f × %.0f…%.0f",
                     w.width, w.height, w.x, w.y, vf.minX, vf.maxX, vf.minY, vf.maxY))
        #expect(w.content_width == 900, "the editor grew")
        #expect(w.x >= Double(vf.minX) - 0.5 && w.x + w.width <= Double(vf.maxX) + 0.5, "inside the screen horizontally")
        #expect(w.y >= Double(vf.minY) - 0.5 && w.y + w.height <= Double(vf.maxY) + 0.5, "inside the screen vertically")
        dalnok_plugin_close_editor(e, slot)
    }

    /// A VST3 editor change that is not a parameter (IComponentHandler2::setDirty with a changed state) marks the project
    /// changed, in process (editor in one of our views) and isolated (editor in the host's window).
    @MainActor @Test(arguments: [false, true]) func setDirtyFromAnEditorMarksTheProjectChanged(_ isolated: Bool) throws {
        setenv("DALNOK_TEST_EDITOR", "1", 1); setenv("DALNOK_TEST_EDITOR_DIRTY", "1", 1)
        defer { unsetenv("DALNOK_TEST_EDITOR"); unsetenv("DALNOK_TEST_EDITOR_DIRTY") }
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolated ? isolationHost : nil)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        let path = tempDir().appendingPathComponent("vst3-dirty-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK && !dalnok_project_dirty(e))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        usleep(2_200_000) // past the 2 s after loading in which setDirty only settles the state
        if isolated {
            #expect(dalnok_plugin_show_editor_window(e, slot, "Audio — Dalnok Test Gain", 100, 600, &err, 256) == DALNOK_OK, "\(cstr(err))")
        } else {
            var w: Int32 = 0, h: Int32 = 0
            #expect(dalnok_plugin_open_editor(e, slot, Unmanaged.passUnretained(view).toOpaque(), &w, &h, nil, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        }
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<4 { _ = dalnok_engine_pump(e, &l, &r, 512) }
        #expect(dalnok_project_dirty(e), "setDirty from the editor marks the project changed (isolated \(isolated))")
        dalnok_plugin_close_editor(e, slot)
    }

    /// An editor that changes its plug-in's state without telling the host: the project is not marked dirty, but
    /// dalnok_project_plugins_changed reports it before closing; saving takes it in. In process and isolated.
    @MainActor @Test(arguments: [false, true]) func silentEditorChangesAreFoundBeforeClosing(_ isolated: Bool) throws {
        setenv("DALNOK_TEST_EDITOR", "1", 1); setenv("DALNOK_TEST_EDITOR_SILENT", "1", 1)
        defer { unsetenv("DALNOK_TEST_EDITOR"); unsetenv("DALNOK_TEST_EDITOR_SILENT") }
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolated ? isolationHost : nil)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        let other = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256) // its editor is never opened
        #expect(slot != 0 && other != 0, "\(cstr(err))")
        let path = tempDir().appendingPathComponent("vst3-silent-\(UUID().uuidString).dalnok").path
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK)
        #expect(!dalnok_project_dirty(e) && !dalnok_project_plugins_changed(e), "clean after saving")
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        if isolated {
            #expect(dalnok_plugin_show_editor_window(e, slot, "Audio — Dalnok Test Gain", 100, 600, &err, 256) == DALNOK_OK, "\(cstr(err))")
        } else {
            var w: Int32 = 0, h: Int32 = 0
            #expect(dalnok_plugin_open_editor(e, slot, Unmanaged.passUnretained(view).toOpaque(), &w, &h, nil, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        }
        var l = [Float](repeating: 0, count: 512), r = l
        for _ in 0..<4 { _ = dalnok_engine_pump(e, &l, &r, 512) }
        #expect(!dalnok_project_dirty(e), "the plug-in told nobody")
        #expect(dalnok_project_plugins_changed(e), "its changed state is found before closing (isolated \(isolated))")
        #expect(dalnok_project_save(e, path, nil, 0) == DALNOK_OK)
        #expect(!dalnok_project_plugins_changed(e), "saving takes the change in")
        dalnok_plugin_close_editor(e, slot)
    }

    // MARK: Audio workgroup (A-01 stage 2)

    /// With a real output device running, the isolated host's processing thread joins the device's audio workgroup.
    /// It joins again after the device restarts, and also when the plug-in is added while the device is already running.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "needs real audio hardware"))
    func hostThreadJoinsTheDeviceWorkgroup() throws {
        let (e, t) = audioSession(); defer { dalnok_engine_destroy(e) }
        dalnok_plugins_set_host(e, isolationHost)
        var err = [CChar](repeating: 0, count: 256)
        let early = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        #expect(early != 0, "\(cstr(err))")
        func stats(_ slot: Int32) -> DalnokPluginIsolationStats {
            var s = DalnokPluginIsolationStats()
            #expect(dalnok_plugin_isolation_stats(e, slot, &s) == DALNOK_OK)
            return s
        }
        #expect(!stats(early).workgroup_joined && stats(early).workgroup_joins == 0, "no device, no workgroup")
        guard dalnok_engine_start_device(e, &err, 256) == DALNOK_OK else { Issue.record("no output device: \(cstr(err))"); return }
        dalnok_transport_play(e)
        usleep(400_000)
        let late = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        usleep(400_000)
        let a = stats(early), b = stats(late)
        print("WORKGROUP device running: early joined \(a.workgroup_joined) (error \(a.workgroup_error), joins \(a.workgroup_joins), missed \(a.missed_blocks), skips \(a.budget_skips)); late joined \(b.workgroup_joined) (error \(b.workgroup_error))")
        #expect(a.workgroup_joined && a.workgroup_error == 0 && a.workgroup_joins == 1, "a host started before the device joins it")
        #expect(b.workgroup_joined && b.workgroup_error == 0, "a host started while the device runs joins it")
        dalnok_engine_stop_device(e)
        #expect(dalnok_engine_start_device(e, &err, 256) == DALNOK_OK)
        usleep(400_000)
        let c = stats(early)
        print("WORKGROUP after restart: joined \(c.workgroup_joined), joins \(c.workgroup_joins)")
        #expect(c.workgroup_joined && c.workgroup_joins == 2, "after the device restarts it joins the new workgroup")
        dalnok_engine_stop_device(e)
    }

    /// Quitting while the device runs: the host's processing thread is in the device's workgroup when the engine goes
    /// away. A thread that exits while still joined makes libdispatch trap (SIGTRAP), so every quit with Safety on
    /// left a crash report per host. Hosts must exit normally.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "needs real audio hardware"))
    func hostsExitCleanlyWhenTheEngineGoesAwayWhileJoined() throws {
        // A busy host main thread answers the quit late, so the processing thread exits first (as with real plug-ins).
        setenv("DALNOK_TEST_MAIN_BUSY", "1", 1); defer { unsetenv("DALNOK_TEST_MAIN_BUSY") }
        let (e, t) = audioSession()
        dalnok_plugins_set_host(e, isolationHost)
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, t, testVst3, gainClass, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        guard dalnok_engine_start_device(e, &err, 256) == DALNOK_OK else {
            dalnok_engine_destroy(e); Issue.record("no output device: \(cstr(err))"); return
        }
        dalnok_transport_play(e)
        usleep(400_000)
        var s = DalnokPluginIsolationStats()
        #expect(dalnok_plugin_isolation_stats(e, slot, &s) == DALNOK_OK && s.workgroup_joined)
        // Watch the host's exit status (kqueue reports it for our own children) before the engine reaps it.
        let pids = plughostPids()
        #expect(pids.count == 1)
        let kq = kqueue(); defer { close(kq) }
        for pid in pids {
            var ev = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: nil)
            #expect(kevent(kq, &ev, 1, nil, 0, nil) == 0)
        }
        // A new project drops the instance while the device (and its workgroup) keeps running, as when the app
        // quits before the device's workgroup goes away.
        dalnok_project_new(e)
        for k in 0..<3 { usleep(200_000); _ = dalnok_track_add(e, "T\(k)") } // the device adopts; commits collect
        var out = kevent(), timeout = timespec(tv_sec: 3, tv_nsec: 0)
        var statuses: [Int32] = []
        while statuses.count < pids.count, kevent(kq, nil, 0, &out, 1, &timeout) == 1 { statuses.append(Int32(truncatingIfNeeded: out.data)) }
        #expect(statuses.count == pids.count)
        for st in statuses {
            let signal = st & 0x7f, code = (st >> 8) & 0xff
            #expect(signal == 0 && code == 0, "host exited normally (status \(st): signal \(signal), code \(code))")
        }
        dalnok_engine_destroy(e)
    }

    func plughostPids() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", "\(getpid())", "dalnok-plughost"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
    }
}
