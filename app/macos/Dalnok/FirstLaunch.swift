// First launch: one question — which app's keyboard shortcuts do you already know? — and then out of the way.
// No tour and no shortcut lessons: someone who knows Logic's or Pro Tools' keys is trusted to use them. The choice is a
// shortcut preset (Settings ▸ Keyboard Shortcuts can change it at any time); bringing projects over stays in
// Help ▸ Migration Assistant and on the new project screen.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class ShortcutChooserController: NSObject {
    let window: NSWindow
    /// The presets offered, in the order people are most likely to come from (Dalnok's own is the quiet last choice).
    static let offered = ["logic", "ableton", "protools", "cubase", "studioone", "reaper"]
    private(set) var cards: [StartCard] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to Dalnok"
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.panel
        window.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Which keyboard shortcuts do you know?")
        title.font = Theme.ui(22, .semibold)
        title.textColor = Theme.text
        let sub = NSTextField(wrappingLabelWithString: "Dalnok will use them. You can change this any time in Settings ▸ Keyboard Shortcuts.")
        sub.font = Theme.ui(13)
        sub.textColor = Theme.textDim
        cards = Self.offered.map { id in
            let preset = ShortcutPreset.named(id)
            let c = StartCard(title: preset.title, detail: "Use \(preset.title)'s shortcuts", symbol: "keyboard", target: self, action: #selector(picked(_:)))
            c.identifier = NSUserInterfaceItemIdentifier(id)
            return c
        }
        let grid = NSGridView(views: stride(from: 0, to: cards.count, by: 2).map { Array(cards[$0..<min($0 + 2, cards.count)]) })
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        let own = NSButton(title: "", target: self, action: #selector(picked(_:)))
        own.identifier = NSUserInterfaceItemIdentifier("dalnok")
        own.isBordered = false
        own.attributedTitle = NSAttributedString(string: "None of these: use Dalnok's own →",
                                                 attributes: [.font: Theme.ui(13, .medium), .foregroundColor: Theme.accent])
        own.setAccessibilityLabel("Use Dalnok's own shortcuts")
        let note = NSTextField(wrappingLabelWithString: "Each set approximates that app's documented macOS defaults where Dalnok has the same command.")
        note.font = Theme.ui(11)
        note.textColor = Theme.textFaint
        let stack = NSStackView(views: [title, sub, grid, own, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: sub)
        stack.setCustomSpacing(16, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 24, right: 32)
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = Theme.panel.cgColor
        bg.appearance = Theme.appearance
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: bg.bottomAnchor),
            sub.widthAnchor.constraint(equalToConstant: 580),
        ])
        window.contentView = bg
    }

    func show() { showCentered(window) }

    @objc private func picked(_ sender: NSButton) { choose(sender.identifier?.rawValue ?? "dalnok") }

    /// Applies the preset and gets out of the way.
    func choose(_ presetId: String) {
        let r = ShortcutRegistry.shared
        if r.actions.isEmpty { r.attach(NSApp.mainMenu) }
        r.selectPreset(presetId)
        // Logic, Ableton and REAPER also lend their words to the command palette and concept guide.
        SourceDAW.preferred = SourceDAW(rawValue: presetId)
        WelcomeController.hasCompleted = true
        window.orderOut(nil)
    }
}
