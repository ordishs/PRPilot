import Foundation
import PRPilotModels
import WorktreeKit

public struct WorktreeReady: Sendable, Equatable {
    public let clonePath: String
    public let worktreePath: String
    public let remoteName: String

    public init(clonePath: String, worktreePath: String, remoteName: String) {
        self.clonePath = clonePath
        self.worktreePath = worktreePath
        self.remoteName = remoteName
    }
}

public typealias PrepProgress = @Sendable (String) async -> Void

public protocol WorktreeProviding: Sendable {
    func ensureWorktree(
        for review: WorkItem,
        editable: Bool,
        registeredClonePath: String?,
        progress: @escaping PrepProgress
    ) async throws -> WorktreeReady
}

public extension WorktreeProviding {
    func ensureWorktree(for review: WorkItem, editable: Bool, registeredClonePath: String?) async throws -> WorktreeReady {
        try await ensureWorktree(for: review, editable: editable, registeredClonePath: registeredClonePath, progress: { _ in })
    }
}

public struct WorktreeProvider: WorktreeProviding {
    private let worktreeManager: WorktreeManager

    public init(worktreeManager: WorktreeManager) {
        self.worktreeManager = worktreeManager
    }

    public func ensureWorktree(
        for review: WorkItem,
        editable: Bool,
        registeredClonePath: String?,
        progress: @escaping PrepProgress
    ) async throws -> WorktreeReady {
        let remoteURL = "https://github.com/\(review.owner)/\(review.repo).git"
        let clonePath = try await worktreeManager.resolveClone(
            owner: review.owner,
            repo: review.repo,
            remoteURL: remoteURL,
            registeredClonePath: registeredClonePath,
            progress: progress
        )
        await progress("Detecting remote…")
        let remotes = (try? await worktreeManager.listRemotes(clonePath: clonePath)) ?? []
        let target = "\(review.owner)/\(review.repo)".lowercased()
        let remoteName = remotes.first { entry in
            guard let (owner, repo) = GitOriginParser.parse(entry.url) else { return false }
            return "\(owner)/\(repo)".lowercased() == target
        }?.name ?? "origin"

        if let existing = review.worktreePath, FileManager.default.fileExists(atPath: existing) {
            if !editable {
                if let number = review.number {
                    await progress("Refreshing existing worktree…")
                    _ = try await worktreeManager.refreshWorktree(clonePath: clonePath, worktreePath: existing, number: number, remoteName: remoteName)
                }
                return WorktreeReady(clonePath: clonePath, worktreePath: existing, remoteName: remoteName)
            }
            let branch = review.headBranch
            let onBranch = (try? await worktreeManager.currentBranch(worktreePath: existing)) ?? nil
            if let branch, onBranch == branch {
                return WorktreeReady(clonePath: clonePath, worktreePath: existing, remoteName: remoteName)
            }
            if let branch, (try? await worktreeManager.isClean(worktreePath: existing)) == true {
                await progress("Converting worktree to branch \(branch)…")
                try? await worktreeManager.removeWorktreeForcing(clonePath: clonePath, worktreePath: existing)
                let path = try await editableWorktree(review: review, branch: branch, clonePath: clonePath, remoteName: remoteName, progress: progress)
                return WorktreeReady(clonePath: clonePath, worktreePath: path, remoteName: remoteName)
            }
            return WorktreeReady(clonePath: clonePath, worktreePath: existing, remoteName: remoteName)
        }

        let worktreePath: String
        if editable, let branch = review.headBranch {
            worktreePath = try await editableWorktree(review: review, branch: branch, clonePath: clonePath, remoteName: remoteName, progress: progress)
        } else if let number = review.number {
            worktreePath = try await worktreeManager.createWorktree(clonePath: clonePath, owner: review.owner, repo: review.repo, number: number, remoteName: remoteName, progress: progress)
        } else {
            throw WorktreeError.notAPullRequest
        }
        return WorktreeReady(clonePath: clonePath, worktreePath: worktreePath, remoteName: remoteName)
    }

    private func editableWorktree(review: WorkItem, branch: String, clonePath: String, remoteName: String, progress: @escaping PrepProgress) async throws -> String {
        if review.number == nil {
            return try await worktreeManager.createBranchWorktree(clonePath: clonePath, owner: review.owner, repo: review.repo, branch: branch, base: review.baseBranch, remoteName: remoteName, progress: progress)
        } else {
            return try await worktreeManager.checkoutBranchWorktree(clonePath: clonePath, owner: review.owner, repo: review.repo, branch: branch, remoteName: remoteName, progress: progress)
        }
    }
}
