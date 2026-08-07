import Foundation
import PRPilotModels

/// Renders the user's launch-prompt template into the first prompt of a session.
///
/// The template exists because what `/review` and `/start-issue` actually do is decided
/// upstream and keeps changing; owning the prompt means the user can adapt without an app
/// change. The rendered string is passed as a single shell-escaped argument, so quotes and
/// newlines in a template are safe.
public enum LaunchPrompt {
    static let placeholders = ["{url}", "{number}", "{owner}", "{repo}", "{title}"]

    public static func render(_ template: String, for item: WorkItem, url: URL?) -> String {
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        var rendered = template
        let values: [String: String] = [
            "{url}": url?.absoluteString ?? "",
            "{number}": item.displayNumber.map(String.init) ?? "",
            "{owner}": item.owner,
            "{repo}": item.repo,
            "{title}": item.title,
        ]
        // Only known placeholders are substituted. An unknown one is left verbatim so a typo
        // shows up in the transcript instead of silently rendering a different prompt.
        for (placeholder, value) in values {
            rendered = rendered.replacingOccurrences(of: placeholder, with: value)
        }
        return rendered
    }
}
