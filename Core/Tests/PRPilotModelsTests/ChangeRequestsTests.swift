import Testing
import Foundation
@testable import PRPilotModels

private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + s) }

private func v(_ login: String, _ state: String, _ commit: String?, _ t: TimeInterval) -> ReviewVerdict {
    ReviewVerdict(login: login, state: state, commitOID: commit, at: at(t))
}

@Test func requestOnTheCurrentHeadIsCurrent() {
    let tally = ChangeRequestTally.tally(verdicts: [v("a", "CHANGES_REQUESTED", "H", 1)], headOID: "H")
    #expect(tally == ChangeRequestTally(current: 1, outdated: 0))
}

@Test func requestOnAnOlderCommitIsOutdated() {
    let tally = ChangeRequestTally.tally(verdicts: [v("a", "CHANGES_REQUESTED", "OLD", 1)], headOID: "H")
    #expect(tally == ChangeRequestTally(current: 0, outdated: 1))
    #expect(tally.isOutdatedOnly)
}

@Test func oneCurrentRequestKeepsItFromBeingOutdatedOnly() {
    let tally = ChangeRequestTally.tally(verdicts: [
        v("a", "CHANGES_REQUESTED", "OLD", 1),
        v("b", "CHANGES_REQUESTED", "H", 2),
    ], headOID: "H")
    #expect(tally == ChangeRequestTally(current: 1, outdated: 1))
    #expect(!tally.isOutdatedOnly)
}

@Test func laterApprovalFromTheSameReviewerLiftsTheRequest() {
    let tally = ChangeRequestTally.tally(verdicts: [
        v("a", "CHANGES_REQUESTED", "OLD", 1),
        v("a", "APPROVED", "H", 2),
    ], headOID: "H")
    #expect(tally == ChangeRequestTally())
}

@Test func dismissalLiftsTheRequest() {
    let tally = ChangeRequestTally.tally(verdicts: [
        v("a", "CHANGES_REQUESTED", "OLD", 1),
        v("a", "DISMISSED", "OLD", 2),
    ], headOID: "H")
    #expect(tally == ChangeRequestTally())
}

@Test func aCommentNeverLiftsARequest() {
    let tally = ChangeRequestTally.tally(verdicts: [
        v("a", "CHANGES_REQUESTED", "OLD", 1),
        v("a", "COMMENTED", "H", 2),
    ], headOID: "H")
    #expect(tally == ChangeRequestTally(current: 0, outdated: 1))
}

@Test func theNewestDecisiveReviewWinsRegardlessOfInputOrder() {
    let tally = ChangeRequestTally.tally(verdicts: [
        v("a", "APPROVED", "H", 5),
        v("a", "CHANGES_REQUESTED", "OLD", 1),
    ], headOID: "H")
    #expect(tally == ChangeRequestTally())
}

@Test func reviewerNamesMatchIgnoringCase() {
    let tally = ChangeRequestTally.tally(verdicts: [
        v("Alice", "CHANGES_REQUESTED", "OLD", 1),
        v("alice", "APPROVED", "H", 2),
    ], headOID: "H")
    #expect(tally == ChangeRequestTally())
}

@Test func unknownCommitsCountAsCurrentSoARequestIsNeverHidden() {
    #expect(ChangeRequestTally.tally(verdicts: [v("a", "CHANGES_REQUESTED", nil, 1)], headOID: "H").current == 1)
    #expect(ChangeRequestTally.tally(verdicts: [v("a", "CHANGES_REQUESTED", "OLD", 1)], headOID: nil).current == 1)
}

@Test func prStatusRoundTripsChangeRequestsAndToleratesTheirAbsence() throws {
    let status = PRStatus(ci: .passing, mergeState: .clean, readiness: .changesRequested,
                          changeRequests: ChangeRequestTally(current: 1, outdated: 2))
    let decoded = try JSONDecoder().decode(PRStatus.self, from: JSONEncoder().encode(status))
    #expect(decoded.changeRequests == ChangeRequestTally(current: 1, outdated: 2))
    let legacy = Data(#"{"ci":"passing","readiness":"changesRequested"}"#.utf8)
    #expect(try JSONDecoder().decode(PRStatus.self, from: legacy).changeRequests == ChangeRequestTally())
}
