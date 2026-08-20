public protocol WorktreeManaging: Sendable {
    func currentBranch(worktreePath: String) async throws -> String?
    func isClean(worktreePath: String) async throws -> Bool
    func localChanges(worktreePath: String) async throws -> [String]
    func discardLocalChanges(worktreePath: String) async throws
    func refreshWorktree(clonePath: String, worktreePath: String, number: Int, remoteName: String) async throws -> Bool
    func fetch(clonePath: String, remoteName: String, ref: String) async throws
    func rebaseOnto(worktreePath: String, upstream: String) async throws -> RebaseOutcome
    func rebaseContinue(worktreePath: String) async throws -> RebaseOutcome
    func rebaseAbort(worktreePath: String) async throws
    func push(worktreePath: String, remoteName: String, branch: String, force: Bool) async throws
    func aheadBehind(worktreePath: String, upstream: String) async throws -> (ahead: Int, behind: Int)
    func repairWorktree(worktreePath: String) async throws
}

extension WorktreeManager: WorktreeManaging {}
