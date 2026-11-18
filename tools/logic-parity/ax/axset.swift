import AppKit
import ApplicationServices
// axset "<descendant description or title>" "<value>"   (first match in focused window)
let a = CommandLine.arguments
let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.hasPrefix("Logic Pro") == true })!
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ k: String) -> String { attr(e, k).map { "\($0)" } ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func desc(_ x: AXUIElement, _ d: Int) -> [AXUIElement] { d > 40 ? [] : kids(x).flatMap { [$0] + desc($0, d + 1) } }
let w = attr(root, kAXFocusedWindowAttribute) as! AXUIElement
guard let el = desc(w, 0).first(where: { str($0, kAXDescriptionAttribute) == a[1] || str($0, kAXTitleAttribute) == a[1] }) else { print("not found"); exit(1) }
AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, a[2] as CFString)
AXUIElementPerformAction(el, "AXConfirm" as CFString)
print("set", r.rawValue, "now", str(el, kAXValueAttribute))
