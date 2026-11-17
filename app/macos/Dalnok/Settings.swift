// Application settings. Appearance changes take effect at the next launch.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class SettingsController: NSWindowController {
    let themePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let copyAudio = NSButton(checkboxWithTitle: "Copy audio into the project folder when saving", target: nil, action: nil)
    let appearanceNote = NSTextField(wrappingLabelWithString: "")
    let relaunch = NSButton(title: "Relaunch Now", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.panel.cgColor
        window.contentView = content
        let title = NSTextField(labelWithString: "Make Dalnok yours")
        title.font = Theme.ui(21, .semibold)
        title.textColor = Theme.text
        let intro = NSTextField(labelWithString: "Choose the look and how your projects keep audio.")
        intro.font = Theme.ui(12)
        intro.textColor = Theme.textDim
        let appearance = NSTextField(labelWithString: "APPEARANCE")
        appearance.font = Theme.mono(10, .semibold)
        appearance.textColor = Theme.textDim
        themePicker.addItems(withTitles: Theme.Style.allCases.map(\.title))
        themePicker.target = self; themePicker.action = #selector(themeChanged(_:))
        themePicker.setAccessibilityLabel("Appearance theme")
        appearanceNote.font = Theme.ui(11)
        appearanceNote.textColor = Theme.textDim
        let projects = NSTextField(labelWithString: "PROJECTS")
        projects.font = Theme.mono(10, .semibold)
        projects.textColor = Theme.textDim
        copyAudio.target = self; copyAudio.action = #selector(copyChanged(_:))
        copyAudio.toolTip = "Keeps saved projects easier to move between computers."
        relaunch.bezelStyle = .rounded
        relaunch.controlSize = .small
        relaunch.target = self; relaunch.action = #selector(relaunchTapped(_:))
        relaunch.toolTip = "Quit and reopen Dalnok with the new appearance (you'll be asked to save changes first)"
        let note = NSStackView(views: [appearanceNote, relaunch])
        note.spacing = 8
        let stack = NSStackView(views: [title, intro, appearance, themePicker, note, projects, copyAudio])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: intro)
        stack.setCustomSpacing(16, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            themePicker.widthAnchor.constraint(equalToConstant: 220),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
    private func refresh() {
        themePicker.selectItem(at: Theme.Style.allCases.firstIndex(of: Theme.preferredStyle) ?? 0)
        copyAudio.state = MainWindowController.copyAudioOnSave ? .on : .off
        appearanceNote.stringValue = Theme.preferredStyle == Theme.activeStyle
            ? "Graphite is crisp and focused. Warm Analog brings a softer studio palette."
            : "The appearance changes when recording stops, or relaunch now."
        relaunch.isHidden = Theme.preferredStyle == Theme.activeStyle
    }
    @objc func relaunchTapped(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.relaunchOnQuit = true
        NSApp.terminate(nil) // a cancelled save prompt clears the flag (AppDelegate.applicationShouldTerminate)
    }
    @objc func themeChanged(_ sender: Any?) {
        let i = themePicker.indexOfSelectedItem
        guard Theme.Style.allCases.indices.contains(i) else { return }
        Theme.preferredStyle = Theme.Style.allCases[i]
        // Live: the windows rebuild in the new style (while recording, the change waits for a relaunch).
        _ = (NSApp.delegate as? AppDelegate)?.switchTheme(to: Theme.preferredStyle)
        refresh()
    }
    @objc func copyChanged(_ sender: Any?) {
        MainWindowController.copyAudioOnSave = copyAudio.state == .on
    }
}
