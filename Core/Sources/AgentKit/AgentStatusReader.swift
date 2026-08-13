import Foundation

public struct AgentStatusReader: Sendable {
    public let idleThresholdSeconds: TimeInterval

    public init(idleThresholdSeconds: TimeInterval = 30) {
        self.idleThresholdSeconds = idleThresholdSeconds
    }

    public func status(
        processState: AgentSessionState,
        lastEventAt: Date?,
        lastVerdictSnippet: String?,
        now: Date = Date(),
        lastEventWasTurnCompletion: Bool = false,
        workflowPending: Bool = false
    ) -> AgentStatus {
        switch processState {
        case .failedToLaunch(let reason):
            return .failed(reason: reason)
        case .exited(let code):
            return .ready(exitCode: code)
        case .starting:
            return .starting
        case .running:
            guard let lastEventAt else {
                return .starting
            }
            // A background workflow (how /code-review runs a review) writes nothing to the
            // transcript for minutes at a time. Claude is working, not idle, and it is not
            // waiting on the user — so this must not decay to .idle or arm .awaitingInput.
            if workflowPending {
                return .working
            }
            // A completed turn means Claude yielded control: stay .awaitingInput until a
            // newer, non-completing event arrives (it does not decay to .idle on its own).
            if lastEventWasTurnCompletion {
                return .awaitingInput(since: lastEventAt, lastVerdictSnippet: lastVerdictSnippet)
            }
            if now.timeIntervalSince(lastEventAt) < idleThresholdSeconds {
                return .working
            } else {
                return .idle(since: lastEventAt, lastVerdictSnippet: lastVerdictSnippet)
            }
        }
    }
}
