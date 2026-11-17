// Empty project: a real drop zone with the three things people want to do.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class EmptyStateView: NSView {
    var onImportAudio: (() -> Void)?
    var onOpen: (() -> Void)?
    var onMigrate: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let cfg = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
        let icon = NSImageView(image: NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!)
        icon.contentTintColor = Theme.textFaint
        let title = NSTextField(labelWithString: "Drop audio files here")
        title.font = Theme.ui(17, .semibold)
        title.textColor = Theme.text
        let sub = NSTextField(labelWithString: "Each file becomes a track. Logic, Ableton and REAPER projects can be dropped too.")
        sub.font = Theme.ui(12)
        sub.textColor = Theme.textDim
        func button(_ title: String, _ key: String, _ sel: Selector, primary: Bool = false) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.toolTip = key
            if primary { b.keyEquivalent = "\r"; b.bezelColor = Theme.accent.withAlphaComponent(0.85) }
            return b
        }
        let buttons = NSStackView(views: [
            button("Import Audio…", "⌘I", #selector(importTapped), primary: false),
            button("Open Project…", "⌘O", #selector(openTapped)),
            button("Migration Assistant…", "", #selector(migrateTapped)),
        ])
        buttons.spacing = 10
        let stack = NSStackView(views: [icon, title, sub, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: sub)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Dashed drop zone.
        let r = bounds.insetBy(dx: 28, dy: 28)
        let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        path.lineWidth = 1.5
        path.setLineDash([6, 5], count: 2, phase: 0)
        Theme.hex(0xFFFFFF, 0.10).setStroke()
        path.stroke()
    }

    // Let drags pass through to the window's drop view.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }

    @objc private func importTapped() { onImportAudio?() }
    @objc private func openTapped() { onOpen?() }
    @objc private func migrateTapped() { onMigrate?() }
}
