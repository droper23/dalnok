import AppKit
import ApplicationServices
// axparam "<label>" [list|set N]  — Logic plug-in Controls view: find the slider after the static text "<label>:"
let a = CommandLine.arguments
let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.hasPrefix("Logic Pro") == true })!
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ k: String) -> String { attr(e, k).map { "\($0)" } ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func flat(_ e: AXUIElement, _ d: Int = 0) -> [AXUIElement] { d > 40 ? [] : [e] + kids(e).flatMap { flat($0, d + 1) } }
var all: [AXUIElement] = []
for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where str(w, kAXTitleAttribute) != "meas.logicx - Tracks" { all += flat(w) }
guard let li = all.firstIndex(where: { str($0, kAXRoleAttribute) == "AXStaticText" && str($0, kAXValueAttribute) == a[1] + ":" }) else { print("label not found"); exit(1) }
let after = all[(li + 1)...].prefix(12)
guard let slider = after.first(where: { str($0, kAXRoleAttribute) == "AXSlider" }) else { print("no slider"); exit(1) }
let texts = after.prefix(3).filter { str($0, kAXRoleAttribute) == "AXGroup" }
func show() -> String { texts.map { str($0, kAXValueAttribute) + str($0, kAXDescriptionAttribute) }.joined(separator: "|") }
let mode = a.count > 2 ? a[2] : "list"
if mode == "set" { AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: Int(a[3])!)); usleep(150_000); print(str(slider, kAXValueAttribute), show()) }
else if mode == "steps" {
    for _ in 0..<140 { AXUIElementPerformAction(slider, kAXDecrementAction as CFString) }
    usleep(300_000)
    for i in 0...Int(a[3])! { print(i, str(slider, kAXValueAttribute), show()); AXUIElementPerformAction(slider, kAXIncrementAction as CFString); usleep(60_000) }
} else if mode == "table" {
    let lo = Int(a[3])!, hi = Int(a[4])!
    for i in lo...hi { AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: i)); usleep(120_000); print(i, str(slider, kAXValueAttribute), show()) }
} else { print("value", str(slider, kAXValueAttribute), "min", str(slider, kAXMinValueAttribute), "max", str(slider, kAXMaxValueAttribute), "texts", show()) }
