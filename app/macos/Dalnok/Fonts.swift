// Bundled theme typefaces (SIL OFL 1.1; licences in Resources/Fonts, listed in 04 - Research/Licensing.md).
// Registered once for this process at launch. Missing files fall back to the system faces, so a theme never fails
// to draw for want of a font.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreText

enum BundledFonts {
    nonisolated(unsafe) private(set) static var registered: [String] = [] // PostScript names, main thread only

    /// The Fonts folder: inside the app bundle, or SwiftPM's resource bundle next to the executable (swift run, tests).
    static var directory: URL? {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Fonts")) }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            let b = exe.appendingPathComponent("Dalnok_Dalnok.bundle")
            candidates += [b.appendingPathComponent("Fonts"), b.appendingPathComponent("Contents/Resources/Fonts")]
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Sora-Regular.ttf").path) }
    }

    static func registerAll() {
        guard registered.isEmpty, let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in files where url.pathExtension == "ttf" {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                for d in descs { if let n = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String { registered.append(n) } }
            }
        }
    }

    /// A bundled face by PostScript name, or nil when it isn't available.
    static func font(_ postScript: String, _ size: CGFloat) -> NSFont? { NSFont(name: postScript, size: size) }
}
