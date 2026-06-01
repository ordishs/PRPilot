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
        for review: Review,
        registeredClonePath: String?,
        progress: @escaping PrepProgress
    ) async throws -> WorktreeReady
}

public extension WorktreeProviding {
    func ensureWorktree(for review: Review, registeredClonePath: String?) async throws -> WorktreeReady {
        try await ensureWorktree(for: review, registeredClonePath: registeredClonePath, progress: { _ in })
    }
}

public struct WorktreeProvider: WorktreeProviding {
    private let worktreeManager: WorktreeManager

    public init(worktreeManager: WorktreeManager) {
        self.worktreeManager = worktreeManager
    }

    public func ensureWorktree(
        for review: Review,
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
        let worktreePath: String
        if let existing = review.worktreePath, FileManager.default.fileExists(atPath: existing) {
            worktreePath = existing
            await progress("Refreshing existing worktree…")
            _ = try await worktreeManager.refreshWorktree(
                clonePath: clonePath,
                worktreePath: existing,
                number: review.number,
                remoteName: remoteName
            )
        } else {
            worktreePath = try await worktreeManager.createWorktree(
                clonePath: clonePath,
                owner: review.owner,
                repo: review.repo,
                number: review.number,
                remoteName: remoteName,
                progress: progress
            )
        }
        return WorktreeReady(clonePath: clonePath, worktreePath: worktreePath, remoteName: remoteName)
    }
}
