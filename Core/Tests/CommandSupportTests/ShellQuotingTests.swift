import Testing
@testable import CommandSupport

@Test func aWorktreePathWithASpaceIsQuoted() {
    let path = "/Users/me/Library/Application Support/PRPilot/worktrees.noindex/repo-branch"

    #expect(ShellQuoting.quote(path)
        == "'/Users/me/Library/Application Support/PRPilot/worktrees.noindex/repo-branch'")
}

@Test func aPathWithNothingSpecialIsLeftAlone() {
    #expect(ShellQuoting.quote("/Users/me/dev/teranode") == "/Users/me/dev/teranode")
}

@Test func aBranchSlugKeepsItsPunctuationUnquoted() {
    // Dots, dashes, underscores and slashes are safe, so a plain worktree name stays bare.
    #expect(ShellQuoting.quote("/tmp/worktrees.noindex/fix_4459-limit-ram") == "/tmp/worktrees.noindex/fix_4459-limit-ram")
}

@Test func anEmbeddedSingleQuoteIsEscaped() {
    #expect(ShellQuoting.quote("/tmp/simon's repo") == "'/tmp/simon'\\''s repo'")
}

@Test func shellExpansionCharactersForceQuoting() {
    #expect(ShellQuoting.quote("/tmp/$HOME") == "'/tmp/$HOME'")
    #expect(ShellQuoting.quote("/tmp/`whoami`") == "'/tmp/`whoami`'")
    #expect(ShellQuoting.quote("/tmp/a;rm -rf b") == "'/tmp/a;rm -rf b'")
    #expect(ShellQuoting.quote("/tmp/back\\slash") == "'/tmp/back\\slash'")
}

@Test func anEmptyStringBecomesAnEmptyQuotedArgument() {
    #expect(ShellQuoting.quote("") == "''")
}
