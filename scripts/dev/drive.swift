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
func pt(_ i: Int) -> CGPoint { CGPoint(x: Double(a[i])!, y: Double(a[i + 1])!) }
switch a.first ?? "" {
case "click":
    let p = pt(1), f = flags(a.count > 3 ? a[3] : nil)
    mouse(.mouseMoved, p); mouse(.leftMouseDown, p, .left, f); mouse(.leftMouseUp, p, .left, f)
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
    mouse(.mouseMoved, p0); mouse(.leftMouseDown, p0, .left, f)
    for k in 1...20 {
        let t = Double(k) / 20
        mouse(.leftMouseDragged, CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t), .left, f)
    }
    mouse(.leftMouseUp, p1, .left, f)
case "key":
    let code = CGKeyCode(a[1])!, f = flags(a.count > 2 ? a[2] : nil)
    let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = f; post(d)
    let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = f; post(u)
case "type":
    for ch in a[1].utf16 {
        var c = ch
        let d = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true); d?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(d)
        let u = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false); u?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c); post(u)
    }
case "scroll":
    let p = pt(1); mouse(.mouseMoved, p)
    post(CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: Int32(a[3])!, wheel2: Int32(a.count > 4 ? a[4] : "0")!, wheel3: 0))
default: print("usage: see header"); exit(2)
}
