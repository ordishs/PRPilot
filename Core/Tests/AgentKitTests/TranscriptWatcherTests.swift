import Testing
import Foundation
@testable import AgentKit
import PRPilotModels

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("p12-tw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let sampleAssistantLine = """
{"type":"assistant","timestamp":"2026-05-28T14:00:22.582Z","sessionId":"x","message":{"content":[{"type":"text","text":"Looks good to me"}]}}
"""

private let sampleAssistantLine2 = """
{"type":"assistant","timestamp":"2026-05-28T14:05:00.000Z","sessionId":"x","message":{"content":[{"type":"text","text":"Done"}]}}
"""

private let toolUseLine = """
{"type":"assistant","timestamp":"2026-05-28T14:06:00.000Z","sessionId":"x","message":{"stop_reason":"tool_use","content":[{"type":"text","text":"Let me check"}]}}
"""

private let endTurnLine = """
{"type":"assistant","timestamp":"2026-05-28T14:07:00.000Z","sessionId":"x","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Review complete"}]}}
"""

// A /code-review session hands the work to a background Workflow: the launching turn
// ends within seconds while the review itself runs on. These lines mirror a real
// transcript (PR #1488) in order.
private let workflowLaunchLine = """
{"type":"assistant","timestamp":"2026-05-28T15:00:00.000Z","sessionId":"x","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Workflow","input":{"name":"code-review"}}]}}
"""

private let workflowLaunchedEndTurnLine = """
{"type":"assistant","timestamp":"2026-05-28T15:00:03.000Z","sessionId":"x","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Review workflow is running in the background"}]}}
"""

private let turnDurationPendingLine = """
{"type":"system","subtype":"turn_duration","timestamp":"2026-05-28T15:00:03.100Z","durationMs":5881,"pendingWorkflowCount":1}
"""

private let taskNotificationLine = """
{"type":"user","timestamp":"2026-05-28T15:13:00.000Z","message":{"role":"user","content":"<task-notification>\\n<task-id>wo10ximxm</task-id>\\n</task-notification>"}}
"""

private let findingsEndTurnLine = """
{"type":"assistant","timestamp":"2026-05-28T15:13:30.000Z","sessionId":"x","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"3 confirmed findings"}]}}
"""

private let turnDurationSettledLine = """
{"type":"system","subtype":"turn_duration","timestamp":"2026-05-28T15:13:30.100Z","durationMs":30000}
"""

@Test @MainActor func watcherWithholdsTurnCompletionWhileWorkflowPending() async throws {
    // /code-review launches a background Workflow and ends its turn ~6s later. That
    // end_turn is not the review finishing — the findings arrive minutes later.
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    let lines = [workflowLaunchLine, workflowLaunchedEndTurnLine, turnDurationPendingLine]
    try (lines.joined(separator: "\n") + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }
    try await Task.sleep(nanoseconds: 300_000_000)

    let launched = received.first { $0.snippet == "Review workflow is running in the background" }
    #expect(launched?.turnCompleted == false)
    #expect(received.last?.workflowPending == true)
    watcher.stop()
}

@Test @MainActor func watcherReportsTurnCompletionAfterWorkflowReportsBack() async throws {
    // Once the workflow reports back, the next end_turn IS the real completion.
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    let lines = [
        workflowLaunchLine,
        workflowLaunchedEndTurnLine,
        turnDurationPendingLine,
        taskNotificationLine,
        findingsEndTurnLine,
        turnDurationSettledLine,
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }
    try await Task.sleep(nanoseconds: 300_000_000)

    let completions = received.filter(\.turnCompleted)
    #expect(completions.count == 1)
    #expect(completions.first?.snippet == "3 confirmed findings")
    #expect(received.last?.workflowPending == false)
    watcher.stop()
}

@Test @MainActor func watcherTracksEachOfTwoPendingWorkflowsSeparately() async throws {
    // Two workflows in flight: the first report-back must not release the turn.
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let secondLaunch = """
    {"type":"assistant","timestamp":"2026-05-28T15:00:01.000Z","sessionId":"x","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Workflow","input":{"name":"code-review"}}]}}
    """
    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    let lines = [
        workflowLaunchLine,
        secondLaunch,
        taskNotificationLine,
        workflowLaunchedEndTurnLine,
        taskNotificationLine,
        findingsEndTurnLine,
    ]
    try (lines.joined(separator: "\n") + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }
    try await Task.sleep(nanoseconds: 300_000_000)

    let completions = received.filter(\.turnCompleted)
    #expect(completions.count == 1)
    #expect(completions.first?.snippet == "3 confirmed findings")
    watcher.stop()
}

@Test @MainActor func watcherReportsTurnCompletedOnlyForEndTurn() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (toolUseLine + "\n" + endTurnLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }
    try await Task.sleep(nanoseconds: 300_000_000)

    // The tool_use line is not a completed turn; the end_turn line is.
    #expect(received.contains { $0.snippet == "Let me check" && !$0.turnCompleted })
    #expect(received.contains { $0.snippet == "Review complete" && $0.turnCompleted })
    watcher.stop()
}

@Test @MainActor func watcherDetectsExistingTranscript() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (sampleAssistantLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }

    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(!received.isEmpty)
    #expect(received.last?.snippet == "Looks good to me")
    watcher.stop()
}

@Test @MainActor func watcherDetectsAppendedEvent() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (sampleAssistantLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }
    try await Task.sleep(nanoseconds: 300_000_000)
    let initialCount = received.count

    let handle = try FileHandle(forWritingTo: jsonl)
    try handle.seekToEnd()
    try handle.write(contentsOf: (sampleAssistantLine2 + "\n").data(using: .utf8)!)
    try handle.close()

    try await Task.sleep(nanoseconds: 600_000_000)

    #expect(received.count > initialCount)
    #expect(received.last?.snippet == "Done")
    watcher.stop()
}

@Test @MainActor func watcherStopsFiringAfterStop() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    try (sampleAssistantLine + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }
    try await Task.sleep(nanoseconds: 300_000_000)
    watcher.stop()
    let countAfterStop = received.count

    let handle = try FileHandle(forWritingTo: jsonl)
    try handle.seekToEnd()
    try handle.write(contentsOf: (sampleAssistantLine2 + "\n").data(using: .utf8)!)
    try handle.close()

    try await Task.sleep(nanoseconds: 600_000_000)

    #expect(received.count == countAfterStop)
}

@Test @MainActor func watcherIgnoresMalformedLines() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let jsonl = tempDir.appendingPathComponent("session.jsonl")
    let mixed = "{not json}\n" + sampleAssistantLine + "\n{\"type\":\"unknown\"}\n"
    try mixed.write(to: jsonl, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(received.count == 1)
    #expect(received.last?.snippet == "Looks good to me")
    watcher.stop()
}

// MARK: - Reporting which transcript is being tailed

/// The app has to know which session the agent is actually writing, not just the one it
/// launched: `/clear` inside Claude Code starts a new transcript under a new id, and an item
/// that keeps resuming the launched id reopens the conversation the user threw away.
@Test @MainActor func watcherReportsTheSessionIdOfTheFileItAttachesTo() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let first = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    try (sampleAssistantLine + "\n").write(
        to: tempDir.appendingPathComponent("\(first).jsonl"), atomically: true, encoding: .utf8
    )

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    defer { watcher.stop() }
    var files: [String] = []
    watcher.start(onEvent: { _ in }, onSessionFile: { files.append($0) })

    #expect(files == [first])

    // The user runs /clear: Claude Code opens a new transcript, now the newest file.
    let second = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    try (sampleAssistantLine2 + "\n").write(
        to: tempDir.appendingPathComponent("\(second).jsonl"), atomically: true, encoding: .utf8
    )
    try await Task.sleep(nanoseconds: 400_000_000)

    #expect(files == [first, second], "the switch to the new transcript is reported")
}

/// A watcher with no interest in the file name still works. Every existing caller passes one
/// closure, and the transcript reporting is opt-in.
@Test @MainActor func watcherStillWorksWithoutTheSessionFileCallback() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try (sampleAssistantLine + "\n").write(
        to: tempDir.appendingPathComponent("cccccccc-cccc-cccc-cccc-cccccccccccc.jsonl"),
        atomically: true, encoding: .utf8
    )

    let watcher = TranscriptWatcher(transcriptDir: tempDir, kind: .claudeCode)
    defer { watcher.stop() }
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(received.count == 1)
}

// MARK: - codex: two candidate directories, one shared with every other project

/// codex writes every project's sessions into one day directory, so "newest file in the
/// directory" is the wrong answer. The watcher must tail this worktree's transcript even when
/// another project's is newer.
@Test @MainActor func watcherIgnoresANewerTranscriptFromAnotherProject() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let worktree = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: worktree) }

    let mine = dir.appendingPathComponent("rollout-2026-08-26T14-00-00-11111111-1111-1111-1111-111111111111.jsonl")
    try codexRollout(cwd: worktree.path, message: "mine").write(to: mine, atomically: true, encoding: .utf8)

    let theirs = dir.appendingPathComponent("rollout-2026-08-26T14-05-00-22222222-2222-2222-2222-222222222222.jsonl")
    try codexRollout(cwd: "/Users/me/dev/unrelated", message: "theirs")
        .write(to: theirs, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: theirs.path
    )

    let watcher = TranscriptWatcher(transcriptDirs: [dir], kind: .codex, worktreePath: worktree.path)
    var received: [TranscriptEvent] = []
    var sessionIDs: [String] = []
    watcher.start(onEvent: { received.append($0) }, onSessionFile: { sessionIDs.append($0) })
    try await Task.sleep(nanoseconds: 300_000_000)
    watcher.stop()

    #expect(sessionIDs == ["11111111-1111-1111-1111-111111111111"])
    #expect(received.contains { $0.snippet == "mine" })
    #expect(!received.contains { $0.snippet == "theirs" })
}

/// A session that starts before midnight keeps appending to the previous day's directory, so
/// the watcher covers more than one. It must find the transcript in either.
@Test @MainActor func watcherFindsATranscriptInASecondCandidateDirectory() async throws {
    let today = try makeTempDir()
    let yesterday = try makeTempDir()
    defer {
        try? FileManager.default.removeItem(at: today)
        try? FileManager.default.removeItem(at: yesterday)
    }
    let worktree = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: worktree) }

    let url = yesterday.appendingPathComponent("rollout-2026-08-25T23-59-00-33333333-3333-3333-3333-333333333333.jsonl")
    try codexRollout(cwd: worktree.path, message: "across midnight")
        .write(to: url, atomically: true, encoding: .utf8)

    let watcher = TranscriptWatcher(
        transcriptDirs: [today, yesterday], kind: .codex, worktreePath: worktree.path
    )
    var received: [TranscriptEvent] = []
    watcher.start { received.append($0) }
    try await Task.sleep(nanoseconds: 300_000_000)
    watcher.stop()

    #expect(received.contains { $0.snippet == "across midnight" })
    #expect(received.last?.turnCompleted == true)
}

/// A codex transcript with `session_meta`, one agent message and a completed turn.
private func codexRollout(cwd: String, message: String) -> String {
    let lines = [
        #"{"timestamp":"2026-08-26T12:00:00.000Z","type":"session_meta","payload":{"cwd":"\#(cwd)","originator":"cli"}}"#,
        #"{"timestamp":"2026-08-26T12:00:01.000Z","type":"event_msg","payload":{"type":"agent_message","message":"\#(message)"}}"#,
        #"{"timestamp":"2026-08-26T12:00:02.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}"#,
    ]
    return lines.joined(separator: "\n") + "\n"
}
