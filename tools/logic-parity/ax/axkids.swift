import AppKit
import ApplicationServices
let pat = CommandLine.arguments[1]
let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.hasPrefix("Logic Pro") == true })!
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ a: String) -> String { attr(e, a).map { "\($0)" } ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func frame(_ e: AXUIElement) -> String {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return "" }
    var pt = CGPoint.zero, sz = CGSize.zero; AXValueGetValue(p as! AXValue, .cgPoint, &pt); AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return "(\(Int(pt.x)),\(Int(pt.y)) \(Int(sz.width))x\(Int(sz.height)))"
}
func walk(_ e: AXUIElement, _ d: Int) {
    let t = str(e, kAXTitleAttribute) + " " + str(e, kAXDescriptionAttribute)
    if t.contains(pat) {
        print(str(e, kAXRoleAttribute), t, frame(e))
        for c in kids(e) { print("   ", str(c, kAXRoleAttribute), str(c, kAXDescriptionAttribute), str(c, kAXTitleAttribute), str(c, kAXValueAttribute), frame(c)) }
        return
    }
    if d < 60 { for c in kids(e) { walk(c, d + 1) } }
}
for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
