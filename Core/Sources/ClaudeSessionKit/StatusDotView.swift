import AppKit
import QuartzCore

/// A small round status dot that can pulse to signal live work.
///
/// The pulse runs as a Core Animation animation on the layer, not as a SwiftUI
/// `repeatForever` animation. A SwiftUI animation keeps the sidebar's hosting view in a
/// render cycle for as long as it repeats, and every cycle re-runs the layout of the whole
/// row tree. Core Animation interpolates the opacity on the render server instead, so the
/// main thread does no work between status changes and the app can go idle.
public final class StatusDotView: NSView {
    static let pulseKey = "prpilot.statusdot.pulse"

    /// Opacity at the dim end of the pulse.
    public static let dimOpacity: Float = 0.3

    /// One dim-and-back cycle takes twice this, because the pulse autoreverses.
    public static let pulseHalfCycleSeconds: CFTimeInterval = 0.7

    public var dotColor: NSColor = .clear {
        didSet { applyColor() }
    }

    public var isPulsing: Bool = false {
        didSet {
            guard isPulsing != oldValue else { return }
            applyPulse()
        }
    }

    /// True while the layer carries the pulse.
    public var hasPulseAnimation: Bool {
        layer?.animation(forKey: Self.pulseKey) != nil
    }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("StatusDotView is created in code, never from a nib")
    }

    public override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    /// A layer drops its animations when its view leaves the window, and a `List` detaches
    /// rows as they scroll out of view. Re-attach the pulse on every move so a working row
    /// still pulses after it scrolls back in.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPulse()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = dotColor.cgColor
        }
    }

    private func applyPulse() {
        guard let layer else { return }
        guard isPulsing else {
            layer.removeAnimation(forKey: Self.pulseKey)
            layer.opacity = 1
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Float(1)
        fade.toValue = Self.dimOpacity
        fade.duration = Self.pulseHalfCycleSeconds
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: Self.pulseKey)
    }
}
