import Testing
@testable import PRPilotModels

@Test func validBranchNamesAccepted() {
    for name in ["main", "feat/test-prpilot", "feature/MvP-4632", "fix/utxo_drain", "release/1.2.3", "a"] {
        #expect(BranchName.isValid(name), "expected valid: \(name)")
    }
}

@Test func invalidBranchNamesRejected() {
    for name in [
        "",
        "feat/test prpilot",      // space (the reported bug)
        "feat/\ttab",
        "feat..bar",
        "feat//bar",
        "/leading",
        "trailing/",
        ".leadingdot",
        "trailingdot.",
        "wip.lock",
        "has~tilde", "has^caret", "has:colon", "has?q", "has*star", "has[bracket", "has\\slash",
        "@",
        "foo@{bar",
    ] {
        #expect(!BranchName.isValid(name), "expected invalid: \(name)")
    }
}
