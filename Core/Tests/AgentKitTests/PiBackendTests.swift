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

private func sampleIssue() -> WorkItem {
    WorkItem(
        title: "limit transactions",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "issue-4459",
        issueRef: IssueRef(
            owner: "bsv-blockchain", repo: "teranode", number: 4459,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/4459")!,
            authorLogin: "ordishs"
        ),
        origin: .added,
        addedAt: Date()
    )
}

private let home = FileManager.default.homeDirectoryForCurrentUser.path

// MARK: - Directory encoding

/// pi drops the leading '/', replaces the remaining '/' with '-', and wraps the result in
/// '--'. Unlike Claude Code it sanitises nothing else. Every case below was read back from a
/// real pi session directory — if this encoding drifts the watcher tails an empty directory
/// and status never leaves .starting.
@Test func piEncodesWorktreePathPreservingSpacesAndDots() {
    let cases: [(String, String)] = [
        ("/Users/ordishs/dev/masa.gi/code-reviewer",
         "--Users-ordishs-dev-masa.gi-code-reviewer--"),
        ("/Users/ordishs",
         "--Users-ordishs--"),
        ("/Users/ordishs/dev/taal/ilumis/teranode_workspace/teranode",
         "--Users-ordishs-dev-taal-ilumis-teranode_workspace-teranode--"),
        // The case that matters most: a real PR Pilot worktree. Both the space in
        // "Application Support" and the dot in "worktrees.noindex" survive verbatim.
        ("/Users/ordishs/Library/Application Support/PRPilot/worktrees.noindex/bsv-blockchain-teranode-issue-4459-limit-transactions-in-ram",
         "--Users-ordishs-Library-Application Support-PRPilot-worktrees.noindex-bsv-blockchain-teranode-issue-4459-limit-transactions-in-ram--"),
    ]
    for (path, expectedFolder) in cases {
        let url = PiBackend().transcriptDirectory(forWorktreePath: path)
        #expect(url.path == "\(home)/.pi/agent/sessions/\(expectedFolder)", "path: \(path)")
    }
}

/// Claude Code and pi must not agree, or one of them is reading the other's directory.
@Test func piAndClaudeCodeEncodeTheSamePathDifferently() {
    let path = "/Users/me/Application Support/masa.gi"
    let pi = PiBackend().transcriptDirectory(forWorktreePath: path)
    let claude = ClaudeCodeBackend().transcriptDirectory(forWorktreePath: path)
    #expect(pi != claude)
    #expect(pi.path.contains("Application Support"))
    #expect(claude.path.contains("Application-Support"))
}

// MARK: - Session ID from file name

@Test func piReadsSessionIDAfterTheTimestampPrefix() {
    let backend = PiBackend()
    #expect(
        backend.sessionID(fromTranscriptFilename: "2026-08-13T11-54-02-626Z_44444444-5555-6666-7777-888888888888.jsonl")
            == "44444444-5555-6666-7777-888888888888"
    )
}

@Test func piRejectsNamesThatAreNotTranscripts() {
    let backend = PiBackend()
    // No .jsonl extension.
    #expect(backend.sessionID(fromTranscriptFilename: "2026-08-13T11-54-02-626Z_abc.txt") == nil)
    // No timestamp separator, so not a pi transcript even though it is one of Claude Code's.
    #expect(backend.sessionID(fromTranscriptFilename: "44444444-5555-6666-7777-888888888888.jsonl") == nil)
    // Nothing after the separator.
    #expect(backend.sessionID(fromTranscriptFilename: "2026-08-13T11-54-02-626Z_.jsonl") == nil)
    #expect(backend.sessionID(fromTranscriptFilename: "archived") == nil)
}

/// Claude Code's reader must not accept pi's names as its own, or `latestSessionID` would
/// return a session ID with a timestamp glued to the front.
@Test func claudeCodeReadsSessionIDAsTheWholeStem() {
    let backend = ClaudeCodeBackend()
    #expect(
        backend.sessionID(fromTranscriptFilename: "10889bb0-624c-4ef5-94f7-77480418849c.jsonl")
            == "10889bb0-624c-4ef5-94f7-77480418849c"
    )
    #expect(backend.sessionID(fromTranscriptFilename: "notes.txt") == nil)
    #expect(backend.sessionID(fromTranscriptFilename: ".jsonl") == nil)
    // A pi name must not parse as a Claude Code session ID, or the timestamp would be glued to
    // the front of the ID and resuming would fail.
    #expect(backend.sessionID(fromTranscriptFilename: "2026-08-13T11-54-02-626Z_44444444-5555-6666-7777-888888888888.jsonl") == nil)
    // Any other .jsonl is still accepted, so the watcher keeps tailing whatever Claude Code
    // writes even if its naming changes.
    #expect(backend.sessionID(fromTranscriptFilename: "session.jsonl") == "session")
}

// MARK: - Launch arguments

@Test func piFreshSessionUsesSessionIDAndItsOwnPromptTemplate() {
    let spec = AgentLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        kind: .pi,
        resolvedExecutablePath: "/opt/node/bin/pi",
        sessionID: "10889bb0-624c-4ef5-94f7-77480418849c",
        resume: false
    )
    #expect(spec.executable == "/opt/node/bin/pi")
    #expect(spec.kind == .pi)
    let idx = spec.arguments.firstIndex(of: "--session-id")
    #expect(idx != nil)
    if let idx {
        #expect(spec.arguments[spec.arguments.index(after: idx)] == "10889bb0-624c-4ef5-94f7-77480418849c")
    }
    // pi has no /review command, so it must get its own template rather than Claude Code's.
    #expect(spec.arguments.contains("Review the pull request at https://github.com/bsv-blockchain/teranode/pull/944."))
    #expect(!spec.arguments.contains { $0.hasPrefix("/review") })
}

@Test func piIssueSessionUsesThePiIssueTemplate() {
    let spec = AgentLaunchBuilder.build(
        settings: .default,
        review: sampleIssue(),
        worktreePath: "/tmp/wt",
        kind: .pi,
        resolvedExecutablePath: "/opt/node/bin/pi",
        sessionID: "sid",
        resume: false
    )
    #expect(spec.arguments.contains("Start work on issue 4459."))
    #expect(!spec.arguments.contains { $0.hasPrefix("/start-issue") })
}

/// The single most important launch difference. `pi --resume <id>` opens an interactive
/// session picker and would leave the pane waiting on a keypress forever.
@Test func piResumeUsesSessionFlagAndNeverResumeFlag() {
    let spec = AgentLaunchBuilder.build(
        settings: .default,
        review: sampleReview(),
        worktreePath: "/tmp/wt",
        kind: .pi,
        resolvedExecutablePath: "/opt/node/bin/pi",
        sessionID: "10889bb0-624c-4ef5-94f7-77480418849c",
        resume: true
    )
    #expect(!spec.arguments.contains("--resume"))
    let idx = spec.arguments.firstIndex(of: "--session")
    #expect(idx != nil)
    if let idx {
        #expect(spec.arguments[spec.arguments.index(after: idx)] == "10889bb0-624c-4ef5-94f7-77480418849c")
    }
    #expect(!spec.arguments.contains("--session-id"))
}

@Test func piTakesItsOwnArgumentsAndEnvironmentNotClaudeCodes() {
    var settings = Settings.default
    settings.claudeLaunchArgs = "--dangerously-skip-permissions"
    settings.claudeEnv = "CLAUDE_ONLY=1"
    settings.piLaunchArgs = "--provider anthropic"
    settings.piEnv = "PI_ONLY=1"

    let pi = AgentLaunchBuilder.build(
        settings: settings, review: sampleReview(), worktreePath: "/tmp/wt",
        kind: .pi, resolvedExecutablePath: "/opt/node/bin/pi", sessionID: "s", resume: false
    )
    #expect(pi.extraArgs == "--provider anthropic")
    #expect(pi.environment == "PI_ONLY=1")

    let claude = AgentLaunchBuilder.build(
        settings: settings, review: sampleReview(), worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "s", resume: false
    )
    #expect(claude.extraArgs == "--dangerously-skip-permissions")
    #expect(claude.environment == "CLAUDE_ONLY=1")
}

/// pi is a node script with an `env node` shebang. A GUI-launched login shell has no nvm
/// PATH, so without this pi exits 127 before drawing anything. Claude Code is a native binary
/// and must not have its child-process PATH altered.
@Test func onlyPiPrependsItsExecutableDirectoryToPath() {
    #expect(PiBackend().prependsExecutableDirectoryToPath)
    #expect(!ClaudeCodeBackend().prependsExecutableDirectoryToPath)

    let pi = AgentLaunchBuilder.build(
        settings: .default, review: sampleReview(), worktreePath: "/tmp/wt",
        kind: .pi, resolvedExecutablePath: "/opt/node/bin/pi", sessionID: "s", resume: false
    )
    #expect(pi.prependExecutableDirectoryToPath)

    let claude = AgentLaunchBuilder.build(
        settings: .default, review: sampleReview(), worktreePath: "/tmp/wt",
        kind: .claudeCode, resolvedExecutablePath: "/bin/claude", sessionID: "s", resume: false
    )
    #expect(!claude.prependExecutableDirectoryToPath)
}

@Test func piCarriesPerItemAgentFlagsBeforeItsOwnArguments() {
    var review = sampleReview()
    review.agentFlags = ["--thinking", "high"]
    let spec = AgentLaunchBuilder.build(
        settings: .default, review: review, worktreePath: "/tmp/wt",
        kind: .pi, resolvedExecutablePath: "/opt/node/bin/pi", sessionID: "s", resume: false
    )
    #expect(Array(spec.arguments.prefix(2)) == ["--thinking", "high"])
}

// MARK: - Transcript parsing

private func piLine(
    role: String,
    stopReason: String? = nil,
    text: String? = nil,
    timestamp: String = "2026-08-12T15:50:12.974Z"
) -> Data {
    var message: [String: Any] = ["role": role]
    if let stopReason { message["stopReason"] = stopReason }
    if let text { message["content"] = [["type": "text", "text": text]] }
    let object: [String: Any] = [
        "type": "message",
        "id": "b4075d82",
        "timestamp": timestamp,
        "message": message,
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

/// Observed stop reasons across real pi sessions: toolUse 390, stop 19, aborted 2, error 4.
/// Only "stop" means pi handed control back to the user.
@Test func piTreatsOnlyStopAsACompletedTurn() {
    let backend = PiBackend()
    let expectations: [(String, Bool)] = [
        ("stop", true),
        ("toolUse", false),
        ("aborted", false),
        ("error", false),
    ]
    for (reason, expected) in expectations {
        var state = TranscriptParseState()
        let event = backend.parse(line: piLine(role: "assistant", stopReason: reason), state: &state)
        #expect(event?.turnCompleted == expected, "stopReason: \(reason)")
    }
}

@Test func piExtractsTheFirstTextBlockAsSnippet() {
    var state = TranscriptParseState()
    let event = PiBackend().parse(
        line: piLine(role: "assistant", stopReason: "stop", text: "The error indicates that the npm package does not exist."),
        state: &state
    )
    #expect(event?.snippet == "The error indicates that the npm package does not exist.")
}

@Test func piTruncatesLongSnippetsToEightyCharacters() {
    var state = TranscriptParseState()
    let long = String(repeating: "x", count: 200)
    let event = PiBackend().parse(line: piLine(role: "assistant", stopReason: "stop", text: long), state: &state)
    #expect(event?.snippet?.count == 80)
}

/// A user turn or tool result still proves the session is alive, so it must move the status
/// clock — but it is never a completion and carries no verdict snippet.
@Test func piReportsNonAssistantMessagesAsLivenessOnly() {
    let backend = PiBackend()
    for role in ["user", "toolResult", "bashExecution"] {
        var state = TranscriptParseState()
        let event = backend.parse(line: piLine(role: role, text: "ignored"), state: &state)
        #expect(event != nil, "role: \(role)")
        #expect(event?.turnCompleted == false, "role: \(role)")
        #expect(event?.snippet == nil, "role: \(role)")
    }
}

@Test func piSkipsNonMessageLines() {
    let backend = PiBackend()
    let header = """
    {"type":"session","version":3,"id":"019ff6aa","timestamp":"2026-08-12T15:49:39.776Z","cwd":"/x"}
    """
    let modelChange = """
    {"type":"model_change","id":"3f6f476d","timestamp":"2026-08-12T15:49:39.831Z","provider":"omlx","modelId":"Q"}
    """
    for line in [header, modelChange, "not json at all", "{}"] {
        var state = TranscriptParseState()
        #expect(backend.parse(line: Data(line.utf8), state: &state) == nil, "line: \(line)")
    }
}

@Test func piNeverReportsAPendingWorkflow() {
    // pi has no workflow concept. If this ever became true, status would pin to .working and
    // never decay to idle.
    var state = TranscriptParseState()
    let event = PiBackend().parse(line: piLine(role: "assistant", stopReason: "stop"), state: &state)
    #expect(event?.workflowPending == false)
    #expect(state.pendingWorkflows == 0)
}

@Test func piParsesTimestampsWithAndWithoutFractionalSeconds() {
    let backend = PiBackend()
    var state = TranscriptParseState()
    let withFraction = backend.parse(
        line: piLine(role: "assistant", stopReason: "stop", timestamp: "2026-08-12T15:50:12.974Z"),
        state: &state
    )
    #expect(withFraction != nil)

    var state2 = TranscriptParseState()
    let withoutFraction = backend.parse(
        line: piLine(role: "assistant", stopReason: "stop", timestamp: "2026-08-12T15:50:12Z"),
        state: &state2
    )
    #expect(withoutFraction != nil)
    #expect(withFraction?.date != withoutFraction?.date)
}

/// Each backend must reject the other's schema outright, otherwise a mis-routed watcher would
/// silently report no completions instead of failing loudly.
@Test func claudeCodeDoesNotUnderstandPiTranscriptLines() {
    var state = TranscriptParseState()
    let event = ClaudeCodeBackend().parse(line: piLine(role: "assistant", stopReason: "stop"), state: &state)
    // The line has a top-level timestamp so an event is produced, but Claude Code sees
    // type "message" rather than "assistant" and so never calls it a completed turn.
    #expect(event?.turnCompleted == false)
    #expect(event?.snippet == nil)
}

@Test func piDoesNotUnderstandClaudeCodeTranscriptLines() {
    let claudeLine = """
    {"type":"assistant","timestamp":"2026-08-12T15:50:12.974Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}
    """
    var state = TranscriptParseState()
    #expect(PiBackend().parse(line: Data(claudeLine.utf8), state: &state) == nil)
}
