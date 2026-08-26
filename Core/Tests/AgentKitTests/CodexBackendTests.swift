import Testing
import Foundation
import PRPilotModels
@testable import AgentKit

/// codex's mechanics, pinned against real transcript lines.
///
/// The lines in `parse` tests below are copied verbatim from a real rollout under
/// `~/.codex/sessions`, apart from shortening long text. If codex reshapes its schema, these
/// fail rather than the status dot silently sticking at `.starting`.
struct CodexBackendTests {
    private let worktree = "/Users/me/Library/Application Support/PRPilot/worktrees.noindex/pr-990"

    private func pullRequest() -> WorkItem {
        WorkItem(
            title: "Limit transactions in RAM",
            repoKey: "github.com/o/r",
            baseBranch: "main",
            headBranch: "pr-990",
            prRef: PRRef(
                owner: "o", repo: "r", number: 990,
                url: URL(string: "https://github.com/o/r/pull/990")!,
                authorLogin: "ordishs"
            ),
            prState: .open,
            origin: .added,
            addedAt: Date()
        )
    }

    private func issue() -> WorkItem {
        WorkItem(
            title: "Limit transactions in RAM",
            repoKey: "github.com/o/r",
            baseBranch: "main",
            headBranch: "issue-4459",
            issueRef: IssueRef(
                owner: "o", repo: "r", number: 4459,
                url: URL(string: "https://github.com/o/r/issues/4459")!,
                authorLogin: "ordishs"
            ),
            origin: .added,
            addedAt: Date()
        )
    }

    // MARK: - Transcript location

    @Test func transcriptDirectoriesAreTodayAndYesterday() {
        let noon = Self.date("2026-08-26T12:00:00Z")
        let dirs = CodexBackend(now: { noon }).transcriptDirectories(forWorktreePath: worktree)
        #expect(dirs.count == 2)
        #expect(dirs[0].path.hasSuffix(".codex/sessions/2026/08/26"))
        #expect(dirs[1].path.hasSuffix(".codex/sessions/2026/08/25"))
    }

    /// A session started before midnight keeps appending to the day directory it created, so
    /// the previous day must stay in the candidate list. Across a month boundary that is not
    /// simple subtraction on the day number.
    @Test func yesterdayCrossesAMonthBoundary() {
        let firstOfMonth = Self.date("2026-09-01T00:30:00Z")
        let dirs = CodexBackend(now: { firstOfMonth }).transcriptDirectories(forWorktreePath: worktree)
        #expect(dirs[0].path.hasSuffix("/2026/09/01"))
        #expect(dirs[1].path.hasSuffix("/2026/08/31"))
    }

    @Test func yesterdayCrossesAYearBoundary() {
        let newYear = Self.date("2027-01-01T06:00:00Z")
        let dirs = CodexBackend(now: { newYear }).transcriptDirectories(forWorktreePath: worktree)
        #expect(dirs[0].path.hasSuffix("/2027/01/01"))
        #expect(dirs[1].path.hasSuffix("/2026/12/31"))
    }

    /// codex ignores the working directory entirely when it files a transcript. Two different
    /// worktrees therefore land in the same place, which is the whole reason membership has to
    /// be read out of the file.
    @Test func twoWorktreesShareTheSameDirectory() {
        let backend = CodexBackend(now: { Self.date("2026-08-26T12:00:00Z") })
        let a = backend.transcriptDirectories(forWorktreePath: "/Users/me/dev/one")
        let b = backend.transcriptDirectories(forWorktreePath: "/Users/me/dev/two")
        #expect(a == b)
    }

    // MARK: - Session ID from a file name

    @Test func sessionIDIsTheUUIDAfterTheTimestamp() {
        let name = "rollout-2026-08-26T14-08-18-01a03df8-9e0c-7672-908a-546665225b9b.jsonl"
        #expect(CodexBackend().sessionID(fromTranscriptFilename: name)
            == "01a03df8-9e0c-7672-908a-546665225b9b")
    }

    @Test func sessionIDReadsASecondRealFileName() {
        let name = "rollout-2026-08-15T17-03-06-01a005f2-b0d3-7bd0-aed9-d2114360d476.jsonl"
        #expect(CodexBackend().sessionID(fromTranscriptFilename: name)
            == "01a005f2-b0d3-7bd0-aed9-d2114360d476")
    }

    @Test func nonCodexNamesAreRejected() {
        let backend = CodexBackend()
        // Claude Code's shape.
        #expect(backend.sessionID(fromTranscriptFilename: "10889bb0-624c-4ef5-94f7-77480418849c.jsonl") == nil)
        // pi's shape.
        #expect(backend.sessionID(fromTranscriptFilename:
            "2026-08-13T11-54-02-626Z_44444444-5555-6666-7777-888888888888.jsonl") == nil)
        #expect(backend.sessionID(fromTranscriptFilename: "rollout-2026-08-26T14-08-18.jsonl") == nil)
        #expect(backend.sessionID(fromTranscriptFilename: "rollout-nope.jsonl") == nil)
        #expect(backend.sessionID(fromTranscriptFilename: "notes.txt") == nil)
        // The right number of groups, but the last one is not hexadecimal.
        #expect(backend.sessionID(fromTranscriptFilename:
            "rollout-2026-08-26T14-08-18-01a03df8-9e0c-7672-908a-zzzzzzzzzzzz.jsonl") == nil)
    }

    // MARK: - Worktree membership

    @Test func membershipComesFromTheRecordedWorkingDirectory() throws {
        let dir = try Self.tempDir()
        let mine = dir.appendingPathComponent("rollout-2026-08-26T14-08-18-11111111-1111-1111-1111-111111111111.jsonl")
        let theirs = dir.appendingPathComponent("rollout-2026-08-26T14-09-18-22222222-2222-2222-2222-222222222222.jsonl")
        try Self.writeRollout(at: mine, cwd: worktree)
        try Self.writeRollout(at: theirs, cwd: "/Users/me/dev/some-other-project")

        let backend = CodexBackend()
        #expect(backend.transcript(at: mine, belongsToWorktreePath: worktree))
        #expect(!backend.transcript(at: theirs, belongsToWorktreePath: worktree))
    }

    /// A file whose first line is not a readable `session_meta` is never claimed. Claiming it
    /// would let `archiveTranscripts` move another project's session.
    @Test func aFileWithNoSessionMetaIsNotClaimed() throws {
        let dir = try Self.tempDir()
        let url = dir.appendingPathComponent("rollout-2026-08-26T14-08-18-33333333-3333-3333-3333-333333333333.jsonl")
        try #"{"timestamp":"2026-08-26T12:00:00Z","type":"event_msg","payload":{"type":"task_started"}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(!CodexBackend().transcript(at: url, belongsToWorktreePath: worktree))

        let empty = dir.appendingPathComponent("rollout-2026-08-26T14-08-19-44444444-4444-4444-4444-444444444444.jsonl")
        try Data().write(to: empty)
        #expect(!CodexBackend().transcript(at: empty, belongsToWorktreePath: worktree))
    }

    /// codex records the resolved path. On macOS `/tmp` is a symlink to `/private/tmp`, so a
    /// literal string comparison would reject the session PR Pilot just launched.
    @Test func membershipResolvesSymlinksAndTrailingSlashes() throws {
        let dir = try Self.tempDir()
        let url = dir.appendingPathComponent("rollout-2026-08-26T14-08-18-55555555-5555-5555-5555-555555555555.jsonl")
        let resolved = dir.resolvingSymlinksInPath().path
        try Self.writeRollout(at: url, cwd: resolved)

        let backend = CodexBackend()
        #expect(backend.transcript(at: url, belongsToWorktreePath: resolved))
        #expect(backend.transcript(at: url, belongsToWorktreePath: dir.path))
        #expect(backend.transcript(at: url, belongsToWorktreePath: dir.path + "/"))
    }

    /// A real `session_meta` line carries the whole system prompt, so it runs to tens of
    /// kilobytes. The reader must still find the newline that ends it.
    @Test func membershipReadsPastAVeryLongFirstLine() throws {
        let dir = try Self.tempDir()
        let url = dir.appendingPathComponent("rollout-2026-08-26T14-08-18-66666666-6666-6666-6666-666666666666.jsonl")
        let padding = String(repeating: "You are Codex. ", count: 4000)
        let first = """
        {"timestamp":"2026-08-26T12:00:00Z","type":"session_meta","payload":{"id":"66666666-6666-6666-6666-666666666666","cwd":"\(worktree)","base_instructions":{"text":"\(padding)"}}}
        """
        let second = #"{"timestamp":"2026-08-26T12:00:01Z","type":"event_msg","payload":{"type":"task_started"}}"#
        try "\(first)\n\(second)\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(first.utf8.count > 8192)
        #expect(CodexBackend().transcript(at: url, belongsToWorktreePath: worktree))
    }

    // MARK: - Launch arguments

    @Test func freshLaunchPassesThePromptAsAPositionalArgument() {
        let args = CodexBackend().launchArguments(
            settings: Self.settings(),
            review: pullRequest(),
            sessionID: "ignored-because-codex-names-its-own",
            resume: false
        )
        #expect(args == ["Review the pull request at https://github.com/o/r/pull/990."])
    }

    /// codex has no `--name` and no `--session-id`. Passing either would abort the launch.
    @Test func freshLaunchPassesNoNameAndNoSessionID() {
        let args = CodexBackend().launchArguments(
            settings: Self.settings(),
            review: pullRequest(),
            sessionID: "01a03df8-9e0c-7672-908a-546665225b9b",
            resume: false
        )
        #expect(!args.contains("--name"))
        #expect(!args.contains("--session-id"))
        #expect(!args.contains("01a03df8-9e0c-7672-908a-546665225b9b"))
    }

    /// `resume` is a subcommand, so it has to lead. It must never be `--resume`, which is pi's
    /// flag, nor `--session`.
    @Test func resumeUsesTheSubcommandAndLeadsWithIt() {
        let args = CodexBackend().launchArguments(
            settings: Self.settings(),
            review: pullRequest(),
            sessionID: "01a03df8-9e0c-7672-908a-546665225b9b",
            resume: true
        )
        #expect(args == ["resume", "01a03df8-9e0c-7672-908a-546665225b9b"])
        #expect(args.first == "resume")
        #expect(!args.contains("--resume"))
        #expect(!args.contains("--session"))
    }

    @Test func anIssueUsesTheIssueTemplate() {
        let args = CodexBackend().launchArguments(
            settings: Self.settings(),
            review: issue(),
            sessionID: "x",
            resume: false
        )
        #expect(args == ["Start work on issue 4459."])
    }

    @Test func aBlankTemplateLaunchesWithNoPrompt() {
        var settings = Self.settings()
        settings.codexReviewPromptTemplate = ""
        let args = CodexBackend().launchArguments(
            settings: settings,
            review: pullRequest(),
            sessionID: "x",
            resume: false
        )
        #expect(args.isEmpty)
    }

    // MARK: - Parsing

    @Test func agentMessageSuppliesTheSnippet() {
        let line = #"{"timestamp":"2026-08-15T15:03:11.070Z","type":"event_msg","payload":{"type":"agent_message","message":"I'll unpack the export and inspect it.","phase":"commentary","memory_citation":null}}"#
        let event = Self.parse(line)
        #expect(event?.snippet == "I'll unpack the export and inspect it.")
        #expect(event?.turnCompleted == false)
        #expect(event?.limitMessage == nil)
    }

    @Test func aLongSnippetIsTruncatedToEightyCharacters() {
        let text = String(repeating: "a", count: 200)
        let line = """
        {"timestamp":"2026-08-15T15:03:11.070Z","type":"event_msg","payload":{"type":"agent_message","message":"\(text)"}}
        """
        #expect(Self.parse(line)?.snippet?.count == 80)
    }

    @Test func taskCompleteIsTheCompletedTurn() {
        let line = #"{"timestamp":"2026-08-15T15:03:21.717Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"01a005f2-b18c-78a3-a761-4d299bce5cb3","last_agent_message":"Done."}}"#
        let event = Self.parse(line)
        #expect(event?.turnCompleted == true)
        #expect(event?.workflowPending == false)
    }

    /// Everything else still proves the session is alive, so it moves the status clock. Only
    /// `task_complete` hands control back.
    @Test func otherLinesAreLivenessOnly() {
        let lines = [
            #"{"timestamp":"2026-08-15T15:03:06.414Z","type":"event_msg","payload":{"type":"task_started","turn_id":"a"}}"#,
            #"{"timestamp":"2026-08-15T15:03:08.475Z","type":"event_msg","payload":{"type":"user_message","message":"go"}}"#,
            #"{"timestamp":"2026-08-15T15:03:08.453Z","type":"response_item","payload":{"type":"reasoning","summary":[]}}"#,
            #"{"timestamp":"2026-08-15T15:03:09.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"shell"}}"#,
            #"{"timestamp":"2026-08-15T15:03:10.000Z","type":"turn_context","payload":{"cwd":"/x"}}"#,
        ]
        for line in lines {
            let event = Self.parse(line)
            #expect(event != nil, "\(line) produced no event")
            #expect(event?.turnCompleted == false)
            #expect(event?.snippet == nil)
            #expect(event?.limitMessage == nil)
        }
    }

    @Test func aLineWithNoTimestampIsSkipped() {
        #expect(Self.parse(#"{"type":"event_msg","payload":{"type":"task_complete"}}"#) == nil)
        #expect(Self.parse("not json at all") == nil)
    }

    /// A real, unblocked `token_count` line. Both limit fields are null, so it must stay a
    /// plain liveness event — a false limit badge would be worse than none.
    @Test func anUnblockedTokenCountIsNotALimit() {
        let line = #"{"timestamp":"2026-08-15T15:03:14.540Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":25530}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":9.0,"window_minutes":10080,"resets_at":1786206068},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}}}"#
        let event = Self.parse(line)
        #expect(event != nil)
        #expect(event?.limitMessage == nil)
    }

    /// Synthesised, not captured: no local codex session has ever been blocked. See the note
    /// on `CodexBackend.limitMessage`.
    @Test func aRateLimitReachedTypeIsALimit() {
        let line = #"{"timestamp":"2026-08-15T15:03:14.540Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1786206068},"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":"primary"}}}"#
        let message = Self.parse(line)?.limitMessage
        #expect(message?.contains("primary") == true)
        #expect(message?.contains("Resets at") == true)
    }

    @Test func aSpendControlBlockIsALimit() {
        let line = #"{"timestamp":"2026-08-15T15:03:14.540Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":null,"spend_control_reached":true,"rate_limit_reached_type":null}}}"#
        let message = Self.parse(line)?.limitMessage
        #expect(message?.contains("spend limit") == true)
    }

    /// A limit block on any other line type is not codex's limit report, and must not raise
    /// the badge.
    @Test func aLimitBlockOutsideTokenCountIsIgnored() {
        let line = #"{"timestamp":"2026-08-15T15:03:14.540Z","type":"event_msg","payload":{"type":"task_started","rate_limits":{"rate_limit_reached_type":"primary"}}}"#
        #expect(Self.parse(line)?.limitMessage == nil)
    }

    // MARK: - Protocol conformance

    @Test func codexCannotBeToldItsSessionID() {
        #expect(CodexBackend().acceptsAssignedSessionID == false)
        // The other two can, which is what keeps their launch path unchanged.
        #expect(ClaudeCodeBackend().acceptsAssignedSessionID == true)
        #expect(PiBackend().acceptsAssignedSessionID == true)
    }

    /// codex is a node script under nvm, so a GUI login shell cannot find its interpreter.
    @Test func codexNeedsItsOwnDirectoryOnPath() {
        #expect(CodexBackend().prependsExecutableDirectoryToPath == true)
    }

    /// The two directory-keyed agents claim every transcript in their own directory, so the
    /// membership filter costs them nothing.
    @Test func directoryKeyedAgentsClaimEveryFileInTheirDirectory() {
        let url = URL(fileURLWithPath: "/nonexistent/anything.jsonl")
        #expect(ClaudeCodeBackend().transcript(at: url, belongsToWorktreePath: worktree))
        #expect(PiBackend().transcript(at: url, belongsToWorktreePath: worktree))
    }

    @Test func theRegistryResolvesCodex() {
        #expect(AgentBackends.backend(for: .codex).kind == .codex)
    }

    // MARK: - Helpers

    private static func parse(_ line: String) -> TranscriptEvent? {
        var state = TranscriptParseState()
        return CodexBackend().parse(line: Data(line.utf8), state: &state)
    }

    private static func settings() -> Settings { .default }

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-backend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a transcript whose first line is a real-shaped `session_meta`.
    static func writeRollout(at url: URL, cwd: String, extraLines: [String] = []) throws {
        let meta = """
        {"timestamp":"2026-08-26T12:08:18.414Z","type":"session_meta","payload":{"session_id":"\(url.deletingPathExtension().lastPathComponent)","cwd":"\(cwd)","originator":"codex_exec","cli_version":"0.133.0","source":"cli"}}
        """
        let body = ([meta] + extraLines).joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - The assembled launch specification

/// These build the full `AgentLaunchSpec`, so they cover what `AgentLaunchBuilder` adds around
/// the backend's own arguments — the per-item flags, the user's extra arguments, the
/// environment and the PATH fix.
struct CodexLaunchSpecTests {
    private func review() -> WorkItem {
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

    @Test func freshSpecCarriesThePromptAndNoSessionFlag() {
        let spec = AgentLaunchBuilder.build(
            settings: .default,
            review: review(),
            worktreePath: "/tmp/wt",
            kind: .codex,
            resolvedExecutablePath: "/opt/node/bin/codex",
            sessionID: "10889bb0-624c-4ef5-94f7-77480418849c",
            resume: false
        )
        #expect(spec.kind == .codex)
        #expect(spec.executable == "/opt/node/bin/codex")
        #expect(spec.executableName == "codex")
        #expect(spec.arguments == ["Review the pull request at https://github.com/bsv-blockchain/teranode/pull/944."])
        #expect(!spec.arguments.contains("--session-id"))
        #expect(!spec.arguments.contains("--name"))
    }

    /// `resume` is a subcommand. Anything positional before it would be read as the prompt of a
    /// fresh session instead, so it has to stay the first argument.
    @Test func resumeSpecLeadsWithTheSubcommand() {
        let spec = AgentLaunchBuilder.build(
            settings: .default,
            review: review(),
            worktreePath: "/tmp/wt",
            kind: .codex,
            resolvedExecutablePath: "/opt/node/bin/codex",
            sessionID: "10889bb0-624c-4ef5-94f7-77480418849c",
            resume: true
        )
        #expect(spec.arguments == ["resume", "10889bb0-624c-4ef5-94f7-77480418849c"])
    }

    @Test func codexTakesItsOwnArgumentsAndEnvironment() {
        var settings = Settings.default
        settings.claudeLaunchArgs = "--dangerously-skip-permissions"
        settings.claudeEnv = "CLAUDE_ONLY=1"
        settings.piLaunchArgs = "--provider anthropic"
        settings.piEnv = "PI_ONLY=1"
        settings.codexLaunchArgs = "--model gpt-5.5"
        settings.codexEnv = "CODEX_ONLY=1"

        let codex = AgentLaunchBuilder.build(
            settings: settings, review: review(), worktreePath: "/tmp/wt",
            kind: .codex, resolvedExecutablePath: "/opt/node/bin/codex", sessionID: "s", resume: false
        )
        #expect(codex.extraArgs == "--model gpt-5.5")
        #expect(codex.environment == "CODEX_ONLY=1")

        // The other two must be untouched by codex's arrival.
        let pi = AgentLaunchBuilder.build(
            settings: settings, review: review(), worktreePath: "/tmp/wt",
            kind: .pi, resolvedExecutablePath: "/opt/node/bin/pi", sessionID: "s", resume: false
        )
        #expect(pi.extraArgs == "--provider anthropic")
        #expect(pi.environment == "PI_ONLY=1")
    }

    /// codex is a node script under nvm, so it needs the same PATH fix pi needed. Claude Code
    /// is a native binary and must keep its child-process PATH unchanged.
    @Test func codexSpecPrependsItsExecutableDirectory() {
        let codex = AgentLaunchBuilder.build(
            settings: .default, review: review(), worktreePath: "/tmp/wt",
            kind: .codex, resolvedExecutablePath: "/opt/node/bin/codex", sessionID: "s", resume: false
        )
        #expect(codex.prependExecutableDirectoryToPath)

        let claude = AgentLaunchBuilder.build(
            settings: .default, review: review(), worktreePath: "/tmp/wt",
            kind: .claudeCode, resolvedExecutablePath: "/usr/local/bin/claude", sessionID: "s", resume: false
        )
        #expect(!claude.prependExecutableDirectoryToPath)
    }

    /// The per-item flags land before the backend's arguments, so on a resume they precede the
    /// `resume` subcommand. That is valid only while they are options — a bare word there would
    /// be taken as the subcommand.
    @Test func perItemFlagsPrecedeTheSubcommand() {
        var item = review()
        item.agentFlags = ["--search"]
        let spec = AgentLaunchBuilder.build(
            settings: .default, review: item, worktreePath: "/tmp/wt",
            kind: .codex, resolvedExecutablePath: "/opt/node/bin/codex", sessionID: "sid", resume: true
        )
        #expect(spec.arguments == ["--search", "resume", "sid"])
    }
}
