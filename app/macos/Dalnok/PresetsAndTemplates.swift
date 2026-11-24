// User presets for any plug-in (Save Preset… / Presets ▸ in a unit's menu) and project templates (File ▸ Save as
// Template…, New from Template ▸): Logic's and Ableton's preset browsers and template / default-set workflows.
// Presets are the plug-in's own state in a small JSON file per preset; templates are ordinary projects.
// Folders: ~/Library/Application Support/Dalnok/Presets/<plug-in>/ and …/Templates/ (DALNOK_PRESETS_DIR and
// DALNOK_TEMPLATES_DIR override them, for tests).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import DalnokEngine

@MainActor enum UserLibrary {
    private static func base(_ env: String, _ name: String) -> URL {
        if let o = ProcessInfo.processInfo.environment[env], !o.isEmpty { return URL(fileURLWithPath: o, isDirectory: true) }
        return (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Dalnok/\(name)", isDirectory: true)
    }
    static func safe(_ s: String) -> String { String(s.map { "/:\\".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces) }

    // MARK: Presets
    static func presetFolder(_ plugin: String) -> URL { base("DALNOK_PRESETS_DIR", "Presets").appendingPathComponent(safe(plugin), isDirectory: true) }
    static func presets(_ plugin: String) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: presetFolder(plugin).path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    @discardableResult
    static func savePreset(_ engine: Engine, slot: Int32, plugin: String, name: String) -> Bool {
        let n = dalnok_plugin_get_state(engine.handle, slot, nil, 0)
        guard n > 0 else { return false }
        var buf = [CChar](repeating: 0, count: n + 1)
        _ = dalnok_plugin_get_state(engine.handle, slot, &buf, buf.count)
        let doc: [String: Any] = ["format": "dalnok-preset", "version": 1, "plugin": plugin, "state": String(cString: buf)]
        guard let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let folder = presetFolder(plugin)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? data.write(to: folder.appendingPathComponent(safe(name) + ".json"))) != nil
    }
    @discardableResult
    static func loadPreset(_ engine: Engine, slot: Int32, plugin: String, name: String) -> Bool {
        let url = presetFolder(plugin).appendingPathComponent(safe(name) + ".json")
        guard let data = try? Data(contentsOf: url), let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = doc["state"] as? String else { return false }
        return dalnok_plugin_set_state(engine.handle, slot, state) == DALNOK_OK
    }

    // MARK: Templates
    static var templateFolder: URL { base("DALNOK_TEMPLATES_DIR", "Templates") }
    static func templates() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: templateFolder.path)) ?? []
        return files.filter { $0.hasSuffix(".dalnok") }.map { String($0.dropLast(7)) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func templateURL(_ name: String) -> URL { templateFolder.appendingPathComponent(safe(name) + ".dalnok") }
}

/// Asks for a name (a sheet on `window`); nil when cancelled or empty.
@MainActor
func askName(_ title: String, _ message: String, initial: String, on window: NSWindow, _ done: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { resp in
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if resp == .alertFirstButtonReturn, !name.isEmpty { MainActor.assumeIsolated { done(name) } }
    }
}

extension DeviceView {
    /// The unit menu's preset items: Save Preset… and the saved ones.
    func presetMenuItems(_ m: NSMenu) {
        let plugin = pluginName
        m.addItem(ClosureMenuItem(title: "Save Preset…", action: { [weak self] in
            guard let self, let win = self.window else { return }
            askName("Save Preset", "A name for these settings of \(plugin):", initial: "", on: win) { name in
                let ok = UserLibrary.savePreset(self.session.engine, slot: self.slot, plugin: plugin, name: name)
                self.session.onMessage?(ok ? "Saved preset “\(name)”" : "Couldn't save the preset")
            }
        }))
        let names = UserLibrary.presets(plugin)
        let sub = NSMenu(title: "Presets")
        if names.isEmpty { let none = NSMenuItem(title: "No presets saved yet", action: nil, keyEquivalent: ""); none.isEnabled = false; sub.addItem(none) }
        for n in names {
            sub.addItem(ClosureMenuItem(title: n, action: { [weak self] in
                guard let self else { return }
                let ok = UserLibrary.loadPreset(self.session.engine, slot: self.slot, plugin: plugin, name: n)
                self.session.refresh()
                self.session.onMessage?(ok ? "Loaded preset “\(n)”" : "Couldn't load the preset")
            }))
        }
        let parent = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        parent.submenu = sub
        m.addItem(parent)
    }
}

extension MainWindowController {
    /// File ▸ Save as Template…: the project as it is, for new projects to start from (the project's own file and
    /// saved state are untouched).
    @objc func saveAsTemplate(_ sender: Any?) {
        guard let win = window else { return }
        askName("Save as Template", "New projects can start from this one (File ▸ New from Template).",
                initial: session.projectURL?.deletingPathExtension().lastPathComponent ?? "My Template", on: win) { [weak self] name in
            guard let self else { return }
            _ = self.saveTemplate(named: name)
        }
    }
    @discardableResult
    func saveTemplate(named name: String) -> Bool {
        try? FileManager.default.createDirectory(at: UserLibrary.templateFolder, withIntermediateDirectories: true)
        var err = [CChar](repeating: 0, count: 256)
        let ok = dalnok_project_save_snapshot(session.engine.handle, UserLibrary.templateURL(name).path, &err, err.count) == DALNOK_OK
        flash(ok ? "Saved template “\(name)”" : "Couldn't save the template: \(String(cString: err))")
        return ok
    }
    /// File ▸ New from Template ▸ <name>: an untitled project that starts as the template.
    @objc func newFromTemplate(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        confirmDiscard { [weak self] in self?.openTemplate(name) }
    }
    func openTemplate(_ name: String, completion: ((Bool) -> Void)? = nil) {
        openProject(UserLibrary.templateURL(name)) { [weak self] ok in
            guard let self else { return }
            if ok { self.session.projectURL = nil; self.updateTitle(); self.flash("New project from “\(name)”") }
            completion?(ok)
        }
    }
}

/// Fills File ▸ New from Template with the saved templates each time it opens.
@MainActor final class TemplateMenuFiller: NSObject, NSMenuDelegate {
    weak var target: AnyObject?
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let names = UserLibrary.templates()
        if names.isEmpty { let none = NSMenuItem(title: "No templates yet (File ▸ Save as Template…)", action: nil, keyEquivalent: ""); none.isEnabled = false; menu.addItem(none) }
        for n in names {
            let it = NSMenuItem(title: n, action: #selector(MainWindowController.newFromTemplate(_:)), keyEquivalent: "")
            it.representedObject = n
            it.target = target
            menu.addItem(it)
        }
    }
}
