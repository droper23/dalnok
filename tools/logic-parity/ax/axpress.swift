import AppKit
import ApplicationServices
// axpress "<container description prefix>" "<child description>" [action]
let a = CommandLine.arguments
let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.hasPrefix("Logic Pro") == true })!
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ k: String) -> String { attr(e, k).map { "\($0)" } ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
var done = false
func walk(_ e: AXUIElement, _ d: Int) {
    if done { return }
    if (str(e, kAXDescriptionAttribute) + str(e, kAXTitleAttribute)).hasPrefix(a[1]) {
        func desc(_ x: AXUIElement, _ d: Int) -> [AXUIElement] { d > 30 ? [] : kids(x).flatMap { [$0] + desc($0, d + 1) } }
        for c in desc(e, 0) where str(c, kAXDescriptionAttribute) == a[2] || str(c, kAXTitleAttribute) == a[2] {
            var acts: CFArray?; AXUIElementCopyActionNames(c, &acts)
            let act = a.count > 3 ? a[3] : kAXPressAction
            print("actions", acts as? [String] ?? [], "->", AXUIElementPerformAction(c, act as CFString).rawValue, "value now", str(c, kAXValueAttribute)); done = true; return
        }
    }
    if d < 60 { for c in kids(e) { walk(c, d + 1) } }
}
for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
if !done { print("not found") }
