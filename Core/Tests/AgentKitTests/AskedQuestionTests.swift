import Testing
import Foundation
@testable import AgentKit

private let askLine = """
{"type":"assistant","timestamp":"2026-10-28T11:53:30.000Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_A","name":"AskUserQuestion","input":{"questions":[{"question":"PR 1992 verdict: APPROVE, no P0/P1. How to post?","header":"PR 1992","multiSelect":false,"options":[{"label":"Skip","description":"Post nothing."},{"label":"Post as approve","description":"Approve with no comment"}]}]}}]}}
"""

private let multiAskLine = """
{"type":"assistant","timestamp":"2026-10-28T11:53:30.000Z","message":{"content":[{"type":"tool_use","id":"toolu_M","name":"AskUserQuestion","input":{"questions":[{"question":"Which checks?","header":"Checks","multiSelect":true,"options":[{"label":"Unit","description":""},{"label":"Lint","description":""}]},{"question":"Push?","header":"Push","multiSelect":false,"options":[{"label":"Yes","description":""}]}]}}]}}
"""

private let interruptedLine = """
{"type":"user","timestamp":"2026-10-28T11:53:40.810Z","toolDenialKind":"interrupted","message":{"role":"user","content":[{"type":"tool_result","content":"[Tool call interrupted: the session ended before this call's result was recorded, so its outcome is unknown.]","is_error":true,"tool_use_id":"toolu_A"}]}}
"""

private let noResponseLine = """
{"type":"assistant","timestamp":"2026-10-28T11:53:41.000Z","message":{"content":[{"type":"text","text":"No response requested."}]}}
"""

private let userPromptLine = """
{"type":"user","timestamp":"2026-10-28T11:55:00.000Z","message":{"role":"user","content":"what was the verdict"}}
"""

private let answeredLine = """
{"type":"user","timestamp":"2026-10-28T11:53:40.810Z","message":{"role":"user","content":[{"type":"tool_result","content":"Your questions have been answered: \\"PR 1992 verdict\\"=\\"Skip\\".","tool_use_id":"toolu_A"}]}}
"""

private let rejectedLine = """
{"type":"user","timestamp":"2026-10-28T11:53:40.810Z","toolDenialKind":"user-rejected","message":{"role":"user","content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use.","is_error":true,"tool_use_id":"toolu_A"}]}}
"""

private let otherToolInterruptedLine = """
{"type":"user","timestamp":"2026-10-28T11:53:40.810Z","toolDenialKind":"interrupted","message":{"role":"user","content":[{"type":"tool_result","content":"[Tool call interrupted]","is_error":true,"tool_use_id":"toolu_Bash"}]}}
"""

private func run(_ lines: [String]) -> [TranscriptEvent] {
    var state = TranscriptParseState()
    return lines.compactMap { AgentBackends.claudeCode.parse(line: Data($0.utf8), state: &state) }
}

@Test func interruptedQuestionIsReportedWithItsOptions() {
    let events = run([askLine, interruptedLine])

    #expect(events[0].interruptedQuestions == nil)
    #expect(events[1].interruptedQuestions == [
        AskedQuestion(
            question: "PR 1992 verdict: APPROVE, no P0/P1. How to post?",
            header: "PR 1992",
            multiSelect: false,
            options: [
                .init(label: "Skip", detail: "Post nothing."),
                .init(label: "Post as approve", detail: "Approve with no comment"),
            ]
        ),
    ])
    #expect(events[1].questionsSettled == false)
}

@Test func syntheticNoResponseLineDoesNotSettleTheQuestion() {
    let events = run([askLine, interruptedLine, noResponseLine])

    #expect(events[2].questionsSettled == false)
    #expect(events[2].interruptedQuestions == nil)
}

@Test func typedPromptSettlesTheQuestion() {
    let events = run([askLine, interruptedLine, noResponseLine, userPromptLine])

    #expect(events[3].questionsSettled)
}

@Test func answeredQuestionIsNotReplayedAndSettles() {
    let events = run([askLine, answeredLine])

    #expect(events[1].interruptedQuestions == nil)
    #expect(events[1].questionsSettled)
}

@Test func rejectedQuestionIsNotReplayed() {
    let events = run([askLine, rejectedLine])

    #expect(events[1].interruptedQuestions == nil)
    #expect(events[1].questionsSettled)
}

@Test func interruptedResultForAnotherToolReportsNothing() {
    let events = run([askLine, otherToolInterruptedLine])

    #expect(events[1].interruptedQuestions == nil)
    #expect(events[1].questionsSettled == false)
}

@Test func taskNotificationAndReminderTextDoNotSettle() {
    let reminder = """
    {"type":"user","timestamp":"2026-10-28T11:56:00.000Z","message":{"role":"user","content":"<system-reminder>x</system-reminder>"}}
    """
    let notification = """
    {"type":"user","timestamp":"2026-10-28T11:57:00.000Z","message":{"role":"user","content":"<task-notification>\\n</task-notification>"}}
    """
    let events = run([askLine, interruptedLine, reminder, notification])

    #expect(events[2].questionsSettled == false)
    #expect(events[3].questionsSettled == false)
}

@Test func oneCallWithTwoQuestionsReportsBoth() {
    let interrupted = interruptedLine.replacingOccurrences(of: "toolu_A", with: "toolu_M")
    let events = run([multiAskLine, interrupted])

    let reported = events[1].interruptedQuestions
    #expect(reported?.map(\.question) == ["Which checks?", "Push?"])
    #expect(reported?.first?.multiSelect == true)
}

@Test func answerMessageNamesTheQuestionAndEveryChoice() {
    let message = AskedQuestion.answerMessage(question: "Which checks?", choices: ["Unit", "Lint"])

    #expect(message == "My answer to your question \"Which checks?\": Unit, Lint")
}

@Test @MainActor func sendPromptReachesTheAgentAsOneLine() async throws {
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: out) }
    let spec = AgentLaunchSpec(
        executable: "/bin/sh",
        cwd: "/tmp",
        arguments: ["-c", "IFS= read -r line; printf '%s' \"$line\" > '\(out.path)'"]
    )
    let session = AgentSession(spec: spec)
    session.start()
    try await Task.sleep(for: .milliseconds(300))

    session.send(prompt: AskedQuestion.answerMessage(question: "Push?", choices: ["Yes"]))

    var written = ""
    for _ in 0..<50 {
        written = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        if !written.isEmpty { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    session.terminate()
    #expect(written == "My answer to your question \"Push?\": Yes")
}
