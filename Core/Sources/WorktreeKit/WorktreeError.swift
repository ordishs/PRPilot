public enum WorktreeError: Error, Equatable {
    case gitFailed(arguments: [String], exitCode: Int32, message: String)
    case notAPullRequest
    case refusedNonManagedWorktree(path: String)
}
