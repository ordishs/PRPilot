import Foundation

public struct IssueLocator: Sendable, Equatable {
    public var owner: String
    public var repo: String
    public var number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    public static func parse(_ urlString: String) throws -> IssueLocator {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            throw GitHubError.invalidURL(urlString)
        }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "issues", let number = Int(parts[3]), number > 0 else {
            throw GitHubError.invalidURL(urlString)
        }
        return IssueLocator(owner: parts[0], repo: parts[1], number: number)
    }
}
