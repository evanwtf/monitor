import AppKit
import QuartzCore
import SwiftUI

/// A gauge hand — the needle or the peak mark — turned by Core Animation.
///
/// It replaced an animatable `Shape` (#69). SwiftUI interpolates an animatable
/// shape on the main thread, once per display frame, and while any animation is
/// running it also re-evaluates the view graph around it. The needle's travel
/// time is the sampling interval, so on a one-second clock there is always an
/// animation running: ten gauges held a dashboard of charts at 40% of a core,
/// all of it spent redrawing between samples. A `CABasicAnimation` is run by
/// the render server instead, so the main thread wakes once per sample and the
/// hand still sweeps rather than jumping.
///
/// The hand is drawn once, pointing at the start of the dial, and turned by the
/// layer's rotation. Only the rotation animates; a resize redraws the path
/// with actions off, so the hand never animates its length.
struct DialHand: NSViewRepresentable {
    /// Position on the dial, 0...1.
    var fraction: Double
    /// Where the hand starts and ends, as fractions of the dial radius. A
    /// negative start is a tail behind the pivot.
    var from: Double
    var to: Double
    var color: Color
    /// Stroke width for a given dial radius.
    var lineWidth: (Double) -> Double
    var lineCap: CAShapeLayerLineCap
    var travelTime: TimeInterval

    func makeNSView(context _: Context) -> DialHandView {
        DialHandView()
    }

    func updateNSView(_ view: DialHandView, context _: Context) {
        view.configure(
            from: from, to: to, color: NSColor(color), lineWidth: lineWidth, lineCap: lineCap
        )
        view.turn(to: fraction, over: travelTime)
    }
}

final class DialHandView: NSView {
    private let container = CALayer()
    /// Internal rather than private so the tests can read its animation.
    let hand = CAShapeLayer()
    private var from = 0.0
    private var to = 0.0
    private var lineWidth: (Double) -> Double = { _ in 1 }

    /// The rotation the hand is heading for, and the one it left from. Kept
    /// here rather than read back from the presentation layer: the dial sweeps
    /// 240°, and `transform.rotation.z` read from a transform comes back folded
    /// into ±180°, which would send an interrupted hand the long way round.
    private var target = 0.0
    private var origin = 0.0
    private var started = 0.0
    private var duration = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // y-down inside the container, as in SwiftUI, so the angles below are
        // the same angles the face is drawn with.
        container.isGeometryFlipped = true
        hand.fillColor = nil
        hand.lineCap = .round
        container.addSublayer(hand)
        layer?.addSublayer(container)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The tile under the gauge takes the drag that reorders it, so the hand
    /// must never be the thing a click lands on.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func configure(
        from: Double,
        to: Double,
        color: NSColor,
        lineWidth: @escaping (Double) -> Double,
        lineCap: CAShapeLayerLineCap
    ) {
        let changed = from != self.from || to != self.to
        self.from = from
        self.to = to
        self.lineWidth = lineWidth
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hand.strokeColor = color.cgColor
        hand.lineCap = lineCap
        CATransaction.commit()
        if changed { needsLayout = true }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        let radius = min(bounds.width, bounds.height) / 2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        hand.bounds = CGRect(origin: .zero, size: bounds.size)
        hand.position = center
        hand.lineWidth = lineWidth(radius)
        let start = GaugeGeometry.dialStart.radians
        let mid = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        func point(_ distance: Double) -> CGPoint {
            CGPoint(x: mid.x + distance * cos(start), y: mid.y + distance * sin(start))
        }
        let path = CGMutablePath()
        path.move(to: point(radius * from))
        path.addLine(to: point(radius * to))
        hand.path = path
        CATransaction.commit()
    }

    /// Where the hand is now, on the curve it is travelling.
    private func current(at now: Double) -> Double {
        guard duration > 0 else { return target }
        let progress = min(1, max(0, (now - started) / duration))
        // Ease-out, matching the animation's timing closely enough that an
        // interruption does not visibly jump.
        let eased = 1 - (1 - progress) * (1 - progress)
        return origin + (target - origin) * eased
    }

    func turn(
        to fraction: Double, over travelTime: TimeInterval, now: Double = CACurrentMediaTime()
    ) {
        let angle = GaugeGeometry.dialSweep.radians * min(1, max(0, fraction))
        guard angle != target else { return }
        let from = current(at: now)
        origin = from
        target = angle
        started = now
        duration = window == nil ? 0 : travelTime

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hand.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        guard duration > 0 else {
            hand.removeAnimation(forKey: "turn")
            return
        }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = from
        animation.toValue = angle
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hand.add(animation, forKey: "turn")
    }
}
