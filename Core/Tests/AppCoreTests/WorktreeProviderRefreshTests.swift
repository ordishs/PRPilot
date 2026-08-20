import Testing
import Foundation
import CommandSupport
import PRPilotModels
import WorktreeKit
@testable import AppCore

/// Answers by inspecting the arguments rather than by call order, so a change in the number of
/// git calls does not silently shift every scripted response onto the wrong command.
private actor ArgumentMatchingGit: CommandRunner {
    private let status: String
    private let fetchHead: String
    private let worktreeHead: String
    private(set) var recorded: [[String]] = []

    init(status: String, fetchHead: String = "new789", worktreeHead: String = "old123") {
        self.status = status
        self.fetchHead = fetchHead
        self.worktreeHead = worktreeHead
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        recorded.append(arguments)
        func ok(_ out: String = "") -> CommandResult {
            CommandResult(exitCode: 0, standardOutput: out, standardError: "")
        }
        if arguments.contains("symbolic-ref") {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "")  // detached
        }
        if arguments.contains("remote"), arguments.contains("-v") {
            return ok("origin\thttps://github.com/o/r.git (fetch)\n")
        }
        if arguments.contains("rev-parse"), arguments.contains("FETCH_HEAD") { return ok(fetchHead + "\n") }
        if arguments.contains("rev-parse"), arguments.contains("HEAD") { return ok(worktreeHead + "\n") }
        if arguments.contains("status"), arguments.contains("--porcelain") { return ok(status) }
        return ok()
    }

    var didReset: Bool {
        recorded.contains { $0.contains("reset") && $0.contains("--hard") }
    }
}

private func reviewRequest(worktreePath: String) -> WorkItem {
    WorkItem(
        title: "fix(seeder): detect truncated utxo-headers files",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        worktreePath: worktreePath,
        prRef: PRRef(owner: "o", repo: "r", number: 1604,
                     url: URL(string: "https://github.com/o/r/pull/1604")!, authorLogin: "someone-else"),
        prState: .open,
        origin: .discovered,
        addedAt: Date()
    )
}

private func tempDirectory() throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtprov-\(UUID().uuidString)", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// Collects the prep-log lines. `PrepProgress` is a `@Sendable` closure, so a plain captured
/// array cannot be mutated from inside it.
private actor PrepLog {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
}

private func provider(_ runner: CommandRunner, managedRoot: String) -> WorktreeProvider {
    WorktreeProvider(worktreeManager: WorktreeManager(runner: runner, gitPath: "git", managedRoot: managedRoot))
}

/// The reported failure. Someone had edited a file inside a review worktree, so the
/// fast-forward could not run — and that took the whole session down with it. The pane showed
/// "Couldn't prepare the worktree" and its Retry button failed the same way every time, with
/// no way out from inside the app.
///
/// The checkout is perfectly usable. A refresh that cannot run is a missed update, not a
/// broken worktree.
@Test func aDirtyReviewWorktreeStillOpensItsSession() async throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let worktree = root + "/wt"
    try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
    let git = ArgumentMatchingGit(status: " M cmd/seeder/seeder.go\n")

    let log = PrepLog()
    let ready = try await provider(git, managedRoot: root).ensureWorktree(
        for: reviewRequest(worktreePath: worktree),
        editable: false,
        registeredClonePath: root,
        progress: { await log.append($0) }
    )

    let lines = await log.lines
    #expect(ready.worktreePath == worktree)
    #expect(await git.didReset == false, "a dirty worktree is never hard-reset")
    #expect(
        lines.contains { $0.lowercased().contains("uncommitted") },
        "the prep log says why the worktree was left as it is — got \(lines)"
    )
}

/// The clean case must keep fast-forwarding, or the tolerance above would quietly turn every
/// review into a review of a stale checkout.
@Test func aCleanReviewWorktreeIsStillFastForwarded() async throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let worktree = root + "/wt"
    try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
    let git = ArgumentMatchingGit(status: "")

    let ready = try await provider(git, managedRoot: root).ensureWorktree(
        for: reviewRequest(worktreePath: worktree),
        editable: false,
        registeredClonePath: root,
        progress: { _ in }
    )

    #expect(ready.worktreePath == worktree)
    #expect(await git.didReset == true)
}

/// A refresh failure that is not about local edits — a network failure on the fetch, say — is
/// no more fatal. The session opens against whatever is on disk.
@Test func aRefreshThatFailsForAnyOtherReasonAlsoOpensTheSession() async throws {
    let root = try tempDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let worktree = root + "/wt"
    try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)

    // Every git call fails, which is what an unreachable remote looks like from here.
    actor AlwaysFailingGit: CommandRunner {
        func run(executable: String, arguments: [String]) async throws -> CommandResult {
            if arguments.contains("remote") { return CommandResult(exitCode: 0, standardOutput: "", standardError: "") }
            return CommandResult(exitCode: 128, standardOutput: "", standardError: "fatal: unable to access remote")
        }
    }

    let log = PrepLog()
    let ready = try await provider(AlwaysFailingGit(), managedRoot: root).ensureWorktree(
        for: reviewRequest(worktreePath: worktree),
        editable: false,
        registeredClonePath: root,
        progress: { await log.append($0) }
    )

    let lines = await log.lines
    #expect(ready.worktreePath == worktree)
    #expect(lines.contains { $0.lowercased().contains("could not refresh") }, "got \(lines)")
}
