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

    #expect(worktree == fixture.managedRoot + "/" + WorktreeLayout.directoryName + "/bsv-blockchain-teranode-pr944")
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
    let worktreesDir = WorktreeLayout.directory(managedRoot: managedRoot)
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
    let worktreesDir = WorktreeLayout.directory(managedRoot: managedRoot)
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
        CommandResult(exitCode: 1, standardOutput: "", standardError: ""),   // symbolic-ref → detached
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
        CommandResult(exitCode: 1, standardOutput: "", standardError: ""),   // symbolic-ref → detached
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
        CommandResult(exitCode: 1, standardOutput: "", standardError: ""),   // symbolic-ref → detached
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

@Test func branchSlugReplacesNonAlphanumerics() {
    #expect(WorktreeManager.branchSlug("feat/parallel_v2.1") == "feat-parallel-v2-1")
}

@Test func createBranchWorktreeCreatesNewBranchOffBase() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("bwt-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: root) }

    let clonePath = root + "/work"
    try await git(["init", "-b", "main", clonePath])
    try await git(["-C", clonePath, "config", "user.email", "test@example.com"])
    try await git(["-C", clonePath, "config", "user.name", "Test User"])
    try await git(["-C", clonePath, "config", "commit.gpgsign", "false"])
    try "base\n".write(toFile: clonePath + "/README.md", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "base"])

    let managedRoot = root + "/managed"
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: managedRoot)

    let wt = try await manager.createBranchWorktree(
        clonePath: clonePath, owner: "o", repo: "r", branch: "feat/spike", base: "main"
    )

    #expect(FileManager.default.fileExists(atPath: wt))
    #expect(wt.hasSuffix("/o-r-feat-spike"))

    let listing = try await git(["-C", clonePath, "worktree", "list", "--porcelain"])
    #expect(listing.contains(wt))

    let head = try await git(["-C", wt, "rev-parse", "--abbrev-ref", "HEAD"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(head == "feat/spike")
}

@Test func checkoutBranchWorktreeAttachesToExistingCheckout() async throws {
    let fixture = try await makeFixture(prNumber: 7)
    defer { try? FileManager.default.removeItem(atPath: fixture.root) }
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let work = fixture.root + "/work"
    // makeFixture leaves the clone checked out on `pr-branch`. Git forbids a second
    // worktree on a branch that's already checked out, so the manager must attach to
    // the existing checkout instead of failing `git worktree add`.
    let path = try await manager.checkoutBranchWorktree(
        clonePath: work, owner: "acme", repo: "app", branch: "pr-branch", number: 7
    )
    // git reports the canonical path (/var -> /private/var on macOS); compare resolved.
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let expected = URL(fileURLWithPath: work).resolvingSymlinksInPath().path
    #expect(resolved == expected)
}

@Test func removeWorktreeForcingRefusesNonManagedPath() async throws {
    let fixture = try await makeFixture(prNumber: 8)
    defer { try? FileManager.default.removeItem(atPath: fixture.root) }
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: fixture.managedRoot)
    let work = fixture.root + "/work"
    let external = fixture.root + "/external-wt"
    try await git(["-C", work, "worktree", "add", "--detach", external, fixture.baseSha])
    #expect(FileManager.default.fileExists(atPath: external))

    await #expect(throws: (any Error).self) {
        try await manager.removeWorktreeForcing(clonePath: work, worktreePath: external)
    }
    #expect(FileManager.default.fileExists(atPath: external))
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

private func makeLocalRepo(root: String, name: String) async throws -> String {
    let path = root + "/" + name
    try await git(["init", "-b", "main", path])
    try await git(["-C", path, "config", "user.email", "test@example.com"])
    try await git(["-C", path, "config", "user.name", "Test User"])
    try await git(["-C", path, "config", "commit.gpgsign", "false"])
    return path
}

@Test func currentBranchReportsBranchAndNilWhenDetached() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("cb-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: root) }

    let clonePath = try await makeLocalRepo(root: root, name: "clone")
    try "base\n".write(toFile: clonePath + "/a.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "C0"])

    let managedRoot = root + "/managed"
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: managedRoot)

    let wtA = try await manager.createBranchWorktree(
        clonePath: clonePath, owner: "o", repo: "r", branch: "feat/x", base: "main"
    )
    let branchA = try await manager.currentBranch(worktreePath: wtA)
    #expect(branchA == "feat/x")

    let pathB = root + "/detached-wt"
    try await git(["-C", clonePath, "worktree", "add", "--detach", pathB, "HEAD"])
    let branchB = try await manager.currentBranch(worktreePath: pathB)
    #expect(branchB == nil)
}

@Test func rebaseOntoCleanReplaysCommits() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("rb-clean-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: root) }

    let clonePath = try await makeLocalRepo(root: root, name: "clone")
    try "base\n".write(toFile: clonePath + "/a.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "C0"])

    let managedRoot = root + "/managed"
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: managedRoot)

    let wtFeat = try await manager.createBranchWorktree(
        clonePath: clonePath, owner: "o", repo: "r", branch: "feat/x", base: "main"
    )

    try await git(["-C", clonePath, "config", "user.email", "test@example.com"])
    try await git(["-C", clonePath, "config", "user.name", "Test User"])
    try await git(["-C", clonePath, "config", "commit.gpgsign", "false"])
    try "main-advance\n".write(toFile: clonePath + "/b.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "C1"])

    try await git(["-C", wtFeat, "config", "user.email", "test@example.com"])
    try await git(["-C", wtFeat, "config", "user.name", "Test User"])
    try await git(["-C", wtFeat, "config", "commit.gpgsign", "false"])
    try "feat-work\n".write(toFile: wtFeat + "/c.txt", atomically: true, encoding: .utf8)
    try await git(["-C", wtFeat, "add", "."])
    try await git(["-C", wtFeat, "commit", "-m", "feat-commit"])

    let outcome = try await manager.rebaseOnto(worktreePath: wtFeat, upstream: "main")
    #expect(outcome == .clean)
    #expect(fileManager.fileExists(atPath: wtFeat + "/b.txt"))
    #expect(fileManager.fileExists(atPath: wtFeat + "/c.txt"))
}

@Test func rebaseOntoReportsConflictsThenAbortRestores() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("rb-conflict-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: root) }

    let clonePath = try await makeLocalRepo(root: root, name: "clone")
    try "parent\n".write(toFile: clonePath + "/conflict.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "parent"])

    let managedRoot = root + "/managed"
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: managedRoot)

    let wtFeat = try await manager.createBranchWorktree(
        clonePath: clonePath, owner: "o", repo: "r", branch: "feat/x", base: "main"
    )

    try await git(["-C", wtFeat, "config", "user.email", "test@example.com"])
    try await git(["-C", wtFeat, "config", "user.name", "Test User"])
    try await git(["-C", wtFeat, "config", "commit.gpgsign", "false"])
    try "branch\n".write(toFile: wtFeat + "/conflict.txt", atomically: true, encoding: .utf8)
    try await git(["-C", wtFeat, "add", "."])
    try await git(["-C", wtFeat, "commit", "-m", "branch-commit"])

    try await git(["-C", clonePath, "config", "user.email", "test@example.com"])
    try await git(["-C", clonePath, "config", "user.name", "Test User"])
    try await git(["-C", clonePath, "config", "commit.gpgsign", "false"])
    try "main\n".write(toFile: clonePath + "/conflict.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "main-commit"])

    let outcome = try await manager.rebaseOnto(worktreePath: wtFeat, upstream: "main")
    if case .conflicts(let files) = outcome {
        #expect(files.contains("conflict.txt"))
    } else {
        Issue.record("expected .conflicts, got \(outcome)")
    }

    try await manager.rebaseAbort(worktreePath: wtFeat)
    let branch = try await manager.currentBranch(worktreePath: wtFeat)
    #expect(branch == "feat/x")
    let clean = try await manager.isClean(worktreePath: wtFeat)
    #expect(clean == true)
}

@Test func pushToLocalBareRemoteSucceeds() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: root) }

    let bareDir = root + "/bare.git"
    try await git(["init", "--bare", "-b", "main", bareDir])

    let clonePath = root + "/clone"
    try await git(["clone", bareDir, clonePath])
    try await git(["-C", clonePath, "config", "user.email", "test@example.com"])
    try await git(["-C", clonePath, "config", "user.name", "Test User"])
    try await git(["-C", clonePath, "config", "commit.gpgsign", "false"])
    try "base\n".write(toFile: clonePath + "/a.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "base"])
    try await git(["-C", clonePath, "push", "origin", "main"])

    let managedRoot = root + "/managed"
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: managedRoot)

    let wtFeat = try await manager.createBranchWorktree(
        clonePath: clonePath, owner: "o", repo: "r", branch: "feat/x", base: "main"
    )
    try await git(["-C", wtFeat, "config", "user.email", "test@example.com"])
    try await git(["-C", wtFeat, "config", "user.name", "Test User"])
    try await git(["-C", wtFeat, "config", "commit.gpgsign", "false"])
    try "feat\n".write(toFile: wtFeat + "/feat.txt", atomically: true, encoding: .utf8)
    try await git(["-C", wtFeat, "add", "."])
    try await git(["-C", wtFeat, "commit", "-m", "feat-commit"])

    try await manager.push(worktreePath: wtFeat, remoteName: "origin", branch: "feat/x", force: false)

    let result = try await git(["-C", bareDir, "rev-parse", "feat/x"])
    #expect(!result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
}

@Test func aheadBehindCountsDivergence() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("ab-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: root) }

    let bareDir = root + "/bare.git"
    try await git(["init", "--bare", "-b", "main", bareDir])

    let clonePath = root + "/clone"
    try await git(["clone", bareDir, clonePath])
    try await git(["-C", clonePath, "config", "user.email", "test@example.com"])
    try await git(["-C", clonePath, "config", "user.name", "Test User"])
    try await git(["-C", clonePath, "config", "commit.gpgsign", "false"])
    try "base\n".write(toFile: clonePath + "/a.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "base"])
    try await git(["-C", clonePath, "push", "origin", "main"])

    let managedRoot = root + "/managed"
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: managedRoot)

    let wtFeat = try await manager.createBranchWorktree(
        clonePath: clonePath, owner: "o", repo: "r", branch: "feat/x", base: "main"
    )
    try await git(["-C", wtFeat, "config", "user.email", "test@example.com"])
    try await git(["-C", wtFeat, "config", "user.name", "Test User"])
    try await git(["-C", wtFeat, "config", "commit.gpgsign", "false"])

    try "feat1\n".write(toFile: wtFeat + "/f1.txt", atomically: true, encoding: .utf8)
    try await git(["-C", wtFeat, "add", "."])
    try await git(["-C", wtFeat, "commit", "-m", "feat1"])
    try "feat2\n".write(toFile: wtFeat + "/f2.txt", atomically: true, encoding: .utf8)
    try await git(["-C", wtFeat, "add", "."])
    try await git(["-C", wtFeat, "commit", "-m", "feat2"])

    try await manager.push(worktreePath: wtFeat, remoteName: "origin", branch: "feat/x", force: false)

    let clone2 = root + "/clone2"
    try await git(["clone", bareDir, clone2])
    try await git(["-C", clone2, "config", "user.email", "test@example.com"])
    try await git(["-C", clone2, "config", "user.name", "Test User"])
    try await git(["-C", clone2, "config", "commit.gpgsign", "false"])
    try await git(["-C", clone2, "checkout", "feat/x"])
    try "behind1\n".write(toFile: clone2 + "/behind.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clone2, "add", "."])
    try await git(["-C", clone2, "commit", "-m", "behind1"])
    try await git(["-C", clone2, "push", "origin", "feat/x"])

    try "local3\n".write(toFile: wtFeat + "/f3.txt", atomically: true, encoding: .utf8)
    try await git(["-C", wtFeat, "add", "."])
    try await git(["-C", wtFeat, "commit", "-m", "feat3"])
    try "local4\n".write(toFile: wtFeat + "/f4.txt", atomically: true, encoding: .utf8)
    try await git(["-C", wtFeat, "add", "."])
    try await git(["-C", wtFeat, "commit", "-m", "feat4"])

    try await git(["-C", wtFeat, "fetch", "origin", "feat/x"])

    let (ahead, behind) = try await manager.aheadBehind(worktreePath: wtFeat, upstream: "origin/feat/x")
    #expect(ahead == 2)
    #expect(behind == 1)
}

@Test func refreshWorktreeSkipsBranchWorktrees() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("rw-skip-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: root) }

    let clonePath = try await makeLocalRepo(root: root, name: "clone")
    try "base\n".write(toFile: clonePath + "/a.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "C0"])

    let managedRoot = root + "/managed"
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: managedRoot)

    let wt = try await manager.createBranchWorktree(
        clonePath: clonePath, owner: "o", repo: "r", branch: "feat/x", base: "main"
    )
    try await git(["-C", wt, "config", "user.email", "test@example.com"])
    try await git(["-C", wt, "config", "user.name", "Test User"])
    try await git(["-C", wt, "config", "commit.gpgsign", "false"])
    try "local\n".write(toFile: wt + "/local.txt", atomically: true, encoding: .utf8)
    try await git(["-C", wt, "add", "."])
    try await git(["-C", wt, "commit", "-m", "local-only"])

    let beforeSha = try await git(["-C", wt, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)

    let result = try await manager.refreshWorktree(
        clonePath: clonePath, worktreePath: wt, number: 9999, remoteName: "origin"
    )

    let afterSha = try await git(["-C", wt, "rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(result == false)
    #expect(afterSha == beforeSha)
}

@Test func checkoutBranchWorktreeUsesPRHeadRefNotBranchName() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("cbw-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: root) }

    let bareDir = root + "/bare.git"
    try await git(["init", "--bare", "-b", "main", bareDir])

    let clonePath = root + "/clone"
    try await git(["clone", bareDir, clonePath])
    try await git(["-C", clonePath, "config", "user.email", "test@example.com"])
    try await git(["-C", clonePath, "config", "user.name", "Test User"])
    try await git(["-C", clonePath, "config", "commit.gpgsign", "false"])
    try "base\n".write(toFile: clonePath + "/README.md", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "base"])
    try await git(["-C", clonePath, "push", "origin", "main"])

    // Build the PR head commit, push its object, then expose it ONLY via refs/pull/7/head and
    // remove the named branch — so `fetch origin feat/y` would fail. Mirrors a fork-head PR.
    try await git(["-C", clonePath, "checkout", "-b", "feat/y"])
    try "feat-y\n".write(toFile: clonePath + "/feat-y.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "feat-y-commit"])
    let sha = (try await git(["-C", clonePath, "rev-parse", "HEAD"])).trimmingCharacters(in: .whitespacesAndNewlines)
    try await git(["-C", clonePath, "push", "origin", "feat/y"])
    try await git(["-C", bareDir, "update-ref", "refs/pull/7/head", sha])
    try await git(["-C", bareDir, "update-ref", "-d", "refs/heads/feat/y"])
    try await git(["-C", clonePath, "checkout", "main"])
    try await git(["-C", clonePath, "branch", "-D", "feat/y"])
    try await git(["-C", clonePath, "fetch", "--prune", "origin"])

    let managedRoot = root + "/managed"
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: managedRoot)

    let wt = try await manager.checkoutBranchWorktree(
        clonePath: clonePath, owner: "o", repo: "r", branch: "feat/y", number: 7, remoteName: "origin"
    )

    #expect(wt.hasSuffix("/o-r-feat-y"))
    let branch = try await manager.currentBranch(worktreePath: wt)
    #expect(branch == "feat/y")
    #expect(fileManager.fileExists(atPath: wt + "/feat-y.txt"))
}

@Test func isCleanReflectsWorktreeState() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent("clean-\(UUID().uuidString)", isDirectory: true).path
    try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(atPath: root) }

    let clonePath = try await makeLocalRepo(root: root, name: "clone")
    try "base\n".write(toFile: clonePath + "/a.txt", atomically: true, encoding: .utf8)
    try await git(["-C", clonePath, "add", "."])
    try await git(["-C", clonePath, "commit", "-m", "C0"])

    let managedRoot = root + "/managed"
    let manager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: managedRoot)

    let wtFeat = try await manager.createBranchWorktree(
        clonePath: clonePath, owner: "o", repo: "r", branch: "feat/x", base: "main"
    )
    try await git(["-C", wtFeat, "config", "user.email", "test@example.com"])
    try await git(["-C", wtFeat, "config", "user.name", "Test User"])
    try await git(["-C", wtFeat, "config", "commit.gpgsign", "false"])

    let cleanBefore = try await manager.isClean(worktreePath: wtFeat)
    #expect(cleanBefore == true)

    try "dirty\n".write(toFile: wtFeat + "/dirty.txt", atomically: true, encoding: .utf8)
    let cleanAfter = try await manager.isClean(worktreePath: wtFeat)
    #expect(cleanAfter == false)
}

/// Renaming the worktree root leaves each clone's `.git/worktrees/<name>/gitdir` pointing
/// at the old path. Repair re-points it, and needs no clone path — git finds the clone from
/// the worktree's own `.git` file, which the rename does not touch.
@Test func repairWorktreeFixesAMovedWorktree() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtrepair-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let clone = root.appendingPathComponent("clone").path
    let legacyRoot = root.appendingPathComponent("worktrees").path
    let newRoot = root.appendingPathComponent("worktrees.noindex").path
    try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)

    let runner = ProcessCommandRunner()
    _ = try await runner.run(executable: gitPath, arguments: ["-C", clone, "init", "-q", "-b", "main"])
    _ = try await runner.run(executable: gitPath, arguments: [
        "-C", clone, "-c", "user.email=a@b", "-c", "user.name=a", "-c", "commit.gpgsign=false",
        "commit", "-q", "--allow-empty", "-m", "init",
    ])
    _ = try await runner.run(executable: gitPath, arguments: [
        "-C", clone, "worktree", "add", "-q", "-b", "feat", legacyRoot + "/wt1",
    ])
    try FileManager.default.moveItem(atPath: legacyRoot, toPath: newRoot)

    let manager = WorktreeManager(runner: runner, gitPath: gitPath, managedRoot: root.path)
    try await manager.repairWorktree(worktreePath: newRoot + "/wt1")

    let listed = try await runner.run(executable: gitPath, arguments: ["-C", clone, "worktree", "list"])

    #expect(listed.standardOutput.contains(newRoot + "/wt1"))
    #expect(!listed.standardOutput.contains(legacyRoot + "/wt1"))
}
