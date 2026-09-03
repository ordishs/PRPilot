import Testing
import Foundation
@testable import PRPilotModels

@Test func ciNoneWhenNoChecks() {
    #expect(PRStatus.aggregateCI([]) == .none)
}

@Test func ciPassingWhenAllSucceed() {
    let checks = [
        CICheck(status: "COMPLETED", conclusion: "SUCCESS"),
        CICheck(state: "SUCCESS"),
        CICheck(status: "COMPLETED", conclusion: "NEUTRAL"),
    ]
    #expect(PRStatus.aggregateCI(checks) == .passing)
}

@Test func ciFailingDominates() {
    let checks = [
        CICheck(status: "COMPLETED", conclusion: "SUCCESS"),
        CICheck(status: "COMPLETED", conclusion: "FAILURE"),
        CICheck(state: "PENDING"),
    ]
    #expect(PRStatus.aggregateCI(checks) == .failing)
}

@Test func ciFailingFromStatusContextErrorState() {
    #expect(PRStatus.aggregateCI([CICheck(state: "ERROR")]) == .failing)
}

@Test func ciPendingWhenAnyInProgressAndNoFailure() {
    let checks = [
        CICheck(status: "COMPLETED", conclusion: "SUCCESS"),
        CICheck(status: "IN_PROGRESS"),
    ]
    #expect(PRStatus.aggregateCI(checks) == .pending)
}

@Test func ciPendingFromStatusContextPending() {
    #expect(PRStatus.aggregateCI([CICheck(state: "PENDING")]) == .pending)
}

@Test func readinessDraftBeatsDecision() {
    #expect(PRStatus.readiness(isDraft: true, reviewDecision: "APPROVED") == .draft)
}

@Test func readinessMapsReviewDecision() {
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: "APPROVED") == .approved)
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: "CHANGES_REQUESTED") == .changesRequested)
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: "REVIEW_REQUIRED") == .reviewRequired)
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: nil) == .none)
    #expect(PRStatus.readiness(isDraft: false, reviewDecision: "") == .none)
}

@Test func prStatusRoundTripsThroughCodable() throws {
    let s = PRStatus(ci: .passing, mergeState: .behind, readiness: .changesRequested)
    #expect(try JSONDecoder().decode(PRStatus.self, from: JSONEncoder().encode(s)) == s)
}

@Test func mergeStateMapsGitHubValues() {
    #expect(PRStatus.mergeState(from: "CLEAN") == .clean)
    #expect(PRStatus.mergeState(from: "DIRTY") == .conflict)
    #expect(PRStatus.mergeState(from: "BEHIND") == .behind)
    #expect(PRStatus.mergeState(from: "BLOCKED") == .blocked)
    #expect(PRStatus.mergeState(from: "UNSTABLE") == .unstable)
    #expect(PRStatus.mergeState(from: "HAS_HOOKS") == .unstable)
    #expect(PRStatus.mergeState(from: "DRAFT") == .unknown)
    #expect(PRStatus.mergeState(from: "UNKNOWN") == .unknown)
    #expect(PRStatus.mergeState(from: nil) == .unknown)
}

@Test func isBehindFollowsMergeState() {
    #expect(PRStatus(ci: .passing, mergeState: .behind, readiness: .none).isBehind)
    #expect(!PRStatus(ci: .passing, mergeState: .conflict, readiness: .none).isBehind)
    #expect(!PRStatus(ci: .passing, mergeState: .clean, readiness: .none).isBehind)
}

@Test func approvalCountCountsOneApprovalPerAuthor() {
    let submissions = [
        ReviewSubmission(authorLogin: "alice", state: "APPROVED", submittedAt: Date(timeIntervalSince1970: 10)),
        ReviewSubmission(authorLogin: "bob", state: "COMMENTED", submittedAt: Date(timeIntervalSince1970: 20)),
        ReviewSubmission(authorLogin: "bob", state: "APPROVED", submittedAt: Date(timeIntervalSince1970: 30)),
        ReviewSubmission(authorLogin: "alice", state: "COMMENTED", submittedAt: Date(timeIntervalSince1970: 40)),
    ]
    #expect(PRStatus.approvalCount(from: submissions) == 2)
}

@Test func approvalCountIgnoresRetractedApprovals() {
    let dismissed = [
        ReviewSubmission(authorLogin: "alice", state: "APPROVED", submittedAt: Date(timeIntervalSince1970: 10)),
        ReviewSubmission(authorLogin: "alice", state: "DISMISSED", submittedAt: Date(timeIntervalSince1970: 20)),
    ]
    #expect(PRStatus.approvalCount(from: dismissed) == 0)

    let reversed = [
        ReviewSubmission(authorLogin: "bob", state: "APPROVED", submittedAt: Date(timeIntervalSince1970: 10)),
        ReviewSubmission(authorLogin: "bob", state: "CHANGES_REQUESTED", submittedAt: Date(timeIntervalSince1970: 20)),
    ]
    #expect(PRStatus.approvalCount(from: reversed) == 0)
}

@Test func approvalCountIsZeroWithoutReviews() {
    #expect(PRStatus.approvalCount(from: []) == 0)
}

@Test func prStatusDecodesPayloadWithoutTheNewFields() throws {
    let legacy = #"{"ci":"passing","readiness":"approved"}"#
    let decoded = try JSONDecoder().decode(PRStatus.self, from: Data(legacy.utf8))
    #expect(decoded.mergeState == .unknown)
    #expect(decoded.approvalCount == 0)
}

@Test func prStatusRoundTripsTheNewFields() throws {
    let s = PRStatus(ci: .failing, mergeState: .conflict, readiness: .changesRequested, approvalCount: 3)
    #expect(try JSONDecoder().decode(PRStatus.self, from: JSONEncoder().encode(s)) == s)
}

@Test func readyToMergeNeedsAnOpenPRWithACleanMergeState() {
    let clean = PRStatus(ci: .passing, mergeState: .clean, readiness: .approved)
    #expect(clean.isReadyToMerge(prState: .open))
    #expect(!clean.isReadyToMerge(prState: .draft))
    #expect(!clean.isReadyToMerge(prState: .merged))
    #expect(!clean.isReadyToMerge(prState: .closed))
    #expect(!clean.isReadyToMerge(prState: nil))

    for state: MergeState in [.conflict, .behind, .blocked, .unstable, .unknown] {
        let status = PRStatus(ci: .passing, mergeState: state, readiness: .approved)
        #expect(!status.isReadyToMerge(prState: .open), "\(state) is not ready to merge")
    }

    let draftReadiness = PRStatus(ci: .passing, mergeState: .clean, readiness: .draft)
    #expect(!draftReadiness.isReadyToMerge(prState: .open))
}
