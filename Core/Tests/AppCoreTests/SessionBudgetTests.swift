import Testing
import Foundation
import AgentKit
@testable import AppCore

private let budgetNow = Date(timeIntervalSince1970: 1_000_000)

private func candidate(
    _ id: String,
    minutesAgo: Int,
    status: AgentStatus = .idle(since: Date(timeIntervalSince1970: 0), lastVerdictSnippet: nil),
    startedSecondsAgo: TimeInterval = 3600
) -> SessionBudget.Candidate {
    SessionBudget.Candidate(
        id: id,
        lastOpenedAt: budgetNow.addingTimeInterval(-Double(minutesAgo) * 60),
        status: status,
        startedAt: budgetNow.addingTimeInterval(-startedSecondsAgo)
    )
}

private func evictions(
    _ candidates: [SessionBudget.Candidate],
    cap: Int,
    selectedID: String?
) -> [String] {
    SessionBudget.evictions(
        candidates: candidates,
        cap: cap,
        selectedID: selectedID,
        now: budgetNow
    )
}

@Test func budgetEvictsNothingUnderTheCap() {
    let victims = evictions(
        [candidate("a", minutesAgo: 1), candidate("b", minutesAgo: 2)],
        cap: 5,
        selectedID: "a"
    )

    #expect(victims.isEmpty)
}

@Test func budgetEvictsTheOldestBeyondTheCap() {
    let victims = evictions(
        [
            candidate("newest", minutesAgo: 1),
            candidate("middle", minutesAgo: 2),
            candidate("oldest", minutesAgo: 3),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims == ["oldest", "middle"])
}

@Test func budgetNeverEvictsTheSelectedItem() {
    let victims = evictions(
        [
            candidate("newest", minutesAgo: 1),
            candidate("middle", minutesAgo: 2),
            candidate("oldest", minutesAgo: 3),
        ],
        cap: 2,
        selectedID: "oldest"
    )

    #expect(victims == ["middle"])
}

@Test func budgetSkipsAWorkingSessionAndTakesTheNextCandidate() {
    let victims = evictions(
        [
            candidate("newest", minutesAgo: 1),
            candidate("middle", minutesAgo: 2),
            candidate("oldest", minutesAgo: 3, status: .working),
        ],
        cap: 2,
        selectedID: "newest"
    )

    #expect(victims == ["middle"])
}

@Test func budgetSkipsASessionStillInsideItsStartupGrace() {
    let victims = evictions(
        [
            candidate("newest", minutesAgo: 1),
            candidate("oldest", minutesAgo: 2, status: .starting, startedSecondsAgo: 10),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims.isEmpty)
}

/// A session whose process runs but writes no transcript reads `.starting` with no
/// timeout of its own. Without the grace expiring it would hold its memory forever.
@Test func budgetEvictsAStartingSessionPastItsStartupGrace() {
    let victims = evictions(
        [
            candidate("newest", minutesAgo: 1),
            candidate("silent", minutesAgo: 2, status: .starting, startedSecondsAgo: 61),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims == ["silent"])
}

@Test func budgetTreatsTheGraceBoundaryAsStillProtected() {
    let victims = evictions(
        [
            candidate("newest", minutesAgo: 1),
            candidate("edge", minutesAgo: 2, status: .starting, startedSecondsAgo: 60),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims.isEmpty)
}

@Test func budgetStaysOverTheCapWhenEveryCandidateIsProtected() {
    let victims = evictions(
        [
            candidate("a", minutesAgo: 1, status: .working),
            candidate("b", minutesAgo: 2, status: .working),
            candidate("c", minutesAgo: 3, status: .working),
        ],
        cap: 1,
        selectedID: nil
    )

    #expect(victims.isEmpty)
}

@Test func budgetEvictsAwaitingInputAndFailedSessions() {
    let victims = evictions(
        [
            candidate("newest", minutesAgo: 1),
            candidate("awaiting", minutesAgo: 2, status: .awaitingInput(since: Date(timeIntervalSince1970: 0), lastVerdictSnippet: nil)),
            candidate("failed", minutesAgo: 3, status: .failed(reason: "boom")),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims == ["failed", "awaiting"])
}

@Test func budgetEvictsNothingForANonPositiveCap() {
    let victims = evictions(
        [candidate("a", minutesAgo: 1)],
        cap: 0,
        selectedID: nil
    )

    #expect(victims.isEmpty)
}
