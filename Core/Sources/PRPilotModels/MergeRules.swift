import Foundation

/// What a repository demands of a pull request before it will merge, as far as the app can
/// read it. Cached per repository and base branch, not per PR: the rules belong to the
/// branch and change rarely.
///
/// `requiredApprovals` is nil when the requirement is unknown — an unprotected branch, a
/// repository with no ruleset, or a token without the access to read one. A nil is a
/// silence, never a zero: the row then shows a plain approval count and claims nothing
/// about what the merge needs.
public struct MergeRules: Codable, Sendable, Equatable {
    public var requiredApprovals: Int?

    public init(requiredApprovals: Int? = nil) {
        self.requiredApprovals = requiredApprovals
    }

    /// Whether this many approvals falls short of the requirement. False whenever the
    /// requirement is unknown.
    public func isApprovalCountShort(_ count: Int) -> Bool {
        guard let requiredApprovals else { return false }
        return count < requiredApprovals
    }

    /// Cache key. The base branch is part of it because a repository can protect `main`
    /// and leave a release branch open.
    public static func key(owner: String, repo: String, branch: String) -> String {
        "\(owner)/\(repo)#\(branch)"
    }
}
