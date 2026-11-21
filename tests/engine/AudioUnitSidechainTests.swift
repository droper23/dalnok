// Audio Unit sidechains with a test unit (scripts/ci/plugin-host.sh builds it and sets DALNOK_TEST_AU): the unit's
// second input bus receives another track's pre-fader signal, as for VST3 and CLAP.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

let testAU = ProcessInfo.processInfo.environment["DALNOK_TEST_AU"] ?? ""

/// Registers the test unit in this process (AudioComponentRegister); nothing is installed on the system.
func registerTestAU() -> Bool {
    guard let lib = dlopen(testAU, RTLD_NOW), let sym = dlsym(lib, "dalnok_test_au_register") else { return false }
    typealias Register = @convention(c) () -> Int32
    return unsafeBitCast(sym, to: Register.self)() == 0
}

@Suite(.serialized, .enabled(if: !testAU.isEmpty, "set DALNOK_TEST_AU (scripts/ci/plugin-host.sh)"))
struct AudioUnitSidechain {
    @Test func sidechainUsesAnotherTracksPreFaderSignal() throws {
        #expect(registerTestAU(), "test AU registers")
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let bedMedia = makeMedia([[Float](repeating: 0.5, count: 48_000)])
        var key = [Float](repeating: 0, count: 48_000)
        for i in 24_000..<48_000 { key[i] = 0.75 }
        let keyMedia = makeMedia([key]); defer { dalnok_media_release(bedMedia); dalnok_media_release(keyMedia) }
        let bed = dalnok_track_add(e, "Bed"), source = dalnok_track_add(e, "Key")
        DalnokEngine.dalnok_clip_add(e, bed, dalnok_pool_add(e, bedMedia, ""), 0, 0, 0)
        DalnokEngine.dalnok_clip_add(e, source, dalnok_pool_add(e, keyMedia, ""), 0, 0, 0)
        #expect(dalnok_track_set_mute(e, source, true) == DALNOK_OK, "a muted source still keys (pre-fader)")
        var err = [CChar](repeating: 0, count: 256)
        let slot = dalnok_plugin_add(e, bed, "au:aufx:dkdk:Dlnk", nil, &err, 256)
        #expect(slot != 0, "\(cstr(err))")
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e, bed, 0, &info) == DALNOK_OK && name(info.name).contains("Test AU Duck") && info.loaded)
        #expect(dalnok_plugin_has_sidechain(e, slot), "the unit's second input bus is a sidechain")
        #expect(abs(render(e, 30_000, 10)[5] - 0.25) < 1e-6, "unconnected sidechain receives silence")
        #expect(dalnok_plugin_set_sidechain(e, bed, slot, source) == DALNOK_OK)
        let out = render(e, 0, 48_000)
        #expect(abs(out[10_000] - 0.25) < 1e-6, "silent key keeps full gain")
        #expect(abs(out[30_000] - 0.0625) < 1e-6, "0.75 key ducks 0.25 output to 0.0625")
        #expect(out[23_990..<24_000].allSatisfy { abs($0 - 0.25) < 1e-6 } && out[24_000..<24_010].allSatisfy { abs($0 - 0.0625) < 1e-6 },
                "sample-accurate: the duck starts exactly where the key does")
        #expect(dalnok_plugin_set_sidechain(e, bed, slot, 0) == DALNOK_OK)
        #expect(abs(render(e, 30_000, 10)[5] - 0.25) < 1e-6, "disconnect returns sidechain to silence")
    }

    @Test func sidechainConnectionSurvivesSaveAndReload() throws {
        #expect(registerTestAU())
        let dir = tempDir(), project = dir.appendingPathComponent("au-sc.dalnok")
        let keyFile = dir.appendingPathComponent("key.wav")
        _ = try writeTestWav(keyFile, frames: 48_000)
        var err = [CChar](repeating: 0, count: 256)
        do {
            let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
            let bed = dalnok_track_add(e, "Bed"), source = dalnok_track_add(e, "Key")
            var media: OpaquePointer?
            #expect(dalnok_media_load(keyFile.path, 48_000, &media, &err, 256) == DALNOK_OK, "\(cstr(err))")
            DalnokEngine.dalnok_clip_add(e, source, dalnok_pool_add(e, media, keyFile.path), 0, 0, 0)
            dalnok_media_release(media)
            let slot = dalnok_plugin_add(e, bed, "au:aufx:dkdk:Dlnk", nil, &err, 256)
            #expect(dalnok_plugin_set_sidechain(e, bed, slot, source) == DALNOK_OK)
            #expect(dalnok_plugin_set_parameter(e, slot, 0, 0.8) == DALNOK_OK)
            #expect(dalnok_project_save(e, project.path, &err, 256) == DALNOK_OK, "\(cstr(err))")
        }
        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        #expect(dalnok_project_load(e, project.path, nil, &err, 256) == DALNOK_OK, "\(cstr(err))")
        let bed = dalnok_track_at(e, 0), source = dalnok_track_at(e, 1)
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e, bed, 0, &info) == DALNOK_OK && info.loaded)
        #expect(dalnok_plugin_sidechain(e, bed, info.id) == source, "the sidechain source is saved")
        var p = DalnokPluginParameter()
        #expect(dalnok_plugin_parameter(e, info.id, 0, &p) == DALNOK_OK && abs(p.value - 0.8) < 1e-6, "the unit's state is saved (\(p.value))")
    }
}
