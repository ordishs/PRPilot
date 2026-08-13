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
        let worktreesDir = WorktreeLayout.directory(managedRoot: managedRoot)
        let worktreePath = worktreesDir + "/" + owner + "-" + repo + "-pr" + String(number)
        if FileManager.default.fileExists(atPath: worktreePath) {
            return try await adoptExistingDirectory(clonePath: clonePath, worktreePath: worktreePath, progress: progress)
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
        guard isManagedWorktreePath(worktreePath) else {
            throw WorktreeError.refusedNonManagedWorktree(path: worktreePath)
        }
        try await runGit(["-C", clonePath, "worktree", "remove", worktreePath])
    }

    /// Re-points a clone's administrative link after its worktree moved on disk. Git finds
    /// the clone from the worktree's own `.git` file, so no clone path is needed.
    public func repairWorktree(worktreePath: String) async throws {
        _ = try await runGit(["-C", worktreePath, "worktree", "repair"])
    }

    /// Takes over a directory that already sits at the managed worktree path.
    ///
    /// A worktree holds two links: the clone's `.git/worktrees/<name>/gitdir` file, and the
    /// worktree's own `.git` file. A move of the worktree root — the `.noindex` migration does
    /// this — breaks the first link only, so the clone keeps listing the old path. A repair
    /// rebuilds that link from the worktree side. Only a directory that is no worktree at all
    /// stays unusable, and the caller must then remove it by hand.
    private func adoptExistingDirectory(
        clonePath: String,
        worktreePath: String,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        if try await isRegisteredWorktree(clonePath: clonePath, worktreePath: worktreePath) {
            await progress("Found existing worktree")
            return worktreePath
        }
        await progress("Repairing worktree registration…")
        if (try? await runGit(["-C", worktreePath, "worktree", "repair"])) != nil,
           try await isRegisteredWorktree(clonePath: clonePath, worktreePath: worktreePath) {
            await progress("Found existing worktree")
            return worktreePath
        }
        throw WorktreeError.gitFailed(
            arguments: ["worktree", "validate", worktreePath],
            exitCode: 1,
            message: "directory exists but is not a registered git worktree: \(worktreePath). Remove it with: rm -rf '\(worktreePath)'"
        )
    }

    private func isRegisteredWorktree(clonePath: String, worktreePath: String) async throws -> Bool {
        let listing = try await runGit(["-C", clonePath, "worktree", "list", "--porcelain"])
        let wanted = WorktreeManager.canonicalPath(worktreePath)
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("worktree ") {
            let listed = String(line.dropFirst("worktree ".count))
            if listed == worktreePath || WorktreeManager.canonicalPath(listed) == wanted { return true }
        }
        return false
    }

    /// Git reports the real path of a worktree. The managed root can hold a symlink component,
    /// so compare the resolved forms as well as the literal strings.
    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func isManagedWorktreePath(_ path: String) -> Bool {
        path.hasPrefix(WorktreeLayout.directory(managedRoot: managedRoot) + "/")
    }

    private func worktreeForCheckedOutBranch(_ branch: String, clonePath: String) async throws -> String? {
        let listing = try await runGit(["-C", clonePath, "worktree", "list", "--porcelain"])
        var path: String?
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)" {
                return path
            }
        }
        return nil
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
        // Editable (branch-based) worktrees may hold unpushed local commits — never hard-reset them.
        if (try? await currentBranch(worktreePath: worktreePath)) ?? nil != nil {
            return false
        }
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

    public func currentBranch(worktreePath: String) async throws -> String? {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", worktreePath, "symbolic-ref", "--quiet", "--short", "HEAD"]
        )
        guard result.exitCode == 0 else { return nil }
        let name = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public func isClean(worktreePath: String) async throws -> Bool {
        let out = try await runGit(["-C", worktreePath, "status", "--porcelain"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func checkoutBranchWorktree(
        clonePath: String, owner: String, repo: String, branch: String, number: Int,
        remoteName: String = "origin", progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        let worktreesDir = WorktreeLayout.directory(managedRoot: managedRoot)
        let worktreePath = worktreesDir + "/" + owner + "-" + repo + "-" + WorktreeManager.branchSlug(branch)
        if FileManager.default.fileExists(atPath: worktreePath) {
            return try await adoptExistingDirectory(clonePath: clonePath, worktreePath: worktreePath, progress: progress)
        }
        // Prune first. A worktree the user deleted by hand stays in the listing as `prunable`,
        // and still holds the branch, so an un-pruned lookup returns a path that is gone.
        try await runGit(["-C", clonePath, "worktree", "prune"])
        if let attached = try await worktreeForCheckedOutBranch(branch, clonePath: clonePath) {
            await progress("Branch already checked out — using \(attached)")
            return attached
        }
        // Fetch the PR head via refs/pull/N/head — always present on the base repo, even for
        // fork heads, unlike the branch name which may live on a remote we don't have.
        await progress("Fetching PR #\(number)…")
        try await runGit(["-C", clonePath, "fetch", remoteName, "refs/pull/\(number)/head"])
        let sha = try await runGit(["-C", clonePath, "rev-parse", "FETCH_HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
        await progress("Checking out \(branch)…")
        let exists = (try? await runGit(["-C", clonePath, "rev-parse", "--verify", "--quiet", branch])) != nil
        if exists {
            try await runGit(["-C", clonePath, "worktree", "add", worktreePath, branch])
        } else {
            try await runGit(["-C", clonePath, "worktree", "add", "-b", branch, worktreePath, sha])
        }
        return worktreePath
    }

    public func removeWorktreeForcing(clonePath: String, worktreePath: String) async throws {
        guard isManagedWorktreePath(worktreePath) else {
            throw WorktreeError.refusedNonManagedWorktree(path: worktreePath)
        }
        try await runGit(["-C", clonePath, "worktree", "remove", "--force", worktreePath])
    }

    public func rebaseOnto(worktreePath: String, upstream: String) async throws -> RebaseOutcome {
        let result = try await runner.run(executable: gitPath, arguments: ["-C", worktreePath, "-c", "core.editor=true", "rebase", upstream])
        if result.exitCode == 0 { return .clean }
        let conflicted = try await conflictedFiles(worktreePath)
        if !conflicted.isEmpty { return .conflicts(conflicted) }
        throw WorktreeError.gitFailed(arguments: ["rebase", upstream], exitCode: result.exitCode, message: result.standardError)
    }

    public func rebaseContinue(worktreePath: String) async throws -> RebaseOutcome {
        let result = try await runner.run(executable: gitPath, arguments: ["-C", worktreePath, "-c", "core.editor=true", "rebase", "--continue"])
        if result.exitCode == 0 { return .clean }
        let conflicted = try await conflictedFiles(worktreePath)
        if !conflicted.isEmpty { return .conflicts(conflicted) }
        throw WorktreeError.gitFailed(arguments: ["rebase", "--continue"], exitCode: result.exitCode, message: result.standardError)
    }

    public func rebaseAbort(worktreePath: String) async throws {
        try await runGit(["-C", worktreePath, "rebase", "--abort"])
    }

    private func conflictedFiles(_ worktreePath: String) async throws -> [String] {
        let out = try await runGit(["-C", worktreePath, "diff", "--name-only", "--diff-filter=U"])
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public func push(worktreePath: String, remoteName: String, branch: String, force: Bool) async throws {
        var args = ["-C", worktreePath, "push"]
        if force { args.append("--force-with-lease") }
        args += [remoteName, branch]
        try await runGit(args)
    }

    public func aheadBehind(worktreePath: String, upstream: String) async throws -> (ahead: Int, behind: Int) {
        let ahead = try await runGit(["-C", worktreePath, "rev-list", "--count", "\(upstream)..HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let behind = try await runGit(["-C", worktreePath, "rev-list", "--count", "HEAD..\(upstream)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (Int(ahead) ?? 0, Int(behind) ?? 0)
    }

    public static func branchSlug(_ branch: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        return String(branch.map { allowed.contains($0) ? $0 : "-" })
    }

    public func createBranchWorktree(
        clonePath: String,
        owner: String,
        repo: String,
        branch: String,
        base: String,
        remoteName: String = "origin",
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        let worktreesDir = WorktreeLayout.directory(managedRoot: managedRoot)
        let worktreePath = worktreesDir + "/" + owner + "-" + repo + "-" + WorktreeManager.branchSlug(branch)
        if FileManager.default.fileExists(atPath: worktreePath) {
            return try await adoptExistingDirectory(clonePath: clonePath, worktreePath: worktreePath, progress: progress)
        }
        await progress("Pruning stale worktrees…")
        try await runGit(["-C", clonePath, "worktree", "prune"])
        await progress("Fetching \(base)…")
        let baseSha: String
        if (try? await runGit(["-C", clonePath, "fetch", remoteName, base])) != nil,
           let fetched = try? await runGit(["-C", clonePath, "rev-parse", "FETCH_HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
           !fetched.isEmpty {
            baseSha = fetched
        } else {
            baseSha = try await runGit(["-C", clonePath, "rev-parse", base]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
        await progress("Creating branch \(branch)…")
        try await runGit(["-C", clonePath, "worktree", "add", "-b", branch, worktreePath, baseSha])
        return worktreePath
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
