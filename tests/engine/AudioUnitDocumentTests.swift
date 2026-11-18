// Optional document-aware Audio Unit round-trip: set DALNOK_TEST_DOCUMENT_AU to an installed AU identifier.
// SPDX-License-Identifier: GPL-3.0-or-later
import AudioToolbox
import DalnokEngine
import Foundation
import Testing

private let documentAU = ProcessInfo.processInfo.environment["DALNOK_TEST_DOCUMENT_AU"] ?? ""

@Suite(.enabled(if: !documentAU.isEmpty, "set DALNOK_TEST_DOCUMENT_AU to a document-aware Audio Unit"))
struct AudioUnitDocumentHosting {
    @Test func restoresChangedParameterFromSavedDocument() throws {
        let fields = documentAU.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        #expect(fields.count == 4 && fields[0] == "au" && fields.dropFirst().allSatisfy { $0.utf8.count == 4 })
        guard fields.count == 4, fields.dropFirst().allSatisfy({ $0.utf8.count == 4 }) else { return }
        func fourcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
        var desc = AudioComponentDescription(componentType: fourcc(fields[1]), componentSubType: fourcc(fields[2]),
                                             componentManufacturer: fourcc(fields[3]), componentFlags: 0, componentFlagsMask: 0)
        let component = try #require(AudioComponentFindNext(nil, &desc))
        var unit: AudioUnit?
        #expect(AudioComponentInstanceNew(component, &unit) == noErr)
        let probe = try #require(unit); defer { AudioComponentInstanceDispose(probe) }
        var size: UInt32 = 0, writable: DarwinBoolean = false
        #expect(AudioUnitGetPropertyInfo(probe, kAudioUnitProperty_ClassInfoFromDocument, kAudioUnitScope_Global, 0, &size, &writable) == noErr && writable.boolValue,
                "the fixture must implement document-specific restoration")

        let e = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_add(e, "Generated")
        let slot = dalnok_plugin_add(e, t, documentAU, nil, nil, 0)
        #expect(slot != 0)
        var chosen: DalnokPluginParameter?
        for i in 0..<dalnok_plugin_parameter_count(e, slot) {
            var p = DalnokPluginParameter()
            if dalnok_plugin_parameter(e, slot, i, &p) == DALNOK_OK && !p.read_only && p.automatable && p.step_count == 0 { chosen = p; break }
        }
        let parameter = try #require(chosen)
        let requested = parameter.value > 0.5 ? 0.25 : 0.75
        #expect(dalnok_plugin_set_parameter(e, slot, parameter.id, requested) == DALNOK_OK)
        dalnok_transport_play(e); _ = pump(e, 2_048)
        var before = DalnokPluginParameter(), beforeValue: Double?
        for i in 0..<dalnok_plugin_parameter_count(e, slot) {
            if dalnok_plugin_parameter(e, slot, i, &before) == DALNOK_OK && before.id == parameter.id { beforeValue = before.value; break }
        }
        let expected = try #require(beforeValue)
        #expect(abs(expected - parameter.value) > 0.001, "the test parameter actually changed")
        let path = tempDir().appendingPathComponent("generated.dalnok")
        var err = [CChar](repeating: 0, count: 256)
        #expect(dalnok_project_save(e, path.path, &err, 256) == DALNOK_OK)
        let restored = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(restored) }
        #expect(dalnok_project_load(restored, path.path, nil, &err, 256) == DALNOK_OK)
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(restored, dalnok_track_at(restored, 0), 0, &info) == DALNOK_OK && info.loaded && name(info.error).isEmpty)
        var actual: Double?
        for i in 0..<dalnok_plugin_parameter_count(restored, info.id) {
            var p = DalnokPluginParameter()
            if dalnok_plugin_parameter(restored, info.id, i, &p) == DALNOK_OK && p.id == parameter.id { actual = p.value; break }
        }
        #expect(abs((actual ?? -1) - expected) < 0.001, "saved parameter restored within 0.001")
    }
}
