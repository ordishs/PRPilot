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
    let s = PRStatus(ci: .passing, isBehind: true, readiness: .changesRequested)
    #expect(try JSONDecoder().decode(PRStatus.self, from: JSONEncoder().encode(s)) == s)
}
