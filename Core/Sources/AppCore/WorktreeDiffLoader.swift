import Foundation
import PRPilotModels
import WorktreeKit
import DiffKit

public struct WorktreeDiffLoader: DiffLoading {
    private let worktreeProvider: WorktreeProviding
    private let worktreeManager: WorktreeManager
    private let diffService: DiffService

    public init(worktreeProvider: WorktreeProviding, worktreeManager: WorktreeManager, diffService: DiffService) {
        self.worktreeProvider = worktreeProvider
        self.worktreeManager = worktreeManager
        self.diffService = diffService
    }

    public func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult {
        let ready = try await worktreeProvider.ensureWorktree(for: review, registeredClonePath: registeredClonePath)
        try await worktreeManager.fetch(clonePath: ready.clonePath, remoteName: ready.remoteName, ref: review.baseBranch)
        let base = try await worktreeManager.mergeBase(worktreePath: ready.worktreePath, baseRef: "\(ready.remoteName)/\(review.baseBranch)")
        let files = try await diffService.diff(worktreePath: ready.worktreePath, baseRef: base)
        return DiffResult(worktreePath: ready.worktreePath, files: files)
    }
}
