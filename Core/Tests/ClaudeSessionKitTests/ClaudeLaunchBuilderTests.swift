import Testing
import Foundation
import PRPilotModels
@testable import ClaudeSessionKit

private func sampleReview() -> Review {
    Review(
        owner: "bsv-blockchain", repo: "teranode", number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        title: "fix", author: "icellan",
        headBranch: "fix", baseBranch: "main",
        origin: .added, prState: .open, addedAt: Date()
    )
}

@Test func launchBuilderFreshSessionUsesSessionIDAndReviewSlashCommand() {
    let spec = ClaudeLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        resolvedClaudePath: "/bin/claude",
        sessionID: "10889bb0-624c-4ef5-94f7-77480418849c",
        resume: false
    )
    #expect(spec.executable == "/bin/claude")
    #expect(spec.cwd == "/tmp/wt")
    let idx = spec.arguments.firstIndex(of: "--session-id")
    #expect(idx != nil)
    if let idx {
        #expect(spec.arguments[spec.arguments.index(after: idx)] == "10889bb0-624c-4ef5-94f7-77480418849c")
    }
    #expect(spec.arguments.contains("/review https://github.com/bsv-blockchain/teranode/pull/944"))
    #expect(!spec.arguments.contains("--resume"))
}

@Test func launchBuilderResumeEmitsResumeFlagAndOmitsReview() {
    let spec = ClaudeLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        resolvedClaudePath: "/bin/claude",
        sessionID: "10889bb0-624c-4ef5-94f7-77480418849c",
        resume: true
    )
    let idx = spec.arguments.firstIndex(of: "--resume")
    #expect(idx != nil)
    if let idx {
        #expect(spec.arguments[spec.arguments.index(after: idx)] == "10889bb0-624c-4ef5-94f7-77480418849c")
    }
    #expect(!spec.arguments.contains("--session-id"))
    #expect(!spec.arguments.contains { $0.hasPrefix("/review ") })
}
