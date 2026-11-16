// Visual identity tokens. Original palette: graphite surfaces, warm brass accent.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

enum Theme {
    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }

    static let window = hex(0x141518)
    static let panel = hex(0x1B1D21)
    static let panelRaised = hex(0x23262B)
    static let laneA = hex(0x18191D)
    static let laneB = hex(0x1C1E22)
    static let separator = hex(0x2C2F35)
    static let gridMajor = hex(0x2E3238)
    static let gridMinor = hex(0x22252A)
    static let text = hex(0xDCDEE3)
    static let textDim = hex(0x8A8F98)
    static let accent = hex(0xE3A857)   // brass
    static let playhead = hex(0xF0C066)

    static let trackPalette: [UInt32] = [0x4E9FA3, 0x8DB27E, 0xD69E58, 0xC7777C, 0x7D8ED0, 0xA68AD0, 0x6FB0C9, 0xC9B45E]
    static func trackColor(_ i: Int) -> NSColor { hex(trackPalette[i % trackPalette.count]) }

    static let rulerHeight: CGFloat = 30
    static let trackHeight: CGFloat = 96
    static let headerWidth: CGFloat = 232
    static let transportHeight: CGFloat = 52

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}
