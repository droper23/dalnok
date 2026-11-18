import AppKit
import ApplicationServices
let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.hasPrefix("Logic Pro") == true })!
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ a: String) -> String { attr(e, a).map { "\($0)" } ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func walk(_ e: AXUIElement, _ d: Int) {
    if str(e, kAXRoleAttribute) == "AXLayoutItem" && str(e, kAXDescriptionAttribute).hasPrefix("Track ") {
        var names: CFArray?; AXUIElementCopyAttributeNames(e, &names)
        print(str(e, kAXDescriptionAttribute), "selected=", str(e, "AXSelected"), (names as? [String])?.joined(separator: ",") ?? "")
        return
    }
    if d < 60 { for c in kids(e) { walk(c, d + 1) } }
}
for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
print("trusted", AXIsProcessTrusted())
