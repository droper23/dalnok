// Generated Logic channel mixer fixtures: no owner project data.
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct LogicMixerImport {
    private func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    private func chunk(_ tag: String, _ payload: Data, id: UInt32 = 0, sub: UInt32 = 0) -> Data {
        var d = Data(tag.reversed().map { UInt8($0.asciiValue!) })
        var header = [UInt8](repeating: 0, count: 24)
        header.replaceSubrange(6..<10, with: le(id)); header.replaceSubrange(10..<14, with: le(sub))
        d.append(contentsOf: header); d.append(contentsOf: le(UInt64(payload.count))); d.append(payload)
        return d
    }
    private func env(_ title: String, channel: UInt16) -> Data {
        let name = Array(title.utf8), padded = (name.count + 1) & ~1
        var d = Data(repeating: 0, count: 200 + padded)
        d.replaceSubrange(158..<160, with: le(UInt16(name.count)))
        d.replaceSubrange(160..<(160 + name.count), with: name)
        d.replaceSubrange((160 + padded)..<(162 + padded), with: le(channel))
        return d
    }
    private func channel(gain: Double, pan: UInt8, mute: Bool) -> Data {
        var d = Data(repeating: 0, count: 201)
        let raw: UInt32 = gain.isFinite ? UInt32((Double(0x5a000000) * pow(10, gain / 40)).rounded()) : 0
        d[85] = UInt8(raw >> 24); d[89] = pan; d[90] = mute ? 1 : 0
        d.replaceSubrange(116..<120, with: le(raw))
        return d
    }
    @Test func importsMixerValuesAndRendersGain() throws {
        let pkg = tempDir().appendingPathComponent("Generated.logicx")
        let alt = pkg.appendingPathComponent("Alternatives/000"), folder = pkg.appendingPathComponent("Media/Audio Files")
        try FileManager.default.createDirectory(at: alt, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples = try writeTestWav(folder.appendingPathComponent("generated.wav"), frames: 48_000)
        var file = Data(repeating: 0, count: 8)
        let fileName = "generated.wav"; file.append(contentsOf: le(UInt16(fileName.utf16.count)))
        for c in fileName.utf16 { file.append(contentsOf: le(c)) }
        var region = Data(repeating: 0, count: 120)
        region.replaceSubrange(22..<26, with: le(UInt32(48_000)))
        var tr1 = Data(repeating: 0, count: 58), tr2 = tr1, tr3 = tr1
        tr1.replaceSubrange(8..<12, with: le(UInt32(20))); tr2.replaceSubrange(8..<12, with: le(UInt32(24)))
        tr3.replaceSubrange(8..<12, with: le(UInt32(28)))
        func placement(_ row: UInt8) -> Data {
            var d = Data(repeating: 0, count: 80)
            d.replaceSubrange(0..<4, with: le(UInt32(0x24))); d.replaceSubrange(4..<8, with: le(UInt32(34_560)))
            d[0x14] = row; d.replaceSubrange(0x2c..<0x30, with: le(UInt32(40)))
            return d
        }
        let end = Data(le(UInt32(0xf1)) + le(UInt32(0x3fff_ffff)) + [UInt8](repeating: 0, count: 8))
        var body = chunk("Envi", env("A", channel: 1), id: 20) + chunk("Envi", env("Bee", channel: 2), id: 24)
        body += chunk("Envi", env("C", channel: 3), id: 28)
        body += chunk("AuCO", channel(gain: -8, pan: 64, mute: false), id: 1, sub: 0)
        body += chunk("AuCO", channel(gain: -15, pan: 96, mute: true), id: 1, sub: 1)
        body += chunk("AuCO", channel(gain: -.infinity, pan: 0, mute: false), id: 1, sub: 2)
        body += chunk("AuFl", file) + chunk("AuRg", region, id: 40) + chunk("MSeq", Data(repeating: 0, count: 8))
        body += chunk("Trak", tr1) + chunk("Trak", tr2) + chunk("Trak", tr3)
        body += chunk("EvSq", placement(1) + placement(2) + placement(3) + end)
        var data = Data([0x23, 0x47, 0xc0, 0xab]); data.append(Data(repeating: 0, count: 12))
        data.append(contentsOf: le(UInt64(body.count))); data.append(body)
        try data.write(to: alt.appendingPathComponent("ProjectData"))
        let (e, report) = try importInto(pkg.path); defer { dalnok_engine_destroy(e) }
        #expect(dalnok_track_count(e) == 3)
        var a = DalnokTrackInfo(), b = a, c = a
        #expect(dalnok_track_info(e, dalnok_track_at(e, 0), &a) == DALNOK_OK)
        #expect(dalnok_track_info(e, dalnok_track_at(e, 1), &b) == DALNOK_OK)
        #expect(dalnok_track_info(e, dalnok_track_at(e, 2), &c) == DALNOK_OK)
        #expect(abs(a.gain_db - -8) < 1e-4 && abs(a.pan) < 1e-6 && !a.muted)
        #expect(abs(b.gain_db - -15) < 1e-4 && abs(b.pan - (32.0 / 63.0)) < 1e-6 && b.muted)
        #expect(c.gain_db == -.infinity && abs(c.pan - -1) < 1e-6 && !c.muted)
        #expect(skipped(report, "logicUnmappedTrackMix") == 0)
        let audio = render(e, 0, 48_000)
        for i in [4_000, 8_000, 12_000, 16_000] {
            #expect(abs(audio[i] - samples[i] * Float(pow(10.0, -8.0 / 20.0))) < 1e-4, "only the unmuted -8 dB track should sound")
        }
    }
}
