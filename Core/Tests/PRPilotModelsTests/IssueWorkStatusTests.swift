import Testing
import Foundation
@testable import PRPilotModels

@Test func closedAlwaysWinsOverManualAndWorking() {
    let s = resolveIssueStatus(manual: .onHold, prState: .closed, claudeReviewedAt: Date(), claudeWorking: true)
    #expect(s == .closed)
}

@Test func manualOverridesDerived() {
    let s = resolveIssueStatus(manual: .onHold, prState: .open, claudeReviewedAt: Date(), claudeWorking: true)
    #expect(s == .onHold)
}

@Test func workingDerivesInReview() {
    let s = resolveIssueStatus(manual: nil, prState: .open, claudeReviewedAt: nil, claudeWorking: true)
    #expect(s == .inReview)
}

@Test func reviewedStampDerivesReviewed() {
    let s = resolveIssueStatus(manual: nil, prState: .open, claudeReviewedAt: Date(), claudeWorking: false)
    #expect(s == .reviewed)
}

@Test func defaultsToNew() {
    let s = resolveIssueStatus(manual: nil, prState: .open, claudeReviewedAt: nil, claudeWorking: false)
    #expect(s == .new)
    let sNilState = resolveIssueStatus(manual: nil, prState: nil, claudeReviewedAt: nil, claudeWorking: false)
    #expect(sNilState == .new)
}

@Test func displayNamesAreHumanReadable() {
    #expect(IssueWorkStatus.onHold.displayName == "On Hold")
    #expect(IssueWorkStatus.inReview.displayName == "In Review")
    #expect(IssueWorkStatus.new.displayName == "New")
    #expect(IssueWorkStatus.reviewed.displayName == "Reviewed")
    #expect(IssueWorkStatus.done.displayName == "Done")
    #expect(IssueWorkStatus.closed.displayName == "Closed")
}
