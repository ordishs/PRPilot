import Testing
import Foundation
import PRPilotModels
@testable import AgentKit

/// Reading a conversation back out of each agent's transcript.
///
/// Every line below is the real shape that agent writes. A handover built from the wrong field
/// is worse than no handover: the receiving agent would be told confidently about work that
/// never happened.
struct ConversationEntryTests {
    // MARK: - Claude Code

    @Test func claudeCodeReadsBothRoles() {
        let user = #"{"type":"user","timestamp":"2026-08-26T12:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Review the pull request."}]}}"#
        let assistant = #"{"type":"assistant","timestamp":"2026-08-26T12:00:05.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"I found two problems in the block assembler."}]}}"#

        let backend = ClaudeCodeBackend()
        let first = backend.conversationEntry(line: Data(user.utf8))
        #expect(first?.role == .user)
        #expect(first?.text == "Review the pull request.")

        let second = backend.conversationEntry(line: Data(assistant.utf8))
        #expect(second?.role == .assistant)
        #expect(second?.text == "I found two problems in the block assembler.")
    }

    /// A user turn can be a bare string rather than a content array.
    @Test func claudeCodeReadsAStringUserTurn() {
        let line = #"{"type":"user","timestamp":"2026-08-26T12:00:00.000Z","message":{"role":"user","content":"carry on"}}"#
        let entry = ClaudeCodeBackend().conversationEntry(line: Data(line.utf8))
        #expect(entry?.role == .user)
        #expect(entry?.text == "carry on")
    }

    /// A tool result arrives as a "user" line. It is the harness reporting back, not the person,
    /// and a dozen of them would crowd the real conversation out of the note.
    @Test func claudeCodeSkipsToolResultsAndReminders() {
        let toolResult = #"{"type":"user","timestamp":"2026-08-26T12:00:01.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}"#
        #expect(ClaudeCodeBackend().conversationEntry(line: Data(toolResult.utf8)) == nil)

        let reminder = #"{"type":"user","timestamp":"2026-08-26T12:00:02.000Z","message":{"role":"user","content":"<system-reminder>do not do that</system-reminder>"}}"#
        #expect(ClaudeCodeBackend().conversationEntry(line: Data(reminder.utf8)) == nil)
    }

    /// A tool call is not a turn either. The assistant line that carries one has no text block,
    /// so it must not produce an empty entry.
    @Test func claudeCodeSkipsALineWithNoText() {
        let toolUse = #"{"type":"assistant","timestamp":"2026-08-26T12:00:03.000Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"x"}]}}"#
        #expect(ClaudeCodeBackend().conversationEntry(line: Data(toolUse.utf8)) == nil)

        let system = #"{"type":"system","subtype":"turn_duration","timestamp":"2026-08-26T12:00:04.000Z"}"#
        #expect(ClaudeCodeBackend().conversationEntry(line: Data(system.utf8)) == nil)
    }

    // MARK: - pi

    @Test func piReadsBothRoles() {
        let user = #"{"type":"message","timestamp":"2026-08-26T12:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"start work"}]}}"#
        let assistant = #"{"type":"message","timestamp":"2026-08-26T12:00:06.000Z","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Done — the UTXO check now runs before the reorg."}]}}"#

        let backend = PiBackend()
        #expect(backend.conversationEntry(line: Data(user.utf8))?.role == .user)
        #expect(backend.conversationEntry(line: Data(assistant.utf8))?.text
            == "Done — the UTXO check now runs before the reorg.")
    }

    @Test func piSkipsNonMessageLines() {
        let header = #"{"type":"session_header","timestamp":"2026-08-26T12:00:00.000Z"}"#
        #expect(PiBackend().conversationEntry(line: Data(header.utf8)) == nil)
        let toolOnly = #"{"type":"message","timestamp":"2026-08-26T12:00:00.000Z","message":{"role":"assistant","content":[{"type":"toolUse","name":"bash"}]}}"#
        #expect(PiBackend().conversationEntry(line: Data(toolOnly.utf8)) == nil)
    }

    // MARK: - codex

    @Test func codexReadsBothRoles() {
        let user = #"{"timestamp":"2026-08-26T12:00:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"take over from here"}}"#
        let assistant = #"{"timestamp":"2026-08-26T12:00:07.000Z","type":"event_msg","payload":{"type":"agent_message","message":"I read the note and picked up the failing test.","phase":"commentary"}}"#

        let backend = CodexBackend()
        #expect(backend.conversationEntry(line: Data(user.utf8))?.role == .user)
        #expect(backend.conversationEntry(line: Data(assistant.utf8))?.text
            == "I read the note and picked up the failing test.")
    }

    /// codex records each turn twice — once as an `event_msg` and once as a `response_item`.
    /// Reading both would double every turn in the note.
    @Test func codexReadsTheEventFormOnlyOnce() {
        let responseItem = #"{"timestamp":"2026-08-26T12:00:07.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I read the note."}]}}"#
        #expect(CodexBackend().conversationEntry(line: Data(responseItem.utf8)) == nil)

        let reasoning = #"{"timestamp":"2026-08-26T12:00:06.000Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"thinking"}}"#
        #expect(CodexBackend().conversationEntry(line: Data(reasoning.utf8)) == nil)
    }

    // MARK: - Reading a whole transcript

    @Test func entriesReadAWholeCodexTranscriptInOrder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("rollout-2026-08-26T12-00-00-11111111-1111-1111-1111-111111111111.jsonl")
        let lines = [
            #"{"timestamp":"2026-08-26T12:00:00.000Z","type":"session_meta","payload":{"cwd":"/x"}}"#,
            #"{"timestamp":"2026-08-26T12:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"one"}}"#,
            #"{"timestamp":"2026-08-26T12:00:02.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#,
            #"{"timestamp":"2026-08-26T12:00:03.000Z","type":"event_msg","payload":{"type":"agent_message","message":"two"}}"#,
            #"{"timestamp":"2026-08-26T12:00:04.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let entries = HandoverNote.entries(inTranscriptAt: url, kind: .codex)
        #expect(entries.map(\.text) == ["one", "two"])
        #expect(entries.map(\.role) == [.user, .assistant])
    }
}

/// The note itself. It is the only thing the receiving agent gets, so what it says matters as
/// much as that it exists.
struct HandoverNoteTests {
    private func item() -> WorkItem {
        WorkItem(
            title: "Limit transactions in RAM",
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

    private func entry(_ role: HandoverEntry.Role, _ text: String, offset: TimeInterval = 0) -> HandoverEntry {
        HandoverEntry(role: role, date: Date(timeIntervalSince1970: 1_786_000_000 + offset), text: text)
    }

    private func render(
        entries: [HandoverEntry],
        reason: String? = "You've reached your usage limit. It will reset at 3pm.",
        transcriptPath: String? = "/Users/me/.claude/projects/-x/abc.jsonl"
    ) -> String {
        HandoverNote.render(
            item: item(),
            from: .claudeCode,
            to: .codex,
            reason: reason,
            entries: entries,
            transcriptPath: transcriptPath,
            now: Date(timeIntervalSince1970: 1_786_000_100)
        )
    }

    @Test func theNoteNamesBothAgentsAndSaysWhoWroteIt() {
        let note = render(entries: [entry(.user, "go")])
        #expect(note.contains("Claude Code → Codex"))
        // The receiving agent must not read the note as the previous agent's own words.
        #expect(note.contains("PR Pilot wrote this note. It is not from Claude Code."))
    }

    @Test func theNoteCarriesTheWorkAndTheReason() {
        let note = render(entries: [entry(.user, "go")])
        #expect(note.contains("Limit transactions in RAM"))
        #expect(note.contains("#4459"))
        #expect(note.contains("github.com/bsv-blockchain/teranode/issues/4459"))
        #expect(note.contains("issue-4459"))
        #expect(note.contains("You've reached your usage limit. It will reset at 3pm."))
    }

    /// The receiving agent inherits a working tree it did not create. Edits the conversation
    /// never mentions are the likeliest way for it to go wrong.
    @Test func theNoteTellsTheNewAgentToCheckTheWorkingTree() {
        #expect(render(entries: []).contains("Check the working tree first"))
    }

    @Test func theNoteCarriesTheConversationWithRoles() {
        let note = render(entries: [
            entry(.user, "Start work on issue 4459.", offset: 0),
            entry(.assistant, "I have changed the mempool limit.", offset: 60),
        ])
        #expect(note.contains("Start work on issue 4459."))
        #expect(note.contains("I have changed the mempool limit."))
        // The assistant's turns are attributed to the agent that wrote them, not to "Assistant".
        #expect(note.contains("### Claude Code"))
        #expect(note.contains("### User"))
    }

    @Test func theNoteNamesTheTranscriptSoTheNewAgentCanReadFurtherBack() {
        let note = render(entries: [entry(.user, "go")])
        #expect(note.contains("/Users/me/.claude/projects/-x/abc.jsonl"))
    }

    /// A transcript that yielded nothing must produce a note that says so, rather than an empty
    /// section the new agent might read as "there was no prior work".
    @Test func anEmptyConversationIsStatedPlainly() {
        let note = render(entries: [])
        #expect(note.contains("no readable turns"))
        #expect(note.contains("fresh start"))
    }

    @Test func aMissingReasonStillProducesAUsableNote() {
        let note = render(entries: [entry(.user, "go")], reason: nil)
        #expect(note.contains("stopped mid-task"))
        #expect(!note.contains("> "))
    }

    @Test func aMissingTranscriptOmitsThePointerRatherThanNamingNothing() {
        let note = render(entries: [entry(.user, "go")], transcriptPath: nil)
        #expect(!note.contains("full transcript"))
    }

    /// Not every turn is carried, and the note says how many it left out — otherwise the new
    /// agent would read a truncated history as the whole history.
    @Test func onlySomeTurnsAreCarriedAndTheNoteSaysSo() {
        let many = (0..<40).map { entry(.assistant, "turn \($0)", offset: TimeInterval($0)) }
        let note = render(entries: many)
        #expect(note.contains("\(HandoverNote.turnLimit) of 40 turns"))
        #expect(note.contains("turn 39"))
        #expect(!note.contains("turn 0\n"))
    }

    @Test func aVeryLongTurnIsTruncatedAndLabelled() {
        let long = String(repeating: "x", count: 5000)
        let note = render(entries: [entry(.assistant, long)])
        #expect(note.contains("[truncated — see the transcript]"))
        #expect(note.count < 5000)
    }
}

/// The pointer that makes the note reach the new agent at all. Without it the note is a file
/// nobody opens.
struct HandoverPromptTests {
    private func item(handover: String?) -> WorkItem {
        var item = WorkItem(
            title: "fix",
            repoKey: "github.com/o/r",
            baseBranch: "main",
            headBranch: "fix",
            prRef: PRRef(
                owner: "o", repo: "r", number: 1,
                url: URL(string: "https://github.com/o/r/pull/1")!,
                authorLogin: "me"
            ),
            prState: .open,
            origin: .added,
            addedAt: Date()
        )
        item.pendingHandoverPath = handover
        return item
    }

    @Test func aPendingHandoverLeadsThePrompt() {
        let prompt = LaunchPrompt.render(
            "Review the pull request at {url}.",
            for: item(handover: "/wt/HANDOVER.md"),
            url: URL(string: "https://github.com/o/r/pull/1")
        )
        #expect(prompt.contains("/wt/HANDOVER.md"))
        // Ordering is the whole point: an agent told to review first will start over before it
        // reaches the note.
        let noteIndex = prompt.range(of: "HANDOVER.md")!.lowerBound
        let taskIndex = prompt.range(of: "Review the pull request")!.lowerBound
        #expect(noteIndex < taskIndex)
    }

    @Test func noHandoverLeavesThePromptExactlyAsItWas() {
        let prompt = LaunchPrompt.render(
            "Review the pull request at {url}.",
            for: item(handover: nil),
            url: URL(string: "https://github.com/o/r/pull/1")
        )
        #expect(prompt == "Review the pull request at https://github.com/o/r/pull/1.")
    }

    /// A user who deliberately blanked the template still needs the handover to arrive.
    @Test func aBlankTemplateStillSendsTheHandover() {
        let prompt = LaunchPrompt.render("", for: item(handover: "/wt/HANDOVER.md"), url: nil)
        #expect(prompt.contains("/wt/HANDOVER.md"))
    }

    @Test func aBlankTemplateWithNoHandoverStaysEmpty() {
        #expect(LaunchPrompt.render("", for: item(handover: nil), url: nil).isEmpty)
    }

    /// Every backend renders its prompt through `LaunchPrompt`, so all three carry the note.
    @Test func allThreeAgentsCarryTheHandoverIntoTheirLaunchArguments() {
        let item = item(handover: "/wt/HANDOVER.md")
        for kind in AgentKind.allCases {
            let spec = AgentLaunchBuilder.build(
                settings: .default,
                review: item,
                worktreePath: "/wt",
                kind: kind,
                resolvedExecutablePath: "/bin/agent",
                sessionID: "sid",
                resume: false
            )
            #expect(
                spec.arguments.contains { $0.contains("/wt/HANDOVER.md") },
                "\(kind.displayName) dropped the handover note"
            )
        }
    }
}

/// Which turns get carried. Found by running the renderer against a real 56-turn transcript:
/// the plain tail held no user turn at all, so the note said what the previous agent had been
/// saying and nothing about what it had been asked to do.
struct HandoverSelectionTests {
    private func entries(_ roles: [HandoverEntry.Role]) -> [HandoverEntry] {
        roles.enumerated().map { index, role in
            HandoverEntry(
                role: role,
                date: Date(timeIntervalSince1970: 1_786_000_000 + TimeInterval(index)),
                text: "\(role.rawValue) \(index)"
            )
        }
    }

    @Test func aShortConversationIsCarriedWhole() {
        let all = entries([.user, .assistant, .user, .assistant])
        #expect(HandoverNote.carriedIndices(of: all) == [0, 1, 2, 3])
    }

    @Test func anEmptyConversationCarriesNothing() {
        #expect(HandoverNote.carriedIndices(of: []).isEmpty)
    }

    /// The real failure. A long tail of assistant turns must not push every user turn out.
    @Test func theFirstAndLastUserTurnsSurviveALongAssistantTail() {
        var roles: [HandoverEntry.Role] = [.user, .assistant, .user]
        roles.append(contentsOf: Array(repeating: .assistant, count: 40))
        let all = entries(roles)

        let kept = HandoverNote.carriedIndices(of: all)
        // The original request, index 0, is far outside the tail window.
        #expect(kept.contains(0))
        // The most recent instruction, index 2, likewise.
        #expect(kept.contains(2))
        #expect(kept.contains(all.count - 1))
        #expect(kept == kept.sorted(), "turns must stay in the order they happened")
        #expect(kept.count == HandoverNote.turnLimit + 2)
    }

    /// Nothing is duplicated when the intent turns already sit inside the tail.
    @Test func userTurnsInsideTheWindowAreNotAddedTwice() {
        var roles: [HandoverEntry.Role] = Array(repeating: .assistant, count: 30)
        roles.append(contentsOf: [.user, .assistant, .user, .assistant])
        let all = entries(roles)
        let kept = HandoverNote.carriedIndices(of: all)
        #expect(kept.count == Set(kept).count)
        #expect(kept.count == HandoverNote.turnLimit)
    }

    /// A gap in the carried turns is stated, so the receiving agent never reads two distant
    /// turns as consecutive.
    @Test func theNoteMarksWhereTurnsWereOmitted() {
        var roles: [HandoverEntry.Role] = [.user]
        roles.append(contentsOf: Array(repeating: .assistant, count: 40))
        let all = entries(roles)

        let note = HandoverNote.render(
            item: WorkItem(
                title: "t", repoKey: "github.com/o/r", baseBranch: "main", headBranch: "b",
                origin: .added, addedAt: Date()
            ),
            from: .claudeCode, to: .codex, reason: nil, entries: all,
            transcriptPath: nil, now: Date(timeIntervalSince1970: 1_786_001_000)
        )
        #expect(note.contains("turns omitted"))
        #expect(note.contains("of \(all.count) turns"))
    }

    @Test func aSingleOmittedTurnReadsAsOneTurn() {
        var roles: [HandoverEntry.Role] = [.user, .assistant]
        roles.append(contentsOf: Array(repeating: .assistant, count: HandoverNote.turnLimit))
        let all = entries(roles)
        let note = HandoverNote.render(
            item: WorkItem(
                title: "t", repoKey: "github.com/o/r", baseBranch: "main", headBranch: "b",
                origin: .added, addedAt: Date()
            ),
            from: .claudeCode, to: .codex, reason: nil, entries: all,
            transcriptPath: nil, now: Date(timeIntervalSince1970: 1_786_001_000)
        )
        #expect(note.contains("1 turn omitted"))
        #expect(!note.contains("1 turns omitted"))
    }
}
