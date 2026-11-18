import AppKit
import ApplicationServices
let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.hasPrefix("Logic Pro") == true })!
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ k: String) -> String { attr(e, k).map { "\($0)" } ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func dump(_ e: AXUIElement, _ d: Int) {
    print(String(repeating: "  ", count: d) + str(e, kAXRoleAttribute), str(e, kAXTitleAttribute), str(e, kAXDescriptionAttribute), str(e, kAXValueAttribute).prefix(200))
    if d < 6 { for c in kids(e) { dump(c, d + 1) } }
}
for k in [kAXFocusedWindowAttribute, kAXMainWindowAttribute, "AXFocusedUIElement"] { if let w = attr(root, k) { print("==", k); dump(w as! AXUIElement, 0) } }
for c in kids(root) where str(c, kAXRoleAttribute) != "AXMenuBar" { print("== child"); dump(c, 0) }
