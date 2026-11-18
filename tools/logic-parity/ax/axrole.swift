import AppKit
import ApplicationServices
// axrole <role> [index] [action]  — act on the n-th element with that role in the focused window
let a = CommandLine.arguments
let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.hasPrefix("Logic Pro") == true })!
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func desc(_ x: AXUIElement, _ d: Int) -> [AXUIElement] { d > 40 ? [] : kids(x).flatMap { [$0] + desc($0, d + 1) } }
let w = attr(root, kAXFocusedWindowAttribute) as! AXUIElement
let els = desc(w, 0).filter { (attr($0, kAXRoleAttribute) as? String) == a[1] }
let i = a.count > 2 ? Int(a[2])! : 0
print(els.count, "found; action", AXUIElementPerformAction(els[i], (a.count > 3 ? a[3] : kAXPressAction) as CFString).rawValue)
