import Testing
import Foundation
import PRPilotModels
@testable import AgentKit

private func sampleReview() -> WorkItem {
    WorkItem(
        title: "fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 944,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date()
    )
}

@Test func launchBuilderFreshSessionUsesSessionIDAndReviewSlashCommand() {
    let spec = AgentLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude",
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
    let spec = AgentLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude",
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

private func nameArg(_ args: [String]) -> String? {
    guard let idx = args.firstIndex(of: "--name") else { return nil }
    return args[args.index(after: idx)]
}

@Test func launchBuilderNamesPRSessionWithNumberAndTitle() {
    let spec = AgentLaunchBuilder.build(
        settings: .default, review: sampleReview(), worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "sid", resume: false
    )
    #expect(nameArg(spec.arguments) == "#944 fix")
}

@Test func launchBuilderNamesSessionOnResumeToo() {
    let spec = AgentLaunchBuilder.build(
        settings: .default, review: sampleReview(), worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "sid", resume: true
    )
    #expect(nameArg(spec.arguments) == "#944 fix")
}

@Test func launchBuilderNamesTaskSessionWithTitle() {
    let item = WorkItem(
        title: "feat/parallel-validation", repoKey: "github.com/o/r", baseBranch: "main",
        headBranch: "feat/parallel-validation", prRef: nil, prState: nil,
        origin: .added, addedAt: Date(timeIntervalSince1970: 0)
    )
    let spec = AgentLaunchBuilder.build(
        settings: .default, review: item, worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "sid", resume: false
    )
    #expect(nameArg(spec.arguments) == "feat/parallel-validation")
}

private func sampleIssueItem() -> WorkItem {
    WorkItem(
        title: "Login crash",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "issue-42-login-crash",
        issueRef: IssueRef(
            owner: "bsv-blockchain", repo: "teranode", number: 42,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/42")!,
            authorLogin: "alice"
        ),
        prState: .open,
        origin: .discovered,
        addedAt: Date()
    )
}

@Test func launchBuilderIssueUsesStartIssueCommand() {
    let spec = AgentLaunchBuilder.build(
        settings: .default,
        review: sampleIssueItem(),
        worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude",
        sessionID: "abc",
        resume: false
    )
    #expect(spec.arguments.contains("/start-issue 42"))
    #expect(!spec.arguments.contains { $0.hasPrefix("/review") })
    let nameIdx = spec.arguments.firstIndex(of: "--name")
    #expect(nameIdx != nil)
    if let nameIdx {
        #expect(spec.arguments[spec.arguments.index(after: nameIdx)] == "#42 Login crash")
    }
}

@Test func launchBuilderIssueResumeOmitsStartIssue() {
    let spec = AgentLaunchBuilder.build(
        settings: .default,
        review: sampleIssueItem(),
        worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude",
        sessionID: "abc",
        resume: true
    )
    #expect(!spec.arguments.contains { $0.hasPrefix("/start-issue") })
    #expect(spec.arguments.contains("--resume"))
}

@Test func buildOmitsReviewCommandWhenNoPR() {
    let item = WorkItem(
        title: "spike", repoKey: "github.com/o/r", baseBranch: "main",
        headBranch: "feat/spike", prRef: nil, prState: nil,
        origin: .added, addedAt: Date(timeIntervalSince1970: 0)
    )
    let spec = AgentLaunchBuilder.build(
        settings: .default, review: item, worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/usr/bin/claude", sessionID: "sid", resume: false
    )
    #expect(!spec.arguments.contains { $0.hasPrefix("/review ") })
    #expect(spec.arguments.contains("--session-id"))
    #expect(spec.arguments.contains("sid"))
}

private func issueItem() -> WorkItem {
    WorkItem(
        title: "limit reorg depth",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: nil,
        issueRef: IssueRef(
            owner: "bsv-blockchain", repo: "teranode", number: 4577,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/4577")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .discovered,
        addedAt: Date()
    )
}

private func settings(review: String? = nil, issue: String? = nil) -> Settings {
    var s = Settings.default
    if let review { s.reviewPromptTemplate = review }
    if let issue { s.issuePromptTemplate = issue }
    return s
}

@Test func launchBuilderUsesCustomReviewTemplate() {
    let template = """
    /review {url}

    End with a single line: VERDICT: APPROVE | REQUEST CHANGES | COMMENT.
    """
    let spec = AgentLaunchBuilder.build(
        settings: settings(review: template), review: sampleReview(), worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "sid", resume: false
    )
    #expect(spec.arguments.contains("""
    /review https://github.com/bsv-blockchain/teranode/pull/944

    End with a single line: VERDICT: APPROVE | REQUEST CHANGES | COMMENT.
    """))
}

@Test func launchBuilderUsesDefaultIssueTemplate() {
    let spec = AgentLaunchBuilder.build(
        settings: .default, review: issueItem(), worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "sid", resume: false
    )
    #expect(spec.arguments.contains("/start-issue 4577"))
}

@Test func launchBuilderUsesCustomIssueTemplate() {
    let spec = AgentLaunchBuilder.build(
        settings: settings(issue: "/start-issue {number} in {owner}/{repo}"),
        review: issueItem(), worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "sid", resume: false
    )
    #expect(spec.arguments.contains("/start-issue 4577 in bsv-blockchain/teranode"))
}

@Test func launchBuilderAppendsNoPromptWhenTemplateIsBlank() {
    // A deliberately empty template opens the session with no prompt at all.
    let spec = AgentLaunchBuilder.build(
        settings: settings(review: "   "), review: sampleReview(), worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "sid", resume: false
    )
    #expect(!spec.arguments.contains { $0.hasPrefix("/") })
    #expect(spec.arguments.contains("--session-id"))
}

@Test func launchBuilderIgnoresTemplatesOnResume() {
    let spec = AgentLaunchBuilder.build(
        settings: settings(review: "/review {url} and be brief"), review: sampleReview(),
        worktreePath: "/tmp/wt", kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "sid", resume: true
    )
    #expect(!spec.arguments.contains { $0.hasPrefix("/review") })
}

@Test func settingsWithoutPromptKeysDecodeToDefaults() {
    // An existing store predates these keys: the user keeps today's behaviour.
    let json = """
    {"managedRoot":"/tmp","reviewRequestQueries":[],"myPRQueries":[],"pollIntervalSeconds":60,
     "claudeLaunchArgs":"","claudeEnv":"","autoLoad":true,"notificationsEnabled":true,
     "diffMode":"unified","diffIgnoreWhitespace":false}
    """
    let decoded = try! JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.reviewPromptTemplate == "/review {url}")
    #expect(decoded.issuePromptTemplate == "/start-issue {number}")
}
