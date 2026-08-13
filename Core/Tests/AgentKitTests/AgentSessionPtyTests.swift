import Foundation
import Testing
@testable import AgentKit

/// One pty the session opened, identified well enough to recognise after teardown.
///
/// A process-wide descriptor count cannot be used: other suites start their own sessions in
/// parallel and every one of them holds a pty. So each session records its master descriptor
/// and the slave name behind it. The pair still names the same pty only while the session
/// holds it open; once the descriptor closes, or the kernel hands the number to an unrelated
/// pty, the pair no longer matches.
private struct PtyHandle {
    let fd: Int32
    let slaveName: String

    var isStillHeld: Bool {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return false }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard String(decoding: bytes, as: UTF8.self) == "/dev/ptmx" else { return false }
        guard let slave = ptsname(fd) else { return false }
        return String(cString: slave) == slaveName
    }
}

private func handle(for fd: Int32) -> PtyHandle? {
    guard fd >= 0, let slave = ptsname(fd) else { return nil }
    return PtyHandle(fd: fd, slaveName: String(cString: slave))
}

@MainActor
struct AgentSessionPtyTests {
    private func spec(command: String) -> AgentLaunchSpec {
        AgentLaunchSpec(executable: "/bin/sh", cwd: "/tmp", arguments: ["-c", command])
    }

    /// Starts and terminates four sessions, keeping every session object alive, and reports the
    /// ptys still held afterwards.
    private func ptysHeldAfterTerminate(command: String) async throws -> Int {
        var sessions: [AgentSession] = []
        var handles: [PtyHandle] = []

        for _ in 0..<4 {
            let session = AgentSession(spec: spec(command: command))
            sessions.append(session)
            session.start()
            try await Task.sleep(nanoseconds: 300_000_000)
            if let recorded = handle(for: session.terminalView.process.childfd) {
                handles.append(recorded)
            }
            session.terminate()
        }

        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(sessions.count == 4)
        #expect(handles.count == 4)
        return handles.filter(\.isStillHeld).count
    }

    /// A terminated session must give its pty back at once. The app keeps a session object
    /// alive after `terminate()` — the exit banner reads its state — so releasing the object
    /// cannot be what closes the terminal.
    @Test func terminateReleasesThePtyWhileTheSessionObjectLives() async throws {
        #expect(try await ptysHeldAfterTerminate(command: "exec cat") == 0)
    }

    /// `claude` spawns MCP servers that inherit the terminal. Signalling only the direct child
    /// leaves them holding the slave open, so the master never reaches EOF and the pty stays
    /// allocated. Terminating the session must take the whole process group down with it.
    @Test func terminateReleasesThePtyWhenAGrandchildInheritsIt() async throws {
        #expect(try await ptysHeldAfterTerminate(command: "sleep 30 & exec cat") == 0)
    }

    /// Closing the terminal cancels the SwiftTerm process monitor whose handler calls `waitpid`,
    /// so the session has to reap the agent itself. An unreaped agent stays in the process table
    /// as a zombie until the app exits.
    ///
    /// `waitpid` here is the assertion: `ECHILD` means the session already reaped the agent, and
    /// any other answer means the test reaped a zombie the session left behind.
    @Test func terminateReapsTheAgentInsteadOfLeavingAZombie() async throws {
        let session = AgentSession(spec: spec(command: "exec cat"))
        session.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        let pid = session.terminalView.process.shellPid
        #expect(pid > 0)

        session.terminate()
        try await Task.sleep(nanoseconds: 2_500_000_000)

        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG)
        #expect(reaped == -1)
        #expect(errno == ECHILD)
    }
}
