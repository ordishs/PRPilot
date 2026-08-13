import Testing
import Foundation
@testable import AgentKit

private let reader = AgentStatusReader(idleThresholdSeconds: 30)

@Test func startingWhenProcessNotYetRunning() {
    let status = reader.status(processState: .starting, lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .starting)
}

@Test func startingWhenRunningButNoEventsYet() {
    let status = reader.status(processState: .running, lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .starting)
}

@Test func workingWhenRecentEventWithinThreshold() {
    let now = Date()
    let status = reader.status(processState: .running, lastEventAt: now.addingTimeInterval(-10), lastVerdictSnippet: nil, now: now)
    #expect(status == .working)
}

@Test func idleAfterThresholdElapses() {
    let now = Date()
    let lastEvent = now.addingTimeInterval(-31)
    let status = reader.status(processState: .running, lastEventAt: lastEvent, lastVerdictSnippet: "hello", now: now)
    if case .idle(let since, let snippet) = status {
        #expect(since == lastEvent)
        #expect(snippet == "hello")
    } else {
        Issue.record("expected .idle, got \(status)")
    }
}

@Test func readyOnCleanExitZero() {
    let status = reader.status(processState: .exited(code: 0), lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .ready(exitCode: 0))
}

@Test func readyKeepsNonZeroExitCode() {
    let status = reader.status(processState: .exited(code: 1), lastEventAt: nil, lastVerdictSnippet: nil)
    #expect(status == .ready(exitCode: 1))
}

@Test func failedFromFailedToLaunch() {
    let status = reader.status(processState: .failedToLaunch("bad path"), lastEventAt: nil, lastVerdictSnippet: nil)
    if case .failed(let reason) = status {
        #expect(reason == "bad path")
    } else {
        Issue.record("expected .failed, got \(status)")
    }
}

@Test func completedTurnYieldsAwaitingInputEvenWhenStale() {
    let reader = AgentStatusReader(idleThresholdSeconds: 30)
    let t = Date(timeIntervalSince1970: 1000)
    let s = reader.status(processState: .running, lastEventAt: t, lastVerdictSnippet: "done",
                          now: t.addingTimeInterval(600), lastEventWasTurnCompletion: true)
    #expect(s == .awaitingInput(since: t, lastVerdictSnippet: "done"))
}

@Test func recentNonCompletedIsWorking() {
    let reader = AgentStatusReader(idleThresholdSeconds: 30)
    let t = Date(timeIntervalSince1970: 1000)
    let s = reader.status(processState: .running, lastEventAt: t, lastVerdictSnippet: nil,
                          now: t.addingTimeInterval(5), lastEventWasTurnCompletion: false)
    #expect(s == .working)
}

@Test func staleNonCompletedIsIdle() {
    let reader = AgentStatusReader(idleThresholdSeconds: 30)
    let t = Date(timeIntervalSince1970: 1000)
    let s = reader.status(processState: .running, lastEventAt: t, lastVerdictSnippet: "x",
                          now: t.addingTimeInterval(60), lastEventWasTurnCompletion: false)
    #expect(s == .idle(since: t, lastVerdictSnippet: "x"))
}

@Test func pendingWorkflowKeepsSessionWorkingWhileTranscriptIsSilent() {
    // A background code-review workflow emits nothing to the transcript for many
    // minutes. The session is working, not idle.
    let reader = AgentStatusReader(idleThresholdSeconds: 30)
    let t = Date(timeIntervalSince1970: 1000)
    let s = reader.status(processState: .running, lastEventAt: t, lastVerdictSnippet: "workflow running",
                          now: t.addingTimeInterval(900), lastEventWasTurnCompletion: false,
                          workflowPending: true)
    #expect(s == .working)
}

@Test func pendingWorkflowNeverReportsAwaitingInput() {
    // Even if a turn completion slips through, a pending workflow means Claude is not
    // waiting on the user — so the "review ready" notification must not be armed.
    let reader = AgentStatusReader(idleThresholdSeconds: 30)
    let t = Date(timeIntervalSince1970: 1000)
    let s = reader.status(processState: .running, lastEventAt: t, lastVerdictSnippet: "done",
                          now: t.addingTimeInterval(600), lastEventWasTurnCompletion: true,
                          workflowPending: true)
    #expect(s == .working)
}

@Test func pendingWorkflowDoesNotMaskProcessExit() {
    let reader = AgentStatusReader(idleThresholdSeconds: 30)
    let s = reader.status(processState: .exited(code: 0), lastEventAt: Date(), lastVerdictSnippet: nil,
                         now: Date(), lastEventWasTurnCompletion: false, workflowPending: true)
    #expect(s == .ready(exitCode: 0))
}

@Test func runningWithNoEventIsStartingEvenIfCompletionFlagSet() {
    let reader = AgentStatusReader()
    let s = reader.status(processState: .running, lastEventAt: nil, lastVerdictSnippet: nil,
                          now: Date(), lastEventWasTurnCompletion: true)
    #expect(s == .starting)
}
