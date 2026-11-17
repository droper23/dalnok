// Posts real OS-level mouse and keyboard events (needs Accessibility access; the screen must be unlocked).
// Build: swiftc -O scripts/dev/drive.swift -o .build/drive. Pair with DALNOK_WINDOW_DUMP to see the result.
// SPDX-License-Identifier: GPL-3.0-or-later
// drive <cmd> ...: click x y [mods] | hold x y seconds | dclick x y | rclick x y | drag x1 y1 x2 y2 [mods] | key code [mods] | type text | scroll x y dy
// mods: comma list of cmd,shift,opt,ctrl. Coordinates are global screen points (top-left origin).
import CoreGraphics
import Foundation
let a = Array(CommandLine.arguments.dropFirst())
func flags(_ s: String?) -> CGEventFlags {
    var f: CGEventFlags = []
    for m in (s ?? "").split(separator: ",") {
        switch m { case "cmd": f.insert(.maskCommand); case "shift": f.insert(.maskShift)
        case "opt": f.insert(.maskAlternate); case "ctrl": f.insert(.maskControl); default: break }
    }
    return f
}
let src = CGEventSource(stateID: .hidSystemState)
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap); usleep(12_000) }
func mouse(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton = .left, _ f: CGEventFlags = [], clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: b)
    e?.flags = f; e?.setIntegerValueField(.mouseEventClickState, value: clicks); post(e)
}
/// Presses the modifier keys for `f` (like a hand on the keyboard), runs `body`, then releases them, so the
/// system never believes a modifier is still held afterwards.
func withModifiers(_ f: CGEventFlags, _ body: () -> Void) {
    let keys: [(CGEventFlags, CGKeyCode)] = [(.maskControl, 59), (.maskAlternate, 58), (.maskShift, 56), (.maskCommand, 55)]
    var held: CGEventFlags = []
    for (m, code) in keys where f.contains(m) {
        held.insert(m)
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); e?.type = .flagsChanged; e?.flags = held; post(e)
    }
    body()
    for (m, code) in keys.reversed() where f.contains(m) {
        held.remove(m)
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); e?.type = .flagsChanged; e?.flags = held; post(e)
    }
}
func pt(_ i: Int) -> CGPoint { CGPoint(x: Double(a[i])!, y: Double(a[i + 1])!) }
switch a.first ?? "" {
case "click":
    let p = pt(1), f = flags(a.count > 3 ? a[3] : nil)
    withModifiers(f) { mouse(.mouseMoved, p); mouse(.leftMouseDown, p, .left, f); mouse(.leftMouseUp, p, .left, f) }
case "hold": // hold x y seconds: press, keep the button down, release
    let p = pt(1), secs = Double(a[3]) ?? 1
    mouse(.mouseMoved, p); mouse(.leftMouseDown, p); usleep(useconds_t(secs * 1_000_000)); mouse(.leftMouseUp, p)
case "dclick":
    let p = pt(1); mouse(.mouseMoved, p)
    mouse(.leftMouseDown, p); mouse(.leftMouseUp, p); mouse(.leftMouseDown, p, clicks: 2); mouse(.leftMouseUp, p, clicks: 2)
case "rclick":
    let p = pt(1); mouse(.mouseMoved, p); mouse(.rightMouseDown, p, .right); mouse(.rightMouseUp, p, .right)
case "drag":
    let p0 = pt(1), p1 = pt(3), f = flags(a.count > 5 ? a[5] : nil)
    withModifiers(f) {
        mouse(.mouseMoved, p0); mouse(.leftMouseDown, p0, .left, f)
        for k in 1...20 {
            let t = Double(k) / 20
            mouse(.leftMouseDragged, CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t), .left, f)
        }
        mouse(.leftMouseUp, p1, .left, f)
    }
case "key":
    let code = CGKeyCode(a[1])!, f = flags(a.count > 2 ? a[2] : nil)
    withModifiers(f) {
        let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = f; post(d)
        let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = f; post(u)
    }
case "type":
    // Real key codes (US layout) for letters, digits and space, so the app sees what a keyboard sends; other
    // characters fall back to key code 0 with the text attached.
    let codes: [Character: CGKeyCode] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25,
        "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49]
    for ch in a[1] {
        let lower = Character(ch.lowercased())
        let code = codes[lower] ?? 0
        let shift: CGEventFlags = ch.isUppercase ? .maskShift : []
        var units = Array(String(ch).utf16)
        let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = shift
        if codes[lower] == nil { d?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units) }
        post(d)
        let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = shift
        if codes[lower] == nil { u?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units) }
        post(u)
    }
case "scroll":
    let p = pt(1); mouse(.mouseMoved, p)
    post(CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(a[3])!, wheel2: Int32(a.count > 4 ? a[4] : "0")!, wheel3: 0))
default: print("usage: see header"); exit(2)
}
// Never leave a modifier looking held (earlier versions could latch ⌘ for the whole system).
for code: CGKeyCode in [55, 56, 58, 59] { let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); e?.type = .flagsChanged; e?.flags = []; post(e) }
