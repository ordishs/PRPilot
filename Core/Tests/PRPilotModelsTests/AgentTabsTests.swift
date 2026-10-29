import Testing
import Foundation
@testable import PRPilotModels

private func item(disabled: Bool = false) -> WorkItem {
    var item = WorkItem(
        title: "t",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        headBranch: "h",
        prRef: PRRef(
            owner: "o", repo: "r", number: 1,
            url: URL(string: "https://github.com/o/r/pull/1")!,
            authorLogin: "a"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 0)
    )
    item.disabled = disabled
    return item
}

@Test func anItemWithNoSessionHasNoAgentTab() {
    let work = item()

    #expect(agentTabs(for: work, defaultAgent: .claudeCode, isLive: false).isEmpty)
    #expect(addableAgents(for: work, defaultAgent: .claudeCode, isLive: false) == AgentKind.allCases)
}

@Test func eachStoredSessionGivesATabInFixedOrder() {
    var work = item()
    work.setSessionID("c1", for: .codex)
    work.setSessionID("a1", for: .claudeCode)

    #expect(agentTabs(for: work, defaultAgent: .pi, isLive: false) == [.claudeCode, .codex])
    #expect(addableAgents(for: work, defaultAgent: .pi, isLive: false) == [.pi])
}

@Test func aLiveAgentWithoutAStoredSessionStillGetsItsTab() {
    var work = item()
    work.setSessionID("a1", for: .claudeCode)
    work.agent = .pi

    #expect(agentTabs(for: work, defaultAgent: .claudeCode, isLive: true) == [.claudeCode, .pi])
    #expect(agentTabs(for: work, defaultAgent: .claudeCode, isLive: false) == [.claudeCode])
}

@Test func aDisabledItemOffersNoAgentTabsAndNoAdd() {
    var work = item(disabled: true)
    work.setSessionID("a1", for: .claudeCode)

    #expect(agentTabs(for: work, defaultAgent: .claudeCode, isLive: true).isEmpty)
    #expect(addableAgents(for: work, defaultAgent: .claudeCode, isLive: true).isEmpty)
}
