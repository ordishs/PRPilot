import Testing
import Foundation
@testable import AgentKit

private let limitText =
    "You've hit your individual spend limit · run /usage-credits to ask your admin for a higher limit"

/// One real assistant line, as the watcher hands it to the backend.
private func assistantLine(stopReason: String, text: String, at ts: String) -> Data {
    let payload: [String: Any] = [
        "type": "assistant",
        "timestamp": ts,
        "message": [
            "role": "assistant",
            "stop_reason": stopReason,
            "content": [["type": "text", "text": text]],
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: payload)
}

@Test func backendReportsTheLimitMessageFromARealLine() {
    var state = TranscriptParseState()
    let event = ClaudeCodeBackend().parse(
        line: assistantLine(stopReason: "stop_sequence", text: limitText, at: "2026-08-20T14:41:49.190Z"),
        state: &state
    )
    #expect(event?.limitMessage == limitText)
    #expect(event?.turnCompleted == false)
}

@Test func backendReportsNoLimitForTheNudgeReply() {
    var state = TranscriptParseState()
    let event = ClaudeCodeBackend().parse(
        line: assistantLine(stopReason: "stop_sequence", text: "No response requested.", at: "2026-08-20T14:26:24.501Z"),
        state: &state
    )
    #expect(event?.limitMessage == nil)
}

@Test func backendReportsNoLimitForAnOrdinaryCompletedTurn() {
    var state = TranscriptParseState()
    let event = ClaudeCodeBackend().parse(
        line: assistantLine(stopReason: "end_turn", text: "Review done.", at: "2026-08-20T14:41:49.190Z"),
        state: &state
    )
    #expect(event?.limitMessage == nil)
    #expect(event?.turnCompleted == true)
}

// MARK: - Status

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func aLimitEventReadsAsLimited() {
    let status = AgentStatusReader().status(
        processState: .running,
        lastEventAt: t0,
        lastVerdictSnippet: nil,
        now: t0.addingTimeInterval(5),
        limitMessage: limitText
    )
    #expect(status == .limited(since: t0, message: limitText))
}

@Test func limitedBeatsWorkingAndDoesNotDecayToIdle() {
    // Long after the event, a blocked agent is still blocked — not idle.
    let status = AgentStatusReader().status(
        processState: .running,
        lastEventAt: t0,
        lastVerdictSnippet: nil,
        now: t0.addingTimeInterval(3600),
        limitMessage: limitText
    )
    #expect(status == .limited(since: t0, message: limitText))
}

@Test func limitedWinsOverAPendingWorkflow() {
    // A limit stop means nothing is running, whatever the workflow counter last said.
    let status = AgentStatusReader().status(
        processState: .running,
        lastEventAt: t0,
        lastVerdictSnippet: nil,
        now: t0.addingTimeInterval(5),
        workflowPending: true,
        limitMessage: limitText
    )
    #expect(status == .limited(since: t0, message: limitText))
}

@Test func aLaterOrdinaryEventClearsTheLimitedStatus() {
    let status = AgentStatusReader().status(
        processState: .running,
        lastEventAt: t0,
        lastVerdictSnippet: nil,
        now: t0.addingTimeInterval(5),
        limitMessage: nil
    )
    #expect(status == .working)
}

@Test func anExitedLimitedSessionStillReportsItsExit() {
    let status = AgentStatusReader().status(
        processState: .exited(code: 0),
        lastEventAt: t0,
        lastVerdictSnippet: nil,
        now: t0.addingTimeInterval(5),
        limitMessage: limitText
    )
    #expect(status == .ready(exitCode: 0))
}
