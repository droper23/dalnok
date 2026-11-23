// Shared pieces of the window's side panels (View ▸ Library at the left, View ▸ Inspector at the right): the panel
// surface in each theme's idiom, section heads, and the inner edge that resizes the panel.
// Atelier: a ruled head with a serif title on the parchment, and the "Mathematics" plate's gold band on the umber.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

/// The surface of a side panel. `edge` is the side that meets the arrangement (it gets the rule or separator).
@MainActor
class SidePanelView: NSView {
    enum Edge { case left, right }
    let edge: Edge
    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let x = edge == .right ? bounds.maxX - 1 : bounds.minX
        switch Theme.look.mixer {
        case .glass:
            Prism.drawField(in: self, frosted: false)
            Prism.liquidPane(self, bounds.insetBy(dx: 4, dy: 4), radius: 16)
        case .instrument:
            Theme.panel.setFill(); bounds.fill()
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            // The panel stands apart from the drawing with a double rule, heavy then fine, as a plate's border does.
            let heavy = edge == .right ? bounds.maxX - 1 : bounds.minX + 1, fine = edge == .right ? bounds.maxX - 4 : bounds.minX + 4
            Atelier.rule(ctx, CGPoint(x: heavy, y: 0), CGPoint(x: heavy, y: bounds.height), weight: Atelier.medium)
            Atelier.rule(ctx, CGPoint(x: fine, y: 0), CGPoint(x: fine, y: bounds.height), weight: Atelier.hair)
        case .console:
            Analog.faceplate.setFill(); bounds.fill()
            NSColor.black.withAlphaComponent(0.22).setFill(); bounds.fill()
            Theme.separator.setFill(); NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        case .flat:
            Theme.panelRaised.setFill(); bounds.fill()
            Theme.separator.setFill(); NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

/// A section head: "Track", "Inserts", "Sends"…, with an optional italic kicker ("Channel") above it in Atelier.
@MainActor
final class PanelHead: NSView {
    let title: String
    var kicker: String? { didSet { needsDisplay = true } }
    /// Gold band (Atelier Dark), ruled head (Atelier Light), or a small-caps label (the other themes).
    private var band: Bool { Theme.look.mixer == .instrument && !Theme.palette.light }
    init(_ title: String, kicker: String? = nil) {
        self.title = title
        self.kicker = kicker
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    static var height: CGFloat { Theme.look.mixer == .instrument ? 30 : 22 }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if Theme.look.mixer == .instrument {
            if band {
                // The plate's band: flat ochre gold, the title set dark in the serif.
                Atelier.gold.setFill(); bounds.insetBy(dx: 0, dy: 3).fill()
                draw(title, font: Theme.title(15, .semibold), color: Theme.window, x: 10, baseline: bounds.height - 9)
                if let kicker { drawRight(kicker, font: Theme.note(11), color: Theme.window.withAlphaComponent(0.8)) }
            } else {
                draw(title, font: Theme.title(15, .semibold), color: Theme.text, x: 2, baseline: bounds.height - 9)
                if let kicker { drawRight(kicker, font: Theme.note(11), color: Theme.textDim) }
                Atelier.rule(ctx, CGPoint(x: 0, y: bounds.height - 3.5), CGPoint(x: bounds.width, y: bounds.height - 3.5), weight: Atelier.medium)
                Atelier.rule(ctx, CGPoint(x: 0, y: bounds.height - 1), CGPoint(x: bounds.width, y: bounds.height - 1), weight: Atelier.hair)
            }
            return
        }
        draw(title.uppercased(), font: Theme.ui(10, .semibold), color: Theme.textDim, x: 2, baseline: bounds.height - 7)
        Theme.hairline.setFill(); NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
    private func draw(_ s: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat) {
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (s as NSString).draw(at: NSPoint(x: x, y: baseline - font.ascender), withAttributes: a)
    }
    private func drawRight(_ s: String, font: NSFont, color: NSColor) {
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let w = (s as NSString).size(withAttributes: a).width
        (s as NSString).draw(at: NSPoint(x: bounds.width - w - (band ? 10 : 2), y: bounds.height - 9 - font.ascender), withAttributes: a)
    }
}

/// The panel's inner edge: drag to resize. Reports the new width while dragging and when the drag ends.
@MainActor
final class PanelResizeEdge: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    /// +1: dragging right widens the panel (the library); −1: dragging left widens it (the inspector).
    let direction: CGFloat
    private var start: (x: CGFloat, width: CGFloat)?
    var currentWidth: () -> CGFloat = { 0 }
    init(direction: CGFloat) {
        self.direction = direction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Drag to resize"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { start = (event.locationInWindow.x, currentWidth()) }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onDrag?(start.width + (event.locationInWindow.x - start.x) * direction)
    }
    override func mouseUp(with event: NSEvent) { start = nil; onEnd?() }
}
