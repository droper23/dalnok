// Generated Logic channel/Audio Unit fixtures; no source project data.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct LogicPluginImport {
    func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    func chunk(_ tag: String, _ payload: Data, id: UInt32 = 0, sub: UInt32 = 0, kind: UInt32 = 0) -> Data {
        var d = Data(tag.reversed().map { UInt8($0.asciiValue!) })
        var hdr = [UInt8](repeating: 0, count: 24)
        hdr.replaceSubrange(6..<10, with: le(id)); hdr.replaceSubrange(10..<14, with: le(sub)); hdr.replaceSubrange(14..<18, with: le(kind))
        d.append(contentsOf: hdr); d.append(contentsOf: le(UInt64(payload.count))); d.append(payload)
        return d
    }
    func component(_ name: String, type: String, subtype: String, manufacturer: String, xml: Data) -> Data {
        var d = Data(repeating: 0, count: 172)
        d.replaceSubrange(0..<4, with: le(UInt32(0x1a8)))
        d.replaceSubrange(120..<(120 + name.utf8.count), with: name.utf8)
        for (offset, value) in [(132, manufacturer), (136, type), (140, subtype)] {
            d.replaceSubrange(offset..<(offset + 4), with: value.utf8.reversed())
        }
        d.append(xml); return d
    }
    @Test func preservesAudioUnitStateAndOrdering() throws {
        let src = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(src) }
        let sourceTrack = dalnok_track_add(src, "Source")
        let sourceSlot = dalnok_plugin_add(src, sourceTrack, "au:aufx:dely:appl", nil, nil, 0)
        #expect(sourceSlot != 0)
        var param = DalnokPluginParameter(), selected: UInt32?
        for i in 0..<dalnok_plugin_parameter_count(src, sourceSlot) {
            if dalnok_plugin_parameter(src, sourceSlot, i, &param) == DALNOK_OK && name(param.title).lowercased().contains("dry/wet") { selected = param.id; break }
        }
        let pid = try #require(selected)
        #expect(dalnok_plugin_set_parameter(src, sourceSlot, pid, 0.7) == DALNOK_OK)
        dalnok_transport_play(src); _ = pump(src, 2_048)
        let n = dalnok_plugin_get_state(src, sourceSlot, nil, 0)
        var b64 = [CChar](repeating: 0, count: n + 1)
        _ = dalnok_plugin_get_state(src, sourceSlot, &b64, b64.count)
        let binary = try #require(Data(base64Encoded: cstr(b64)))
        let plist = try PropertyListSerialization.propertyList(from: binary, options: [], format: nil)
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let pkg = tempDir().appendingPathComponent("Generated.logicx")
        let alt = pkg.appendingPathComponent("Alternatives/000"), folder = pkg.appendingPathComponent("Media/Audio Files")
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTestWav(folder.appendingPathComponent("sample.wav"), frames: 48_000)
        var fl = Data(repeating: 0, count: 8); fl.append(contentsOf: le(UInt16(10))); for c in "sample.wav".utf16 { fl.append(contentsOf: le(c)) }
        var region = Data(repeating: 0, count: 120); region.replaceSubrange(22..<26, with: le(UInt32(48_000)))
        var env = Data(repeating: 0, count: 220); env.replaceSubrange(158..<160, with: le(UInt16(4))); env.replaceSubrange(160..<164, with: "Test".utf8); env.replaceSubrange(164..<166, with: le(UInt16(1)))
        var track = Data(repeating: 0, count: 58); track.replaceSubrange(8..<12, with: le(UInt32(20)))
        var event = Data(repeating: 0, count: 96); event.replaceSubrange(0..<4, with: le(UInt32(0x24))); event.replaceSubrange(4..<8, with: le(UInt32(34_560))); event[0x14] = 1; event.replaceSubrange(0x2c..<0x30, with: le(UInt32(40))); event[80] = 0xf1
        var env2 = env; env2.replaceSubrange(164..<166, with: le(UInt16(2)))
        var track2 = track; track2.replaceSubrange(8..<12, with: le(UInt32(24)))
        var event2 = event; event2[0x14] = 2
        var body = chunk("Envi", env, id: 20) + chunk("Envi", env2, id: 24)
            + chunk("AuCO", Data(repeating: 0, count: 201), id: 36, sub: 0)
            + chunk("AuCO", Data(repeating: 0, count: 201), id: 36, sub: 1)
        let delay = component("Delay", type: "aufx", subtype: "dely", manufacturer: "appl", xml: xml)
        let missingState: [String: Any] = ["type": 0x61756678, "subtype": 0x7a7a7a7a, "manufacturer": 0x74657374, "version": 0, "name": "Missing"]
        let missingXml = try PropertyListSerialization.data(fromPropertyList: missingState, format: .xml, options: 0)
        let missing = component("Missing", type: "aufx", subtype: "zzzz", manufacturer: "test", xml: missingXml)
        var native = Data(repeating: 0, count: 180); native.replaceSubrange(0..<4, with: le(UInt32(0x1a8))); native.replaceSubrange(120..<126, with: "Native".utf8)
        body += chunk("AuCU", missing, id: 36, sub: 0, kind: 4) + chunk("AuCU", native, id: 36, sub: 0, kind: 3) + chunk("AuCU", delay, id: 36, sub: 0, kind: 2)
        body += chunk("AuCU", missing, id: 36, sub: 1, kind: 2)
        body += chunk("AuFl", fl) + chunk("AuRg", region, id: 40) + chunk("MSeq", Data(repeating: 0, count: 8))
            + chunk("Trak", track) + chunk("Trak", track2) + chunk("EvSq", Data(event.prefix(80)) + event2)
        var file = Data([0x23, 0x47, 0xc0, 0xab]); file.append(Data(repeating: 0, count: 12)); file.append(contentsOf: le(UInt64(body.count))); file.append(body)
        try file.write(to: alt.appendingPathComponent("ProjectData"))
        let (e, report) = try importInto(pkg.path); defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_at(e, 0)
        #expect(dalnok_track_plugin_count(e, t) == 2)
        var a = DalnokPluginSlotInfo(), b = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e, t, 0, &a) == DALNOK_OK && a.loaded && name(a.name) == "Delay" && !a.instrument && name(a.error).isEmpty)
        #expect(dalnok_track_plugin_info(e, t, 1, &b) == DALNOK_OK && !b.loaded && name(b.name) == "Missing" && !name(b.error).isEmpty)
        var actual = DalnokPluginParameter(), actualValue: Double?
        for i in 0..<dalnok_plugin_parameter_count(e, a.id) {
            if dalnok_plugin_parameter(e, a.id, i, &actual) == DALNOK_OK && actual.id == pid { actualValue = actual.value; break }
        }
        #expect(abs((actualValue ?? -1) - 0.7) < 0.001, "restored Audio Unit parameter \(actualValue as Any)")
        let second = dalnok_track_at(e, 1)
        #expect(dalnok_track_plugin_count(e, second) == 1, "plug-in chain belongs to its own track")
        var secondInfo = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e, second, 0, &secondInfo) == DALNOK_OK && !secondInfo.loaded && name(secondInfo.name) == "Missing")
        #expect(((report["skipped"] as? [String: Int])?["unsupportedLogicPlugins"] ?? 0) == 1)
    }
    @Test(arguments: [0, 96]) func convertsChannelEqToTheBuiltInPlugin(prefix: Int) throws {
        let pkg = tempDir().appendingPathComponent("ChannelEQ.logicx")
        let alt = pkg.appendingPathComponent("Alternatives/000"), folder = pkg.appendingPathComponent("Media/Audio Files")
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeTestWav(folder.appendingPathComponent("sample.wav"), frames: 48_000)
        var fl = Data(repeating: 0, count: 8); fl.append(contentsOf: le(UInt16(10))); for c in "sample.wav".utf16 { fl.append(contentsOf: le(c)) }
        var region = Data(repeating: 0, count: 120); region.replaceSubrange(22..<26, with: le(UInt32(48_000)))
        var env = Data(repeating: 0, count: 220); env.replaceSubrange(158..<160, with: le(UInt16(4))); env.replaceSubrange(160..<164, with: "Test".utf8); env.replaceSubrange(164..<166, with: le(UInt16(1)))
        var track = Data(repeating: 0, count: 58); track.replaceSubrange(8..<12, with: le(UInt32(20)))
        var event = Data(repeating: 0, count: 96); event.replaceSubrange(0..<4, with: le(UInt32(0x24))); event.replaceSubrange(4..<8, with: le(UInt32(34_560))); event[0x14] = 1; event.replaceSubrange(0x2c..<0x30, with: le(UInt32(40))); event[80] = 0xf1
        // Logic's native Channel EQ: AuCU header, then size, flags, count, "GAMETSPP", subtype 0xec, 0, 52 floats.
        var values = [Float](repeating: 0, count: 52)
        let preset: [Float] = [0, 20, 2, 0.71, 1, 75, 0, 1, 1, 100, 0, 0.6, 1, 250, 0, 0.3, 1, 1000, 12, 1, 1, 2500, 0, 0.2, 1, 7500, 0, 1, 0, 20000, 4, 0.71]
        for (i, v) in preset.enumerated() { values[i] = v }
        values[41] = 1; values[42] = -1
        var block = Data(le(UInt32(240))) + Data(le(UInt32(1))) + Data(le(UInt32(52))) + Data("GAMETSPP".utf8) + Data(le(UInt32(0xec))) + Data(le(UInt32(0)))
        for v in values { block.append(contentsOf: le(v.bitPattern)) }
        var native = Data(repeating: 0, count: 172); native.replaceSubrange(0..<4, with: le(UInt32(0x1a8))); native.replaceSubrange(120..<130, with: "Channel EQ".utf8)
        native.replaceSubrange(140..<144, with: le(UInt32(0xec)))
        native.append(Data(repeating: 7, count: prefix)) // some records carry a knob-position table before the block
        native.append(block)
        var body = chunk("Envi", env, id: 20) + chunk("AuCO", Data(repeating: 0, count: 201), id: 36, sub: 0)
        body += chunk("AuCU", native, id: 36, sub: 0, kind: 2)
        body += chunk("AuFl", fl) + chunk("AuRg", region, id: 40) + chunk("MSeq", Data(repeating: 0, count: 8)) + chunk("Trak", track) + chunk("EvSq", Data(event.prefix(80)) + Data(repeating: 0, count: 16))
        var file = Data([0x23, 0x47, 0xc0, 0xab]); file.append(Data(repeating: 0, count: 12)); file.append(contentsOf: le(UInt64(body.count))); file.append(body)
        try file.write(to: alt.appendingPathComponent("ProjectData"))
        let (e, report) = try importInto(pkg.path); defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_at(e, 0)
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_count(e, t) == 1 && dalnok_track_plugin_info(e, t, 0, &info) == DALNOK_OK)
        #expect(info.loaded && name(info.name) == "Dalnok Channel EQ" && name(info.path) == "channel-eq", "\(name(info.name)) \(name(info.path))")
        var gain = DalnokPluginParameter(), freq = DalnokPluginParameter()
        for i in 0..<dalnok_plugin_parameter_count(e, info.id) {
            var p = DalnokPluginParameter()
            guard dalnok_plugin_parameter(e, info.id, i, &p) == DALNOK_OK else { continue }
            if p.id == 18 { gain = p }
            if p.id == 17 { freq = p }
        }
        #expect(abs(gain.value - 0.75) < 1e-9, "Peak 3 gain is +12 dB")   // -24…+24 dB
        #expect(abs(freq.value - log(1000.0 / 20) / log(1000.0)) < 1e-6, "Peak 3 frequency is 1 kHz")
        #expect(((report["skipped"] as? [String: Int])?["unsupportedLogicPlugins"] ?? 0) == 0)
        #expect((report["notes"] as? [String] ?? []).contains { $0.contains("converted to Dalnok Channel EQ") })
    }
    @Test func importsAudioUnitInstrumentOnMidiTrack() throws {
        let source = dalnok_engine_create(48_000)!; defer { dalnok_engine_destroy(source) }
        let sourceTrack = dalnok_track_add_instrument(source, "Source")
        let slot = dalnok_plugin_add(source, sourceTrack, "au:aumu:dls :appl", nil, nil, 0)
        #expect(slot != 0)
        let n = dalnok_plugin_get_state(source, slot, nil, 0)
        var encoded = [CChar](repeating: 0, count: n + 1)
        _ = dalnok_plugin_get_state(source, slot, &encoded, encoded.count)
        let binary = try #require(Data(base64Encoded: cstr(encoded)))
        let plist = try PropertyListSerialization.propertyList(from: binary, format: nil)
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let pkg = tempDir().appendingPathComponent("Instrument.logicx")
        let alt = pkg.appendingPathComponent("Alternatives/000")
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        var env = Data(repeating: 0, count: 220)
        env.replaceSubrange(158..<160, with: le(UInt16(4))); env.replaceSubrange(160..<164, with: "Keys".utf8)
        env.replaceSubrange(164..<166, with: le(UInt16(1)))
        var track = Data(repeating: 0, count: 58); track.replaceSubrange(8..<12, with: le(UInt32(20)))
        func line(_ a: UInt32, _ b: UInt32, _ c: UInt32 = 0, _ d: UInt32 = 0) -> Data { Data(le(a) + le(b) + le(c) + le(d)) }
        let end = line(0xf1, 0x3fff_ffff)
        let placement = line(0x20, 34_560) + line(0x80, 0x8900_0001, 0, 0x3fff_ffff) + line(104, 0x8800_0000)
            + line(0x600, 0x8a06_0000) + line(0, 0x8800_0000) + end
        var region = Data(repeating: 0, count: 180)
        region.replaceSubrange(16..<18, with: le(UInt16(4))); region.replaceSubrange(18..<22, with: "Keys".utf8)
        region.replaceSubrange(0x52..<0x56, with: le(UInt32(3_840)))
        var note = line(0x90, 38_400); note[11] = 120; note[12] = 60
        let notes = note + line(0x40, 0x8900_0000, 0, 960) + end
        var strip = Data(repeating: 0, count: 201) // unity fader, centre pan
        strip[85] = 0x5a; strip[89] = 64; strip.replaceSubrange(116..<120, with: le(UInt32(0x5a00_0000)))
        var body = chunk("Envi", env, id: 20) + chunk("AuCO", strip, id: 36, sub: 0)
        body += chunk("AuCU", component("DLS", type: "aumu", subtype: "dls ", manufacturer: "appl", xml: xml), id: 36, sub: 0, kind: 2)
        body += chunk("MSeq", Data(repeating: 0, count: 8)) + chunk("Trak", track) + chunk("EvSq", placement)
        body += chunk("MSeq", region, id: 104) + chunk("EvSq", notes, id: 104)
        var file = Data([0x23, 0x47, 0xc0, 0xab]); file.append(Data(repeating: 0, count: 12))
        file.append(contentsOf: le(UInt64(body.count))); file.append(body)
        try file.write(to: alt.appendingPathComponent("ProjectData"))
        let (e, _) = try importInto(pkg.path); defer { dalnok_engine_destroy(e) }
        let t = dalnok_track_at(e, 0)
        var info = DalnokPluginSlotInfo()
        #expect(dalnok_track_plugin_info(e, t, 0, &info) == DALNOK_OK && info.loaded && info.instrument && name(info.name) == "DLS")
        let sound = render(e, 0, 24_000)
        #expect(sound.contains { abs($0) > 0.005 }, "imported Audio Unit instrument renders the MIDI note")
    }

}
