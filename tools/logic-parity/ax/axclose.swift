import AppKit
import ApplicationServices
let title = CommandLine.arguments[1]
let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.hasPrefix("Logic Pro") == true })!
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where (attr(w, kAXTitleAttribute) as? String) == title {
    var acts: CFArray?; AXUIElementCopyActionNames(w, &acts)
    let close = attr(w, kAXCloseButtonAttribute)
    print("actions", acts as? [String] ?? [], "close btn", close != nil, "subrole", attr(w, kAXSubroleAttribute) ?? "")
    if let c = close { print("press close", AXUIElementPerformAction(c as! AXUIElement, kAXPressAction as CFString).rawValue) }
    else { print("cancel", AXUIElementPerformAction(w, kAXCancelAction as CFString).rawValue) }
}
