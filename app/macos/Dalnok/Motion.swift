// Motion: short, purposeful animations shared by every control. All of them respect
// System Settings ▸ Accessibility ▸ Display ▸ Reduce Motion (then state changes are instant,
// and pulses become a steady highlight). Durations follow the knob reveal (0.16 s ease-out).
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import QuartzCore

@MainActor
enum Motion {
    static let quick = 0.12, standard = 0.16, gentle = 0.24
    /// Self-tests and screenshots force motion on or off; otherwise follow the system setting.
    static var override: Bool?
    static var reduced: Bool { override.map { !$0 } ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Implicit layer animations inside `body` (instant when motion is reduced).
    static func layers(_ duration: Double = standard, timing: CAMediaTimingFunctionName = .easeOut, _ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(reduced)
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: timing))
        body()
        CATransaction.commit()
    }

    /// NSView animator changes (alpha, frames) inside `body`.
    static func views(_ duration: Double = standard, _ body: () -> Void, completion: (@Sendable () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduced ? 0 : duration
            ctx.allowsImplicitAnimation = !reduced
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            body()
        }, completionHandler: completion)
    }

    /// A slow breathing opacity pulse (recording indicators). Removed with `stopPulse`.
    static func pulse(_ layer: CALayer?, from: Float = 1, to: Float = 0.35, period: Double = 1.0) {
        guard let layer, layer.animation(forKey: "pulse") == nil, !reduced else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = period / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "pulse")
    }
    static func stopPulse(_ layer: CALayer?) { layer?.removeAnimation(forKey: "pulse") }

    /// Warm lamp filaments catch quickly and cool gradually. Start at the visible brightness
    /// so rapid state changes continue smoothly instead of restarting from an endpoint.
    static func filament(_ layer: CALayer, from brightness: Float, lit: Bool) {
        layer.removeAnimation(forKey: "filament")
        guard !reduced else { return }
        let a = CAKeyframeAnimation(keyPath: "shadowOpacity")
        a.values = lit ? [brightness, 1, 0.85] : [brightness, brightness * 0.45, 0]
        a.keyTimes = lit ? [0, 0.25, 1] : [0, 0.45, 1]
        a.duration = lit ? 0.18 : 0.38
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeOut)]
        layer.add(a, forKey: "filament")
    }

    /// A quick scale "tick" (metronome beats, confirmations). Scales around the layer's center.
    static func bounce(_ layer: CALayer?, scale: CGFloat = 1.18, duration: Double = 0.18) {
        guard let layer, !reduced else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, scale, 1]
        a.keyTimes = [0, 0.3, 1]
        a.duration = duration
        a.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        layer.add(a, forKey: "bounce")
    }

    /// Cross-fades a layer's next content change (text, image, color).
    static func fadeNextChange(_ layer: CALayer?, duration: Double = quick) {
        guard let layer, !reduced else { return }
        let t = CATransition()
        t.type = .fade
        t.duration = duration
        layer.add(t, forKey: "fade")
    }

    /// Draws a new patch cable, seats its plug, and lets its curve settle under gravity.
    static func connectCable(_ cable: CAShapeLayer, plug: CALayer, paths: [CGPath]) {
        guard !reduced else { return }
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.35
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cable.add(draw, forKey: "plug")
        let settle = CAKeyframeAnimation(keyPath: "path")
        settle.values = paths
        settle.keyTimes = [0, 0.48, 0.72, 0.88, 1]
        settle.duration = 0.65
        settle.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        cable.add(settle, forKey: "settle")
        let seat = CAKeyframeAnimation(keyPath: "transform.translation.x")
        seat.values = [-12, -12, 1.5, 0]
        seat.keyTimes = [0, 0.6, 0.85, 1]
        seat.duration = 0.5
        plug.add(seat, forKey: "seat")
    }

    /// Centers a layer's anchor point without moving it, so scale animations grow from the middle.
    static func centerAnchor(_ layer: CALayer?) {
        guard let layer, layer.anchorPoint != CGPoint(x: 0.5, y: 0.5) else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.frame = frame
    }
}
