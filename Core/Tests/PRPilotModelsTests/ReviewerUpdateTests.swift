import Testing
import Foundation
@testable import PRPilotModels

private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds) }

private func latest(
    events: [ReviewerEvent],
    mine: [Date] = [],
    head: Date? = nil
) -> ReviewerUpdate? {
    ReviewerUpdate.latest(myLogin: "me", events: events, myActivity: mine, headCommittedAt: head)
}

@Test func reviewerAfterMyPushIsAnUpdate() {
    let r = latest(events: [ReviewerEvent(login: "rev", at: at(100), kind: .changesRequested)], head: at(50))
    #expect(r == ReviewerUpdate(at: at(100), requestedChanges: true))
}

@Test func myPushAfterTheReviewerClearsIt() {
    let r = latest(events: [ReviewerEvent(login: "rev", at: at(100), kind: .changesRequested)], head: at(200))
    #expect(r == nil)
}

@Test func myReplyAfterTheReviewerClearsIt() {
    let r = latest(events: [ReviewerEvent(login: "rev", at: at(100), kind: .other)], mine: [at(150)], head: at(50))
    #expect(r == nil)
}

@Test func myOwnEventsNeverCount() {
    let r = latest(events: [ReviewerEvent(login: "Me", at: at(100), kind: .changesRequested)], head: at(50))
    #expect(r == nil)
}

@Test func plainReplyIsAnUpdateButNotAChangeRequest() {
    let r = latest(events: [ReviewerEvent(login: "rev", at: at(100), kind: .other)], head: at(50))
    #expect(r == ReviewerUpdate(at: at(100), requestedChanges: false))
}

@Test func newestVerdictDecidesRequestedChanges() {
    let events = [
        ReviewerEvent(login: "rev", at: at(100), kind: .changesRequested),
        ReviewerEvent(login: "rev", at: at(200), kind: .approved),
        ReviewerEvent(login: "rev", at: at(300), kind: .other),
    ]
    #expect(latest(events: events, head: at(50)) == ReviewerUpdate(at: at(300), requestedChanges: false))
}

@Test func laterChangeRequestFromAnotherReviewerWins() {
    let events = [
        ReviewerEvent(login: "a", at: at(100), kind: .approved),
        ReviewerEvent(login: "b", at: at(200), kind: .changesRequested),
    ]
    #expect(latest(events: events, head: at(50))?.requestedChanges == true)
}

@Test func noEventsGivesNil() {
    #expect(latest(events: [], head: at(50)) == nil)
}

@Test func withoutAnyAnchorEveryReviewerEventCounts() {
    let r = latest(events: [ReviewerEvent(login: "rev", at: at(1), kind: .other)])
    #expect(r?.at == at(1))
}

@Test func seenMarkSuppressesUntilSomethingNewer() {
    let update = ReviewerUpdate(at: at(100), requestedChanges: true)
    #expect(update.isUnseen(seenAt: nil))
    #expect(!update.isUnseen(seenAt: at(100)))
    #expect(update.isUnseen(seenAt: at(99)))
}
