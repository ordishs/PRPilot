import Testing
import Foundation
@testable import PRPilotModels

private let trail = ["a", "b", "c", "d"]

@Test func oneTapGoesToPreviousTicket() {
    var s = TrailSwitcher()

    #expect(s.handle(.tab, trail: trail) == .none)
    #expect(s.highlight == 1)
    #expect(s.handle(.controlReleased, trail: trail) == .commit(itemID: "b"))
    #expect(!s.isOpen)
}

@Test func twoJumpsToggleTwoTickets() {
    var s = TrailSwitcher()
    _ = s.handle(.tab, trail: ["a", "b", "c"])

    #expect(s.handle(.controlReleased, trail: ["a", "b", "c"]) == .commit(itemID: "b"))

    _ = s.handle(.tab, trail: ["b", "a", "c"])

    #expect(s.handle(.controlReleased, trail: ["b", "a", "c"]) == .commit(itemID: "a"))
}

@Test func threeTapsReachTheFourthEntry() {
    var s = TrailSwitcher()
    for _ in 1...3 { _ = s.handle(.tab, trail: trail) }

    #expect(s.handle(.controlReleased, trail: trail) == .commit(itemID: "d"))
}

@Test func shiftTabStepsBackAndWraps() {
    var s = TrailSwitcher()
    _ = s.handle(.tab, trail: trail)
    _ = s.handle(.shiftTab, trail: trail)

    #expect(s.highlight == 0)

    _ = s.handle(.shiftTab, trail: trail)

    #expect(s.highlight == 3)

    _ = s.handle(.tab, trail: trail)

    #expect(s.highlight == 0)
}

@Test func releaseOnCurrentTicketCommitsNothing() {
    var s = TrailSwitcher()
    _ = s.handle(.tab, trail: trail)
    _ = s.handle(.shiftTab, trail: trail)

    #expect(s.handle(.controlReleased, trail: trail) == .none)
    #expect(!s.isOpen)
}

@Test func escapeClosesWithNoCommit() {
    var s = TrailSwitcher()
    _ = s.handle(.tab, trail: trail)

    #expect(s.handle(.escape, trail: trail) == .none)
    #expect(!s.isOpen)
    #expect(s.handle(.controlReleased, trail: trail) == .none)
}

@Test func shortTrailNeverOpens() {
    var s = TrailSwitcher()

    #expect(s.handle(.tab, trail: ["a"]) == .none)
    #expect(s.handle(.shiftTab, trail: []) == .none)
    #expect(!s.isOpen)
}

@Test func orderHoldsWhileOpen() {
    var s = TrailSwitcher()
    _ = s.handle(.tab, trail: trail)
    _ = s.handle(.tab, trail: ["z", "y"])

    #expect(s.ids == trail)
    #expect(s.handle(.controlReleased, trail: ["z", "y"]) == .commit(itemID: "c"))
}

@Test func shiftTabFromClosedStartsAtTheOldest() {
    var s = TrailSwitcher()
    _ = s.handle(.shiftTab, trail: trail)

    #expect(s.highlight == 3)
}
