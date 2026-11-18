import AppKit
import ApplicationServices
let x = Float(CommandLine.arguments[1])!, y = Float(CommandLine.arguments[2])!
var el: AXUIElement?
let r = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), x, y, &el)
func str(_ e: AXUIElement, _ a: String) -> String { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? "\(v!)" : "" }
var pid: pid_t = 0
if let el { AXUIElementGetPid(el, &pid); print(r.rawValue, pid, NSRunningApplication(processIdentifier: pid)?.localizedName ?? "", str(el, kAXRoleAttribute), str(el, kAXDescriptionAttribute), str(el, kAXTitleAttribute)) } else { print("none", r.rawValue) }
for s in NSScreen.screens { print("screen", s.frame) }
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
for w in (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as! [[String: Any]]).prefix(8) { print(w[kCGWindowOwnerName as String] ?? "", w[kCGWindowLayer as String] ?? "", w[kCGWindowBounds as String] ?? "") }
