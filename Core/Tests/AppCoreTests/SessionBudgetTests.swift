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

/// `.idle` means the last transcript line did not end the turn. When that line arrived after
/// this process started, the agent is mid-turn inside a long tool call — it writes nothing for
/// minutes and must keep its slot.
@Test func budgetKeepsAnIdleSessionWhoseTurnIsStillInFlight() {
    let midTurn = AgentStatus.idle(
        since: budgetNow.addingTimeInterval(-45),
        lastVerdictSnippet: "reading files"
    )
    let victims = evictions(
        [
            candidate("newest", minutesAgo: 1),
            candidate("quiet", minutesAgo: 2, status: midTurn, startedSecondsAgo: 600),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims.isEmpty)
}

/// The mirror case. A resumed session replays the interrupted turn of an earlier run, so its
/// last event predates this process. That says nothing about what this process does now, and
/// the cap must still reclaim the slot.
@Test func budgetEvictsAnIdleSessionWhoseLastEventPredatesTheProcess() {
    let replayed = AgentStatus.idle(
        since: budgetNow.addingTimeInterval(-7200),
        lastVerdictSnippet: nil
    )
    let victims = evictions(
        [
            candidate("newest", minutesAgo: 1),
            candidate("resumed", minutesAgo: 2, status: replayed, startedSecondsAgo: 600),
        ],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims == ["resumed"])
}

// MARK: - Time-bounded idle protection

/// Mid-turn protection has to expire. Without a bound, any session that ever wrote a
/// transcript line stays protected for the life of the app, the cap never reclaims a slot,
/// and the only session left to take is the one that has just answered the user.
@Test func budgetEvictsAMidTurnSessionThatHasBeenQuietPastTheWindow() {
    let longQuiet = AgentStatus.idle(
        since: budgetNow.addingTimeInterval(-3 * 3600),
        lastVerdictSnippet: "reading files"
    )
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("stale", minutesAgo: 2, status: longQuiet, startedSecondsAgo: 4 * 3600),
        ],
        cap: 1,
        selectedID: "newest",
        now: budgetNow,
        idleProtectionSeconds: 20 * 60
    )

    #expect(victims == ["stale"])
}

@Test func budgetKeepsAMidTurnSessionInsideTheWindow() {
    let recentlyQuiet = AgentStatus.idle(
        since: budgetNow.addingTimeInterval(-10 * 60),
        lastVerdictSnippet: "running tests"
    )
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("busy", minutesAgo: 2, status: recentlyQuiet, startedSecondsAgo: 3600),
        ],
        cap: 1,
        selectedID: "newest",
        now: budgetNow,
        idleProtectionSeconds: 20 * 60
    )

    #expect(victims.isEmpty)
}

/// The window bounds `.idle` only. A session still writing reads `.working`, and a workflow
/// that reports nothing for an hour reads `.working` too — neither may be reclaimed.
@Test func theIdleWindowDoesNotTouchAWorkingSession() {
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("working", minutesAgo: 2, status: .working, startedSecondsAgo: 6 * 3600),
        ],
        cap: 1,
        selectedID: "newest",
        now: budgetNow,
        idleProtectionSeconds: 20 * 60
    )

    #expect(victims.isEmpty)
}

@Test func theIdleWindowIsInclusiveAtItsEdge() {
    let exactlyAtTheEdge = AgentStatus.idle(
        since: budgetNow.addingTimeInterval(-20 * 60),
        lastVerdictSnippet: nil
    )
    let victims = SessionBudget.evictions(
        candidates: [
            candidate("newest", minutesAgo: 1),
            candidate("edge", minutesAgo: 2, status: exactlyAtTheEdge, startedSecondsAgo: 3600),
        ],
        cap: 1,
        selectedID: "newest",
        now: budgetNow,
        idleProtectionSeconds: 20 * 60
    )

    #expect(victims.isEmpty, "a session exactly at the boundary is still protected")
}

// MARK: - Reaping dead sessions

/// A session whose process has exited is not a session. Reaping it frees nothing the user
/// could still be using, so it is not gated on the cap the way an eviction is.
@Test func deadSessionsFindsExitedAndFailedOnes() {
    let dead = SessionBudget.deadSessions(candidates: [
        candidate("running", minutesAgo: 1, status: .working),
        candidate("exited", minutesAgo: 2, status: .ready(exitCode: 0)),
        candidate("crashed", minutesAgo: 3, status: .failed(reason: "boom")),
        candidate("waiting", minutesAgo: 4,
                  status: .awaitingInput(since: budgetNow, lastVerdictSnippet: nil)),
    ])

    #expect(Set(dead) == ["exited", "crashed"])
}

@Test func deadSessionsIgnoresTheCapAndTheSelection() {
    // One candidate, well under any cap, and it is the one on screen: still reapable.
    let dead = SessionBudget.deadSessions(candidates: [
        candidate("only", minutesAgo: 1, status: .ready(exitCode: 1)),
    ])

    #expect(dead == ["only"])
}

@Test func deadSessionsFindsNothingWhenEveryoneIsAlive() {
    let dead = SessionBudget.deadSessions(candidates: [
        candidate("a", minutesAgo: 1, status: .working),
        candidate("b", minutesAgo: 2, status: .starting),
    ])

    #expect(dead.isEmpty)
}
