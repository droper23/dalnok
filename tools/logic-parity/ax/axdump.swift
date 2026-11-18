import AppKit
import ApplicationServices
setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let pat = args.count > 1 ? args[1].lowercased() : ""
let maxDepth = args.count > 2 ? Int(args[2])! : 40
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.logic10").first
        ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.hasPrefix("Logic Pro") == true }) else { print("no logic"); exit(1) }
let root = AXUIElementCreateApplication(app.processIdentifier)
func attr(_ e: AXUIElement, _ a: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func s(_ o: AnyObject?) -> String? { guard let o else { return nil }; let t = "\(o)"; return t.isEmpty ? nil : t }
func walk(_ e: AXUIElement, _ d: Int) {
    if d > maxDepth { return }
    let role = s(attr(e, kAXRoleAttribute)) ?? "?"
    let parts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute].compactMap { s(attr(e, $0)) }
    let txt = parts.joined(separator: " | ")
    if !txt.isEmpty && (pat.isEmpty || txt.lowercased().contains(pat)) { print(String(repeating: " ", count: min(d, 14) * 2) + "\(role): \(txt)".prefix(220)) }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d + 1) }
}
for w in (attr(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { walk(w, 0) }
