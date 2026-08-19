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
    cap: Int,
    selectedID: String? = nil
) -> SessionQueue.Step {
    SessionQueue.nextStep(
        queued: queued,
        live: sessions,
        cap: cap,
        selectedID: selectedID,
        now: queueNow
    )
}

@Test func queueDoesNothingWhenNothingIsQueued() {
    let result = step(queued: [], live: [live("a", minutesAgo: 1)], cap: 1)

    #expect(result.release == nil)
    #expect(result.start == nil)
}

@Test func queueStartsTheHeadWhenASlotIsFree() {
    let result = step(queued: ["next"], live: [live("a", minutesAgo: 1)], cap: 3)

    #expect(result.release == nil)
    #expect(result.start == "next")
}

@Test func queueReleasesTheOldestIdleSessionAtTheCap() {
    let result = step(
        queued: ["next"],
        live: [live("newest", minutesAgo: 1), live("oldest", minutesAgo: 5)],
        cap: 2
    )

    #expect(result.release == "oldest")
    #expect(result.start == "next")
}

@Test func queueNeverReleasesAWorkingSession() {
    let result = step(
        queued: ["next"],
        live: [live("newest", minutesAgo: 1), live("oldest", minutesAgo: 5, status: .working)],
        cap: 2
    )

    #expect(result.release == "newest")
    #expect(result.start == "next")
}

@Test func queueNeverReleasesASessionInsideItsStartupGrace() {
    let result = step(
        queued: ["next"],
        live: [
            live("newest", minutesAgo: 1),
            live("starting", minutesAgo: 5, status: .starting, startedSecondsAgo: 10),
        ],
        cap: 2
    )

    #expect(result.release == "newest")
}

@Test func queueNeverReleasesTheSelectedItem() {
    let result = step(
        queued: ["next"],
        live: [live("newest", minutesAgo: 1), live("oldest", minutesAgo: 5)],
        cap: 2,
        selectedID: "oldest"
    )

    #expect(result.release == "newest")
    #expect(result.start == "next")
}

@Test func queueDoesNothingWhenEverySessionIsProtected() {
    let result = step(
        queued: ["next"],
        live: [
            live("a", minutesAgo: 1, status: .working),
            live("b", minutesAgo: 5, status: .working),
        ],
        cap: 2
    )

    #expect(result.release == nil)
    #expect(result.start == nil)
}

@Test func queueReleasesAFinishedSessionSoTheBacklogMoves() {
    let result = step(
        queued: ["next"],
        live: [live("done", minutesAgo: 5, status: .ready(exitCode: 0))],
        cap: 1
    )

    #expect(result.release == "done")
    #expect(result.start == "next")
}

@Test func queueReleasesAnAwaitingInputSessionEvenThoughItIsUnread() {
    let unread = AgentStatus.awaitingInput(since: Date(timeIntervalSince1970: 0), lastVerdictSnippet: "verdict")
    let result = step(
        queued: ["next"],
        live: [live("unread", minutesAgo: 5, status: unread)],
        cap: 1
    )

    #expect(result.release == "unread")
}

@Test func queueDoesNothingForANonPositiveCap() {
    let result = step(queued: ["next"], live: [], cap: 0)

    #expect(result.release == nil)
    #expect(result.start == nil)
}

/// The drain must not take the slot of an agent that is mid-turn but quiet, whatever the
/// backlog costs. Losing a long review is worse than a slow queue.
@Test func queueNeverReleasesASessionWhoseTurnIsStillInFlight() {
    let midTurn = AgentStatus.idle(
        since: queueNow.addingTimeInterval(-45),
        lastVerdictSnippet: "running tests"
    )
    let result = step(
        queued: ["next"],
        live: [
            live("newest", minutesAgo: 1),
            live("quiet", minutesAgo: 5, status: midTurn, startedSecondsAgo: 600),
        ],
        cap: 2
    )

    #expect(result.release == "newest")
    #expect(result.start == "next")
}

/// A replayed event from an earlier run does not protect the current process.
@Test func queueReleasesASessionWhoseLastEventPredatesTheProcess() {
    let replayed = AgentStatus.idle(
        since: queueNow.addingTimeInterval(-7200),
        lastVerdictSnippet: nil
    )
    let result = step(
        queued: ["next"],
        live: [live("resumed", minutesAgo: 5, status: replayed, startedSecondsAgo: 600)],
        cap: 1
    )

    #expect(result.release == "resumed")
    #expect(result.start == "next")
}
