import Testing
import Foundation
import PRPilotModels
@testable import AgentKit

/// A verbatim pi transcript, captured from a real pi session run inside the PR Pilot worktree
/// "bsv-blockchain-teranode-issue-4459-limit-transactions-in-ram" on 2026-08-13. Kept byte for
/// byte rather than hand-written, so the parser is proved against what pi actually emits:
/// four non-message header lines, then user -> assistant(toolUse) -> toolResult ->
/// assistant(stop).
private let realPiTranscript = #"""
{"type":"session","version":3,"id":"44444444-5555-6666-7777-888888888888","timestamp":"2026-08-13T11:54:02.626Z","cwd":"/Users/ordishs/Library/Application Support/PRPilot/worktrees.noindex/bsv-blockchain-teranode-issue-4459-limit-transactions-in-ram"}
{"type":"session_info","id":"9f91ec01","parentId":null,"timestamp":"2026-08-13T11:54:02.627Z","name":"spike-4459"}
{"type":"model_change","id":"1ed3f516","parentId":"9f91ec01","timestamp":"2026-08-13T11:54:02.831Z","provider":"anthropic","modelId":"claude-opus-5"}
{"type":"thinking_level_change","id":"58a2eb75","parentId":"1ed3f516","timestamp":"2026-08-13T11:54:02.831Z","thinkingLevel":"medium"}
{"type":"message","id":"cbe12d45","parentId":"58a2eb75","timestamp":"2026-08-13T11:54:02.851Z","message":{"role":"user","content":[{"type":"text","text":"Name the top-level directories here. Two lines maximum."}],"timestamp":1786622042850}}
{"type":"message","id":"412698ad","parentId":"cbe12d45","timestamp":"2026-08-13T11:54:08.567Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"toolu_017de9EJs4NqWLBXeFu9qu1U","name":"bash","arguments":{"command":"ls -d */ | tr '\\n' ' '"}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-opus-5","usage":{"input":2,"output":62,"cacheRead":0,"cacheWrite":13301,"totalTokens":13365,"cost":{"input":0.00001,"output":0.0015500000000000002,"cacheRead":0,"cacheWrite":0.08313125,"total":0.08469125000000001},"cacheWrite1h":0,"reasoning":0},"stopReason":"toolUse","timestamp":1786622042861,"responseId":"msg_011CdzhhRan57jCnpcgps9rd","rawStopReason":"tool_use"}}
{"type":"message","id":"9425c617","parentId":"412698ad","timestamp":"2026-08-13T11:54:08.577Z","message":{"role":"toolResult","toolCallId":"toolu_017de9EJs4NqWLBXeFu9qu1U","toolName":"bash","content":[{"type":"text","text":"cmd/ compose/ daemon/ deploy/ docs/ errors/ interfaces/ internal/ model/ openapi/ pkg/ plans/ scripts/ seeds/ services/ settings/ stores/ test/ ui/ ulogger/ util/ "}],"isError":false,"timestamp":1786622048577}}
{"type":"message","id":"4eb75e04","parentId":"9425c617","timestamp":"2026-08-13T11:54:11.126Z","message":{"role":"assistant","content":[{"type":"text","text":"cmd, compose, daemon, deploy, docs, errors, interfaces, internal, model, openapi, pkg,\nplans, scripts, seeds, services, settings, stores, test, ui, ulogger, util"}],"api":"anthropic-messages","provider":"anthropic","model":"claude-opus-5","usage":{"input":2,"output":72,"cacheRead":13301,"cacheWrite":159,"totalTokens":13534,"cost":{"input":0.00001,"output":0.0018000000000000002,"cacheRead":0.006650499999999999,"cacheWrite":0.00099375,"total":0.009454249999999999},"cacheWrite1h":0,"reasoning":0},"stopReason":"stop","timestamp":1786622048577,"responseId":"msg_011CdzhhqmKkL1g7S7AZi5w3","rawStopReason":"end_turn"}}
"""#

@MainActor
private func replayIntoWatcher(_ transcript: String, kind: AgentKind) async throws -> [TranscriptEvent] {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Named the way pi names transcripts, so the watcher recognises it as one.
    let file = dir.appendingPathComponent("2026-08-13T11-54-02-626Z_44444444-5555-6666-7777-888888888888.jsonl")
    try (transcript + "\n").write(to: file, atomically: true, encoding: .utf8)

    var received: [TranscriptEvent] = []
    let watcher = TranscriptWatcher(transcriptDir: dir, kind: kind)
    watcher.start { received.append($0) }
    // The watcher replays an existing transcript on attach, so no waiting is needed.
    watcher.stop()
    return received
}

@Test @MainActor func watcherReplaysARealPiTranscriptAndReportsOneCompletion() async throws {
    let events = try await replayIntoWatcher(realPiTranscript, kind: .pi)

    // The four header lines carry no message and must be skipped; the four message lines
    // (user, assistant/toolUse, toolResult, assistant/stop) each produce one event.
    #expect(events.count == 4)
    #expect(events.filter(\.turnCompleted).count == 1)
    // Only the final assistant line completes the turn.
    #expect(events.last?.turnCompleted == true)
    // pi has no workflows, so nothing may ever pin the status to working.
    #expect(events.allSatisfy { !$0.workflowPending })
}

/// The status a PR Pilot pane would actually show while replaying that real session.
@Test @MainActor func realPiSessionDrivesStatusFromWorkingToAwaitingInput() async throws {
    let events = try await replayIntoWatcher(realPiTranscript, kind: .pi)
    let reader = AgentStatusReader()

    let firstEvent = try #require(events.first)
    let working = reader.status(
        processState: .running,
        lastEventAt: firstEvent.date,
        lastVerdictSnippet: nil,
        now: firstEvent.date.addingTimeInterval(1),
        lastEventWasTurnCompletion: firstEvent.turnCompleted
    )
    #expect(working == .working)

    let final = try #require(events.last)
    let awaiting = reader.status(
        processState: .running,
        lastEventAt: final.date,
        lastVerdictSnippet: final.snippet,
        // Well past the idle threshold: a completed turn must stay awaitingInput rather than
        // decaying to idle, because pi is waiting on the user, not stalled.
        now: final.date.addingTimeInterval(600),
        lastEventWasTurnCompletion: final.turnCompleted
    )
    #expect(awaiting == .awaitingInput(since: final.date, lastVerdictSnippet: final.snippet))
}

/// Routing this transcript to the wrong backend must yield no completion, which is what would
/// happen if an item's agent and its transcript directory ever disagreed.
@Test @MainActor func claudeCodeFindsNoCompletionInARealPiTranscript() async throws {
    // Claude Code rejects the pi file name outright, so it never even opens the file.
    let events = try await replayIntoWatcher(realPiTranscript, kind: .claudeCode)
    #expect(events.isEmpty)
}
