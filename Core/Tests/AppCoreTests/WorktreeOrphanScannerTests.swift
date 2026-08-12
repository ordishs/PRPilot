import Testing
@testable import AppCore

@Test func scannerFindsDirectoriesWithNoMatchingItem() {
    let orphans = WorktreeOrphanScanner.orphanPaths(
        directoryNames: ["owner-repo-pr1", "owner-repo-pr2", "owner-repo-pr3"],
        rootPath: "/m/worktrees.noindex",
        liveWorktreePaths: ["/m/worktrees.noindex/owner-repo-pr2"]
    )

    #expect(orphans == ["/m/worktrees.noindex/owner-repo-pr1", "/m/worktrees.noindex/owner-repo-pr3"])
}

@Test func scannerFindsNothingWhenEveryDirectoryIsLive() {
    let orphans = WorktreeOrphanScanner.orphanPaths(
        directoryNames: ["a", "b"],
        rootPath: "/m/worktrees.noindex",
        liveWorktreePaths: ["/m/worktrees.noindex/a", "/m/worktrees.noindex/b"]
    )

    #expect(orphans.isEmpty)
}

@Test func scannerIgnoresDotDirectories() {
    let orphans = WorktreeOrphanScanner.orphanPaths(
        directoryNames: [".DS_Store", "a"],
        rootPath: "/m/worktrees.noindex",
        liveWorktreePaths: []
    )

    #expect(orphans == ["/m/worktrees.noindex/a"])
}
