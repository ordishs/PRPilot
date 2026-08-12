/// Finds worktree directories that no work item points at. Removing a work item does not
/// remove its worktree, so the managed root accumulates checkouts of several gigabytes each.
public enum WorktreeOrphanScanner {
    public static func orphanPaths(
        directoryNames: [String],
        rootPath: String,
        liveWorktreePaths: Set<String>
    ) -> [String] {
        directoryNames
            .filter { !$0.hasPrefix(".") }
            .map { rootPath + "/" + $0 }
            .filter { !liveWorktreePaths.contains($0) }
            .sorted()
    }
}
