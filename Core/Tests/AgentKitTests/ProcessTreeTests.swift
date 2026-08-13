import Foundation
import Testing
@testable import AgentKit

/// Spawns a throwaway process tree and reports the pids it created.
///
/// The shell writes each descendant pid to a file, then `exec`s so the root pid stays the one
/// `Process` reports. Reading pids back from the file is what lets the test name a specific
/// grandchild rather than counting processes.
private struct ProcessTreeFixture {
    let root: Process
    let descendantPids: [pid_t]

    static func make(script: String, expectedPidCount: Int) throws -> ProcessTreeFixture {
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prpilot-tree-\(UUID().uuidString).pids")
        FileManager.default.createFile(atPath: pidFile.path, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script.replacingOccurrences(of: "@PIDFILE@", with: pidFile.path)]
        try process.run()

        var pids: [pid_t] = []
        for _ in 0..<100 {
            let text = (try? String(contentsOf: pidFile, encoding: .utf8)) ?? ""
            pids = text.split(whereSeparator: \.isNewline).compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            if pids.count >= expectedPidCount { break }
            usleep(50_000)
        }
        try? FileManager.default.removeItem(at: pidFile)
        return ProcessTreeFixture(root: process, descendantPids: pids)
    }

    func killAll() {
        for pid in descendantPids { kill(pid, SIGKILL) }
        kill(root.processIdentifier, SIGKILL)
    }
}

@Suite(.serialized)
struct ProcessTreeTests {
    /// The plain case: a background child of the agent shell.
    @Test func descendantsFindsABackgroundChild() throws {
        let fixture = try ProcessTreeFixture.make(
            script: "sleep 30 & echo $! > @PIDFILE@; exec sleep 30",
            expectedPidCount: 1
        )
        defer { fixture.killAll() }
        #expect(fixture.descendantPids.count == 1)

        let found = ProcessTree.descendants(of: fixture.root.processIdentifier)

        #expect(found.contains(fixture.descendantPids[0]))
    }

    /// The case that caused the runaway load generators. Claude Code puts every Bash tool
    /// command in a new process group, so `killpg` on the agent never reaches it. A descendant
    /// walk must find it regardless of which process group it joined.
    @Test func descendantsFindsAChildThatLeftTheProcessGroup() throws {
        let fixture = try ProcessTreeFixture.make(
            script: """
            perl -e 'setpgrp(0,0); open(F, ">", $ARGV[0]); print F "$$\\n"; close F; exec "sleep 30"' @PIDFILE@ &
            exec sleep 30
            """,
            expectedPidCount: 1
        )
        defer { fixture.killAll() }
        #expect(fixture.descendantPids.count == 1)
        let escapee = fixture.descendantPids[0]
        #expect(getpgid(escapee) != getpgid(fixture.root.processIdentifier))

        let found = ProcessTree.descendants(of: fixture.root.processIdentifier)

        #expect(found.contains(escapee))
    }

    /// Grandchildren matter because the agent runs a shell, and that shell runs the real work.
    @Test func descendantsWalksMoreThanOneLevelDeep() throws {
        let fixture = try ProcessTreeFixture.make(
            script: """
            sh -c 'echo $$ > @PIDFILE@; sleep 30 & echo $! >> @PIDFILE@; wait' &
            exec sleep 30
            """,
            expectedPidCount: 2
        )
        defer { fixture.killAll() }
        #expect(fixture.descendantPids.count == 2)

        let found = ProcessTree.descendants(of: fixture.root.processIdentifier)

        #expect(found.contains(fixture.descendantPids[0]))
        #expect(found.contains(fixture.descendantPids[1]))
    }

    /// An unrelated process must never appear, or terminate would kill other sessions' agents.
    @Test func descendantsExcludesUnrelatedProcesses() throws {
        let fixture = try ProcessTreeFixture.make(
            script: "sleep 30 & echo $! > @PIDFILE@; exec sleep 30",
            expectedPidCount: 1
        )
        defer { fixture.killAll() }

        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["30"]
        try bystander.run()
        defer { kill(bystander.processIdentifier, SIGKILL) }

        let found = ProcessTree.descendants(of: fixture.root.processIdentifier)

        #expect(!found.contains(bystander.processIdentifier))
        #expect(!found.contains(fixture.root.processIdentifier))
    }

    /// A pid with no children must produce an empty list rather than every process on the box.
    @Test func descendantsOfALeafIsEmpty() throws {
        let leaf = Process()
        leaf.executableURL = URL(fileURLWithPath: "/bin/sleep")
        leaf.arguments = ["30"]
        try leaf.run()
        defer { kill(leaf.processIdentifier, SIGKILL) }

        #expect(ProcessTree.descendants(of: leaf.processIdentifier).isEmpty)
    }
}
