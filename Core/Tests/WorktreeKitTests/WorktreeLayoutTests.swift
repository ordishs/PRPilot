import Testing
@testable import WorktreeKit

@Test func layoutUsesANonIndexedDirectoryName() {
    #expect(WorktreeLayout.directoryName == "worktrees.noindex")
    #expect(WorktreeLayout.legacyDirectoryName == "worktrees")
}

@Test func layoutBuildsBothRoots() {
    #expect(WorktreeLayout.directory(managedRoot: "/m") == "/m/worktrees.noindex")
    #expect(WorktreeLayout.legacyDirectory(managedRoot: "/m") == "/m/worktrees")
}

@Test func layoutRewritesALegacyPath() {
    let rewritten = WorktreeLayout.migratedPath("/m/worktrees/owner-repo-pr1", managedRoot: "/m")

    #expect(rewritten == "/m/worktrees.noindex/owner-repo-pr1")
}

@Test func layoutLeavesAnAlreadyMigratedPathAlone() {
    let rewritten = WorktreeLayout.migratedPath("/m/worktrees.noindex/owner-repo-pr1", managedRoot: "/m")

    #expect(rewritten == nil)
}

@Test func layoutLeavesAPathOutsideTheManagedRootAlone() {
    let rewritten = WorktreeLayout.migratedPath("/elsewhere/worktrees/x", managedRoot: "/m")

    #expect(rewritten == nil)
}
