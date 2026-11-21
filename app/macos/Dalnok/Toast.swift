// Toast: a short heads-up display at the bottom of the arrangement that names what just happened ("Undo Move Clip",
// "Saved"), the way Final Cut Pro and Figma confirm invisible actions. It rises and fades in, holds, then fades out;
// a new toast replaces the one showing. It never takes clicks or focus.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class ToastView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    /// The text currently shown (empty when hidden); the self-test reads it.
    private(set) var text = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Theme.hex(0x101114, 0.92).cgColor
        layer?.borderColor = Theme.hex(0xFFFFFF, 0.10).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.masksToBounds = false
        icon.contentTintColor = Theme.accent
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        label.font = Theme.ui(13, .semibold)
        label.textColor = Theme.text
        shortcut.font = Theme.ui(11, .medium)
        shortcut.textColor = Theme.textFaint
        let row = NSStackView(views: [icon, label, shortcut])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        alphaValue = 0
        isHidden = true
        setAccessibilityElement(false) // the same message is announced, see `show`
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `message` for `seconds`. `symbol` is an SF Symbol; `keys` a shortcut hint shown dimmed after the text.
    func show(_ message: String, symbol: String, keys: String = "", seconds: Double = 1.4) {
        text = message
        label.stringValue = message
        shortcut.stringValue = keys
        shortcut.isHidden = keys.isEmpty
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        hideWork?.cancel()
        let wasShowing = !isHidden && alphaValue > 0.5
        isHidden = false
        superview?.layoutSubtreeIfNeeded()
        Motion.centerAnchor(layer)
        if !Motion.reduced, let layer {
            if wasShowing {
                Motion.bounce(layer, scale: 1.04, duration: 0.16) // a repeat (undo, undo…) nudges instead of re-entering
            } else {
                let rise = CASpringAnimation(keyPath: "transform.translation.y")
                rise.fromValue = -14 // flipped superview not assumed: AppKit layer y grows upward
                rise.toValue = 0
                rise.damping = 16
                rise.stiffness = 260
                rise.duration = rise.settlingDuration
                layer.add(rise, forKey: "rise")
                let grow = CASpringAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.94
                grow.toValue = 1
                grow.damping = 16
                grow.stiffness = 260
                grow.duration = grow.settlingDuration
                layer.add(grow, forKey: "grow")
            }
        }
        Motion.views(Motion.quick) { animator().alphaValue = 1 }
        if let win = window ?? NSApp.mainWindow {
            NSAccessibility.post(element: win, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        text = ""
        Motion.views(Motion.gentle, { self.animator().alphaValue = 0 }, completion: { [weak self] in
            DispatchQueue.main.async { if self?.text.isEmpty == true { self?.isHidden = true } }
        })
    }
}

/// The count-in, big over the arrangement: each beat's number punches in and fades, so a player can watch it from
/// across the room instead of reading the small display.
@MainActor
final class CountInOverlay: NSView {
    private let number = CATextLayer()
    private(set) var shown: Int?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        number.alignmentMode = .center
        number.font = NSFont.monospacedDigitSystemFont(ofSize: 120, weight: .heavy)
        number.fontSize = 120
        number.foregroundColor = Theme.hex(0xFF4D4D).cgColor
        number.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        number.opacity = 0
        number.shadowColor = Theme.hex(0xFF2020).cgColor
        number.shadowRadius = 24
        number.shadowOpacity = 0.55
        number.shadowOffset = .zero
        layer?.addSublayer(number)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        number.frame = CGRect(x: 0, y: bounds.midY - 75, width: bounds.width, height: 150)
        CATransaction.commit()
    }
    /// Shows beat `n` (counting down); nil hides it. `beat` is the beat's length, for the fade.
    func show(_ n: Int?, beat seconds: Double) {
        guard n != shown else { return }
        shown = n
        guard let n else { number.removeAllAnimations(); number.opacity = 0; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        number.string = "\(n)"
        number.opacity = Motion.reduced ? 0.85 : 0
        CATransaction.commit()
        guard !Motion.reduced else { return }
        Motion.centerAnchor(number)
        let punch = CAKeyframeAnimation(keyPath: "transform.scale")
        punch.values = [1.35, 0.97, 1]
        punch.keyTimes = [0, 0.35, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.95, 0.8, 0]
        fade.keyTimes = [0, 0.4, 1]
        for a in [punch, fade] as [CAKeyframeAnimation] {
            a.duration = max(0.25, seconds * 0.95)
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            number.add(a, forKey: a.keyPath)
        }
    }
}
