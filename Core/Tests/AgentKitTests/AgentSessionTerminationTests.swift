import Foundation
import Testing
@testable import AgentKit

/// Termination has to survive two things a real agent does: it starts work in a process group of
/// its own, and that work does not always honour `SIGTERM`.
@MainActor
@Suite(.serialized)
struct AgentSessionTerminationTests {
    private func spec(command: String) -> AgentLaunchSpec {
        AgentLaunchSpec(executable: "/bin/sh", cwd: "/tmp", arguments: ["-c", command])
    }

    private func pidFilePath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prpilot-term-\(UUID().uuidString).pid").path
    }

    private func readPid(from path: String, timeout: TimeInterval = 5) async -> pid_t? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// The runaway-load-generator bug, reproduced. Claude Code runs each Bash tool command in a
    /// new process group, so the command escapes `killpg`. Terminating the session must still
    /// kill it. The descendant here never reads or writes the terminal, which is what let the
    /// real ones outlive their agent: nothing ever delivered them `SIGPIPE`.
    @Test func terminateKillsADescendantThatLeftTheProcessGroup() async throws {
        let pidFile = pidFilePath()
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let session = AgentSession(spec: spec(command: """
        perl -e 'setpgrp(0,0); open(F, ">", $ARGV[0]); print F "$$"; close F; sleep 300' \(pidFile) &
        exec cat
        """))
        session.start()

        let escapee = await readPid(from: pidFile)
        let escapeePid = try #require(escapee)
        #expect(getpgid(escapeePid) != getpgid(session.terminalView.process.shellPid))
        defer { kill(escapeePid, SIGKILL) }

        await session.terminateAndWait()

        #expect(!isAlive(escapeePid))
    }

    /// `terminateAndWait` is what the quit path awaits, so it must not return while the agent is
    /// still running. Any sleep in this test would hide the bug it guards: the check runs on the
    /// line after the await.
    @Test func terminateAndWaitReturnsOnlyAfterTheAgentIsDead() async throws {
        let session = AgentSession(spec: spec(command: "exec cat"))
        session.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        let pid = session.terminalView.process.shellPid
        #expect(pid > 0)

        await session.terminateAndWait()

        #expect(!isAlive(pid))
    }

    /// An agent that ignores `SIGTERM` must not outlive the wait. Without escalation the quit
    /// path would either hang or return with the agent still alive.
    @Test func terminateAndWaitEscalatesToKillForAnAgentThatIgnoresTerm() async throws {
        let session = AgentSession(spec: spec(command: "exec perl -e '$SIG{TERM} = q{IGNORE}; sleep 300'"))
        session.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        let pid = session.terminalView.process.shellPid
        #expect(pid > 0)
        #expect(isAlive(pid))

        await session.terminateAndWait()

        #expect(!isAlive(pid))
    }

    /// The descendant sweep must not outlive its usefulness: a session whose agent already exited
    /// has to complete the wait instead of blocking the quit for its full timeout.
    @Test func terminateAndWaitReturnsForAnAgentThatAlreadyExited() async throws {
        let session = AgentSession(spec: spec(command: "exit 0"))
        session.start()
        try await Task.sleep(nanoseconds: 500_000_000)

        let started = Date()
        await session.terminateAndWait()

        #expect(Date().timeIntervalSince(started) < 3)
    }

    /// `restart` terminates and starts again in the same turn. The teardown must not reach into
    /// the session afterwards and kill the replacement it finds there.
    @Test func restartDoesNotKillTheReplacementAgent() async throws {
        let session = AgentSession(spec: spec(command: "exec cat"))
        session.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        let first = session.terminalView.process.shellPid
        #expect(first > 0)

        session.restart()
        let second = session.terminalView.process.shellPid
        #expect(second > 0)
        #expect(second != first)

        try await Task.sleep(nanoseconds: 1_500_000_000)

        #expect(isAlive(second))
        await session.terminateAndWait()
    }
}
