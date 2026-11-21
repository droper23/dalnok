// Clip motion in the arrangement, in the spirit of FL Studio's lively playlist (the feel only; the design is Dalnok's):
//   - Picking a clip up lifts it off the lane (it grows a little and casts a deeper shadow).
//   - While dragged, the lifted clip follows the pointer on a spring, leaning into the direction it travels and
//     swinging back when it stops, while a ghost outline shows where it will land on the grid.
//   - Dropped, it glides onto the ghost and settles with a small squash and stretch.
//   - Clips that appear (paste, duplicate, record, import) pop in; deleted clips shrink and fade out.
// Everything follows Reduce Motion (Motion.reduced): then clips just move.
// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import QuartzCore

@MainActor
final class ClipLift {
    /// The lifted picture of the clip(s), in the timeline's layer.
    let layer = CALayer()
    private(set) var position: CGPoint      // the picture's centre now (follows `target` on a spring)
    private(set) var velocity = CGPoint.zero
    private(set) var lean: CGFloat = 0      // radians, positive leans right
    var target: CGPoint                     // where the pointer wants the centre
    private var timer: Timer?
    private var dropping = false
    static let liftScale: CGFloat = 1.045

    /// `image` is the clip(s) as drawn, `frame` their rect in the timeline (flipped, y down).
    init(image: CGImage, frame: CGRect, in host: CALayer, scale: CGFloat) {
        position = CGPoint(x: frame.midX, y: frame.midY)
        target = position
        layer.contents = image
        layer.contentsScale = scale
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = position
        layer.zPosition = 500
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 6) // the timeline is flipped: positive y is down
        layer.shadowRadius = 10
        layer.shadowOpacity = 0
        layer.cornerRadius = 3
        host.addSublayer(layer)
        // Lift: grow a little and raise the shadow.
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 1; grow.toValue = Self.liftScale
        grow.damping = 14; grow.stiffness = 320; grow.mass = 1
        grow.duration = grow.settlingDuration
        layer.add(grow, forKey: "lift")
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0; shadow.toValue = 0.45; shadow.duration = 0.14
        layer.add(shadow, forKey: "shadow")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(Self.liftScale, Self.liftScale, 1)
        layer.shadowOpacity = 0.45
        CATransaction.commit()
        let t = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One 120 Hz step of the follow spring: a stiff spring with damping, so fast moves overshoot a touch and the
    /// clip leans with its horizontal speed (like something carried by its top edge).
    private func step() {
        guard !dropping else { return }
        let k: CGFloat = 0.22, damping: CGFloat = 0.62
        velocity.x = (velocity.x + (target.x - position.x) * k) * damping
        velocity.y = (velocity.y + (target.y - position.y) * k) * damping
        position.x += velocity.x
        position.y += velocity.y
        let wanted = max(-0.09, min(0.09, velocity.x * 0.006)) // at most about 5 degrees
        lean += (wanted - lean) * 0.3
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.position = position
        var t = CATransform3DMakeScale(Self.liftScale, Self.liftScale, 1)
        t = CATransform3DRotate(t, lean, 0, 0, 1)
        layer.transform = t
        CATransaction.commit()
    }

    /// Glides onto `landing` (the clip's real place) and settles with a squash and stretch, then removes itself.
    func drop(onto landing: CGRect, done: @escaping () -> Void) {
        dropping = true
        timer?.invalidate(); timer = nil
        let end = CGPoint(x: landing.midX, y: landing.midY)
        let duration = 0.3
        let glide = CABasicAnimation(keyPath: "position")
        glide.fromValue = NSValue(point: position)
        glide.toValue = NSValue(point: end)
        glide.duration = duration * 0.55
        glide.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let squash = CAKeyframeAnimation(keyPath: "transform")
        let tilt = CATransform3DRotate(CATransform3DMakeScale(Self.liftScale, Self.liftScale, 1), lean, 0, 0, 1)
        squash.values = [tilt, CATransform3DMakeScale(1.06, 0.9, 1), CATransform3DMakeScale(0.98, 1.04, 1), CATransform3DIdentity]
            .map { NSValue(caTransform3D: $0) }
        squash.keyTimes = [0, 0.55, 0.8, 1]
        squash.duration = duration
        squash.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0.45; shadow.toValue = 0; shadow.duration = duration * 0.6
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.layer.removeFromSuperlayer(); done() } }
        layer.add(glide, forKey: "glide")
        layer.add(squash, forKey: "squash")
        layer.add(shadow, forKey: "shadowDrop")
        CATransaction.setDisableActions(true)
        layer.position = end
        layer.transform = CATransform3DIdentity
        layer.shadowOpacity = 0
        CATransaction.commit()
        position = end
    }

    /// Ends at once (Reduce Motion turned on mid-drag, the view went away, a new drag began).
    func cancel() {
        timer?.invalidate(); timer = nil
        layer.removeFromSuperlayer()
    }
}

@MainActor
enum ClipFlourish {
    /// A clip that just appeared pops in: from a little small, overshooting slightly, and fading up.
    static func pop(_ image: CGImage, frame: CGRect, in host: CALayer, scale: CGFloat) {
        let l = picture(image, frame: frame, in: host, scale: scale)
        let grow = CAKeyframeAnimation(keyPath: "transform.scale")
        grow.values = [0.82, 1.06, 0.99, 1]
        grow.keyTimes = [0, 0.5, 0.8, 1]
        grow.duration = 0.32
        grow.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeOut)]
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.16
        finish(l, [grow, fade], duration: 0.32)
    }

    /// A deleted clip shrinks towards its centre and fades, with a slight drop.
    static func poof(_ image: CGImage, frame: CGRect, in host: CALayer, scale: CGFloat) {
        let l = picture(image, frame: frame, in: host, scale: scale)
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: CATransform3DTranslate(CATransform3DMakeScale(0.7, 0.55, 1), 0, 8, 0))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        for a in [shrink, fade] { a.duration = 0.22; a.timingFunction = CAMediaTimingFunction(name: .easeIn); a.fillMode = .forwards; a.isRemovedOnCompletion = false }
        finish(l, [shrink, fade], duration: 0.22)
    }

    /// Layers currently animating (tests).
    static var active = 0

    private static func picture(_ image: CGImage, frame: CGRect, in host: CALayer, scale: CGFloat) -> CALayer {
        let l = CALayer()
        l.contents = image
        l.contentsScale = scale
        l.frame = frame
        l.zPosition = 400
        host.addSublayer(l)
        return l
    }
    private static func finish(_ l: CALayer, _ animations: [CAAnimation], duration: Double) {
        active += 1
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { l.removeFromSuperlayer(); active -= 1 } }
        for (i, a) in animations.enumerated() { l.add(a, forKey: "f\(i)") }
        CATransaction.commit()
    }
}
