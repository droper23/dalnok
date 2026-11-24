// First launch: two questions, then out of the way. First the look (the owner: "the onboarding should include asking
// you which theme you want"): a card per theme with a picture of it, Light or Dark for the themes that have both, and
// every choice applied at once, so the whole app (this window included) is already in the look being considered.
// Then: which app's keyboard shortcuts do you already know? No tour and no shortcut lessons: someone who knows Logic's
// or Pro Tools' keys is trusted to use them. Both stay changeable in Settings; bringing projects over stays in
// Help ▸ Migration Assistant and on the new project screen.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

@MainActor
final class ShortcutChooserController: NSObject, NSWindowDelegate {
    static let shared = ShortcutChooserController()
    /// Runs once when the questions are answered or the window is closed (the crash-recovery offer waits for it, so it
    /// never opens over this window and hides it).
    var onFinished: (() -> Void)?
    let window: NSWindow
    /// The presets offered, in the order people are most likely to come from (Dalnok's own is the quiet last choice).
    static let offered = ["logic", "ableton", "protools", "cubase", "studioone", "reaper"]
    enum Step { case look, shortcuts }
    private(set) var step: Step = .look
    private(set) var cards: [StartCard] = []
    private(set) var lookCards: [LookCard] = []

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.autorecalculatesKeyViewLoop = true // Tab follows the layout (keyboard-only use)
        super.init()
        window.title = "Welcome to Dalnok"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    /// Closing the window answers the questions with what is chosen so far (asked again from Settings ▸ General, never
    /// at every launch).
    func windowWillClose(_ notification: Notification) { WelcomeController.hasCompleted = true; step = .look; finished() }
    private func finished() { let f = onFinished; onFinished = nil; f?() }

    /// Opens on the look; `step` skips to a later question (Help ▸ Welcome reopens at the shortcuts).
    func show(at step: Step = .look) {
        self.step = step
        build()
        showCentered(window)
    }

    /// Builds the current step in the active theme (again after each look change).
    private func build() {
        window.appearance = Theme.appearance
        window.backgroundColor = Theme.panel
        cards = makeShortcutCards()
        let content = step == .look ? lookStep() : shortcutStep()
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = Theme.panel.cgColor
        if Theme.activeStyle == .prism {
            bg.layer?.backgroundColor = NSColor.clear.cgColor
            let back = PrismBackdropView(frame: .zero)
            back.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(back)
            NSLayoutConstraint.activate([back.leadingAnchor.constraint(equalTo: bg.leadingAnchor), back.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
                                         back.topAnchor.constraint(equalTo: bg.topAnchor), back.bottomAnchor.constraint(equalTo: bg.bottomAnchor)])
        }
        bg.appearance = Theme.appearance
        content.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: bg.leadingAnchor), content.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            content.topAnchor.constraint(equalTo: bg.topAnchor), content.bottomAnchor.constraint(lessThanOrEqualTo: bg.bottomAnchor),
        ])
        window.contentView = bg
        if window.isVisible { Motion.pageIn(content) }
        window.setContentSize(step == .look ? NSSize(width: 990, height: 470) : NSSize(width: 660, height: 420))
        if Theme.activeStyle == .atelier { Atelier.unifyFonts(in: bg) }
        Theme.tintControls(in: bg) // rebuilt while the window is key: tint now, not at the next key change
    }

    private func heading(_ title: String, _ sub: String) -> [NSView] {
        let t = NSTextField(labelWithString: title)
        t.font = Theme.activeStyle == .atelier ? Theme.title(24, .semibold) : Theme.ui(22, .semibold)
        t.textColor = Theme.text
        let s = NSTextField(wrappingLabelWithString: sub)
        s.font = Theme.activeStyle == .atelier ? Theme.title(13) : Theme.ui(13)
        s.textColor = Theme.textDim
        s.preferredMaxLayoutWidth = 580
        return [t, s]
    }

    // MARK: Step 1: the look

    private func lookStep() -> NSView {
        lookCards = Theme.Style.allCases.map { style in
            let c = LookCard(style: style, variant: style == Theme.activeStyle ? Theme.activeVariant : Theme.resolvedVariant(for: style))
            c.isSelected = style == Theme.activeStyle
            c.onPick = { [weak self] s, v in self?.chooseLook(s, v) }
            return c
        }
        let row = NSStackView(views: lookCards)
        row.spacing = 14
        row.alignment = .top
        let next = NSButton(title: "Continue", target: self, action: #selector(continueTapped))
        next.keyEquivalent = "\r"
        next.bezelStyle = .rounded
        next.setAccessibilityLabel("Continue to keyboard shortcuts")
        let foot = NSStackView(views: [label("You can change the look any time in Settings ▸ Appearance."), NSView(), next])
        foot.orientation = .horizontal
        let stack = NSStackView(views: heading("Choose a look", "Each look is the whole app: the arrangement, the mixer, the plug-ins. Pick one to see it now.") + [row, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(22, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(22, after: row)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 24, right: 32)
        foot.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return stack
    }
    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = Theme.activeStyle == .atelier ? Theme.title(12) : Theme.ui(11)
        l.textColor = Theme.textFaint
        return l
    }

    /// Applies a look at once: the preference, then the app's windows rebuilt in it (this one kept and redrawn).
    func chooseLook(_ style: Theme.Style, _ variant: Theme.Variant) {
        Theme.preferredStyle = style
        if style.variants.count > 1 { Theme.variantPreference = variant.rawValue }
        if style != Theme.activeStyle || variant != Theme.activeVariant {
            _ = (NSApp.delegate as? AppDelegate)?.switchTheme(to: style, variant: variant, keeping: [window])
        }
        build()
        window.makeKeyAndOrderFront(nil)
    }
    @objc func continueTapped() {
        step = .shortcuts
        build()
        showCentered(window)
    }

    // MARK: Step 2: shortcuts

    private func makeShortcutCards() -> [StartCard] {
        Self.offered.map { id in
            let preset = ShortcutPreset.named(id)
            let c = StartCard(title: preset.title, detail: "Use \(preset.title)'s shortcuts", symbol: "keyboard", target: self, action: #selector(picked(_:)))
            c.identifier = NSUserInterfaceItemIdentifier(id)
            return c
        }
    }
    private func shortcutStep() -> NSView {
        let grid = NSGridView(views: stride(from: 0, to: cards.count, by: 2).map { Array(cards[$0..<min($0 + 2, cards.count)]) })
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        let own = NSButton(title: "", target: self, action: #selector(picked(_:)))
        own.identifier = NSUserInterfaceItemIdentifier("dalnok")
        own.isBordered = false
        own.attributedTitle = NSAttributedString(string: "None of these: use Dalnok's own →",
                                                 attributes: [.font: Theme.ui(13, .medium), .foregroundColor: Theme.accentText])
        own.setAccessibilityLabel("Use Dalnok's own shortcuts")
        let note = NSTextField(wrappingLabelWithString: "Each set approximates that app's documented macOS defaults where Dalnok has the same command.")
        note.font = Theme.ui(11)
        note.textColor = Theme.textFaint
        let stack = NSStackView(views: heading("Which keyboard shortcuts do you know?", "Dalnok will use them. You can change this any time in Settings ▸ Keyboard Shortcuts.") + [grid, own, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(16, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 24, right: 32)
        return stack
    }

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
        step = .look
        finished()
    }
}

/// A theme on the first-launch page: its picture (a capture of the generated demo project), name and one line; Light |
/// Dark below for the themes that have both. Picking the card or a version applies it.
@MainActor
final class LookCard: NSView, KeyOwner {
    let style: Theme.Style
    private(set) var variant: Theme.Variant
    var onPick: ((Theme.Style, Theme.Variant) -> Void)?
    var isSelected = false { didSet { needsDisplay = true; setAccessibilityValue(isSelected ? "selected" : nil) } }
    let versions: NSSegmentedControl?
    private let picture = LookPicture()
    static let size = NSSize(width: 204, height: 128)

    init(style: Theme.Style, variant: Theme.Variant) {
        self.style = style
        self.variant = variant
        versions = style.variants.count > 1 ? NSSegmentedControl(labels: ["Dark", "Light"], trackingMode: .selectOne, target: nil, action: nil) : nil
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(style.title) look")
        setAccessibilityHelp(style.summary)
        picture.image = Self.image(style, variant)
        picture.wantsLayer = true
        picture.layer?.cornerRadius = style == .atelier ? 0 : 6
        picture.layer?.masksToBounds = true
        let name = NSTextField(labelWithString: style.title)
        name.font = Theme.activeStyle == .atelier ? Theme.title(15, .semibold) : Theme.ui(14, .semibold)
        name.textColor = Theme.text
        let line = NSTextField(wrappingLabelWithString: style.summary)
        line.font = Theme.activeStyle == .atelier ? Theme.title(12) : Theme.ui(11.5)
        line.textColor = Theme.textDim
        line.preferredMaxLayoutWidth = Self.size.width
        var views: [NSView] = [picture, name, line]
        if let versions {
            versions.selectedSegment = variant == .dark ? 0 : 1
            versions.target = self
            versions.action = #selector(versionChosen)
            versions.controlSize = .small
            versions.setAccessibilityLabel("\(style.title): dark or light")
            views.append(versions)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 10, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            picture.widthAnchor.constraint(equalToConstant: Self.size.width), picture.heightAnchor.constraint(equalToConstant: Self.size.height),
            heightAnchor.constraint(equalToConstant: 268),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// The bundled picture of a look (Resources/Looks, regenerated with the README stills).
    static func image(_ style: Theme.Style, _ variant: Theme.Variant) -> NSImage? {
        let stem: String = switch style {
        case .graphite: "graphite"
        case .warmAnalog: "warm-analog"
        case .prism: variant == .light ? "prism-light" : "prism-dark"
        case .atelier: variant == .light ? "atelier-light" : "atelier-dark"
        }
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Looks")) }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            dirs.append(exe.appendingPathComponent("Dalnok_Dalnok.bundle/Looks"))
            dirs.append(exe.appendingPathComponent("Dalnok_Dalnok.bundle/Contents/Resources/Looks"))
        }
        for d in dirs { if let i = NSImage(contentsOf: d.appendingPathComponent(stem + ".jpg")) { return i } }
        return nil
    }

    override func mouseDown(with event: NSEvent) { onPick?(style, variant) }
    // Keyboard: Tab reaches each card; Space or Return picks it (the menu leaves those keys to it).
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled && !isHiddenOrHasHiddenAncestor }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    func ownsKey(_ event: NSEvent) -> Bool { window?.firstResponder === self && [36, 49, 76].contains(event.keyCode) }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { onPick?(style, variant) } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onPick?(style, variant); return true }
    @objc private func versionChosen() {
        variant = versions?.selectedSegment == 1 ? .light : .dark
        onPick?(style, variant)
    }
    override func draw(_ dirtyRect: NSRect) {
        defer {
            if window?.firstResponder === self {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                let f = NSBezierPath(rect: bounds.insetBy(dx: 2.5, dy: 2.5)); f.lineWidth = 2; f.stroke()
            }
        }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        if Theme.activeStyle == .atelier, let ctx = NSGraphicsContext.current?.cgContext {
            if isSelected { Theme.laneHighlight.setFill(); r.fill() }
            Atelier.box(ctx, r, weight: isSelected ? Atelier.heavy : Atelier.fine, color: isSelected ? Atelier.gold : Theme.ink(0.5))
            return
        }
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        (isSelected ? Theme.ink(0.08) : Theme.ink(0.03)).setFill(); path.fill()
        (isSelected ? Theme.accent : Theme.ink(0.12)).setStroke(); path.lineWidth = isSelected ? 2 : 1; path.stroke()
    }
}

/// A look's picture, drawn (not an image control: the card is the control, the picture decoration).
@MainActor
final class LookPicture: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { Theme.ink(0.06).setFill(); bounds.fill(); return }
        let s = image.size, k = min(bounds.width / max(1, s.width), bounds.height / max(1, s.height))
        let r = NSRect(x: (bounds.width - s.width * k) / 2, y: (bounds.height - s.height * k) / 2, width: s.width * k, height: s.height * k)
        image.draw(in: r)
    }
}
