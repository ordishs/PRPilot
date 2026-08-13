import Testing
import AppKit
import QuartzCore
@testable import ClaudeSessionKit

@Test @MainActor func aDotThatIsNotWorkingCarriesNoAnimation() {
    let dot = StatusDotView()

    #expect(dot.hasPulseAnimation == false)
    #expect(dot.layer?.opacity == 1)
}

@Test @MainActor func pulsingAttachesARepeatingOpacityAnimation() {
    let dot = StatusDotView()

    dot.isPulsing = true

    let fade = dot.layer?.animation(forKey: StatusDotView.pulseKey) as? CABasicAnimation
    #expect(fade != nil)
    #expect(fade?.keyPath == "opacity")
    #expect(fade?.autoreverses == true)
    #expect(fade?.repeatCount == .infinity)
    #expect(fade?.duration == StatusDotView.pulseHalfCycleSeconds)
    #expect((fade?.fromValue as? NSNumber)?.floatValue == 1)
    #expect((fade?.toValue as? NSNumber)?.floatValue == StatusDotView.dimOpacity)
}

@Test @MainActor func endingTheWorkRemovesThePulseAndRestoresFullOpacity() {
    let dot = StatusDotView()
    dot.isPulsing = true

    dot.isPulsing = false

    #expect(dot.hasPulseAnimation == false)
    #expect(dot.layer?.opacity == 1)
}

@Test @MainActor func settingTheSamePulseStateTwiceDoesNotRestartTheAnimation() {
    let dot = StatusDotView()
    dot.isPulsing = true
    let first = dot.layer?.animation(forKey: StatusDotView.pulseKey)

    dot.isPulsing = true

    #expect(dot.layer?.animation(forKey: StatusDotView.pulseKey) === first)
}

@Test @MainActor func thePulseComesBackWhenTheRowReturnsToAWindow() {
    let dot = StatusDotView()
    dot.isPulsing = true
    // What AppKit does to the layer when the view leaves its window.
    dot.layer?.removeAllAnimations()
    #expect(dot.hasPulseAnimation == false)

    dot.viewDidMoveToWindow()

    #expect(dot.hasPulseAnimation)
}

@Test @MainActor func aDotThatIsNotWorkingStaysUnanimatedWhenItReturnsToAWindow() {
    let dot = StatusDotView()

    dot.viewDidMoveToWindow()

    #expect(dot.hasPulseAnimation == false)
}

@Test @MainActor func theDotIsRound() {
    let dot = StatusDotView()
    dot.frame = NSRect(x: 0, y: 0, width: 8, height: 8)

    dot.layout()

    #expect(dot.layer?.cornerRadius == 4)
}

@Test @MainActor func theDotPaintsTheColourItIsGiven() {
    let dot = StatusDotView()
    let blue = NSColor(srgbRed: 0, green: 0.4, blue: 1, alpha: 1)

    dot.dotColor = blue

    #expect(dot.layer?.backgroundColor == blue.cgColor)
}
