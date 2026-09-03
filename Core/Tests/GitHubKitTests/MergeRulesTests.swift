import Testing
import Foundation
import PRPilotModels
import CommandSupport
@testable import GitHubKit

/// The real payload from `gh api repos/bsv-blockchain/teranode/rules/branches/main`,
/// trimmed to the rules that carry parameters we read.
private let teranodeRulesJSON = """
[{"type":"repository_visibility","parameters":{"public":false},"ruleset_id":3665905},
 {"type":"copilot_code_review","parameters":{"review_on_push":true},"ruleset_id":20978320},
 {"type":"deletion","ruleset_id":10181754},
 {"type":"non_fast_forward","ruleset_id":10181754},
 {"type":"pull_request","parameters":{
   "allowed_merge_methods":["squash"],
   "dismiss_stale_reviews_on_push":false,
   "require_code_owner_review":false,
   "require_extra_approval_for_unattributed_changes":true,
   "require_last_push_approval":false,
   "required_approving_review_count":2,
   "required_review_thread_resolution":false,
   "required_reviewers":[]},"ruleset_id":10181754},
 {"type":"required_status_checks","parameters":{
   "required_status_checks":[{"context":"test","integration_id":15368},
                             {"context":"gitleaks","integration_id":15368}],
   "strict_required_status_checks_policy":false},"ruleset_id":10181754}]
"""

private func rulesClient(_ json: String, exitCode: Int32 = 0) -> (GitHubClient, RulesRunner) {
    let runner = RulesRunner(CommandResult(exitCode: exitCode, standardOutput: json, standardError: "forbidden"))
    return (GitHubClient(runner: runner, ghPath: "/usr/bin/gh"), runner)
}

actor RulesRunner: CommandRunner {
    private let result: CommandResult
    private(set) var lastArguments: [String]?
    private(set) var invocationCount = 0

    init(_ result: CommandResult) { self.result = result }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        lastArguments = arguments
        invocationCount += 1
        return result
    }
}

@Test func mergeRulesReadTheRequiredApprovalCount() async throws {
    let (client, runner) = rulesClient(teranodeRulesJSON)
    let rules = try await client.fetchMergeRules(owner: "bsv-blockchain", repo: "teranode", branch: "main")
    #expect(rules.requiredApprovals == 2)
    #expect(await runner.lastArguments == ["api", "repos/bsv-blockchain/teranode/rules/branches/main"])
}

@Test func mergeRulesAreUnknownWithoutAPullRequestRule() async throws {
    let json = """
    [{"type":"deletion","ruleset_id":1},{"type":"non_fast_forward","ruleset_id":1}]
    """
    let (client, _) = rulesClient(json)
    let rules = try await client.fetchMergeRules(owner: "o", repo: "r", branch: "main")
    #expect(rules.requiredApprovals == nil)
}

@Test func mergeRulesAreUnknownForAnUnprotectedBranch() async throws {
    let (client, _) = rulesClient("[]")
    let rules = try await client.fetchMergeRules(owner: "o", repo: "r", branch: "dev")
    #expect(rules.requiredApprovals == nil)
}

@Test func mergeRulesTreatAZeroRequirementAsNoRequirement() async throws {
    let json = """
    [{"type":"pull_request","parameters":{"required_approving_review_count":0},"ruleset_id":1}]
    """
    let (client, _) = rulesClient(json)
    let rules = try await client.fetchMergeRules(owner: "o", repo: "r", branch: "main")
    #expect(rules.requiredApprovals == nil)
}

@Test func mergeRulesThrowOnANonZeroExit() async {
    let (client, _) = rulesClient("", exitCode: 1)
    await #expect(throws: GitHubError.self) {
        try await client.fetchMergeRules(owner: "o", repo: "r", branch: "main")
    }
}

@Test func mergeRulesThrowOnMalformedJSON() async {
    let (client, _) = rulesClient("not json at all")
    await #expect(throws: GitHubError.self) {
        try await client.fetchMergeRules(owner: "o", repo: "r", branch: "main")
    }
}

@Test func mergeRulesEncodeTheApprovalShortfallForDisplay() {
    #expect(MergeRules(requiredApprovals: 2).isApprovalCountShort(1))
    #expect(MergeRules(requiredApprovals: 2).isApprovalCountShort(0))
    #expect(!MergeRules(requiredApprovals: 2).isApprovalCountShort(2))
    #expect(!MergeRules(requiredApprovals: 2).isApprovalCountShort(3))
    // Nothing is short of an unknown requirement.
    #expect(!MergeRules(requiredApprovals: nil).isApprovalCountShort(0))
}
