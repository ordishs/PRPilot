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

    /// Sentence that points a newly launched agent at the handover note.
    ///
    /// Prepended rather than appended: the note explains that this is a continuation, and an
    /// agent that reads "review the pull request" first will start over before it gets there.
    static func handoverPointer(_ path: String) -> String {
        """
        Another agent was working on this and stopped part-way. Read `\(path)` first. It says \
        where it had reached and what is left. Then carry on from there rather than starting \
        again.
        """
    }

    public static func render(_ template: String, for item: WorkItem, url: URL?) -> String {
        let body = renderTemplate(template, for: item, url: url)
        guard let handover = item.pendingHandoverPath else { return body }
        // A blank template still gets the pointer. Otherwise a user who deliberately launches
        // with no prompt would silently lose the handover.
        guard !body.isEmpty else { return handoverPointer(handover) }
        return handoverPointer(handover) + "\n\n" + body
    }

    private static func renderTemplate(_ template: String, for item: WorkItem, url: URL?) -> String {
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
