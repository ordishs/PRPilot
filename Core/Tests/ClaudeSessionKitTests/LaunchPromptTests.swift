import Testing
import Foundation
import PRPilotModels
@testable import ClaudeSessionKit

private let prURL = URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!

private func prItem() -> WorkItem {
    WorkItem(
        id: "item-1",
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/centrifuge",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 944,
            url: prURL, authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func rendersEveryPlaceholder() {
    let rendered = LaunchPrompt.render(
        "url={url} number={number} owner={owner} repo={repo} title={title}",
        for: prItem(),
        url: prURL
    )
    #expect(rendered == "url=https://github.com/bsv-blockchain/teranode/pull/944 number=944 owner=bsv-blockchain repo=teranode title=centrifuge fix")
}

@Test func rendersDefaultReviewTemplateUnchanged() {
    let rendered = LaunchPrompt.render(Settings.defaultReviewPromptTemplate, for: prItem(), url: prURL)
    #expect(rendered == "/review https://github.com/bsv-blockchain/teranode/pull/944")
}

@Test func substitutesEveryOccurrenceNotJustTheFirst() {
    let rendered = LaunchPrompt.render("{number} and again {number}", for: prItem(), url: prURL)
    #expect(rendered == "944 and again 944")
}

@Test func leavesUnknownPlaceholderVerbatim() {
    // A typo must stay visible in the transcript rather than silently vanishing.
    let rendered = LaunchPrompt.render("/review {urls}", for: prItem(), url: prURL)
    #expect(rendered == "/review {urls}")
}

@Test func preservesMultiLineInstructions() {
    let template = """
    /review {url}

    End with a single line: VERDICT: APPROVE | REQUEST CHANGES | COMMENT.
    Keep the summary under 10 lines.
    """
    let rendered = LaunchPrompt.render(template, for: prItem(), url: prURL)
    #expect(rendered == """
    /review https://github.com/bsv-blockchain/teranode/pull/944

    End with a single line: VERDICT: APPROVE | REQUEST CHANGES | COMMENT.
    Keep the summary under 10 lines.
    """)
}

@Test func passesThroughATemplateWithNoPlaceholders() {
    let rendered = LaunchPrompt.render("just review the current diff", for: prItem(), url: prURL)
    #expect(rendered == "just review the current diff")
}

@Test func whitespaceOnlyTemplateRendersEmpty() {
    #expect(LaunchPrompt.render("   \n  ", for: prItem(), url: prURL).isEmpty)
    #expect(LaunchPrompt.render("", for: prItem(), url: prURL).isEmpty)
}

@Test func missingValueRendersEmpty() {
    let rendered = LaunchPrompt.render("/review {url}", for: prItem(), url: nil)
    #expect(rendered == "/review ")
}
