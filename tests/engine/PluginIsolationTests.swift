// Out-of-process plug-in hosting (ADR-0014, audit A-01) against the test VST3 built by scripts/ci/plugin-isolation.sh.
// Runs when DALNOK_TEST_VST3 names the bundle and DALNOK_PLUGIN_HOST names dalnok-plughost. The failure cases set
// DALNOK_TEST_PROCESS_FAILURE, which every host started afterwards inherits, so the script runs this suite alone.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
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
        dalnok_transport_play(e)
        let worst = pumpLive(e, blocks: 40)
        #expect(worst < 50, "the audio path never stalls on the dead plug-in (worst block \(worst) ms)")
        var waited = 0
        while info(e, t).loaded && waited < 200 { dalnok_engine_collect_garbage(e); usleep(5_000); waited += 1 }
        let failed = info(e, t)
        #expect(!failed.loaded && name(failed.error).contains("crashed"), "reported: \(name(failed.error))")
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
        // 512 frames at 48 kHz is a 10.7 ms period; a hung plug-in may cost at most its 40 % wait per block.
        let worst = pumpLive(e, blocks: 240)
        // The wait itself is 40 % of the period (4.3 ms); the bound that matters is never overrunning the period.
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
}
