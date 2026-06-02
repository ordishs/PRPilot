import Testing
import Foundation
import PRPilotModels
import ReviewStore

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("prpilot-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("store.json")
}

private func sampleItem(number: Int = 944, title: String = "centrifuge fix") -> WorkItem {
    WorkItem(
        title: title,
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/centrifuge",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: number,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/\(number)")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func newStoreCreatesFileAndStartsEmpty() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let items = await store.allItems()
    #expect(items.isEmpty)
}

@Test func upsertAddsThenReplacesByID() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let first = sampleItem(title: "first")
    try await store.upsertItem(first)
    var all = await store.allItems()
    #expect(all.count == 1)
    #expect(all.first?.title == "first")

    var second = first
    second.title = "second"
    try await store.upsertItem(second)
    all = await store.allItems()
    #expect(all.count == 1)
    #expect(all.first?.title == "second")
}

@Test func removeItemDeletesByID() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = sampleItem()
    try await store.upsertItem(item)
    try await store.removeItem(id: item.id)
    let all = await store.allItems()
    #expect(all.isEmpty)
}

@Test func itemsPersistAcrossReload() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleItem(number: 901, title: "prune subtrees"))

    let reloaded = try ReviewStore(fileURL: url)
    let all = await reloaded.allItems()
    #expect(all.count == 1)
    #expect(all.first?.prRef?.number == 901)
}

@Test func registeredRepoLookupByRemote() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let repo = RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    )
    try await store.upsert(repo)
    let found = await store.repo(forRemote: "github.com/bsv-blockchain/teranode")
    #expect(found?.localClonePath == "/Users/me/dev/teranode")
}

@Test func settingsUpdatePersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    var settings = await store.settings()
    settings.diffMode = .split
    settings.pollIntervalSeconds = 300
    try await store.updateSettings(settings)

    let reloaded = try ReviewStore(fileURL: url)
    let reloadedSettings = await reloaded.settings()
    #expect(reloadedSettings.diffMode == .split)
    #expect(reloadedSettings.pollIntervalSeconds == 300)
}

@Test func loadMigratesLegacySchemaV1FileAndRewritesIt() async throws {
    let url = tempStoreURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Legacy store.json: schemaVersion 1, one flat Review record. Dates are ISO8601 (the store's encoder uses .iso8601).
    let legacy = """
    {
      "schemaVersion": 1,
      "reviews": [
        {
          "id": "bsv-blockchain/teranode#944",
          "owner": "bsv-blockchain", "repo": "teranode", "number": 944,
          "url": "https://github.com/bsv-blockchain/teranode/pull/944",
          "title": "centrifuge fix", "author": "icellan",
          "headBranch": "fix/centrifuge", "baseBranch": "main",
          "origin": "discovered", "prState": "open",
          "worktreePath": "/tmp/wt/bsv-blockchain-teranode-pr944",
          "claudeSessionID": "abc-123",
          "addedAt": "2021-01-01T00:00:00Z", "disabled": false, "viewedFiles": []
        }
      ],
      "registeredRepos": [],
      "settings": {
        "managedRoot": "/tmp/x",
        "discoveryQueries": ["review-requested:@me is:open"],
        "pollIntervalSeconds": 120,
        "claudeLaunchArgs": "", "claudeEnv": "", "autoLoad": false,
        "notificationsEnabled": true, "diffMode": "unified",
        "diffIgnoreWhitespace": false, "sidebarGrouping": "byDate"
      }
    }
    """
    try Data(legacy.utf8).write(to: url, options: [.atomic])

    let store = try ReviewStore(fileURL: url)
    let items = await store.allItems()
    #expect(items.count == 1)
    let item = items[0]
    #expect(item.repoKey == "github.com/bsv-blockchain/teranode")
    #expect(item.prRef?.number == 944)
    #expect(item.prRef?.authorLogin == "icellan")
    #expect(item.worktreePath == "/tmp/wt/bsv-blockchain-teranode-pr944")
    #expect(item.claudeSessionID == "abc-123")
    #expect(item.origin == .discovered)
    #expect(UUID(uuidString: item.id) != nil)   // minted UUID, not the old PR string
    #expect(item.id != "bsv-blockchain/teranode#944")

    // The file must have been rewritten at the current schema version …
    let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    #expect(rewritten?["schemaVersion"] as? Int == PRPilotModels.schemaVersion)

    // … and a second load must yield the SAME id (UUID frozen by the rewrite).
    let reloaded = try ReviewStore(fileURL: url)
    let reloadedItems = await reloaded.allItems()
    #expect(reloadedItems.count == 1)
    #expect(reloadedItems[0].id == item.id)
}
