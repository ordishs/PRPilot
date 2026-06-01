import Foundation
import CommandSupport

public struct WorktreeManager: Sendable {
    private let runner: CommandRunner
    private let gitPath: String
    private let managedRoot: String

    public init(runner: CommandRunner, gitPath: String, managedRoot: String) {
        self.runner = runner
        self.gitPath = gitPath
        self.managedRoot = managedRoot
    }

    public func resolveClone(
        owner: String,
        repo: String,
        remoteURL: String,
        registeredClonePath: String?,
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        await progress("Resolving clone…")
        let fileManager = FileManager.default
        if let registeredClonePath, fileManager.fileExists(atPath: registeredClonePath) {
            await progress("Found existing clone")
            return registeredClonePath
        }
        let reposDir = managedRoot + "/repos/" + owner
        let clonePath = reposDir + "/" + repo
        if fileManager.fileExists(atPath: clonePath) {
            await progress("Found existing clone")
            return clonePath
        }
        try fileManager.createDirectory(atPath: reposDir, withIntermediateDirectories: true)
        await progress("Cloning \(owner)/\(repo)… (first time, this can take a while)")
        try await runGit(["clone", remoteURL, clonePath])
        return clonePath
    }

    public func createWorktree(
        clonePath: String,
        owner: String,
        repo: String,
        number: Int,
        remoteName: String = "origin",
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        let worktreesDir = managedRoot + "/worktrees"
        let worktreePath = worktreesDir + "/" + owner + "-" + repo + "-pr" + String(number)
        if FileManager.default.fileExists(atPath: worktreePath) {
            let listing = try await runGit(["-C", clonePath, "worktree", "list", "--porcelain"])
            if listing.contains("worktree \(worktreePath)\n") || listing.contains("worktree \(worktreePath)") {
                await progress("Found existing worktree")
                return worktreePath
            }
            throw WorktreeError.gitFailed(
                arguments: ["worktree", "validate", worktreePath],
                exitCode: 1,
                message: "directory exists but is not a registered git worktree: \(worktreePath). Remove it with: rm -rf '\(worktreePath)'"
            )
        }
        await progress("Pruning stale worktrees…")
        try await runGit(["-C", clonePath, "worktree", "prune"])
        await progress("Fetching PR #\(number)…")
        try await runGit(["-C", clonePath, "fetch", remoteName, "refs/pull/\(number)/head"])
        let sha = try await runGit(["-C", clonePath, "rev-parse", "FETCH_HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
        await progress("Adding worktree…")
        try await runGit(["-C", clonePath, "worktree", "add", "--detach", worktreePath, sha])
        return worktreePath
    }

    public func mergeBase(worktreePath: String, baseRef: String) async throws -> String {
        try await runGit(["-C", worktreePath, "merge-base", "HEAD", baseRef]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func removeWorktree(clonePath: String, worktreePath: String) async throws {
        try await runGit(["-C", clonePath, "worktree", "remove", worktreePath])
    }

    public func fetch(clonePath: String, remoteName: String, ref: String) async throws {
        try await runGit(["-C", clonePath, "fetch", remoteName, ref])
    }

    public func listRemotes(clonePath: String) async throws -> [(name: String, url: String)] {
        let result = try await runner.run(executable: gitPath, arguments: ["-C", clonePath, "remote", "-v"])
        guard result.exitCode == 0 else {
            throw WorktreeError.gitFailed(arguments: ["-C", clonePath, "remote", "-v"], exitCode: result.exitCode, message: result.standardError)
        }
        var remotes: [(name: String, url: String)] = []
        var seen: Set<String> = []
        for line in result.standardOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0]
            if seen.contains(name) { continue }
            seen.insert(name)
            let urlPart = parts[1].split(separator: " ").first.map(String.init) ?? parts[1]
            remotes.append((name: name, url: urlPart))
        }
        return remotes
    }

    public func refreshWorktree(
        clonePath: String,
        worktreePath: String,
        number: Int,
        remoteName: String = "origin"
    ) async throws -> Bool {
        try await runGit(["-C", clonePath, "fetch", remoteName, "refs/pull/\(number)/head"])
        let fetchHead = try await runGit(["-C", clonePath, "rev-parse", "FETCH_HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let statusOutput = try await runGit(["-C", worktreePath, "status", "--porcelain"])
        let worktreeHead = try await runGit(["-C", worktreePath, "rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if fetchHead == worktreeHead {
            return false
        }
        if !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WorktreeError.gitFailed(
                arguments: ["refresh", "validate"],
                exitCode: 1,
                message: "worktree has uncommitted changes; cannot fast-forward to \(fetchHead). Commit or stash your changes first."
            )
        }
        try await runGit(["-C", worktreePath, "reset", "--hard", fetchHead])
        return true
    }

    @discardableResult
    private func runGit(_ arguments: [String]) async throws -> String {
        let result = try await runner.run(executable: gitPath, arguments: arguments)
        guard result.exitCode == 0 else {
            throw WorktreeError.gitFailed(arguments: arguments, exitCode: result.exitCode, message: result.standardError)
        }
        return result.standardOutput
    }
}
