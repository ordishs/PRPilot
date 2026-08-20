import Testing
import Foundation
import AgentKit
@testable import AppCore

private let queueNow = Date(timeIntervalSince1970: 1_000_000)

private func live(
    _ id: String,
    minutesAgo: Int,
    status: AgentStatus = .idle(since: Date(timeIntervalSince1970: 0), lastVerdictSnippet: nil),
    startedSecondsAgo: TimeInterval = 3600
) -> SessionBudget.Candidate {
    SessionBudget.Candidate(
        id: id,
        lastOpenedAt: queueNow.addingTimeInterval(-Double(minutesAgo) * 60),
        status: status,
        startedAt: queueNow.addingTimeInterval(-startedSecondsAgo)
    )
}

private func step(
    queued: [String],
    live sessions: [SessionBudget.Candidate],
    cap: Int
) -> SessionQueue.Step {
    SessionQueue.nextStep(queued: queued, live: sessions, cap: cap, now: queueNow)
}

@Test func queueDoesNothingWhenNothingIsQueued() {
    #expect(step(queued: [], live: [live("a", minutesAgo: 1)], cap: 1).start == nil)
}

@Test func queueStartsTheHeadWhenASlotIsFree() {
    #expect(step(queued: ["next"], live: [live("a", minutesAgo: 1)], cap: 3).start == "next")
}

@Test func queueDoesNothingForANonPositiveCap() {
    #expect(step(queued: ["next"], live: [], cap: 0).start == nil)
}

/// The backlog never costs a live agent its process. autoLoad exists to fill idle capacity,
/// not to take capacity away — a queued review is worth less than the turn already running.
@Test func queueWaitsAtTheCapRatherThanReleasingAnything() {
    let result = step(
        queued: ["next"],
        live: [live("newest", minutesAgo: 1), live("oldest", minutesAgo: 5)],
        cap: 2
    )

    #expect(result.start == nil)
}

/// The case the user hits: a session that has just answered and is waiting on them reads
/// `.awaitingInput`, which used to make it the drain's first choice of victim.
@Test func queueDoesNotTakeTheSlotOfASessionWaitingOnTheUser() {
    let waiting = AgentStatus.awaitingInput(
        since: queueNow.addingTimeInterval(-30),
        lastVerdictSnippet: "shall I continue?"
    )
    let result = step(
        queued: ["next"],
        live: [live("waiting", minutesAgo: 5, status: waiting)],
        cap: 1
    )

    #expect(result.start == nil)
}

/// Nor does a finished one. The budget reclaims stale slots on its own schedule; the drain
/// only ever fills what is already free.
@Test func queueDoesNotTakeTheSlotOfAFinishedSession() {
    let result = step(
        queued: ["next"],
        live: [live("done", minutesAgo: 5, status: .ready(exitCode: 0))],
        cap: 1
    )

    #expect(result.start == nil)
}

@Test func queueStartsAgainOnceTheBudgetHasFreedASlot() {
    // One live session below a cap of two: the slot the budget reclaimed is now fillable.
    #expect(step(queued: ["next"], live: [live("a", minutesAgo: 1)], cap: 2).start == "next")
}
