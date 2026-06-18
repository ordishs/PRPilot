import Foundation

public struct IssueRef: Codable, Sendable, Equatable {
    public var owner: String
    public var repo: String
    public var number: Int
    public var url: URL
    public var authorLogin: String

    public init(owner: String, repo: String, number: Int, url: URL, authorLogin: String) {
        self.owner = owner
        self.repo = repo
        self.number = number
        self.url = url
        self.authorLogin = authorLogin
    }
}
