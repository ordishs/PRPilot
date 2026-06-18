import Testing
import Foundation
@testable import GitHubKit

@Test func issueLocatorParsesIssueURL() throws {
    let loc = try IssueLocator.parse("https://github.com/bsv-blockchain/teranode/issues/42")
    #expect(loc.owner == "bsv-blockchain")
    #expect(loc.repo == "teranode")
    #expect(loc.number == 42)
}

@Test func issueLocatorRejectsPullURL() {
    #expect(throws: GitHubError.self) {
        try IssueLocator.parse("https://github.com/o/r/pull/7")
    }
}

@Test func issueLocatorRejectsNonGitHub() {
    #expect(throws: GitHubError.self) {
        try IssueLocator.parse("https://gitlab.com/o/r/issues/7")
    }
}
