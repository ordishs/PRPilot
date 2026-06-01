import Testing
import Foundation
import CommandSupport
import WorktreeKit

private let gitPath = "/opt/homebrew/bin/git"

private actor StubRunner: CommandRunner {
    private let responses: [(arguments: [String], result: CommandResult)]
    private var callIndex = 0
    init(responses: [(arguments: [String], result: CommandResult)]) {
        self.responses = responses
    }
    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        if callIndex < responses.count {
            let r = responses[callIndex]
            callIndex += 1
            return r.result
        }
        return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}

private actor QueuedStubRunner: CommandRunner {
    private var queue: [CommandResult]
    private(set) var recordedArguments: [[String]] = []

    init(scriptedResponses: [CommandResult]) {
        self.queue = scriptedResponses
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        recordedArguments.append(arguments)
        guard !queue.isEmpty else {
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        return queue.removeFirst()
    }
}

private struct GitFixture {
    let root: String
    let remoteURL: String
    let managedRoot: String
    let baseSha: String
    let prHeadSha: String
}

@discardableResult
private func git(_ arguments: [String]) async throws -> String {
    let result = try await ProcessCommandRunner().run(executable: gitPath, arguments: arguments)
    guard result.exitCode == 0 else {
        throw NSError(domain: "git-fixture", code: Int(result.exitCode), userInfo: [
            NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(result.standardError)"
        ])
    }
    return result.standardOutput
}

private func makeFixture(prNumber: Int) async throws -> GitFixture {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    let bare = root + "/remote.git"
    let work = root + "/work"

    try await git(["init", "--bare", "-b", "main", bare])
    try await git(["clone", bare, work])
    try await git(["-C", work, "config", "user.email", "test@example.com"])
    try await git(["-C", work, "config", "user.name", "Test User"])
    try await git(["-C", work, "config", "commit.gpgsign", "false"])

    try "base\n".write(toFile: work + "/README.md", atomically: true, encoding: .utf8)
    try await git(["-C", work, "add", "."])
    try await git(["-C", work, "commit", "-m", "base"])
    try await git(["-C", work, "branch", "-M", "main"])
    try await git(["-C", work, "push", "origin", "main"])
    let baseSha = try await git(["-C", work, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

    try await git(["-C", work, "checkout", "-b", "pr-branch"])
    try "feature\n".write(toFile: work + "/feature.txt", atomically: true, encoding: .utf8)
    try await git(["-C", work, "add", "."])
    try await git(["-C", work, "commit", "-m", "feature"])
    let prHeadSha = try await git(["-C", work, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    try await git(["-C", work, "push", "origin", "pr-branch"])
    try await git(["-C", bare, "update-ref", "refs/pull/\(prNumber)/head", prHeadSha])

    return GitFixture(root: root, remoteURL: bare, managedRoot: root + "/managed", baseSha: baseSha, prHeadSha: prHeadSha)
}

@Test func resolveCloneUsesRegisteredPathWhenItExists() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let registered = fixture.root + "/work"
    let resolved = try await manager.resolveClone(owner: "o", repo: "r", remoteURL: fixture.remoteURL, registeredClonePath: registered)
    #expect(resolved == registered)
}

@Test func resolveCloneAutoClonesIntoManagedDir() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let resolved = try await manager.resolveClone(owner: "bsv-blockchain", repo: "teranode", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    #expect(resolved == fixture.managedRoot + "/repos/bsv-blockchain/teranode")
    #expect(FileManager.default.fileExists(atPath: resolved + "/.git"))
}

@Test func resolveCloneFallsBackToManagedWhenRegisteredPathMissing() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let missing = fixture.root + "/does-not-exist"
    let resolved = try await manager.resolveClone(owner: "bsv-blockchain", repo: "teranode", remoteURL: fixture.remoteURL, registeredClonePath: missing)
    #expect(resolved == fixture.managedRoot + "/repos/bsv-blockchain/teranode")
    #expect(FileManager.default.fileExists(atPath: resolved + "/.git"))
}

@Test func createWorktreeChecksOutPRHead() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let clone = try await manager.resolveClone(owner: "bsv-blockchain", repo: "teranode", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    let worktree = try await manager.createWorktree(clonePath: clone, owner: "bsv-blockchain", repo: "teranode", number: 944)

    #expect(worktree == fixture.managedRoot + "/worktrees/bsv-blockchain-teranode-pr944")
    #expect(FileManager.default.fileExists(atPath: worktree + "/feature.txt"))
    let head = try await git(["-C", worktree, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(head == fixture.prHeadSha)
}

@Test func mergeBaseReturnsBaseCommit() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let clone = try await manager.resolveClone(owner: "o", repo: "r", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    let worktree = try await manager.createWorktree(clonePath: clone, owner: "o", repo: "r", number: 944)
    let base = try await manager.mergeBase(worktreePath: worktree, baseRef: "origin/main")
    #expect(base == fixture.baseSha)
}

@Test func removeWorktreeDeletesIt() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let clone = try await manager.resolveClone(owner: "o", repo: "r", remoteURL: fixture.remoteURL, registeredClonePath: nil)
    let worktree = try await manager.createWorktree(clonePath: clone, owner: "o", repo: "r", number: 944)
    #expect(FileManager.default.fileExists(atPath: worktree))
    try await manager.removeWorktree(clonePath: clone, worktreePath: worktree)
    #expect(!FileManager.default.fileExists(atPath: worktree))
}

@Test func createWorktreeRejectsStaleDirectory() async throws {
    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("stale-wt-\(UUID().uuidString)", isDirectory: true).path
    let managedRoot = tmpRoot + "/managed"
    let worktreesDir = managedRoot + "/worktrees"
    let worktreePath = worktreesDir + "/o-r-pr1"
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)

    let porcelainWithoutStalePath = "worktree /some/other/path\nHEAD abc123\nbranch refs/heads/main\n"
    let stub = StubRunner(responses: [
        (arguments: ["-C", tmpRoot + "/clone", "worktree", "list", "--porcelain"],
         result: CommandResult(exitCode: 0, standardOutput: porcelainWithoutStalePath, standardError: ""))
    ])
    let manager = WorktreeManager(runner: stub, gitPath: gitPath, managedRoot: managedRoot)

    await #expect(throws: WorktreeError.self) {
        _ = try await manager.createWorktree(clonePath: tmpRoot + "/clone", owner: "o", repo: "r", number: 1)
    }

    let errorThrown: WorktreeError? = try? await {
        do {
            _ = try await manager.createWorktree(clonePath: tmpRoot + "/clone", owner: "o", repo: "r", number: 1)
            return nil
        } catch let e as WorktreeError {
            return e
        }
    }()

    if case .gitFailed(_, _, let message) = errorThrown {
        #expect(message.contains("not a registered git worktree"))
        #expect(message.contains(worktreePath))
    } else {
        Issue.record("expected WorktreeError.gitFailed, got \(String(describing: errorThrown))")
    }
}

@Test func createWorktreeReturnsExistingRegisteredWorktree() async throws {
    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("existing-wt-\(UUID().uuidString)", isDirectory: true).path
    let managedRoot = tmpRoot + "/managed"
    let worktreesDir = managedRoot + "/worktrees"
    let worktreePath = worktreesDir + "/o-r-pr1"
    try FileManager.default.createDirectory(atPath: worktreePath, withIntermediateDirectories: true)

    let porcelainWithPath = "worktree \(worktreePath)\nHEAD abc123\nbranch refs/heads/main\n"
    let stub = StubRunner(responses: [
        (arguments: ["-C", tmpRoot + "/clone", "worktree", "list", "--porcelain"],
         result: CommandResult(exitCode: 0, standardOutput: porcelainWithPath, standardError: ""))
    ])
    let manager = WorktreeManager(runner: stub, gitPath: gitPath, managedRoot: managedRoot)

    let result = try await manager.createWorktree(clonePath: tmpRoot + "/clone", owner: "o", repo: "r", number: 1)
    #expect(result == worktreePath)
}

@Test func refreshWorktreeReturnsFalseWhenHeadsMatch() async throws {
    let runner = QueuedStubRunner(scriptedResponses: [
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "abc123\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "abc123\n", standardError: "")
    ])
    let manager = WorktreeManager(runner: runner, gitPath: "git", managedRoot: "/tmp/managed")

    let updated = try await manager.refreshWorktree(
        clonePath: "/tmp/clone",
        worktreePath: "/tmp/wt",
        number: 42,
        remoteName: "origin"
    )

    #expect(updated == false)
}

@Test func refreshWorktreeResetsHeadWhenChanged() async throws {
    let runner = QueuedStubRunner(scriptedResponses: [
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "new789\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "old123\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    ])
    let manager = WorktreeManager(runner: runner, gitPath: "git", managedRoot: "/tmp/managed")

    let updated = try await manager.refreshWorktree(
        clonePath: "/tmp/clone",
        worktreePath: "/tmp/wt",
        number: 42,
        remoteName: "origin"
    )

    #expect(updated == true)
    let args = await runner.recordedArguments
    #expect(args.contains(["-C", "/tmp/wt", "reset", "--hard", "new789"]))
}

@Test func refreshWorktreeRefusesToClobberDirtyWorktree() async throws {
    let runner = QueuedStubRunner(scriptedResponses: [
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "new789\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: " M file.txt\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "old123\n", standardError: "")
    ])
    let manager = WorktreeManager(runner: runner, gitPath: "git", managedRoot: "/tmp/managed")

    do {
        _ = try await manager.refreshWorktree(
            clonePath: "/tmp/clone",
            worktreePath: "/tmp/wt",
            number: 42,
            remoteName: "origin"
        )
        Issue.record("expected throw")
    } catch let WorktreeError.gitFailed(_, _, message) {
        #expect(message.contains("uncommitted changes"))
    } catch {
        Issue.record("expected WorktreeError.gitFailed, got \(error)")
    }
}

@Test func createWorktreePrunesBeforeAddingNewWorktree() async throws {
    let tempRoot = NSTemporaryDirectory() + "wt-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tempRoot) }

    let runner = QueuedStubRunner(scriptedResponses: [
        // worktree prune
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        // fetch
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),
        // rev-parse FETCH_HEAD
        CommandResult(exitCode: 0, standardOutput: "abc123\n", standardError: ""),
        // worktree add
        CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    ])
    let manager = WorktreeManager(runner: runner, gitPath: "git", managedRoot: tempRoot)

    _ = try await manager.createWorktree(
        clonePath: "/tmp/clone",
        owner: "owner",
        repo: "repo",
        number: 999,
        remoteName: "origin"
    )

    let args = await runner.recordedArguments
    let firstCall = args.first ?? []
    #expect(firstCall == ["-C", "/tmp/clone", "worktree", "prune"])
}

private actor LineCollector {
    private(set) var lines: [String] = []
    func add(_ s: String) { lines.append(s) }
}

@Test func resolveCloneEmitsProgressForAutoClone() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let collector = LineCollector()
    _ = try await manager.resolveClone(
        owner: "bsv-blockchain", repo: "teranode",
        remoteURL: fixture.remoteURL, registeredClonePath: nil,
        progress: { await collector.add($0) }
    )
    let lines = await collector.lines
    #expect(lines.contains("Resolving clone…"))
    #expect(lines.contains(where: { $0.hasPrefix("Cloning bsv-blockchain/teranode") }))
}

@Test func resolveCloneEmitsFoundExistingForRegisteredClone() async throws {
    let fixture = try await makeFixture(prNumber: 944)
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let collector = LineCollector()
    _ = try await manager.resolveClone(
        owner: "o", repo: "r",
        remoteURL: fixture.remoteURL, registeredClonePath: fixture.root + "/work",
        progress: { await collector.add($0) }
    )
    let lines = await collector.lines
    #expect(lines.contains("Found existing clone"))
}

@Test func createWorktreeEmitsFetchAndAddProgress() async throws {
    let tempRoot = NSTemporaryDirectory() + "wt-prog-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tempRoot) }
    let runner = QueuedStubRunner(scriptedResponses: [
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),        // prune
        CommandResult(exitCode: 0, standardOutput: "", standardError: ""),        // fetch
        CommandResult(exitCode: 0, standardOutput: "abc123\n", standardError: ""),// rev-parse FETCH_HEAD
        CommandResult(exitCode: 0, standardOutput: "", standardError: "")         // worktree add
    ])
    let manager = WorktreeManager(runner: runner, gitPath: "git", managedRoot: tempRoot)
    let collector = LineCollector()
    _ = try await manager.createWorktree(
        clonePath: "/tmp/clone", owner: "o", repo: "r", number: 999, remoteName: "origin",
        progress: { await collector.add($0) }
    )
    let lines = await collector.lines
    #expect(lines.contains("Pruning stale worktrees…"))
    #expect(lines.contains("Fetching PR #999…"))
    #expect(lines.contains("Adding worktree…"))
}
