import Testing
import Foundation
import ClaudeSessionKit
@testable import AppCore

private func candidate(
    _ id: String,
    minutesAgo: Int,
    status: ClaudeStatus = .idle(since: Date(timeIntervalSince1970: 0), lastVerdictSnippet: nil)
) -> SessionBudget.Candidate {
    SessionBudget.Candidate(
        id: id,
        lastOpenedAt: Date(timeIntervalSince1970: 1_000_000 - Double(minutesAgo) * 60),
        status: status
    )
}

@Test func budgetEvictsNothingUnderTheCap() {
    let victims = SessionBudget.evictions(
        candidates: [candidate("a", minutesAgo: 1), candidate("b", minutesAgo: 2)],
        cap: 5,
        selectedID: "a"
    )

    #expect(victims.isEmpty)
}

@Test func budgetEvictsTheOldestBeyondTheCap() {
    let victims = SessionBudget.evictions(
        candidates: [
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
    let victims = SessionBudget.evictions(
        candidates: [
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
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("middle", minutesAgo: 2),
            candidate("oldest", minutesAgo: 3, status: .working),
        ],
        cap: 2,
        selectedID: "newest"
    )

    #expect(victims == ["middle"])
}

@Test func budgetSkipsAStartingSession() {
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("oldest", minutesAgo: 2, status: .starting),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims.isEmpty)
}

@Test func budgetStaysOverTheCapWhenEveryCandidateIsProtected() {
    let victims = SessionBudget.evictions(
        candidates: [
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
    let victims = SessionBudget.evictions(
        candidates: [
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
    let victims = SessionBudget.evictions(
        candidates: [candidate("a", minutesAgo: 1)],
        cap: 0,
        selectedID: nil
    )

    #expect(victims.isEmpty)
}
