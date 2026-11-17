// Read-only plugin discovery (Phase 4 step 1).
// SPDX-License-Identifier: GPL-3.0-or-later
import DalnokEngine
import Foundation
import Testing

@Suite struct PluginDiscovery {
    func scan(_ extra: URL?, audioUnits: Bool) -> [[String: Any]] {
        let n = dalnok_plugins_scan(extra?.path, audioUnits, nil, 0)
        var buf = [CChar](repeating: 0, count: n + 1)
        dalnok_plugins_scan(extra?.path, audioUnits, &buf, buf.count)
        return (try? JSONSerialization.jsonObject(with: Data(cstr(buf).utf8))) as? [[String: Any]] ?? []
    }

    @Test func readsVst3ModuleInfoAndBundleMetadataWithoutLoading() throws {
        let dir = tempDir()
        let synth = dir.appendingPathComponent("Fake Synth.vst3/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: synth, withIntermediateDirectories: true)
        // moduleinfo.json as shipped by the VST3 SDK: trailing commas, and a ", ]" inside a string.
        try """
        {
          "Name": "Fake, ]Synth",
          "Version": "1.2.3",
          "Factory Info": { "Vendor": "Dalnok Tests", "Flags": { "Unicode": true, }, },
          "Classes": [
            { "Category": "Audio Module Class", "Name": "Fake", "Sub Categories": [ "Instrument", "Synth", ], },
          ],
        }
        """.write(to: synth.appendingPathComponent("moduleinfo.json"), atomically: true, encoding: .utf8)
        let effect = dir.appendingPathComponent("Vendor/Fake Delay.vst3/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: effect, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        <key>CFBundleName</key><string>Fake Delay</string><key>CFBundleShortVersionString</key><string>2.0</string></dict></plist>
        """.write(to: effect.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        // A bundle nested inside another bundle is not a separate plugin.
        try FileManager.default.createDirectory(at: effect.appendingPathComponent("Resources/Inner.vst3"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Fake Clap.clap/Contents"), withIntermediateDirectories: true)

        let found = scan(dir, audioUnits: false).filter { ($0["path"] as? String ?? "").hasPrefix(dir.path) }
        #expect(found.count == 3, "\(found.map { $0["name"] ?? "" })")
        let s = found.first { $0["format"] as? String == "vst3" && ($0["name"] as? String) == "Fake, ]Synth" }
        #expect(s?["kind"] as? String == "instrument" && s?["vendor"] as? String == "Dalnok Tests" && s?["version"] as? String == "1.2.3")
        let d = found.first { $0["name"] as? String == "Fake Delay" }
        #expect(d?["kind"] as? String == "unknown" && d?["version"] as? String == "2.0") // no moduleinfo: needs a sandboxed scan
        #expect(found.contains { $0["format"] as? String == "clap" && $0["name"] as? String == "Fake Clap" })
    }

    @Test func listsRegisteredAudioUnitsByType() {
        let units = scan(nil, audioUnits: true).filter { $0["format"] as? String == "au" }
        // Every macOS install registers Apple's effects (e.g. AUDelay).
        #expect(units.contains { $0["vendor"] as? String == "Apple" && $0["kind"] as? String == "effect" && ($0["name"] as? String ?? "").contains("Delay") })
        #expect(units.contains { $0["kind"] as? String == "instrument" }) // Apple's DLSMusicDevice
        #expect(units.allSatisfy { ["instrument", "effect", "midi"].contains($0["kind"] as? String ?? "") })
    }
}
