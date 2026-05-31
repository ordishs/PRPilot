import Testing
import Foundation
import PRPilotModels
import ReviewStore

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("prreview-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("store.json")
}

private func sampleReview(number: Int = 944, title: String = "centrifuge fix") -> Review {
    Review(
        owner: "bsv-blockchain",
        repo: "teranode",
        number: number,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/\(number)")!,
        title: title,
        author: "icellan",
        headBranch: "fix/centrifuge",
        baseBranch: "main",
        origin: .added,
        prState: .open,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test func newStoreCreatesFileAndStartsEmpty() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let reviews = await store.allReviews()
    #expect(reviews.isEmpty)
}

@Test func upsertAddsThenReplacesByID() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(sampleReview(title: "first"))
    var all = await store.allReviews()
    #expect(all.count == 1)
    #expect(all.first?.title == "first")

    try await store.upsert(sampleReview(title: "second"))
    all = await store.allReviews()
    #expect(all.count == 1)
    #expect(all.first?.title == "second")
}

@Test func removeReviewDeletesByID() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    try await store.removeReview(id: review.id)
    let all = await store.allReviews()
    #expect(all.isEmpty)
}

@Test func reviewsPersistAcrossReload() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsert(sampleReview(number: 901, title: "prune subtrees"))

    let reloaded = try ReviewStore(fileURL: url)
    let all = await reloaded.allReviews()
    #expect(all.count == 1)
    #expect(all.first?.number == 901)
    #expect(all.first?.id == "bsv-blockchain/teranode#901")
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
