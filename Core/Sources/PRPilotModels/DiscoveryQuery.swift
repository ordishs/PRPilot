import Foundation

public struct DiscoveryQuery: Codable, Sendable, Equatable {
    public var text: String
    public var allowUnscoped: Bool

    public init(text: String, allowUnscoped: Bool = false) {
        self.text = text
        self.allowUnscoped = allowUnscoped
    }

    /// A query is "scoped" when it contains at least one qualifier that bounds results to a
    /// person or a repo/org. Without one, `gh search prs` returns a global firehose.
    public static func isScoped(_ text: String) -> Bool {
        let qualifiers = [
            "author:", "review-requested:", "assignee:", "mentions:", "involves:",
            "commenter:", "user:", "org:", "repo:",
        ]
        let lower = text.lowercased()
        return qualifiers.contains { lower.contains($0) }
    }

    public var isScoped: Bool { DiscoveryQuery.isScoped(text) }
}
