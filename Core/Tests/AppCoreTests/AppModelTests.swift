import Testing
import Foundation
import PRPilotModels
import GitHubKit
import CommandSupport
import ReviewStore
import DiffKit
import WorktreeKit
@testable import AppCore
import AgentKit
import GatewayKit

private actor StubRunner: CommandRunner {
    private var results: [CommandResult]
    private let fallback: CommandResult?
    private(set) var recordedArguments: [[String]] = []

    init(result: CommandResult) {
        self.results = []
        self.fallback = result
    }

    init(results: [CommandResult]) {
        self.results = results
        self.fallback = nil
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        recordedArguments.append(arguments)
        if !results.isEmpty {
            return results.removeFirst()
        }
        if let fallback {
            return fallback
        }
        throw NSError(domain: "StubRunner", code: -1, userInfo: [NSLocalizedDescriptionKey: "queue exhausted"])
    }
}

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("appcore-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("store.json")
}

private let prJSON = """
{
  "number": 944,
  "title": "centrifuge fix",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge",
  "baseRefName": "main"
}
"""

private struct StubDiffLoader: DiffLoading {
    var files: [DiffFile] = []
    var shouldThrow = false
    func loadDiff(for review: WorkItem, registeredClonePath: String?) async throws -> DiffResult {
        if shouldThrow {
            throw DiffError.gitFailed(exitCode: 1, message: "stub failure")
        }
        return DiffResult(worktreePath: "/tmp/wt", files: files)
    }
}

private struct StubRegistrar: CloneRegistering {
    var shouldThrow: RegistrationError? = nil
    var detectedRepositories: [String] = []
    func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws {
        if let error = shouldThrow {
            throw error
        }
    }
    func detectRepositories(at localPath: String) async throws -> [String] {
        if let error = shouldThrow {
            throw error
        }
        return detectedRepositories
    }
}

private actor RecordingDiffLoader: DiffLoading {
    private(set) var lastRegisteredClonePath: String?
    private(set) var callCount: Int = 0
    func loadDiff(for review: WorkItem, registeredClonePath: String?) async throws -> DiffResult {
        callCount += 1
        lastRegisteredClonePath = registeredClonePath
        return DiffResult(worktreePath: "/tmp/wt", files: [])
    }
}

private actor StubNotificationPoster: NotificationPosting {
    private(set) var posted: [(reviewID: String, title: String, body: String)] = []
    private(set) var needsYou: [(reviewID: String, title: String, body: String)] = []
    func postReviewReady(reviewID: String, title: String, body: String) async {
        posted.append((reviewID: reviewID, title: title, body: body))
    }

    func postNeedsYou(reviewID: String, title: String, body: String) async {
        needsYou.append((reviewID: reviewID, title: title, body: body))
    }

    func waitForNeedsYou(atLeast count: Int, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while needsYou.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits until at least `count` notifications have arrived, or the deadline passes.
    ///
    /// A notification is posted from its own task, so a fixed sleep either wastes time or
    /// flakes under load. Polling asserts the same thing without guessing how long it takes.
    /// It deliberately does not fail on timeout: the caller's own expectation reports what it
    /// actually saw.
    func waitForPosts(atLeast count: Int, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while posted.count < count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Waits out a further quiet period, for a test asserting that nothing *more* arrives.
    func settle(seconds: TimeInterval = 0.4) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

private struct StubWorktreeProvider: WorktreeProviding {
    var result: WorktreeReady = WorktreeReady(clonePath: "/tmp/clone", worktreePath: "/tmp/wt", remoteName: "origin")
    var shouldThrow = false
    var progressLines: [String] = []
    func ensureWorktree(for review: WorkItem, editable: Bool, registeredClonePath: String?, progress: @escaping PrepProgress) async throws -> WorktreeReady {
        for line in progressLines {
            await progress(line)
        }
        if shouldThrow {
            throw WorktreeError.gitFailed(arguments: ["stub"], exitCode: 1, message: "stub failure")
        }
        return result
    }
}

private actor StubWorktreeOps: WorktreeManaging {
    var currentBranchResult: String? = nil
    var isCleanResult: Bool = true
    var isCleanThrows = false
    var rebaseResult: RebaseOutcome = .clean
    var aheadBehindByUpstream: [String: (ahead: Int, behind: Int)] = [:]
    var aheadBehindDefaultResult: (ahead: Int, behind: Int) = (0, 0)
    var shouldThrowAheadBehind: Set<String> = []
    private(set) var recordedPushCalls: [(remoteName: String, branch: String, force: Bool)] = []

    var localChangesResult: [String] = []
    private(set) var discardedPaths: [String] = []
    private(set) var refreshedWorktrees: [String] = []

    func set(localChangesResult: [String]) { self.localChangesResult = localChangesResult }

    func localChanges(worktreePath: String) async throws -> [String] { localChangesResult }

    func discardLocalChanges(worktreePath: String) async throws {
        discardedPaths.append(worktreePath)
        localChangesResult = []
    }

    func refreshWorktree(clonePath: String, worktreePath: String, number: Int, remoteName: String) async throws -> Bool {
        refreshedWorktrees.append(worktreePath)
        return true
    }

    func set(currentBranchResult: String?) { self.currentBranchResult = currentBranchResult }
    func set(isCleanThrows: Bool) { self.isCleanThrows = isCleanThrows }
    func set(rebaseResult: RebaseOutcome) { self.rebaseResult = rebaseResult }
    func set(aheadBehindDefaultResult: (ahead: Int, behind: Int)) { self.aheadBehindDefaultResult = aheadBehindDefaultResult }
    func set(aheadBehindByUpstream: [String: (ahead: Int, behind: Int)]) { self.aheadBehindByUpstream = aheadBehindByUpstream }
    func set(shouldThrowAheadBehind: Set<String>) { self.shouldThrowAheadBehind = shouldThrowAheadBehind }

    func currentBranch(worktreePath: String) async throws -> String? { currentBranchResult }
    func isClean(worktreePath: String) async throws -> Bool {
        if isCleanThrows { throw NSError(domain: "StubWorktreeOps", code: 128) }
        return isCleanResult
    }
    func fetch(clonePath: String, remoteName: String, ref: String) async throws {}
    func rebaseOnto(worktreePath: String, upstream: String) async throws -> RebaseOutcome { rebaseResult }
    func rebaseContinue(worktreePath: String) async throws -> RebaseOutcome { rebaseResult }
    private(set) var abortedRebases = 0
    func rebaseAbort(worktreePath: String) async throws { abortedRebases += 1 }
    func push(worktreePath: String, remoteName: String, branch: String, force: Bool) async throws {
        recordedPushCalls.append((remoteName: remoteName, branch: branch, force: force))
    }
    func aheadBehind(worktreePath: String, upstream: String) async throws -> (ahead: Int, behind: Int) {
        if shouldThrowAheadBehind.contains(upstream) {
            throw WorktreeError.gitFailed(arguments: ["rev-list"], exitCode: 128, message: "no such upstream")
        }
        return aheadBehindByUpstream[upstream] ?? aheadBehindDefaultResult
    }
    private(set) var repairedWorktreePaths: [String] = []
    func repairWorktree(worktreePath: String) async throws {
        repairedWorktreePaths.append(worktreePath)
    }

    private(set) var removedOrphanPaths: [String] = []
    var orphanRemovalError: WorktreeError?
    func removeOrphanWorktree(worktreePath: String) async throws {
        if let orphanRemovalError { throw orphanRemovalError }
        removedOrphanPaths.append(worktreePath)
    }

    func set(isCleanResult: Bool) { self.isCleanResult = isCleanResult }
    func set(orphanRemovalError: WorktreeError?) { self.orphanRemovalError = orphanRemovalError }
}

private let sampleReviewID = "AAAAAAAA-0000-0000-0000-000000000944"

private func sampleReview() -> WorkItem {
    WorkItem(
        id: sampleReviewID,
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/centrifuge",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 944,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func stubClient() -> GitHubClient {
    GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
}

@Test @MainActor func addPRFetchesStoresAndSelects() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: prJSON, standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.prRef?.number == 944)
    #expect(model.selection == model.reviews.first?.id)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func addPRSetsErrorOnInvalidURL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addPR(urlString: "not a pr url")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

@Test @MainActor func addPRSurfacesCommandFailureAndDismisses() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)

    model.dismissError()
    #expect(model.errorMessage == nil)
}

@Test @MainActor func loadReadsExistingReviews() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    try await seedStore.upsertItem(WorkItem(
        title: "prune",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "prune",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 901,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/901")!,
            authorLogin: "jad"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: try ReviewStore(fileURL: url), client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.load()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.number == 901)
}

@Test @MainActor func loadDiffSetsLoadedState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let file = DiffFile(oldPath: "foo.txt", newPath: "foo.txt", changeKind: .modified, hunks: [], addedCount: 1, removedCount: 0)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: [file]), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.loadDiff(for: sampleReview())

    #expect(model.diffStates[sampleReview().id] == .loaded([file]))
}

@Test @MainActor func loadDiffSetsFailedStateOnError() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(shouldThrow: true), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.loadDiff(for: sampleReview())

    if case .failed = model.diffStates[sampleReview().id] {
    } else {
        Issue.record("expected .failed, got \(String(describing: model.diffStates[sampleReview().id]))")
    }
}

@Test @MainActor func loadDiffPersistsWorktreePath() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: []), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.loadDiff(for: review)

    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allItems().first?.worktreePath == "/tmp/wt")
}

@Test @MainActor func registerCloneSucceedsAndPersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.registerClone(for: review, localPath: "/Users/me/dev/teranode")

    #expect(model.errorMessage == nil)
    #expect(model.registeredClonePath(for: review) == "/Users/me/dev/teranode")
    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.repo(forRemote: "github.com/bsv-blockchain/teranode")?.localClonePath == "/Users/me/dev/teranode")
}

@Test @MainActor func registerCloneSetsErrorOnValidationFailure() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(shouldThrow: .originMismatch(expected: "bsv-blockchain/teranode", actual: "x/y"))
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: registrar, worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.registerClone(for: sampleReview(), localPath: "/wrong/path")

    #expect(model.errorMessage != nil)
    #expect(model.registeredClonePath(for: sampleReview()) == nil)
}

@Test @MainActor func loadDiffPassesRegisteredClonePathToLoader() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    ))
    let recorder = RecordingDiffLoader()
    let model = AppModel(store: store, client: stubClient(), diffLoader: recorder, worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.loadDiff(for: review)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == "/Users/me/dev/teranode")
}

@Test @MainActor func loadDiffPassesNilWhenNoRegisteredClone() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let recorder = RecordingDiffLoader()
    let model = AppModel(store: store, client: stubClient(), diffLoader: recorder, worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.loadDiff(for: review)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == nil)
}

@Test @MainActor func registerLocalCloneRegistersAllDetected() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(detectedRepositories: ["ordishs/teranode", "bsv-blockchain/teranode"])
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: registrar, worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.registerLocalClone(at: "/Users/me/dev/teranode")

    #expect(model.errorMessage == nil)
    #expect(model.registeredRepos.count == 2)
    let identities = model.registeredRepos.map(\.remoteIdentity).sorted()
    #expect(identities == ["github.com/bsv-blockchain/teranode", "github.com/ordishs/teranode"])
    #expect(model.registeredRepos.allSatisfy { $0.localClonePath == "/Users/me/dev/teranode" })
}

@Test @MainActor func registerLocalCloneSetsErrorWhenNoReposFound() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(detectedRepositories: [])
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: registrar, worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.registerLocalClone(at: "/Users/me/empty")

    #expect(model.errorMessage != nil)
    #expect(model.registeredRepos.isEmpty)
}

@Test @MainActor func removeRegisteredRepoDeletes() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    ))
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    #expect(model.registeredRepos.count == 1)

    await model.removeRegisteredRepo(remoteIdentity: "github.com/bsv-blockchain/teranode")

    #expect(model.registeredRepos.isEmpty)
}

@Test @MainActor func removeReviewRemovesFromStoreAndClearsSelection() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    model.selection = review.id

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(model.selection == nil)
    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allItems().isEmpty)
}

@Test @MainActor func removeReviewBestEffortRemovesWorktreeDir() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let tempWorktree = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: tempWorktree, withIntermediateDirectories: true)
    var review = sampleReview()
    review.worktreePath = tempWorktree
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: tempWorktree))
}

@Test @MainActor func removeReviewNeverDeletesRegisteredClone() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let clonePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: clonePath, withIntermediateDirectories: true)
    let sentinel = clonePath + "/.git"
    try FileManager.default.createDirectory(atPath: sentinel, withIntermediateDirectories: true)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: clonePath,
        defaultBase: "main"
    ))
    var review = sampleReview()
    review.worktreePath = clonePath
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(FileManager.default.fileExists(atPath: clonePath))
    #expect(FileManager.default.fileExists(atPath: sentinel))
    #expect(model.errorMessage?.contains("registered repository clone") == true)

    try? FileManager.default.removeItem(atPath: clonePath)
}

@Test @MainActor func removeReviewDeletesWorktreeInsideCloneParent() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let clonePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: clonePath, withIntermediateDirectories: true)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: clonePath,
        defaultBase: "main"
    ))
    let worktree = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
    var review = sampleReview()
    review.worktreePath = worktree
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.removeReview(id: review.id)

    #expect(!FileManager.default.fileExists(atPath: worktree))
    #expect(FileManager.default.fileExists(atPath: clonePath))

    try? FileManager.default.removeItem(atPath: clonePath)
}

@Test @MainActor func prepLogRetainedOnWorktreeFailure() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(shouldThrow: true, progressLines: ["Fetching PR #944…"]),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureAgentSession(for: review)

    if case .worktreeFailed = model.claudePaneState[review.id] {} else {
        Issue.record("expected .worktreeFailed, got \(String(describing: model.claudePaneState[review.id]))")
    }
    let messages = (model.claudePrepLog[review.id] ?? []).map(\.message)
    #expect(messages.contains("Locating claude…"))
    #expect(messages.contains("Fetching PR #944…"))
}

@Test @MainActor func ensureAgentSessionStartsFreshWhenPersistedTranscriptMissing() async throws {
    // A persisted session whose transcript no longer exists (archived/pruned) must not be
    // resumed — `claude --resume` would exit "No conversation found". The model should
    // assign a fresh session id instead. The stub worktree path points at /tmp/wt, whose
    // ~/.claude/projects transcript dir has no transcript for this id.
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = "ghost-session-\(UUID().uuidString.lowercased())"
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureAgentSession(for: review)

    let refreshed = model.reviews.first(where: { $0.id == review.id })
    #expect(refreshed?.claudeSessionID != nil)
    #expect(refreshed?.claudeSessionID != review.claudeSessionID)
}

@Test @MainActor func prepLogRetainedOnSessionLive() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(progressLines: ["Fetching PR #944…"]),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureAgentSession(for: review)

    // The prep log persists after the session goes live so the pane can re-open it
    // on demand; it is reset at the start of the next prep run, not cleared here.
    #expect(model.claudePaneState[review.id] == .sessionLive)
    let messages = (model.claudePrepLog[review.id] ?? []).map(\.message)
    #expect(messages.contains("Fetching PR #944…"))
    // Agent-neutral wording: the same log serves pi, which has no `/review` command. The
    // "Locating" line names the agent's own binary rather than hardcoding claude.
    #expect(messages.contains("Starting fresh session"))
    #expect(messages.contains("Locating claude…"))
}

@Test @MainActor func ensureAgentSessionFlagsWorktreeFailure() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(shouldThrow: true),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    let review = sampleReview()

    await model.ensureAgentSession(for: review)

    let state = model.claudePaneState[review.id]
    if case .worktreeFailed(let message) = state {
        #expect(message.contains("stub failure"))
    } else {
        Issue.record("expected .worktreeFailed, got \(String(describing: state))")
    }
    #expect(model.claudeSessions[review.id] == nil)
}

@Test @MainActor func ensureAgentSessionInitializesStatus() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureAgentSession(for: review)

    let status = model.claudeStatuses[review.id]
    #expect(status == .starting)
}

@Test @MainActor func recomputeStatusFlipsToIdle() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster(),
        statusReader: AgentStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureAgentSession(for: review)

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: "Hello")
    model.recomputeStatus(for: review.id, now: Date())

    let firstStatus = model.claudeStatuses[review.id]
    #expect(firstStatus == .working)

    let later = Date().addingTimeInterval(1)
    model.recomputeStatus(for: review.id, now: later)

    let secondStatus = model.claudeStatuses[review.id]
    if case .idle(_, let snippet) = secondStatus {
        #expect(snippet == "Hello")
    } else {
        Issue.record("expected .idle, got \(String(describing: secondStatus))")
    }
}

@Test @MainActor func clearAgentSessionResetsSessionAndReviewedState() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    var review = sampleReview()
    review.claudeSessionID = "existing-session"
    review.claudeReviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.clearAgentSession(for: review.id)

    let cleared = model.reviews.first(where: { $0.id == review.id })
    // Clearing archives the old session and starts a fresh one (new id), and
    // resets the "reviewed" stamp so the fresh review can re-stamp it.
    #expect(cleared?.claudeSessionID != nil)
    #expect(cleared?.claudeSessionID != "existing-session")
    #expect(cleared?.claudeReviewedAt == nil)
}

@Test @MainActor func clearAgentSessionStartsFreshSessionForOpenPane() async throws {
    // Clearing the session for the currently-open PR must immediately start a fresh
    // session. The pane only re-triggers ensureAgentSession when review.id changes,
    // so if clear left the pane state nil it would hang on "Preparing worktree…".
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = "existing-session"
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureAgentSession(for: review)

    await model.clearAgentSession(for: review.id)

    #expect(model.claudePaneState[review.id] == .sessionLive)
    let refreshed = model.reviews.first(where: { $0.id == review.id })
    #expect(refreshed?.claudeSessionID != nil)
    #expect(refreshed?.claudeSessionID != "existing-session")
}

@Test func ensureWorktreeTwoArgOverloadForwardsToProgressVariant() async throws {
    final class Box: @unchecked Sendable { var called = false }
    struct Recorder: WorktreeProviding {
        let box: Box
        func ensureWorktree(for review: WorkItem, editable: Bool, registeredClonePath: String?, progress: @escaping PrepProgress) async throws -> WorktreeReady {
            box.called = true
            return WorktreeReady(clonePath: "/c", worktreePath: "/w", remoteName: "origin")
        }
    }
    let box = Box()
    let recorder = Recorder(box: box)
    _ = try await recorder.ensureWorktree(for: sampleReview(), editable: false, registeredClonePath: nil)
    #expect(box.called == true)
}

@Test @MainActor func idleWithoutCompletedTurnDoesNotStampReviewed() async throws {
    // An interrupted-then-resumed review goes idle without ever completing a turn
    // (no end_turn). It must NOT be marked reviewed just for being idle.
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster(),
        statusReader: AgentStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureAgentSession(for: review)

    let staleEvent = Date().addingTimeInterval(-3600)
    model.handleTranscriptEvent(reviewID: review.id, at: staleEvent, snippet: "Gathering details", turnCompleted: false)
    model.recomputeStatus(for: review.id, now: Date())

    if case .idle = model.claudeStatuses[review.id] {} else {
        Issue.record("expected .idle, got \(String(describing: model.claudeStatuses[review.id]))")
    }

    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeReviewedAt == nil)
}

@Test @MainActor func completedTurnStampsReviewed() async throws {
    // A genuinely finished review (assistant reached end_turn) is marked reviewed,
    // even without a live working->idle edge (e.g. replayed on resume).
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let poster = StubNotificationPoster()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: AgentStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureAgentSession(for: review)

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: "Review complete", turnCompleted: true)

    try await waitForItem(model, id: review.id) { $0.claudeReviewedAt != nil }
    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeReviewedAt != nil)

    // Completing a turn now yields .awaitingInput, which fires the "needs you" notification.
    let posted = await poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.reviewID == review.id)
}

@Test @MainActor func awaitingInputFiresNotificationOnceAndRearms() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let poster = StubNotificationPoster()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: AgentStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureAgentSession(for: review)

    // All transitions run synchronously (no await) so the stub process cannot
    // exit mid-sequence; the single sleep at the end flushes the notification Tasks.
    let t0 = Date()
    model.handleTranscriptEvent(reviewID: review.id, at: t0, snippet: "working", turnCompleted: false)
    model.recomputeStatus(for: review.id, now: t0)                       // working
    let t1 = t0.addingTimeInterval(1)
    model.handleTranscriptEvent(reviewID: review.id, at: t1, snippet: "done", turnCompleted: true)
    model.recomputeStatus(for: review.id, now: t1)                       // awaitingInput -> fire #1
    model.recomputeStatus(for: review.id, now: t1.addingTimeInterval(1)) // still awaiting -> no fire
    let t2 = t1.addingTimeInterval(2)
    model.handleTranscriptEvent(reviewID: review.id, at: t2, snippet: "more", turnCompleted: false)
    model.recomputeStatus(for: review.id, now: t2)                       // working -> re-arm
    let t3 = t2.addingTimeInterval(1)
    model.handleTranscriptEvent(reviewID: review.id, at: t3, snippet: "done2", turnCompleted: true)
    model.recomputeStatus(for: review.id, now: t3)                       // awaitingInput -> fire #2

    try await Task.sleep(nanoseconds: 200_000_000)
    let posted = await poster.posted
    #expect(posted.count == 2)
}

private let sampleSearchHitJSON = """
[
  {
    "number": 944,
    "title": "centrifuge fix",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "open",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

private let sampleMergedSearchHitJSON = """
[
  {
    "number": 944,
    "title": "centrifuge fix",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "merged",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

private let emptySearchJSON = "[]"

private let prFetchJSON = """
{
  "number": 944,
  "title": "centrifuge fix",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge",
  "baseRefName": "main",
  "closingIssuesReferences": []
}
"""

@Test @MainActor func discoverNowPopulatesNewReviews() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    seed.issuesEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.prRef?.number == 944)
    #expect(model.reviews.first?.origin == .discovered)
}

@Test @MainActor func discoverNowPromotesAddedToBoth() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.origin == .both)
}

// The issue query finds the stub queue empty and fails. That says nothing about PRs, so the
// PR that fell out of its query still goes.
@Test @MainActor func discoverNowDropsPRsFallingOutOfQueryWhenOnlyTheIssueQueryFails() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    var existing = sampleReview()
    existing.origin = .discovered
    try await store.upsertItem(existing)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.discoveryWarnings.count == 1)
    #expect(model.discoveryWarnings.first?.contains("assignee:@me") == true)
    #expect(model.reviews.isEmpty)
}

@Test @MainActor func discoverNowUpdatesPRState() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    var existing = sampleReview()
    existing.prState = .open
    existing.origin = .discovered
    try await store.upsertItem(existing)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleMergedSearchHitJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.first?.prState == .merged)
}

@Test @MainActor func discoverNowDeduplicatesAcrossQueries() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [
        DiscoveryQuery(text: "review-requested:@me is:open"),
        DiscoveryQuery(text: "assignee:@me is:open"),
    ]
    seed.myPRsEnabled = false
    seed.issuesEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
}

@Test @MainActor func setDiffModePersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    #expect(model.diffMode == .unified)

    await model.setDiffMode(.split)

    #expect(model.diffMode == .split)
    let reloaded = try ReviewStore(fileURL: url)
    let settings = await reloaded.settings()
    #expect(settings.diffMode == .split)
}

@Test @MainActor func loadReadsPersistedDiffMode() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seedSettings = Settings.default
    seedSettings.diffMode = .split
    try await seedStore.updateSettings(seedSettings)
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )

    await model.load()

    #expect(model.diffMode == .split)
}

@Test @MainActor func loadReadsAllPersistedSettings() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "author:@me")]
    seed.myPRsEnabled = false
    seed.pollIntervalSeconds = 240
    seed.claudeLaunchArgs = "--model opus"
    seed.notificationsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )

    await model.load()

    #expect(model.settings.reviewRequestQueries == [DiscoveryQuery(text: "author:@me")])
    #expect(model.settings.myPRsEnabled == false)
    #expect(model.settings.pollIntervalSeconds == 240)
    #expect(model.settings.claudeLaunchArgs == "--model opus")
    #expect(model.settings.notificationsEnabled == false)
}

@Test @MainActor func updateSettingsPersistsAndUpdatesInMemory() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    var newSettings = model.settings
    newSettings.reviewRequestQueries = [DiscoveryQuery(text: "assignee:foo is:open")]
    newSettings.myPRsEnabled = false
    newSettings.pollIntervalSeconds = 300
    await model.updateSettings(newSettings)

    #expect(model.settings.reviewRequestQueries == [DiscoveryQuery(text: "assignee:foo is:open")])
    #expect(model.settings.myPRsEnabled == false)
    #expect(model.settings.pollIntervalSeconds == 300)

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.settings()
    #expect(persisted.reviewRequestQueries == [DiscoveryQuery(text: "assignee:foo is:open")])
    #expect(persisted.myPRsEnabled == false)
    #expect(persisted.pollIntervalSeconds == 300)
}

@Test @MainActor func setReviewDisabledPersistsFlag() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    #expect(model.reviews.first?.disabled == false)

    await model.setReviewDisabled(true, for: review.id)

    #expect(model.reviews.first?.disabled == true)
    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems().first
    #expect(persisted?.disabled == true)
}

@Test @MainActor func prefetchSkipsDisabledReview() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.disabled = true
    try await store.upsertItem(review)
    let recorder = RecordingDiffLoader()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: recorder,
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    model.prefetch(for: review)
    try await Task.sleep(nanoseconds: 200_000_000)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == nil)
}

@Test @MainActor func discoverNowUsesCurrentSettingsQueries() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "author:@me custom:query")]
    seed.myPRsEnabled = false
    try await store.updateSettings(seed)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "[]", standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    let args = await runner.recordedArguments
    let containsQuery = args.contains { $0.contains("custom:query") }
    #expect(containsQuery)
}

@Test @MainActor func updateSettingsTriggersPollWhenQueriesChange() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "[]", standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    var updated = model.settings
    updated.reviewRequestQueries = [DiscoveryQuery(text: "author:@me custom:newquery")]
    updated.myPRsEnabled = false
    await model.updateSettings(updated)

    try await Task.sleep(nanoseconds: 250_000_000)

    let args = await runner.recordedArguments
    let containsNewQuery = args.contains { call in
        call.contains("custom:newquery")
    }
    #expect(containsNewQuery)
}

@Test @MainActor func markReviewOpenedPersistsTimestamp() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    let id = sampleReview().id

    await model.markReviewOpened(id)

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems().first
    #expect(persisted?.lastOpenedAt != nil)
}

@Test @MainActor func loadAutoSelectsMostRecentlyOpenedReview() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var first = sampleReview()
    first.lastOpenedAt = Date(timeIntervalSince1970: 1_000_000)
    var second = WorkItem(
        title: "second",
        repoKey: "github.com/other/repo",
        baseBranch: "main",
        headBranch: "f",
        prRef: PRRef(
            owner: "other", repo: "repo", number: 1,
            url: URL(string: "https://github.com/other/repo/pull/1")!,
            authorLogin: "bob"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date()
    )
    second.lastOpenedAt = Date(timeIntervalSince1970: 2_000_000)
    try await store.upsertItem(first)
    try await store.upsertItem(second)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )

    await model.load()

    #expect(model.selection == second.id)
}

@Test @MainActor func updateSettingsDoesNotPollWhenQueriesUnchanged() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    var updated = model.settings
    updated.pollIntervalSeconds = 60
    await model.updateSettings(updated)

    try await Task.sleep(nanoseconds: 150_000_000)

    let args = await runner.recordedArguments
    let searchCallCount = args.filter { $0.first == "search" }.count
    #expect(searchCallCount == 0)
}

@Test @MainActor func loadDiffSkipsRunWhenAlreadyLoaded() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let recorder = RecordingDiffLoader()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: recorder,
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    let review = sampleReview()

    await model.loadDiff(for: review)
    let firstCount = await recorder.callCount

    await model.loadDiff(for: review)
    let secondCount = await recorder.callCount

    #expect(firstCount == 1)
    #expect(secondCount == 1)
}

@Test @MainActor func loadDiffForceReruns() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let recorder = RecordingDiffLoader()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: recorder,
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    let review = sampleReview()

    await model.loadDiff(for: review)
    await model.loadDiff(for: review, force: true)

    let count = await recorder.callCount
    #expect(count == 2)
}

@Test @MainActor func setFileViewedPersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.setFileViewed(true, filePath: "src/foo.swift", reviewID: sampleReview().id)

    #expect(model.reviews.first?.viewedFiles.contains("src/foo.swift") == true)
    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems().first
    #expect(persisted?.viewedFiles.contains("src/foo.swift") == true)
}

@Test @MainActor func setFileViewedFalseRemovesEntry() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seeded = sampleReview()
    seeded.viewedFiles = ["a.swift", "b.swift"]
    try await store.upsertItem(seeded)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.setFileViewed(false, filePath: "a.swift", reviewID: seeded.id)

    let viewed = model.reviews.first?.viewedFiles ?? []
    #expect(viewed == ["b.swift"])
}

@Test @MainActor func setFileViewedNoOpsWhenAlreadyInDesiredState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.setFileViewed(false, filePath: "x.swift", reviewID: sampleReview().id)
    #expect(model.reviews.first?.viewedFiles.isEmpty == true)

    await model.setFileViewed(true, filePath: "x.swift", reviewID: sampleReview().id)
    await model.setFileViewed(true, filePath: "x.swift", reviewID: sampleReview().id)
    #expect(model.reviews.first?.viewedFiles == ["x.swift"])
}

@Test @MainActor func loadCachesCurrentLogin() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.load()

    #expect(model.currentLogin == "ordishs")
}

@Test @MainActor func markClaudeReviewedStampsOnce() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.markClaudeTurnCompleted(sampleReviewID)
    let first = model.reviews.first?.claudeReviewedAt
    let firstCompletion = model.reviews.first?.claudeLastCompletedAt
    #expect(first != nil)
    #expect(firstCompletion != nil)

    await model.markClaudeTurnCompleted(sampleReviewID)
    #expect(model.reviews.first?.claudeReviewedAt == first)
    #expect(model.reviews.first?.claudeLastCompletedAt != firstCompletion)
}

@Test @MainActor func refreshReviewStateSetsApprovedByMe() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let snapshotJSON = """
    {"data":{"r0":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN",
      "author":{"login":"icellan"},
      "commits":{"nodes":[{"commit":{"committedDate":null,"statusCheckRollup":null}}]},
      "reviews":{"nodes":[{"author":{"login":"ordishs"},"state":"APPROVED","submittedAt":"2026-08-06T09:00:00Z"}]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: snapshotJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewState(for: sampleReviewID)

    #expect(model.reviews.first?.approvedByMe == true)
}

@Test @MainActor func refreshReviewStatesSkipsTerminalPRs() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    var merged = sampleReview()
    merged.prState = .merged
    try await store.upsertItem(merged)
    let approvedJSON = """
    {"state":"OPEN","isDraft":false,"reviews":[{"author":{"login":"ordishs"},"state":"APPROVED"}]}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: approvedJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewStates()

    #expect(model.reviews.first?.approvedByMe == false)
    #expect(model.reviews.first?.prState == .merged)
}

@Test @MainActor func discoverSkipsUnscopedQueryAndWarns() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.isEmpty)
    #expect(!model.discoveryWarnings.isEmpty)
    #expect(model.discoveryWarnings.first?.contains("is:open") == true)
}

@Test @MainActor func discoverRunsUnscopedQueryWhenAllowed() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "is:open", allowUnscoped: true)]
    seed.myPRsEnabled = false
    seed.issuesEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.discoveryWarnings.isEmpty)
}

@Test @MainActor func createTaskAddsAPRlessTaskSelected() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/o/r",
        localClonePath: "/tmp/clone",
        defaultBase: "main"
    ))
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.createTask(repoKey: "github.com/o/r", branch: "feat/spike")

    #expect(model.reviews.count == 1)
    let t = try #require(model.reviews.first)
    #expect(t.prRef == nil)
    #expect(t.headBranch == "feat/spike")
    #expect(t.baseBranch == "main")
    #expect(t.category(myLogin: "anyone") == .task)
    #expect(model.selection == t.id)
}

@Test @MainActor func createTaskRejectsEmptyBranch() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/o/r",
        localClonePath: "/tmp/clone",
        defaultBase: "main"
    ))
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.createTask(repoKey: "github.com/o/r", branch: "   ")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

private let taskSearchHitJSON = """
[
  {
    "number": 5,
    "title": "feat/x",
    "url": "https://github.com/o/r/pull/5",
    "state": "open",
    "isDraft": false,
    "author": { "login": "me" },
    "repository": { "nameWithOwner": "o/r" }
  }
]
"""

private let taskFetchJSON = """
{
  "number": 5,
  "title": "feat/x",
  "url": "https://github.com/o/r/pull/5",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "me" },
  "headRefName": "feat/x",
  "baseRefName": "main",
  "closingIssuesReferences": []
}
"""

@Test @MainActor func discoveryGraduatesMatchingTaskInPlace() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "author:@me is:open")]
    seed.myPRsEnabled = false
    seed.issuesEnabled = false
    try await seedStore.updateSettings(seed)

    let store = try ReviewStore(fileURL: url)
    let task = WorkItem(
        title: "feat/x",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        headBranch: "feat/x",
        prRef: nil,
        prState: nil,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try await store.upsertItem(task)
    let taskID = task.id

    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "me\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: taskSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: taskFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    let g = try #require(model.reviews.first)
    #expect(g.id == taskID)
    #expect(g.prRef?.number == 5)
    #expect(g.origin == .both)
    #expect(g.headBranch == "feat/x")
}

@Test @MainActor func refreshPopulatesPRStatus() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let snapshotJSON = """
    {"data":{"r0":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":null,"mergeStateStatus":"BEHIND",
      "author":{"login":"icellan"},
      "commits":{"nodes":[{"commit":{"committedDate":"2026-08-06T11:00:00Z","statusCheckRollup":
        {"state":"FAILURE","contexts":{"totalCount":1,"nodes":[{"status":"COMPLETED","conclusion":"FAILURE"}]}}}}]},
      "reviews":{"nodes":[{"author":{"login":"ordishs"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-06T09:00:00Z"}]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: snapshotJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewState(for: sampleReviewID)

    #expect(model.prStatuses[sampleReviewID]?.ci == .failing)
    #expect(model.prStatuses[sampleReviewID]?.isBehind == true)
    // The author pushed at 11:00, after the 09:00 change request — the "Updated" chip data
    // has to reach the model, not just the client.
    #expect(model.prStatuses[sampleReviewID]?.authorUpdatedAt == ISO8601DateFormatter().date(from: "2026-08-06T11:00:00Z"))
}

@Test @MainActor func discoverSkipsCappedResultsAndWarns() async throws {
    let hundredHitsJSON: String = {
        let items = (0..<100).map { i in
            """
            {"number":\(i),"title":"t\(i)","url":"https://github.com/o/r/pull/\(i)","state":"open","isDraft":false,"author":{"login":"a"},"repository":{"nameWithOwner":"o/r"}}
            """
        }
        return "[" + items.joined(separator: ",") + "]"
    }()
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "author:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: hundredHitsJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.isEmpty)
    #expect(!model.discoveryWarnings.isEmpty)
    #expect(model.discoveryWarnings.first?.contains("100+") == true)
}

private func editableItem(worktreePath: String = "/tmp/wt", headBranch: String = "feat/x", baseBranch: String = "main") -> WorkItem {
    WorkItem(
        title: headBranch,
        repoKey: "github.com/o/r",
        baseBranch: baseBranch,
        headBranch: headBranch,
        worktreePath: worktreePath,
        prRef: nil,
        prState: nil,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test @MainActor func rebaseCleanClearsConflictState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(rebaseResult: .clean)
    await stub.set(currentBranchResult: "feat/x")
    await stub.set(aheadBehindDefaultResult: (0, 0))
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: stub,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.rebase(id: item.id)

    #expect(model.rebaseStates[item.id] == nil)
}

@Test @MainActor func rebaseConflictSetsConflictedStateAndAbortClears() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(rebaseResult: .conflicts(["a.swift"]))
    await stub.set(currentBranchResult: nil)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: stub,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.rebase(id: item.id)

    #expect(model.rebaseStates[item.id] == .conflicted(["a.swift"]))

    await model.abortRebase(id: item.id)

    #expect(model.rebaseStates[item.id] == nil)
}

@Test @MainActor func pushabilityReflectsAheadBehind() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(currentBranchResult: "feat/x")

    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: stub,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await stub.set(aheadBehindByUpstream: ["origin/feat/x": (ahead: 2, behind: 0)])
    await model.refreshPushability(for: item.id)
    #expect(model.pushability[item.id]?.canPush == true)
    #expect(model.pushability[item.id]?.needsForce == false)

    await stub.set(aheadBehindByUpstream: ["origin/feat/x": (ahead: 1, behind: 3)])
    await model.refreshPushability(for: item.id)
    #expect(model.pushability[item.id]?.canPush == true)
    #expect(model.pushability[item.id]?.needsForce == true)

    await stub.set(aheadBehindByUpstream: ["origin/feat/x": (ahead: 0, behind: 0)])
    await model.refreshPushability(for: item.id)
    #expect(model.pushability[item.id]?.canPush == false)
}

@Test @MainActor func ensureAgentSessionPopulatesPushabilityForEditableItem() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(currentBranchResult: "feat/x")
    await stub.set(aheadBehindByUpstream: ["origin/feat/x": (ahead: 1, behind: 0)])
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: stub,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureAgentSession(for: item)

    #expect(model.pushability[item.id]?.canPush == true)
    #expect(model.pushability[item.id]?.needsForce == false)
}

@Test @MainActor func pushabilityFallsBackForNeverPushedBranch() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(currentBranchResult: "feat/x")
    await stub.set(shouldThrowAheadBehind: ["origin/feat/x"])
    await stub.set(aheadBehindByUpstream: ["origin/main": (ahead: 1, behind: 0)])
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: stub,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.refreshPushability(for: item.id)

    #expect(model.pushability[item.id]?.canPush == true)
    #expect(model.pushability[item.id]?.needsForce == false)
}

@Test @MainActor func setTerminalAppearanceFlipsOnlyOnChange() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    #expect(model.terminalIsDark == true)
    await model.setTerminalAppearance(isDark: true)   // no-op
    #expect(model.terminalIsDark == true)
    await model.setTerminalAppearance(isDark: false)  // flips; no selection → no relaunch
    #expect(model.terminalIsDark == false)
}

private let issueViewJSON = """
{
  "number": 42,
  "title": "Login crash",
  "url": "https://github.com/bsv-blockchain/teranode/issues/42",
  "state": "OPEN",
  "author": { "login": "alice" }
}
"""
private let repoViewJSON = """
{ "isFork": false, "parent": null, "defaultBranchRef": { "name": "main" } }
"""

@Test @MainActor func addIssueFetchesStoresAndSelects() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    // fetchIssue → gh issue view, then gh repo view (fetchDefaultBase).
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: issueViewJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: repoViewJSON, standardError: ""),
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addIssue(urlString: "https://github.com/bsv-blockchain/teranode/issues/42")

    #expect(model.reviews.count == 1)
    let item = try #require(model.reviews.first)
    #expect(item.issueRef?.number == 42)
    #expect(item.prRef == nil)
    #expect(item.headBranch == "issue-42-login-crash")
    #expect(item.category(myLogin: nil) == .issue)
    #expect(model.selection == item.id)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func addIssueSetsErrorOnInvalidURL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addIssue(urlString: "https://github.com/o/r/pull/7")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

private let issueSearchHitJSON = """
[
  {
    "number": 42,
    "title": "Login crash",
    "url": "https://github.com/bsv-blockchain/teranode/issues/42",
    "state": "open",
    "author": { "login": "alice" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

@Test @MainActor func discoverNowCreatesDiscoveredIssue() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestsEnabled = false
    seed.myPRsEnabled = false
    seed.issuesEnabled = true
    seed.issueQueries = [DiscoveryQuery(text: "assignee:@me is:open")]
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: issueSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: issueViewJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: repoViewJSON, standardError: ""),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    let item = try #require(model.reviews.first)
    #expect(item.issueRef?.number == 42)
    #expect(item.prRef == nil)
    #expect(item.origin == .discovered)
    #expect(item.headBranch == "issue-42-login-crash")
    #expect(item.category(myLogin: "user") == .issue)
}

@Test @MainActor func setIssueStatusSetsAndClearsManualOverride() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let issue = WorkItem(
        title: "Login crash",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "issue-42-login-crash",
        issueRef: IssueRef(owner: "bsv-blockchain", repo: "teranode", number: 42,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/42")!, authorLogin: "alice"),
        prState: .open,
        origin: .discovered,
        addedAt: Date()
    )
    try await store.upsertItem(issue)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setIssueStatus(.onHold, for: issue.id)
    #expect(model.reviews.first(where: { $0.id == issue.id })?.manualIssueStatus == .onHold)

    // Persistence: a fresh store over the same file reflects the override.
    let reopened = try ReviewStore(fileURL: url)
    #expect(await reopened.item(id: issue.id)?.manualIssueStatus == .onHold)

    await model.setIssueStatus(nil, for: issue.id)
    #expect(model.reviews.first(where: { $0.id == issue.id })?.manualIssueStatus == nil)
}

@Test @MainActor func refreshPushabilityStoresAheadBehindCounts() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let ops = StubWorktreeOps()
    await ops.set(currentBranchResult: "fix/centrifuge")
    await ops.set(aheadBehindByUpstream: ["origin/fix/centrifuge": (ahead: 3, behind: 2)])
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: ops,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureAgentSession(for: review)   // sets worktreePath via the stub provider
    await model.refreshPushability(for: review.id)

    let p = model.pushability[review.id]
    #expect(p?.ahead == 3)
    #expect(p?.behind == 2)
    #expect(p?.canPush == true)
    #expect(p?.needsForce == true)
}

@Test @MainActor func refreshPushabilityFallsBackToBaseWithZeroBehind() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()   // headBranch "fix/centrifuge", baseBranch "main"
    try await store.upsertItem(review)
    let ops = StubWorktreeOps()
    await ops.set(currentBranchResult: "fix/centrifuge")
    await ops.set(shouldThrowAheadBehind: ["origin/fix/centrifuge"])   // upstream path unavailable
    await ops.set(aheadBehindByUpstream: ["origin/main": (ahead: 1, behind: 5)])
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: ops,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureAgentSession(for: review)
    await model.refreshPushability(for: review.id)

    let p = model.pushability[review.id]
    #expect(p?.ahead == 1)
    #expect(p?.behind == 0)        // base-fallback forces behind to 0
    #expect(p?.canPush == true)
    #expect(p?.needsForce == false)
}

@Test @MainActor func setLabelPersistsTrimmedValue() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setLabel("  Blocks the mainnet upgrade  ", for: sampleReviewID)

    #expect(model.reviews.first?.label == "Blocks the mainnet upgrade")
    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allItems().first?.label == "Blocks the mainnet upgrade")
}

@Test @MainActor func setLabelClearsOnNilOrBlank() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seeded = sampleReview()
    seeded.label = "old label"
    try await store.upsertItem(seeded)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setLabel("   ", for: sampleReviewID)
    #expect(model.reviews.first?.label == nil)

    await model.setLabel("again", for: sampleReviewID)
    #expect(model.reviews.first?.label == "again")

    await model.setLabel(nil, for: sampleReviewID)
    #expect(model.reviews.first?.label == nil)
}

@Test @MainActor func setPanePersistsSelectionPerItem() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let other = WorkItem(
        id: "other-item",
        title: "second",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try await store.upsertItem(other)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setPane(.claude, for: sampleReviewID)
    await model.setPane(.github, for: "other-item")

    #expect(model.reviews.first(where: { $0.id == sampleReviewID })?.lastPane == .claude)
    #expect(model.reviews.first(where: { $0.id == "other-item" })?.lastPane == .github)

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems()
    #expect(persisted.first(where: { $0.id == sampleReviewID })?.lastPane == .claude)
    #expect(persisted.first(where: { $0.id == "other-item" })?.lastPane == .github)
}

@Test @MainActor func setPaneIsNoOpForUnknownItem() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setPane(.claude, for: "does-not-exist")

    #expect(model.reviews.first?.lastPane == nil)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func pendingWorkflowKeepsStatusWorkingAndDoesNotStampReviewed() async throws {
    // /code-review hands the review to a background workflow and ends its turn in
    // seconds. That is not a finished review: the item must stay working, must not be
    // stamped reviewed, and must not fire the "review ready" notification.
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let poster = StubNotificationPoster()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: AgentStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureAgentSession(for: review)

    let launchedAt = Date().addingTimeInterval(-600)
    model.handleTranscriptEvent(
        reviewID: review.id,
        at: launchedAt,
        snippet: "Review workflow is running in the background",
        turnCompleted: false,
        workflowPending: true
    )
    model.recomputeStatus(for: review.id, now: Date())

    #expect(model.claudeStatuses[review.id] == .working)

    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeReviewedAt == nil)
    #expect(await poster.posted.isEmpty)
}

@Test @MainActor func completionAfterWorkflowSettlesStampsReviewedAndNotifies() async throws {
    // When the workflow reports back and Claude finishes the turn for real, the item is
    // reviewed and the notification carries the real verdict.
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let poster = StubNotificationPoster()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: AgentStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureAgentSession(for: review)

    model.handleTranscriptEvent(
        reviewID: review.id,
        at: Date().addingTimeInterval(-600),
        snippet: "Review workflow is running in the background",
        turnCompleted: false,
        workflowPending: true
    )
    model.handleTranscriptEvent(
        reviewID: review.id,
        at: Date(),
        snippet: "3 confirmed findings",
        turnCompleted: true,
        workflowPending: false
    )

    try await waitForItem(model, id: review.id) { $0.claudeReviewedAt != nil }
    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeReviewedAt != nil)
    let posted = await poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.body == "3 confirmed findings")
}

@Test @MainActor func discoverySurfacesSearchFailureAsWarning() async throws {
    // A failing `gh search prs` (rate limit, auth, network) used to be swallowed: no new
    // PRs appeared and nothing said why. It must surface as a discovery warning.
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    seed.issuesEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "HTTP 403: You have exceeded a secondary rate limit."
        ),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.isEmpty)
    #expect(model.discoveryWarnings.count == 1)
    #expect(model.discoveryWarnings.first?.contains("review-requested:@me is:open") == true)
    #expect(model.discoveryWarnings.first?.contains("secondary rate limit") == true)
}

private func authorUpdateSnapshotJSON(committedDate: String) -> String {
    """
    {"data":{"r0":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"CLEAN",
      "author":{"login":"icellan"},
      "commits":{"nodes":[{"commit":{"committedDate":"\(committedDate)","statusCheckRollup":null}}]},
      "reviews":{"nodes":[{"author":{"login":"ordishs"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-06T09:00:00Z"}]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
}

@Test @MainActor func clearingTheUpdatedBadgePersistsAWatermarkAndHidesTheChip() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: authorUpdateSnapshotJSON(committedDate: "2026-08-06T11:00:00Z"), standardError: ""),
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    await model.refreshReviewState(for: sampleReviewID)

    let before = try #require(model.reviews.first { $0.id == sampleReviewID })
    #expect(model.hasUnseenAuthorUpdate(before))

    await model.markAuthorUpdateSeen(id: sampleReviewID)

    let after = try #require(model.reviews.first { $0.id == sampleReviewID })
    #expect(model.hasUnseenAuthorUpdate(after) == false)
    // The watermark is the update's own timestamp, not "now".
    #expect(after.authorUpdateSeenAt == ISO8601DateFormatter().date(from: "2026-08-06T11:00:00Z"))

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems().first { $0.id == sampleReviewID }
    #expect(persisted?.authorUpdateSeenAt != nil)
}

@Test @MainActor func aNewerAuthorUpdateReBadgesAfterDismissal() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: authorUpdateSnapshotJSON(committedDate: "2026-08-06T11:00:00Z"), standardError: ""),
        // The first refresh of a repo also reads its merge rules, before the second refresh.
        CommandResult(exitCode: 0, standardOutput: twoApprovalsRuleJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: authorUpdateSnapshotJSON(committedDate: "2026-08-06T15:30:00Z"), standardError: ""),
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    await model.refreshReviewState(for: sampleReviewID)
    await model.markAuthorUpdateSeen(id: sampleReviewID)
    #expect(model.hasUnseenAuthorUpdate(try #require(model.reviews.first)) == false)

    // The author pushes again after the dismissal.
    await model.refreshReviewState(for: sampleReviewID)

    #expect(model.hasUnseenAuthorUpdate(try #require(model.reviews.first)))
}

@Test @MainActor func clearingTheUpdatedBadgeIsANoOpWithoutAnUpdate() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.markAuthorUpdateSeen(id: sampleReviewID)
    await model.markAuthorUpdateSeen(id: "does-not-exist")

    #expect(model.reviews.first?.authorUpdateSeenAt == nil)
    #expect(model.errorMessage == nil)
}

private func cappedReview(_ suffix: String, number: Int, openedMinutesAgo: Int) -> WorkItem {
    WorkItem(
        id: "item-\(suffix)",
        title: "item \(suffix)",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "branch-\(suffix)",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: number,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/\(number)")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(openedMinutesAgo) * 60)
    )
}

@MainActor
private func cappedModel(store: ReviewStore, worktreeOps: WorktreeManaging = StubWorktreeOps()) -> AppModel {
    AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: worktreeOps,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
}

/// `prewarmClaudeAndWait` skips any item whose registered clone is missing from disk, so a
/// prewarm test must register a repo that really exists.
private func registerExistingClone(in store: ReviewStore) async throws -> URL {
    let clone = FileManager.default.temporaryDirectory
        .appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: clone.path,
        defaultBase: "main"
    ))
    return clone
}

/// The distinction the Waiting chip depends on: the one-shot stamp must stay put while the
/// latest-completion stamp moves.
@Test @MainActor func queueIsEmptyWhenAutoLoadIsOff() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(cappedReview("q1", number: 1, openedMinutesAgo: 1))
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.queuedReviewIDs.isEmpty)
}

@Test @MainActor func queueHoldsNeverReviewedItemsMostRecentFirst() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...3 {
        try await store.upsertItem(cappedReview("q\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.queuedReviewIDs == ["item-q1", "item-q2", "item-q3"])
}

@Test @MainActor func queueExcludesReviewedDisabledAndCloneLessItems() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var reviewed = cappedReview("done", number: 1, openedMinutesAgo: 1)
    reviewed.claudeReviewedAt = Date(timeIntervalSince1970: 500)
    var disabled = cappedReview("off", number: 2, openedMinutesAgo: 2)
    disabled.disabled = true
    let plain = cappedReview("keep", number: 3, openedMinutesAgo: 3)
    var otherRepo = cappedReview("noclone", number: 4, openedMinutesAgo: 4)
    otherRepo.repoKey = "github.com/other/repo"
    for item in [reviewed, disabled, plain, otherRepo] { try await store.upsertItem(item) }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.queuedReviewIDs == ["item-keep"])
}

@Test @MainActor func drainStartsAQueuedSessionWhenASlotIsFree() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...3 {
        try await store.upsertItem(cappedReview("d\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveAgentSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.drainSessionQueue()

    #expect(model.claudeSessions.count == 1)
    #expect(model.claudeSessions["item-d1"] != nil)
}

/// One step per tick, so the backlog moves steadily rather than in a burst.
@Test @MainActor func drainStartsOneSessionPerCall() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...3 {
        try await store.upsertItem(cappedReview("d\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveAgentSessions = 3
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.drainSessionQueue()
    await model.drainSessionQueue()

    #expect(model.claudeSessions.count == 2)
}

@Test @MainActor func drainReleasesAnIdleSessionAtTheCapAndStartsTheNext() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...2 {
        try await store.upsertItem(cappedReview("r\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveAgentSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    // load() selects the most recently opened item, and the selected session is never
    // released. Clear it so this test exercises the release path rather than the
    // selection exemption, which SessionQueueTests already covers.
    model.selection = nil
    await model.drainSessionQueue()
    let firstStarted = model.claudeSessions["item-r1"] != nil

    // AgentSession.start runs `cd <cwd> && exec <claude>`, and StubWorktreeProvider's
    // /tmp/wt does not exist, so the shell exits and the status settles to .ready —
    // releasable. The wait covers `zsh -l` sourcing a slow profile before it can fail.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    model.recomputeStatus(for: "item-r1", now: Date())
    #expect(model.claudeStatuses["item-r1"] != .working)

    await model.drainSessionQueue()

    #expect(firstStarted == true)
    #expect(model.claudeSessions["item-r1"] == nil)
    #expect(model.claudeSessions["item-r2"] != nil)
    #expect(model.claudeSessions.count == 1)
}

/// The drain gives each item one turn. An item that lost its session before earning the
/// reviewed stamp used to fall straight back into the queue, so the drain restarted it on the
/// next tick and cycled the backlog for as long as the app ran.
@Test @MainActor func drainDoesNotRestartAnItemItAlreadyStarted() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...2 {
        try await store.upsertItem(cappedReview("q\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveAgentSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = nil

    await model.drainSessionQueue()
    try await Task.sleep(nanoseconds: 1_500_000_000)
    model.recomputeStatus(for: "item-q1", now: Date())
    #expect(model.claudeSessions["item-q1"] != nil)

    // q1's process has exited, so the drain reaps that slot and fills it with q2.
    await model.drainSessionQueue()
    #expect(model.claudeSessions["item-q1"] == nil, "the dead session is reaped, not killed")
    #expect(model.claudeSessions["item-q2"] != nil)
    try await Task.sleep(nanoseconds: 1_500_000_000)
    model.recomputeStatus(for: "item-q2", now: Date())

    await model.drainSessionQueue()

    #expect(model.queuedReviewIDs.isEmpty, "both items have spent their turn")
    #expect(model.claudeSessions["item-q1"] == nil, "and neither is started a second time")
}

@Test @MainActor func aSecondCompletedTurnMovesOnlyTheLatestStamp() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = cappedReview("turns", number: 1, openedMinutesAgo: 1)
    try await store.upsertItem(item)

    let model = cappedModel(store: store)
    await model.load()
    await model.ensureAgentSession(for: item)

    // Each stamp is written by a detached task, so the test waits for the write rather than
    // guessing how long it takes. A fixed sleep passed on an idle machine and failed under a
    // loaded one, which said nothing about the behaviour under test.
    let first = Date(timeIntervalSince1970: 1_000)
    model.handleTranscriptEvent(reviewID: item.id, at: first, snippet: "done", turnCompleted: true)
    try await waitForItem(model, id: item.id) { $0.claudeLastCompletedAt != nil }
    let afterFirst = model.reviews.first { $0.id == item.id }

    let second = Date(timeIntervalSince1970: 2_000)
    model.handleTranscriptEvent(reviewID: item.id, at: second, snippet: "done again", turnCompleted: true)
    try await waitForItem(model, id: item.id) { $0.claudeLastCompletedAt != afterFirst?.claudeLastCompletedAt }
    let afterSecond = model.reviews.first { $0.id == item.id }

    #expect(afterFirst?.claudeReviewedAt != nil)
    #expect(afterFirst?.claudeLastCompletedAt != nil)
    #expect(afterSecond?.claudeReviewedAt == afterFirst?.claudeReviewedAt, "the one-shot stamp stays put")
    #expect(afterSecond?.claudeLastCompletedAt != afterFirst?.claudeLastCompletedAt, "the latest stamp moves")
}

/// Polls until a persisted change lands, or fails the test. Two seconds is far longer than the
/// write needs and short enough to keep a real breakage obvious.
///
/// Every stamp the model writes goes through a detached task, so a test that sleeps a fixed
/// 300ms is really asserting how busy the machine is. Use this wherever a test waits for a
/// change to appear; a fixed sleep is only right when the test asserts nothing changed.
@MainActor
private func waitForItem(
    _ model: AppModel,
    id: String,
    timeout: TimeInterval = 2,
    until condition: (WorkItem) -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let item = model.reviews.first(where: { $0.id == id }), condition(item) { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("timed out after \(timeout)s waiting for the persisted stamp to change")
}

@Test @MainActor func clearingASessionClearsBothClaudeStamps() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("clear", number: 1, openedMinutesAgo: 1)
    item.claudeReviewedAt = Date(timeIntervalSince1970: 1_000)
    item.claudeLastCompletedAt = Date(timeIntervalSince1970: 2_000)
    item.waitingSeenAt = Date(timeIntervalSince1970: 2_000)
    try await store.upsertItem(item)

    let model = cappedModel(store: store)
    await model.load()

    await model.clearAgentSession(for: item.id)

    let stored = await store.item(id: item.id)

    #expect(stored?.claudeReviewedAt == nil)
    #expect(stored?.claudeLastCompletedAt == nil)
    #expect(stored?.waitingSeenAt == nil)
}

@Test @MainActor func clearWaitingStampsTheCurrentClaudeCompletion() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("waiting", number: 1, openedMinutesAgo: 1)
    item.claudeLastCompletedAt = Date(timeIntervalSince1970: 2_000)
    try await store.upsertItem(item)

    let model = cappedModel(store: store)
    await model.load()

    await model.clearWaiting(id: item.id)

    let stored = await store.item(id: item.id)

    #expect(stored?.waitingSeenAt == Date(timeIntervalSince1970: 2_000))
    #expect(stored?.claudeLastCompletedAt == Date(timeIntervalSince1970: 2_000))
}

@Test @MainActor func clearWaitingDoesNothingWithoutACompletedTurn() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = cappedReview("waiting-none", number: 2, openedMinutesAgo: 1)
    try await store.upsertItem(item)

    let model = cappedModel(store: store)
    await model.load()

    await model.clearWaiting(id: item.id)

    let stored = await store.item(id: item.id)

    #expect(stored?.waitingSeenAt == nil)
}

@Test @MainActor func refreshPersistsMyReviewStateAndDate() async throws {
    let snapshotJSON = """
    {"data":{"r0":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":null,"mergeStateStatus":"CLEAN",
      "author":{"login":"icellan"},
      "commits":{"nodes":[]},
      "reviews":{"nodes":[
        {"author":{"login":"ordishs"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-04T10:00:00Z"}
      ]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = cappedReview("rev", number: 1, openedMinutesAgo: 1)
    try await store.upsertItem(item)

    let client = GitHubClient(
        runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: snapshotJSON, standardError: "")),
        ghPath: "gh"
    )
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    model.setCurrentLoginForTesting("ordishs")

    await model.refreshReviewState(for: item.id)

    let stored = await store.item(id: item.id)

    #expect(model.reviews.first { $0.id == item.id }?.myReviewState == .changesRequested)
    #expect(stored?.myReviewState == .changesRequested)
    #expect(stored?.myLastReviewAt == ISO8601DateFormatter().date(from: "2026-08-04T10:00:00Z"))
}

@Test @MainActor func pruneRemovesOnlyTheOrphanedWorktrees() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtprune-\(UUID().uuidString)", isDirectory: true)
    let root = managedRoot.appendingPathComponent("worktrees.noindex")
    for name in ["live", "orphan-a", "orphan-b"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name),
            withIntermediateDirectories: true
        )
    }
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("live", number: 1, openedMinutesAgo: 1)
    item.worktreePath = root.appendingPathComponent("live").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    // A real manager, so the assertions below measure the filesystem and not a stub.
    let model = cappedModel(store: store, worktreeOps: WorktreeManager(
        runner: ProcessCommandRunner(), gitPath: "git", managedRoot: managedRoot.path
    ))
    await model.load()

    #expect(model.orphanedWorktreePaths().count == 2)

    let removed = await model.pruneOrphanedWorktrees()

    #expect(removed == 2)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("live").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan-a").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan-b").path))
}

@Test @MainActor func migrationMovesTheWorktreeRootAndRewritesPaths() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmigrate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("mig", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.migrateWorktreeRoot()

    let expected = managedRoot.appendingPathComponent("worktrees.noindex/owner-repo-pr1").path
    let stored = await store.item(id: item.id)?.worktreePath

    #expect(FileManager.default.fileExists(atPath: expected))
    #expect(!FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("worktrees").path))
    #expect(model.reviews.first { $0.id == item.id }?.worktreePath == expected)
    #expect(stored == expected)
}

@Test @MainActor func migrationRepairsEachMovedWorktree() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmigrate3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("mig", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let ops = StubWorktreeOps()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: ops,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.migrateWorktreeRoot()

    let expected = managedRoot.appendingPathComponent("worktrees.noindex/owner-repo-pr1").path
    let repaired = await ops.repairedWorktreePaths

    #expect(repaired == [expected])
}

/// A half-finished migration must be recoverable. If the directory move landed but the
/// path rewrite did not, the next run has no legacy directory to key off, so a guard on
/// that alone would strand every stale path forever.
@Test @MainActor func migrationRewritesStalePathsAfterTheDirectoryAlreadyMoved() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtresume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees.noindex/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("stale", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.migrateWorktreeRoot()

    let expected = managedRoot.appendingPathComponent("worktrees.noindex/owner-repo-pr1").path
    let stored = await store.item(id: item.id)?.worktreePath

    #expect(stored == expected)
    #expect(model.reviews.first { $0.id == item.id }?.worktreePath == expected)
}

/// `load()` must never touch the filesystem outside the store. A test that does not
/// override `managedRoot` inherits `Settings.default`, which points at the user's real
/// Application Support directory — running the suite once moved 11 GB of live checkouts.
@Test @MainActor func loadDoesNotMigrateTheWorktreeRoot() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtnoload-\(UUID().uuidString)", isDirectory: true)
    let legacy = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("noload", number: 1, openedMinutesAgo: 1)
    item.worktreePath = legacy.path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(FileManager.default.fileExists(atPath: legacy.path))
    #expect(!FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("worktrees.noindex").path))
}

@Test @MainActor func migrationIsANoOpOnASecondRun() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmigrate2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("mig", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.migrateWorktreeRoot()
    let afterFirst = model.reviews.first { $0.id == item.id }?.worktreePath
    await model.migrateWorktreeRoot()

    #expect(model.reviews.first { $0.id == item.id }?.worktreePath == afterFirst)
}

@Test @MainActor func refreshReviewStatesRefreshesEveryOpenItemInOneCycle() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...10 {
        try await store.upsertItem(cappedReview("rf\(index)", number: index, openedMinutesAgo: index))
    }

    let model = cappedModel(store: store)
    await model.load()
    model.selection = "item-rf1"

    await model.refreshReviewStates()

    #expect(model.refreshedIDsForTesting().count == 10)
    #expect(model.refreshedIDsForTesting().contains("item-rf1"))
}

@Test @MainActor func refreshAllNowRefreshesEveryOpenItem() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...10 {
        try await store.upsertItem(cappedReview("ra\(index)", number: index, openedMinutesAgo: index))
    }

    let model = cappedModel(store: store)
    await model.load()

    await model.refreshAllNow()

    #expect(model.refreshedIDsForTesting().count == 10)
}

@Test @MainActor func prewarmStopsAtTheSessionCap() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...5 {
        try await store.upsertItem(cappedReview("pw\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveAgentSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.prewarmClaudeAndWait()

    #expect(model.claudeSessions.count == 2)
}

@Test @MainActor func prewarmStartsTheMostRecentlyOpenedItemsFirst() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...4 {
        try await store.upsertItem(cappedReview("pw\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveAgentSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.prewarmClaudeAndWait()

    #expect(model.claudeSessions["item-pw1"] != nil)
    #expect(model.claudeSessions["item-pw2"] != nil)
    #expect(model.claudeSessions["item-pw3"] == nil)
    #expect(model.claudeSessions["item-pw4"] == nil)
}

@Test @MainActor func sessionBudgetEvictsTheOldestSessionBeyondTheCap() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let middle = cappedReview("middle", number: 2, openedMinutesAgo: 2)
    let oldest = cappedReview("oldest", number: 3, openedMinutesAgo: 3)
    for item in [newest, middle, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveAgentSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, middle, newest] {
        await model.ensureAgentSession(for: item)
    }

    model.enforceSessionBudget(now: Date().addingTimeInterval(120))

    #expect(model.claudeSessions.count == 2)
    #expect(model.claudeSessions[oldest.id] == nil)
    #expect(model.claudeSessions[middle.id] != nil)
    #expect(model.claudeSessions[newest.id] != nil)
}

@Test @MainActor func sessionEvictionKeepsThePersistedSessionIDForResume() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let oldest = cappedReview("oldest", number: 2, openedMinutesAgo: 2)
    for item in [newest, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveAgentSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, newest] {
        await model.ensureAgentSession(for: item)
    }
    let persistedBefore = model.reviews.first { $0.id == oldest.id }?.claudeSessionID

    model.enforceSessionBudget(now: Date().addingTimeInterval(120))

    let stored = await store.item(id: oldest.id)?.claudeSessionID

    #expect(persistedBefore != nil)
    #expect(model.claudeSessions[oldest.id] == nil)
    #expect(model.reviews.first { $0.id == oldest.id }?.claudeSessionID == persistedBefore)
    #expect(stored == persistedBefore)
}

@Test @MainActor func sessionEvictionKeepsTheGitHubStatusChips() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let oldest = cappedReview("oldest", number: 2, openedMinutesAgo: 2)
    for item in [newest, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveAgentSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, newest] {
        await model.ensureAgentSession(for: item)
    }
    model.setPRStatusForTesting(
        PRStatus(ci: .passing, mergeState: .clean, readiness: .reviewRequired),
        for: oldest.id
    )

    model.enforceSessionBudget(now: Date().addingTimeInterval(120))

    #expect(model.claudeSessions[oldest.id] == nil)
    #expect(model.prStatuses[oldest.id] != nil)
}

/// The session must genuinely still be running for its status to read `.working`.
/// `AgentSession.start()` runs `cd <cwd> && exec <claude> …`, so the default stub's
/// non-existent `/tmp/wt` makes the shell exit at once and the status decays to `.ready`.
/// `yes` ignores its arguments and never exits, which pins the status deterministically.
@Test @MainActor func sessionBudgetProtectsAWorkingSession() async throws {
    let cwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("livewt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let oldest = cappedReview("oldest", number: 2, openedMinutesAgo: 2)
    for item in [newest, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveAgentSessions = 1
    try await store.updateSettings(settings)

    var provider = StubWorktreeProvider()
    provider.result = WorktreeReady(clonePath: cwd.path, worktreePath: cwd.path, remoteName: "origin")
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: provider,
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/yes",
        notificationPoster: StubNotificationPoster()
    )
    defer { model.terminateAllAgentSessions() }
    await model.load()
    model.selection = newest.id
    for item in [oldest, newest] {
        await model.ensureAgentSession(for: item)
    }
    let now = Date()
    model.handleTranscriptEvent(reviewID: oldest.id, at: now, snippet: "working", turnCompleted: false)
    model.recomputeStatus(for: oldest.id, now: now)

    #expect(model.claudeStatuses[oldest.id] == .working)

    model.enforceSessionBudget(now: now.addingTimeInterval(120))

    #expect(model.claudeSessions[oldest.id] != nil)
}

// MARK: - Switching an item's agent

@MainActor
private func agentSwitchModel(store: ReviewStore) -> AppModel {
    AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
}

/// The point of a session ID per agent: flipping an item to pi and back must leave the Claude
/// Code conversation resumable rather than destroying it.
///
/// Real transcripts are written for both agents, because the stored session ID is deliberately
/// replaced when its transcript has gone — resuming a pruned session would fail. So the promise
/// only holds while both transcripts exist, and that is what this asserts.
@Test @MainActor func switchingAgentKeepsBothSessionIDsWhileBothTranscriptsExist() async throws {
    let worktree = "/tmp/agent-switch-\(UUID().uuidString)"
    let claudeSessionID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    let piSessionID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    let fm = FileManager.default
    let claudeDir = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: worktree)
    let piDir = AgentTranscriptPath.directoryURL(for: .pi, worktreePath: worktree)
    try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: piDir, withIntermediateDirectories: true)
    defer {
        try? fm.removeItem(at: claudeDir)
        try? fm.removeItem(at: piDir)
    }
    try "{}".write(to: claudeDir.appendingPathComponent("\(claudeSessionID).jsonl"), atomically: true, encoding: .utf8)
    try "{}".write(
        to: piDir.appendingPathComponent("2026-08-13T11-54-02-626Z_\(piSessionID).jsonl"),
        atomically: true,
        encoding: .utf8
    )

    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.worktreePath = worktree
    review.claudeSessionID = claudeSessionID
    review.piSessionID = piSessionID
    try await store.upsertItem(review)
    var settings = await store.settings()
    settings.piPath = "/usr/bin/true"
    try await store.updateSettings(settings)

    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(
            result: WorktreeReady(clonePath: "/tmp/clone", worktreePath: worktree, remoteName: "origin")
        ),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.setAgent(.pi, for: review.id)
    var current = model.reviews.first(where: { $0.id == review.id })
    #expect(current?.agent == .pi)
    #expect(current?.claudeSessionID == claudeSessionID, "switching to pi must not disturb Claude Code")
    #expect(current?.piSessionID == piSessionID, "pi resumes its own existing transcript")

    await model.setAgent(.claudeCode, for: review.id)
    current = model.reviews.first(where: { $0.id == review.id })
    #expect(current?.agent == .claudeCode)
    #expect(current?.claudeSessionID == claudeSessionID, "Claude Code resumes where it stopped")
    #expect(current?.piSessionID == piSessionID, "switching back must not disturb pi")
}

/// The other half of the contract: a stored session whose transcript has gone is replaced
/// rather than resumed, because resuming it would fail.
@Test @MainActor func aSessionWithNoTranscriptIsReplacedNotResumed() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    review.piSessionID = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    try await store.upsertItem(review)
    let model = agentSwitchModel(store: store)
    await model.load()

    await model.setAgent(.pi, for: review.id)

    let current = model.reviews.first(where: { $0.id == review.id })
    #expect(current?.piSessionID != "dddddddd-dddd-dddd-dddd-dddddddddddd", "no transcript, so a fresh id")
    #expect(current?.piSessionID != nil)
    // The inactive agent is untouched either way.
    #expect(current?.claudeSessionID == "cccccccc-cccc-cccc-cccc-cccccccccccc")
}

@Test @MainActor func settingAgentToNilRestoresTheGlobalDefault() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.agent = .pi
    try await store.upsertItem(review)
    let model = agentSwitchModel(store: store)
    await model.load()

    await model.setAgent(nil, for: review.id)

    let current = model.reviews.first(where: { $0.id == review.id })
    #expect(current?.agent == nil)
    #expect(current?.effectiveAgent(default: .claudeCode) == .claudeCode)
}

/// Clearing a session must only archive and forget the agent that is actually running, or the
/// other agent's conversation would be collateral damage.
@Test @MainActor func clearingASessionLeavesTheOtherAgentsSessionIDIntact() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = "claude-session"
    review.piSessionID = "pi-session"
    try await store.upsertItem(review)
    let model = agentSwitchModel(store: store)
    await model.load()

    // The item follows the default, which is Claude Code.
    await model.clearAgentSession(for: review.id)

    let cleared = model.reviews.first(where: { $0.id == review.id })
    #expect(cleared?.claudeSessionID != "claude-session")
    #expect(cleared?.piSessionID == "pi-session")
}

/// Quitting must not leave agent processes behind, and the window that reports the wait needs
/// something to report. `/usr/bin/yes` never exits on its own, so the only thing that can stop
/// these agents is the shutdown itself.
@Test @MainActor func shutdownStopsEveryAgentProcessBeforeItReturns() async throws {
    let cwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("shutdownwt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    let first = cappedReview("first", number: 1, openedMinutesAgo: 1)
    let second = cappedReview("second", number: 2, openedMinutesAgo: 2)
    for item in [first, second] { try await store.upsertItem(item) }

    var provider = StubWorktreeProvider()
    provider.result = WorktreeReady(clonePath: cwd.path, worktreePath: cwd.path, remoteName: "origin")
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: provider,
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/yes",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    for item in [first, second] { await model.ensureAgentSession(for: item) }

    let pids = model.claudeSessions.values.map(\.terminalView.process.shellPid)
    #expect(pids.count == 2)
    #expect(pids.allSatisfy { $0 > 0 })
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(pids.allSatisfy { kill($0, 0) == 0 })

    await model.shutdownAgentSessions()

    #expect(pids.allSatisfy { kill($0, 0) != 0 })
    #expect(model.claudeSessions.isEmpty)
}

/// The quit window reads this state. It has to exist before the first suspension point, or the
/// window opens on an empty model and shows nothing while the agents are still dying.
@Test @MainActor func shutdownPublishesProgressBeforeItAwaitsAnything() async throws {
    let cwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("shutdownwt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    let first = cappedReview("first", number: 1, openedMinutesAgo: 1)
    let second = cappedReview("second", number: 2, openedMinutesAgo: 2)
    for item in [first, second] { try await store.upsertItem(item) }

    var provider = StubWorktreeProvider()
    provider.result = WorktreeReady(clonePath: cwd.path, worktreePath: cwd.path, remoteName: "origin")
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: provider,
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/yes",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    for item in [first, second] { await model.ensureAgentSession(for: item) }
    #expect(model.shutdown == nil)

    let progress = model.beginShutdown()

    #expect(progress.total == 2)
    #expect(progress.remaining == 2)
    #expect(progress.isFinished == false)
    #expect(model.shutdown === progress)
    #expect(progress.stopping.sorted() == ["item first", "item second"])

    await model.shutdownAgentSessions()

    #expect(progress.remaining == 0)
    #expect(progress.isFinished)
    #expect(progress.fraction == 1)
}

/// `beginShutdown` names the agents so the window can list what it is waiting for, and the wait
/// must clear every one of them even when the quit is driven straight from the async call.
@Test @MainActor func shutdownWithoutABeginStillPublishesProgress() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = cappedModel(store: store)
    await model.load()

    await model.shutdownAgentSessions()

    #expect(model.shutdown?.total == 0)
    #expect(model.shutdown?.isFinished == true)
}

/// Quitting with nothing running must not put a window on screen at all.
@Test @MainActor func shutdownReportsNothingToWaitForWhenNoAgentRuns() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = cappedModel(store: store)
    await model.load()

    #expect(model.hasLiveAgentSessions == false)

    await model.shutdownAgentSessions()

    #expect(model.claudeSessions.isEmpty)
}

/// A live agent that is mid-turn writes nothing to its transcript during a long tool call, so
/// its status decays to `.idle` after 30 seconds. Clicking another item at the cap used to
/// SIGTERM that agent — and since the kill takes the whole process tree, it threw away a build
/// or a push in flight.
@Test @MainActor func clickingAnotherItemAtTheCapKeepsAQuietRunningAgentAlive() async throws {
    let cwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("quietwt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    let running = cappedReview("running", number: 1, openedMinutesAgo: 2)
    let clicked = cappedReview("clicked", number: 2, openedMinutesAgo: 1)
    for item in [running, clicked] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveAgentSessions = 1
    try await store.updateSettings(settings)

    var provider = StubWorktreeProvider()
    provider.result = WorktreeReady(clonePath: cwd.path, worktreePath: cwd.path, remoteName: "origin")
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: provider,
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/yes",
        notificationPoster: StubNotificationPoster()
    )
    defer { model.terminateAllAgentSessions() }
    await model.load()
    model.selection = running.id
    await model.ensureAgentSession(for: running)

    // Ten minutes into the session, 45 seconds into a long tool call: the process runs, the
    // transcript stays quiet, and the last line did not end the turn.
    model.setSessionStartedAtForTesting(Date().addingTimeInterval(-600), for: running.id)
    let quiet = Date().addingTimeInterval(-45)
    model.handleTranscriptEvent(reviewID: running.id, at: quiet, snippet: "reading files", turnCompleted: false)
    model.recomputeStatus(for: running.id, now: Date())
    #expect(model.claudeStatuses[running.id] == .idle(since: quiet, lastVerdictSnippet: "reading files"))

    // The user clicks the other item.
    model.selection = clicked.id
    await model.markReviewOpened(clicked.id)
    await model.ensureAgentSession(for: clicked)

    #expect(model.claudeSessions[running.id] != nil)
    #expect(model.claudeSessions[clicked.id] != nil)
}

/// The drain already refuses to restart an item it released. The budget shared none of that
/// bookkeeping, so an item the user opened by hand fell back into the queue after eviction, and
/// the next drain tick released a second live session to start it again.
@Test @MainActor func anItemTheBudgetEvictsDoesNotFallBackIntoTheQueue() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let first = cappedReview("first", number: 1, openedMinutesAgo: 2)
    let second = cappedReview("second", number: 2, openedMinutesAgo: 1)
    for item in [first, second] { try await store.upsertItem(item) }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveAgentSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = first.id
    await model.ensureAgentSession(for: first)
    model.selection = second.id
    await model.markReviewOpened(second.id)
    await model.ensureAgentSession(for: second)

    model.enforceSessionBudget(now: Date().addingTimeInterval(120))
    model.recomputeReviewQueue()

    #expect(model.claudeSessions[first.id] == nil)
    #expect(model.queuedReviewIDs.contains(first.id) == false)
}

// MARK: - Agent run start

/// A model whose worktree is unique to one test, so a transcript another test left behind
/// cannot turn a fresh launch into a resume.
@MainActor
private func agentRunModel(store: ReviewStore, worktree: String) -> AppModel {
    AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(
            result: WorktreeReady(clonePath: "/tmp/clone", worktreePath: worktree, remoteName: "origin")
        ),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
}

@Test @MainActor func aFreshAgentLaunchStampsTheRunStart() async throws {
    let worktree = "/tmp/agent-run-\(UUID().uuidString)"
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = agentRunModel(store: store, worktree: worktree)
    await model.load()

    let before = Date()
    await model.ensureAgentSession(for: review)

    let current = model.reviews.first(where: { $0.id == review.id })
    let started = try #require(current?.agentRunStartedAt)
    #expect(started >= before)
    #expect(started <= Date())
}

/// Resuming continues work that already started, so the original moment must survive. A
/// resume that re-stamped would report the app's last relaunch as the start of the review.
@Test @MainActor func resumingAnAgentKeepsTheOriginalRunStart() async throws {
    let worktree = "/tmp/agent-run-\(UUID().uuidString)"
    let sessionID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    let fm = FileManager.default
    let dir = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: worktree)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    try "{}".write(to: dir.appendingPathComponent("\(sessionID).jsonl"), atomically: true, encoding: .utf8)

    let originalStart = Date(timeIntervalSince1970: 1_755_000_000)
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = sessionID
    review.agentRunStartedAt = originalStart
    try await store.upsertItem(review)
    let model = agentRunModel(store: store, worktree: worktree)
    await model.load()

    await model.ensureAgentSession(for: review)

    let current = model.reviews.first(where: { $0.id == review.id })
    #expect(current?.claudeSessionID == sessionID, "the session must actually have resumed")
    #expect(current?.agentRunStartedAt == originalStart)
}

/// Clearing a session throws the conversation away and relaunches, so the old start time is
/// no longer true. The new run gets its own.
@Test @MainActor func clearingTheSessionRestampsTheRunStart() async throws {
    let worktree = "/tmp/agent-run-\(UUID().uuidString)"
    let originalStart = Date(timeIntervalSince1970: 1_755_000_000)
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
    review.agentRunStartedAt = originalStart
    try await store.upsertItem(review)
    let model = agentRunModel(store: store, worktree: worktree)
    await model.load()

    let before = Date()
    await model.clearAgentSession(for: review.id)

    let current = model.reviews.first(where: { $0.id == review.id })
    let started = try #require(current?.agentRunStartedAt)
    #expect(started != originalStart)
    #expect(started >= before)
}

// MARK: - The backlog never costs a live agent its process

/// The reported bug. A session that has just answered and is waiting on the user reads
/// `.awaitingInput`, which made it the drain's first choice of victim: within one 5 second
/// tick the agent was SIGTERMed to start a queued review. The user came back to a session
/// they had left running and found it gone.
@Test @MainActor func drainNeverTakesTheSlotOfASessionWaitingOnTheUser() async throws {
    let cwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("waitwt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    let waiting = cappedReview("waiting", number: 1, openedMinutesAgo: 5)
    let queued = cappedReview("queued", number: 2, openedMinutesAgo: 1)
    for item in [waiting, queued] { try await store.upsertItem(item) }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveAgentSessions = 1
    try await store.updateSettings(settings)

    var provider = StubWorktreeProvider()
    provider.result = WorktreeReady(clonePath: cwd.path, worktreePath: cwd.path, remoteName: "origin")
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: provider,
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/yes",
        notificationPoster: StubNotificationPoster()
    )
    defer { model.terminateAllAgentSessions() }
    await model.load()
    await model.ensureAgentSession(for: waiting)
    // Not the selected item, so the selection exemption cannot be what saves it.
    model.selection = nil

    // The agent finished a turn a minute ago and is waiting on the user.
    let answered = Date().addingTimeInterval(-60)
    model.handleTranscriptEvent(reviewID: waiting.id, at: answered, snippet: "shall I continue?", turnCompleted: true)
    model.recomputeStatus(for: waiting.id, now: Date())
    #expect(model.claudeStatuses[waiting.id] == .awaitingInput(since: answered, lastVerdictSnippet: "shall I continue?"))

    await model.drainSessionQueue()

    #expect(model.claudeSessions[waiting.id] != nil, "the waiting agent keeps its process")
    #expect(model.claudeSessions[queued.id] == nil, "and the queued review waits for real headroom")
}

/// A mid-turn agent that has gone quiet for hours is not mid-turn any more. Protecting it
/// forever is what let the session count reach 11 against a cap of 3, and left the drain with
/// nothing to take but the session that had just answered.
@Test @MainActor func theBudgetReclaimsASessionQuietPastTheProtectionWindow() async throws {
    let cwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("stalewt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    let stale = cappedReview("stale", number: 1, openedMinutesAgo: 5)
    let fresh = cappedReview("fresh", number: 2, openedMinutesAgo: 1)
    for item in [stale, fresh] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveAgentSessions = 1
    settings.idleSessionProtectionMinutes = 20
    try await store.updateSettings(settings)

    var provider = StubWorktreeProvider()
    provider.result = WorktreeReady(clonePath: cwd.path, worktreePath: cwd.path, remoteName: "origin")
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: provider,
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/yes",
        notificationPoster: StubNotificationPoster()
    )
    defer { model.terminateAllAgentSessions() }
    await model.load()
    await model.ensureAgentSession(for: stale)
    await model.ensureAgentSession(for: fresh)
    model.selection = fresh.id

    // Three hours quiet, on a session that started four hours ago: its last line is its own,
    // so the old rule protected it, but nothing has happened since.
    model.setSessionStartedAtForTesting(Date().addingTimeInterval(-4 * 3600), for: stale.id)
    let longQuiet = Date().addingTimeInterval(-3 * 3600)
    model.handleTranscriptEvent(reviewID: stale.id, at: longQuiet, snippet: "reading files", turnCompleted: false)
    model.recomputeStatus(for: stale.id, now: Date())
    #expect(model.claudeStatuses[stale.id] == .idle(since: longQuiet, lastVerdictSnippet: "reading files"))

    model.enforceSessionBudget()

    #expect(model.claudeSessions[stale.id] == nil, "a session parked for three hours gives up its slot")
    #expect(model.claudeSessions[fresh.id] != nil)
}

/// A session whose process has already exited holds a slot for nothing. Reaping it is not a
/// kill, so it is not bound by the cap comparison — otherwise a dead session at exactly the
/// cap would block the backlog for as long as the app runs.
@Test @MainActor func drainReapsAnExitedSessionAndStartsTheNext() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...2 {
        try await store.upsertItem(cappedReview("r\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveAgentSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = nil
    await model.drainSessionQueue()
    let firstStarted = model.claudeSessions["item-r1"] != nil

    // AgentSession.start runs `cd <cwd> && exec <claude>`, and StubWorktreeProvider's /tmp/wt
    // does not exist, so the shell exits and the status settles to .ready. The wait covers
    // `zsh -l` sourcing a slow profile before it can fail.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    model.recomputeStatus(for: "item-r1", now: Date())
    #expect(model.claudeStatuses["item-r1"] == .ready(exitCode: 1) || model.claudeStatuses["item-r1"] != .working)

    await model.drainSessionQueue()

    #expect(firstStarted == true)
    #expect(model.claudeSessions["item-r1"] == nil, "the dead session is reaped")
    #expect(model.claudeSessions["item-r2"] != nil, "and the backlog moves")
    #expect(model.claudeSessions.count == 1)
}

// MARK: - Adopting the session the agent actually writes

@MainActor
private func adoptionModel(store: ReviewStore, worktree: String) -> AppModel {
    AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(
            result: WorktreeReady(clonePath: worktree, worktreePath: worktree, remoteName: "origin")
        ),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/yes",
        notificationPoster: StubNotificationPoster()
    )
}

/// Running `/clear` in the terminal starts a new conversation under a new session id. The item
/// kept resuming the id it launched with, so the next open reopened the conversation the user
/// had just thrown away — and once that transcript was pruned, started the review from scratch.
@Test @MainActor func theItemAdoptsTheSessionIdTheAgentMovesTo() async throws {
    let worktree = "/tmp/adopt-\(UUID().uuidString)"
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = "launched-id"
    try await store.upsertItem(review)
    let model = adoptionModel(store: store, worktree: worktree)
    await model.load()
    await model.ensureAgentSession(for: review)
    defer { model.terminateAllAgentSessions() }

    model.setSessionStartedAtForTesting(Date().addingTimeInterval(-60), for: review.id)
    model.setWatchedSessionIDForTesting("cleared-id", for: review.id)
    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: "starting over", turnCompleted: false)
    try await waitForItem(model, id: review.id) { $0.claudeSessionID == "cleared-id" }

    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeSessionID == "cleared-id")
}

/// The watcher replays a transcript from the start every time it attaches. Those events are
/// older than the process, and must not rewrite the item's session id.
@Test @MainActor func replayedEventsDoNotChangeTheStoredSessionId() async throws {
    let worktree = "/tmp/adopt-\(UUID().uuidString)"
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = "launched-id"
    try await store.upsertItem(review)
    let model = adoptionModel(store: store, worktree: worktree)
    await model.load()
    await model.ensureAgentSession(for: review)
    defer { model.terminateAllAgentSessions() }

    // ensureAgentSession replaces a stored id whose transcript is gone, so the launched id is
    // whatever it settled on. That is the value adoption must leave alone here.
    let launched = model.reviews.first(where: { $0.id == review.id })?.claudeSessionID
    model.setSessionStartedAtForTesting(Date(), for: review.id)
    model.setWatchedSessionIDForTesting("older-id", for: review.id)
    model.handleTranscriptEvent(
        reviewID: review.id,
        at: Date().addingTimeInterval(-3600),
        snippet: "from an earlier run",
        turnCompleted: false
    )
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeSessionID == launched)
}

/// Two items that point at the same clone share a transcript directory, so each watcher sees
/// the other's files. Adopting there would hand one item's conversation to another.
@Test @MainActor func anItemSharingAWorktreeNeverAdopts() async throws {
    let worktree = "/tmp/adopt-shared-\(UUID().uuidString)"
    let store = try ReviewStore(fileURL: tempStoreURL())
    var first = cappedReview("shared1", number: 1, openedMinutesAgo: 2)
    var second = cappedReview("shared2", number: 2, openedMinutesAgo: 1)
    first.claudeSessionID = "first-id"
    second.claudeSessionID = "second-id"
    for item in [first, second] { try await store.upsertItem(item) }
    let model = adoptionModel(store: store, worktree: worktree)
    await model.load()
    await model.ensureAgentSession(for: first)
    await model.ensureAgentSession(for: second)
    defer { model.terminateAllAgentSessions() }

    let launched = model.reviews.first(where: { $0.id == first.id })?.claudeSessionID
    model.setSessionStartedAtForTesting(Date().addingTimeInterval(-60), for: first.id)
    model.setWatchedSessionIDForTesting("newest-in-the-shared-dir", for: first.id)
    model.handleTranscriptEvent(reviewID: first.id, at: Date(), snippet: "whose is this?", turnCompleted: false)
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(model.reviews.first(where: { $0.id == first.id })?.claudeSessionID == launched)
}

/// The narrower version of the same danger: an id another item already owns is never taken,
/// even when the directory is this item's alone.
@Test @MainActor func anIdAnotherItemOwnsIsNeverAdopted() async throws {
    let worktree = "/tmp/adopt-\(UUID().uuidString)"
    let store = try ReviewStore(fileURL: tempStoreURL())
    var mine = cappedReview("mine", number: 1, openedMinutesAgo: 2)
    var theirs = cappedReview("theirs", number: 2, openedMinutesAgo: 1)
    mine.claudeSessionID = "my-id"
    theirs.claudeSessionID = "their-id"
    theirs.worktreePath = "/tmp/somewhere-else-\(UUID().uuidString)"
    for item in [mine, theirs] { try await store.upsertItem(item) }
    let model = adoptionModel(store: store, worktree: worktree)
    await model.load()
    await model.ensureAgentSession(for: mine)
    defer { model.terminateAllAgentSessions() }

    let launched = model.reviews.first(where: { $0.id == mine.id })?.claudeSessionID
    model.setSessionStartedAtForTesting(Date().addingTimeInterval(-60), for: mine.id)
    model.setWatchedSessionIDForTesting("their-id", for: mine.id)
    model.handleTranscriptEvent(reviewID: mine.id, at: Date(), snippet: "not mine", turnCompleted: false)
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(model.reviews.first(where: { $0.id == mine.id })?.claudeSessionID == launched)
    #expect(model.reviews.first(where: { $0.id == theirs.id })?.claudeSessionID == "their-id")
}

// MARK: - Local changes in a review worktree

@MainActor
private func dirtyWorktreeModel(store: ReviewStore, ops: StubWorktreeOps, worktree: String) -> AppModel {
    AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(
            result: WorktreeReady(clonePath: worktree, worktreePath: worktree, remoteName: "origin")
        ),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: ops,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
}

/// Someone edited a file inside a review checkout, so it can no longer be fast-forwarded to
/// the PR head. The session opens regardless, and the row has to say the tree is not what the
/// PR says it is — otherwise the review reads a stale diff with nothing on screen to warn it.
@Test @MainActor func aDirtyReviewWorktreeIsRecorded() async throws {
    let worktree = FileManager.default.temporaryDirectory
        .appendingPathComponent("dirty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: worktree) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()          // authored by icellan, so a review request
    review.worktreePath = worktree.path
    try await store.upsertItem(review)
    let ops = StubWorktreeOps()
    await ops.set(localChangesResult: [" M cmd/seeder/seeder.go"])
    let model = dirtyWorktreeModel(store: store, ops: ops, worktree: worktree.path)
    await model.load()
    model.setCurrentLoginForTesting("ordishs")

    await model.refreshWorktreeCleanliness(for: review.id)

    #expect(model.worktreeLocalChanges[review.id] == 1)
}

/// An editable worktree is the user's own branch. Edits there are the work, not a problem, and
/// flagging them would make the badge meaningless on every item the user is actually building.
@Test @MainActor func anEditableWorktreeIsNeverFlaggedAsDirty() async throws {
    let worktree = FileManager.default.temporaryDirectory
        .appendingPathComponent("mine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: worktree) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.worktreePath = worktree.path
    try await store.upsertItem(review)
    let ops = StubWorktreeOps()
    await ops.set(localChangesResult: [" M main.go", "?? scratch.txt"])
    let model = dirtyWorktreeModel(store: store, ops: ops, worktree: worktree.path)
    await model.load()
    // The PR author is the user, so this is their own branch.
    model.setCurrentLoginForTesting("icellan")

    await model.refreshWorktreeCleanliness(for: review.id)

    #expect(model.worktreeLocalChanges[review.id] == nil)
}

@Test @MainActor func discardingLocalChangesClearsTheFlagAndRefreshes() async throws {
    let worktree = FileManager.default.temporaryDirectory
        .appendingPathComponent("discard-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: worktree) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.worktreePath = worktree.path
    try await store.upsertItem(review)
    let ops = StubWorktreeOps()
    await ops.set(localChangesResult: [" M cmd/seeder/seeder.go", "?? notes.txt"])
    let model = dirtyWorktreeModel(store: store, ops: ops, worktree: worktree.path)
    await model.load()
    model.setCurrentLoginForTesting("ordishs")
    await model.refreshWorktreeCleanliness(for: review.id)
    #expect(model.worktreeLocalChanges[review.id] == 2)

    await model.discardLocalChanges(id: review.id)

    #expect(model.worktreeLocalChanges[review.id] == nil, "the flag clears once the tree is clean")
    #expect(await ops.discardedPaths == [worktree.path])
    #expect(await ops.refreshedWorktrees == [worktree.path], "and the fast-forward it was blocking runs")
}

/// A worktree the user deleted from disk is not dirty, it is absent. Reporting a stale count
/// would leave a badge on a row with nothing behind it.
@Test @MainActor func aMissingWorktreeClearsTheFlag() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.worktreePath = "/tmp/gone-\(UUID().uuidString)"
    try await store.upsertItem(review)
    let ops = StubWorktreeOps()
    await ops.set(localChangesResult: [" M something.go"])
    let model = dirtyWorktreeModel(store: store, ops: ops, worktree: "/tmp/unused")
    await model.load()
    model.setCurrentLoginForTesting("ordishs")

    await model.refreshWorktreeCleanliness(for: review.id)

    #expect(model.worktreeLocalChanges[review.id] == nil)
}

// MARK: - Agent limit stops

private let spendLimitMessage =
    "You've hit your individual spend limit · run /usage-credits to ask your admin for a higher limit"

@MainActor
private func modelWithLiveSession(
    poster: StubNotificationPoster = StubNotificationPoster()
) async throws -> (AppModel, WorkItem) {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: AgentStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureAgentSession(for: review)
    return (model, review)
}

@Test @MainActor func aLimitStopShowsAsLimitedRatherThanIdle() async throws {
    let (model, review) = try await modelWithLiveSession()
    let at = Date()

    model.handleTranscriptEvent(reviewID: review.id, at: at, snippet: nil, limitMessage: spendLimitMessage)

    // Well past the idle threshold: a blocked agent must not decay into a quiet one.
    model.recomputeStatus(for: review.id, now: at.addingTimeInterval(600))
    #expect(model.claudeStatuses[review.id] == .limited(since: at, message: spendLimitMessage))
}

@Test @MainActor func aLimitStopIsPersistedOnTheItem() async throws {
    let (model, review) = try await modelWithLiveSession()
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    model.handleTranscriptEvent(reviewID: review.id, at: at, snippet: nil, limitMessage: spendLimitMessage)
    await model.waitForPendingItemEdits()

    let stored = model.reviews.first { $0.id == review.id }
    #expect(stored?.agentLimitedAt == at)
    #expect(stored?.agentLimitMessage == spendLimitMessage)
}

@Test @MainActor func theNextRealEventClearsThePersistedLimit() async throws {
    let (model, review) = try await modelWithLiveSession()
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    model.handleTranscriptEvent(reviewID: review.id, at: at, snippet: nil, limitMessage: spendLimitMessage)
    await model.waitForPendingItemEdits()
    #expect(model.reviews.first { $0.id == review.id }?.agentLimitedAt != nil)

    model.handleTranscriptEvent(reviewID: review.id, at: at.addingTimeInterval(60), snippet: "back at it")
    await model.waitForPendingItemEdits()

    let stored = model.reviews.first { $0.id == review.id }
    #expect(stored?.agentLimitedAt == nil)
    #expect(stored?.agentLimitMessage == nil)
    #expect(model.claudeStatuses[review.id] != .limited(since: at, message: spendLimitMessage))
}

@Test @MainActor func clearingTheLimitBadgeByHandRemovesIt() async throws {
    let (model, review) = try await modelWithLiveSession()
    let at = Date(timeIntervalSince1970: 1_700_000_000)

    model.handleTranscriptEvent(reviewID: review.id, at: at, snippet: nil, limitMessage: spendLimitMessage)
    await model.waitForPendingItemEdits()

    await model.clearAgentLimit(for: review.id)

    let stored = model.reviews.first { $0.id == review.id }
    #expect(stored?.agentLimitedAt == nil)
    #expect(stored?.agentLimitMessage == nil)
}

@Test @MainActor func aLimitStopNotifiesOnceAndCarriesTheMessage() async throws {
    let poster = StubNotificationPoster()
    let (model, review) = try await modelWithLiveSession(poster: poster)
    let at = Date()

    model.handleTranscriptEvent(reviewID: review.id, at: at, snippet: nil, limitMessage: spendLimitMessage)
    model.recomputeStatus(for: review.id, now: at)
    // A second recompute of the same block must not notify again.
    model.recomputeStatus(for: review.id, now: at.addingTimeInterval(30))
    try await Task.sleep(nanoseconds: 300_000_000)

    let posted = await poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.reviewID == review.id)
    #expect(posted.first?.body == spendLimitMessage)
}

@Test @MainActor func aFreshLimitAfterRecoveryNotifiesAgain() async throws {
    let poster = StubNotificationPoster()
    let (model, review) = try await modelWithLiveSession(poster: poster)
    let at = Date()

    model.handleTranscriptEvent(reviewID: review.id, at: at, snippet: nil, limitMessage: spendLimitMessage)
    model.recomputeStatus(for: review.id, now: at)
    model.handleTranscriptEvent(reviewID: review.id, at: at.addingTimeInterval(60), snippet: "working")
    model.recomputeStatus(for: review.id, now: at.addingTimeInterval(60))
    model.handleTranscriptEvent(
        reviewID: review.id, at: at.addingTimeInterval(120), snippet: nil, limitMessage: spendLimitMessage
    )
    model.recomputeStatus(for: review.id, now: at.addingTimeInterval(120))
    try await Task.sleep(nanoseconds: 300_000_000)

    let posted = await poster.posted
    #expect(posted.count == 2)
}

// MARK: - codex

/// codex has no `--session-id`, so PR Pilot cannot tell it which session to create. Storing an
/// invented ID would name a conversation that does not exist: the next open would find no
/// transcript for it and start fresh again, for ever. The slot must stay empty until the
/// watcher reports the ID codex actually chose.
@Test @MainActor func aFreshCodexLaunchStoresNoSessionID() async throws {
    let worktree = "/tmp/codex-fresh-\(UUID().uuidString)"
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.worktreePath = worktree
    review.agent = .codex
    try await store.upsertItem(review)
    var settings = await store.settings()
    settings.codexPath = "/usr/bin/true"
    try await store.updateSettings(settings)

    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(
            result: WorktreeReady(clonePath: "/tmp/clone", worktreePath: worktree, remoteName: "origin")
        ),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureAgentSession(for: review)

    let current = model.reviews.first(where: { $0.id == review.id })
    #expect(current?.codexSessionID == nil, "codex names its own session; the app must not invent one")
    #expect(current?.claudeSessionID == nil)
    model.terminateAgentSession(for: review.id)
}

/// The other half: an ID that came from a real codex transcript IS stored, because resuming it
/// works. This proves the launch path distinguishes a resume from a fresh start rather than
/// simply never writing the codex slot.
@Test @MainActor func aCodexResumeStoresTheSessionIDItResumed() async throws {
    let fm = FileManager.default
    let worktree = "/tmp/codex-resume-\(UUID().uuidString)"
    try fm.createDirectory(atPath: worktree, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: worktree) }

    let sessionID = "01a03df8-9e0c-7672-908a-546665225b9b"
    let dir = AgentTranscriptPath.directoryURL(for: .codex, worktreePath: worktree)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    // Written into the user's real codex tree, because that is where the backend looks. Only
    // this one file is created, and only it is removed — the membership filter means no real
    // session can match this worktree.
    let transcript = dir.appendingPathComponent("rollout-2026-08-26T14-08-18-\(sessionID).jsonl")
    let resolvedWorktree = URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path
    try """
    {"timestamp":"2026-08-26T12:08:18.414Z","type":"session_meta","payload":{"cwd":"\(resolvedWorktree)","originator":"cli"}}
    """.write(to: transcript, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: transcript) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.worktreePath = worktree
    review.agent = .codex
    try await store.upsertItem(review)
    var settings = await store.settings()
    settings.codexPath = "/usr/bin/true"
    try await store.updateSettings(settings)

    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(
            result: WorktreeReady(clonePath: "/tmp/clone", worktreePath: worktree, remoteName: "origin")
        ),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureAgentSession(for: review)

    let current = model.reviews.first(where: { $0.id == review.id })
    #expect(current?.codexSessionID == sessionID, "an ID read from a real transcript is resumable, so it is stored")
    model.terminateAgentSession(for: review.id)
}

/// Switching between all three agents must leave each conversation where it was.
///
/// Real transcripts are written for all three, for the reason the two-agent version of this
/// test explains: a stored session whose transcript has gone is deliberately replaced rather
/// than resumed, so the promise only holds while every transcript exists.
@Test @MainActor func switchingAcrossThreeAgentsKeepsEverySessionID() async throws {
    let fm = FileManager.default
    let worktree = "/tmp/three-agents-\(UUID().uuidString)"
    try fm.createDirectory(atPath: worktree, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: worktree) }

    let claudeSessionID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    let piSessionID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    let codexSessionID = "01a04000-1111-7672-908a-546665225b9b"

    let claudeDir = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: worktree)
    let piDir = AgentTranscriptPath.directoryURL(for: .pi, worktreePath: worktree)
    let codexDir = AgentTranscriptPath.directoryURL(for: .codex, worktreePath: worktree)
    try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: piDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)

    try "{}".write(to: claudeDir.appendingPathComponent("\(claudeSessionID).jsonl"), atomically: true, encoding: .utf8)
    try "{}".write(
        to: piDir.appendingPathComponent("2026-08-13T11-54-02-626Z_\(piSessionID).jsonl"),
        atomically: true,
        encoding: .utf8
    )
    // codex shares its day directory with every project, so only this file may be removed —
    // and only a transcript recording this worktree can match it.
    let codexTranscript = codexDir.appendingPathComponent("rollout-2026-08-26T14-30-00-\(codexSessionID).jsonl")
    let resolvedWorktree = URL(fileURLWithPath: worktree).resolvingSymlinksInPath().path
    try """
    {"timestamp":"2026-08-26T12:08:18.414Z","type":"session_meta","payload":{"cwd":"\(resolvedWorktree)","originator":"cli"}}
    """.write(to: codexTranscript, atomically: true, encoding: .utf8)
    defer {
        try? fm.removeItem(at: claudeDir)
        try? fm.removeItem(at: piDir)
        try? fm.removeItem(at: codexTranscript)
    }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.worktreePath = worktree
    review.claudeSessionID = claudeSessionID
    review.piSessionID = piSessionID
    review.codexSessionID = codexSessionID
    try await store.upsertItem(review)
    var settings = await store.settings()
    settings.piPath = "/usr/bin/true"
    settings.codexPath = "/usr/bin/true"
    try await store.updateSettings(settings)

    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(
            result: WorktreeReady(clonePath: "/tmp/clone", worktreePath: worktree, remoteName: "origin")
        ),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    for kind in [AgentKind.codex, .pi, .claudeCode, .codex] {
        await model.setAgent(kind, for: review.id)
        let current = model.reviews.first(where: { $0.id == review.id })
        #expect(current?.agent == kind)
        #expect(current?.claudeSessionID == claudeSessionID, "Claude Code survives a switch to \(kind)")
        #expect(current?.piSessionID == piSessionID, "pi survives a switch to \(kind)")
        #expect(current?.codexSessionID == codexSessionID, "codex survives a switch to \(kind)")
    }
    model.terminateAgentSession(for: review.id)
}

// MARK: - Failover on a limit

/// Builds a model whose item has a real worktree directory, so the handover note has somewhere
/// to be written, and whose transcript holds a conversation worth carrying.
@MainActor
private func modelReadyToHandOver(
    mode: AgentFailoverMode = .manual,
    target: AgentKind = .codex,
    writeTranscript: Bool = true
) async throws -> (AppModel, WorkItem, String) {
    let fm = FileManager.default
    let worktree = "/tmp/handover-\(UUID().uuidString)"
    try fm.createDirectory(atPath: worktree, withIntermediateDirectories: true)

    let claudeSessionID = "cccccccc-cccc-cccc-cccc-cccccccccccc"
    if writeTranscript {
        let dir = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: worktree)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","timestamp":"2026-08-26T12:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Start work on issue 4459."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-08-26T12:01:00.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"I changed the mempool cap and added a test."}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("\(claudeSessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.worktreePath = worktree
    review.claudeSessionID = claudeSessionID
    try await store.upsertItem(review)
    var settings = await store.settings()
    settings.agentFailover = mode
    settings.failoverAgent = target
    settings.codexPath = "/usr/bin/true"
    settings.piPath = "/usr/bin/true"
    try await store.updateSettings(settings)

    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(
            result: WorktreeReady(clonePath: "/tmp/clone", worktreePath: worktree, remoteName: "origin")
        ),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster(),
        statusReader: AgentStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureAgentSession(for: review)
    return (model, review, worktree)
}

/// The whole feature in one test: a blocked Claude Code item moves to codex, and the note that
/// explains the work is on disk where the new agent was told to look.
@Test @MainActor func handingOverWritesTheNoteAndSwitchesTheAgent() async throws {
    let (model, review, worktree) = try await modelReadyToHandOver()
    defer { try? FileManager.default.removeItem(atPath: worktree) }

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, limitMessage: spendLimitMessage)
    await model.waitForPendingItemEdits()
    #expect(model.canHandOver(model.reviews.first { $0.id == review.id }!))

    let switched = await model.handOverToFailoverAgent(for: review.id)
    #expect(switched)

    let current = model.reviews.first { $0.id == review.id }
    #expect(current?.agent == .codex)
    // Claude Code's own conversation is left intact, so the item can go back to it once the
    // limit resets.
    #expect(current?.claudeSessionID == "cccccccc-cccc-cccc-cccc-cccccccccccc")

    let note = try String(
        contentsOf: URL(fileURLWithPath: worktree).appendingPathComponent(HandoverNote.fileName),
        encoding: .utf8
    )
    #expect(note.contains("Claude Code → Codex"))
    #expect(note.contains("I changed the mempool cap and added a test."))
    #expect(note.contains("Start work on issue 4459."))
    #expect(note.contains(spendLimitMessage))

    model.terminateAgentSession(for: review.id)
}

/// The badge described the agent that no longer runs this item. Leaving it would make the new
/// session look blocked from its first frame.
@Test @MainActor func handingOverClearsTheLimitBadge() async throws {
    let (model, review, worktree) = try await modelReadyToHandOver()
    defer { try? FileManager.default.removeItem(atPath: worktree) }

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, limitMessage: spendLimitMessage)
    await model.waitForPendingItemEdits()
    await model.handOverToFailoverAgent(for: review.id)

    let current = model.reviews.first { $0.id == review.id }
    #expect(current?.agentLimitMessage == nil)
    #expect(current?.agentLimitedAt == nil)
    if case .limited = model.claudeStatuses[review.id] {
        Issue.record("the new session must not inherit the old agent's limit")
    }
    model.terminateAgentSession(for: review.id)
}

/// The note reaches the agent only if the launch prompt points at it, and the pointer must be
/// spent exactly once — a later relaunch is not a handover.
@Test @MainActor func theHandoverPointerIsSentOnceAndThenCleared() async throws {
    let (model, review, worktree) = try await modelReadyToHandOver()
    defer { try? FileManager.default.removeItem(atPath: worktree) }

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, limitMessage: spendLimitMessage)
    await model.waitForPendingItemEdits()
    await model.handOverToFailoverAgent(for: review.id)

    let current = model.reviews.first { $0.id == review.id }
    #expect(current?.pendingHandoverPath == nil, "the launch that sent it must clear it")
    model.terminateAgentSession(for: review.id)
}

/// Manual is the default, so a limit must not move anything on its own.
@Test @MainActor func manualModeDoesNotSwitchOnItsOwn() async throws {
    let (model, review, worktree) = try await modelReadyToHandOver(mode: .manual)
    defer { try? FileManager.default.removeItem(atPath: worktree) }

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, limitMessage: spendLimitMessage)
    model.recomputeStatus(for: review.id, now: Date())
    await model.waitForPendingItemEdits()
    // Automatic failover runs as its own task, so give it a moment before asserting that
    // nothing moved.
    try await Task.sleep(nanoseconds: 400_000_000)
    await model.waitForPendingItemEdits()

    let current = model.reviews.first { $0.id == review.id }
    #expect(current?.agent == nil, "manual mode leaves the agent alone")
    #expect(!FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: worktree).appendingPathComponent(HandoverNote.fileName).path
    ))
    model.terminateAgentSession(for: review.id)
}

@Test @MainActor func automaticModeSwitchesWithoutBeingAsked() async throws {
    let (model, review, worktree) = try await modelReadyToHandOver(mode: .automatic)
    defer { try? FileManager.default.removeItem(atPath: worktree) }

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, limitMessage: spendLimitMessage)
    model.recomputeStatus(for: review.id, now: Date())
    // The switch is started from the status recomputation, so poll for its result rather than
    // guessing at a duration.
    for _ in 0..<100 where model.reviews.first(where: { $0.id == review.id })?.agent == nil {
        try await Task.sleep(nanoseconds: 50_000_000)
        await model.waitForPendingItemEdits()
    }

    let current = model.reviews.first { $0.id == review.id }
    #expect(current?.agent == .codex)
    #expect(FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: worktree).appendingPathComponent(HandoverNote.fileName).path
    ))
    model.terminateAgentSession(for: review.id)
}

/// One account cannot rescue itself. An item already running the failover agent must never be
/// "switched" to it, which would restart the work for nothing.
@Test @MainActor func anItemAlreadyOnTheFailoverAgentIsNeverSwitched() async throws {
    let (model, review, worktree) = try await modelReadyToHandOver(mode: .automatic, target: .claudeCode)
    defer { try? FileManager.default.removeItem(atPath: worktree) }

    #expect(!model.canHandOver(model.reviews.first { $0.id == review.id }!))

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, limitMessage: spendLimitMessage)
    model.recomputeStatus(for: review.id, now: Date())
    await model.waitForPendingItemEdits()
    // Automatic failover runs as its own task, so give it a moment before asserting that
    // nothing moved.
    try await Task.sleep(nanoseconds: 400_000_000)
    await model.waitForPendingItemEdits()

    #expect(await model.handOverToFailoverAgent(for: review.id) == false)
    #expect(model.reviews.first { $0.id == review.id }?.agent == nil)
    model.terminateAgentSession(for: review.id)
}

/// An item that is merely idle or working is not a handover candidate. Offering the switch
/// there would invite the user to restart healthy work under a different agent.
@Test @MainActor func anUnblockedItemIsNotAHandoverCandidate() async throws {
    let (model, review, worktree) = try await modelReadyToHandOver()
    defer { try? FileManager.default.removeItem(atPath: worktree) }

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: "working away")
    model.recomputeStatus(for: review.id, now: Date())
    #expect(!model.canHandOver(model.reviews.first { $0.id == review.id }!))
    model.terminateAgentSession(for: review.id)
}

/// A transcript that could not be read must not stop the switch. Losing the summary is bad;
/// leaving the item stuck on a blocked agent is worse.
@Test @MainActor func aMissingTranscriptStillHandsOver() async throws {
    let (model, review, worktree) = try await modelReadyToHandOver(writeTranscript: false)
    defer { try? FileManager.default.removeItem(atPath: worktree) }

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, limitMessage: spendLimitMessage)
    await model.waitForPendingItemEdits()

    #expect(await model.handOverToFailoverAgent(for: review.id))
    #expect(model.reviews.first { $0.id == review.id }?.agent == .codex)

    let note = try String(
        contentsOf: URL(fileURLWithPath: worktree).appendingPathComponent(HandoverNote.fileName),
        encoding: .utf8
    )
    #expect(note.contains("no readable turns"))
    model.terminateAgentSession(for: review.id)
}

// MARK: - The usage gauge

@MainActor
private func modelWithUsage(
    warnAt: Int = 90,
    failoverAgent: AgentKind = .claudeCode,
    poster: StubNotificationPoster = StubNotificationPoster()
) async throws -> (AppModel, WorkItem) {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.agent = .codex
    try await store.upsertItem(review)
    var settings = await store.settings()
    settings.usageWarningPercent = warnAt
    settings.failoverAgent = failoverAgent
    settings.codexPath = "/usr/bin/true"
    try await store.updateSettings(settings)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: AgentStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureAgentSession(for: review)
    return (model, review)
}

private func usageReading(_ percent: Double, readAt: Date = Date()) -> AgentUsage {
    AgentUsage(
        usedPercent: percent,
        windowMinutes: 10080,
        resetsAt: readAt.addingTimeInterval(3 * 24 * 3600),
        agent: .codex,
        readAt: readAt
    )
}

@Test @MainActor func aUsageReadingIsShownAndPersisted() async throws {
    let (model, review) = try await modelWithUsage()
    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, usage: usageReading(93))
    await model.waitForPendingItemEdits()

    #expect(model.usageToShow(for: model.reviews.first { $0.id == review.id }!)?.displayPercent == 93)
    // Persisted, so eviction or a quit does not lose the figure.
    #expect(model.reviews.first { $0.id == review.id }?.agentUsage?.displayPercent == 93)
    model.terminateAgentSession(for: review.id)
}

/// The whole point of the gauge: the warning arrives while the agent is still working, not
/// after it has stopped.
@Test @MainActor func crossingTheThresholdWarnsOnce() async throws {
    let poster = StubNotificationPoster()
    let (model, review) = try await modelWithUsage(poster: poster)

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, usage: usageReading(88))
    await model.waitForPendingItemEdits()
    await poster.settle()
    #expect(await poster.posted.isEmpty, "below the threshold is not worth an alert")

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, usage: usageReading(91))
    await poster.waitForPosts(atLeast: 1)
    let afterCrossing = await poster.posted
    #expect(afterCrossing.count == 1)
    #expect(afterCrossing.first?.title.contains("91%") == true)
    #expect(afterCrossing.first?.body.contains("7 days") == true)

    // Every codex turn reports usage, so a session sitting above the line must not alert again.
    for percent in [92.0, 95.0, 99.0] {
        model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, usage: usageReading(percent))
    }
    await model.waitForPendingItemEdits()
    await poster.settle()
    #expect(await poster.posted.count == 1, "one crossing is one alert")
    model.terminateAgentSession(for: review.id)
}

/// A window that has reset earns a fresh warning next time round.
@Test @MainActor func aResetWindowCanWarnAgain() async throws {
    let poster = StubNotificationPoster()
    let (model, review) = try await modelWithUsage(poster: poster)

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, usage: usageReading(95))
    await poster.waitForPosts(atLeast: 1)
    #expect(await poster.posted.count == 1)

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, usage: usageReading(2))
    await model.waitForPendingItemEdits()
    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, usage: usageReading(94))
    await poster.waitForPosts(atLeast: 2)
    #expect(await poster.posted.count == 2)
    model.terminateAgentSession(for: review.id)
}

@Test @MainActor func theThresholdIsTheUsersSetting() async throws {
    let poster = StubNotificationPoster()
    let (model, review) = try await modelWithUsage(warnAt: 75, poster: poster)

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, usage: usageReading(80))
    await poster.waitForPosts(atLeast: 1)
    #expect(await poster.posted.count == 1)
    model.terminateAgentSession(for: review.id)
}

/// The warning names the escape route, but only when there is one — an item already on the
/// failover agent has nowhere to go.
@Test @MainActor func theWarningNamesTheFailoverAgentOnlyWhenItDiffers() async throws {
    let poster = StubNotificationPoster()
    let (model, review) = try await modelWithUsage(failoverAgent: .claudeCode, poster: poster)
    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, usage: usageReading(95))
    await poster.waitForPosts(atLeast: 1)
    #expect(await poster.posted.first?.body.contains("Hand the item to Claude Code") == true)
    model.terminateAgentSession(for: review.id)

    let otherPoster = StubNotificationPoster()
    let (sameAgent, item) = try await modelWithUsage(failoverAgent: .codex, poster: otherPoster)
    sameAgent.handleTranscriptEvent(reviewID: item.id, at: Date(), snippet: nil, usage: usageReading(95))
    await otherPoster.waitForPosts(atLeast: 1)
    #expect(await otherPoster.posted.first?.body.contains("Hand the item to") == false)
    sameAgent.terminateAgentSession(for: item.id)
}

/// A figure whose window has since reset must not be shown. Acting on it would mean handing
/// work over for no reason.
@Test @MainActor func aStaleReadingIsNotShown() async throws {
    let (model, review) = try await modelWithUsage()
    let read = Date(timeIntervalSince1970: 1_786_000_000)
    model.handleTranscriptEvent(reviewID: review.id, at: read, snippet: nil, usage: usageReading(95, readAt: read))
    await model.waitForPendingItemEdits()

    let stored = model.reviews.first { $0.id == review.id }!
    #expect(model.usageToShow(for: stored, now: read.addingTimeInterval(60)) != nil)
    // Past the reset time the reading is dropped, though it stays on the item.
    #expect(model.usageToShow(for: stored, now: read.addingTimeInterval(4 * 24 * 3600)) == nil)
    #expect(stored.agentUsage != nil)
    model.terminateAgentSession(for: review.id)
}

/// Claude Code publishes nothing, so an item running it has no gauge — and must not inherit
/// the figure another item read from codex.
@Test @MainActor func anItemWithNoReadingShowsNothing() async throws {
    let (model, review) = try await modelWithUsage()
    #expect(model.usageToShow(for: model.reviews.first { $0.id == review.id }!) == nil)
    model.terminateAgentSession(for: review.id)
}

/// Usage arrives on every turn. Writing the store each time would be a write per keystroke of
/// the agent's output, so only a change to the displayed figure is persisted.
@Test @MainActor func anUnchangedFigureIsNotWrittenAgain() async throws {
    let (model, review) = try await modelWithUsage()
    let read = Date()
    model.handleTranscriptEvent(reviewID: review.id, at: read, snippet: nil, usage: usageReading(93.1, readAt: read))
    await model.waitForPendingItemEdits()
    let first = model.reviews.first { $0.id == review.id }?.agentUsage
    #expect(first?.displayPercent == 93, "the first reading must land before the comparison")

    // Same whole percentage, later reading: nothing to show differently, so nothing is written.
    model.handleTranscriptEvent(reviewID: review.id, at: read, snippet: nil, usage: usageReading(93.4, readAt: read))
    await model.waitForPendingItemEdits()
    #expect(model.reviews.first { $0.id == review.id }?.agentUsage == first)

    // A different whole percentage is written through.
    model.handleTranscriptEvent(reviewID: review.id, at: read, snippet: nil, usage: usageReading(94.0, readAt: read))
    await model.waitForPendingItemEdits()
    #expect(model.reviews.first { $0.id == review.id }?.agentUsage?.displayPercent == 94)
    model.terminateAgentSession(for: review.id)
}

private let secondReviewID = "AAAAAAAA-0000-0000-0000-000000000945"

private func secondReviewInSameRepo() -> WorkItem {
    WorkItem(
        id: secondReviewID,
        title: "second PR on the same base",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/other",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 945,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/945")!,
            authorLogin: "ordishs"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private let blockedSnapshotJSON = """
{"data":{"r0":{"pullRequest":{
  "state":"OPEN","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"BLOCKED",
  "author":{"login":"ordishs"},
  "commits":{"nodes":[{"commit":{"committedDate":"2026-08-06T11:00:00Z","statusCheckRollup":null}}]},
  "reviews":{"nodes":[{"author":{"login":"liam"},"state":"APPROVED","submittedAt":"2026-08-06T09:00:00Z"}]},
  "reviewThreads":{"nodes":[{"isResolved":false,"resolvedBy":null,"comments":{"nodes":[]}}]},
  "timelineItems":{"nodes":[]}
}}}}
"""

private let twoApprovalsRuleJSON = """
[{"type":"pull_request","parameters":{"required_approving_review_count":2},"ruleset_id":1}]
"""

@MainActor private func modelWith(_ runner: StubRunner, store: ReviewStore) -> AppModel {
    AppModel(
        store: store,
        client: GitHubClient(runner: runner, ghPath: "gh"),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
}

@Test @MainActor func refreshReadsTheMergeRulesOncePerRepoAndBase() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    try await store.upsertItem(secondReviewInSameRepo())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: blockedSnapshotJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: twoApprovalsRuleJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: blockedSnapshotJSON, standardError: ""),
    ])
    let model = modelWith(runner, store: store)
    await model.load()

    await model.refreshReviewState(for: sampleReviewID)
    await model.refreshReviewState(for: secondReviewID)

    let key = MergeRules.key(owner: "bsv-blockchain", repo: "teranode", branch: "main")
    #expect(model.mergeRules[key]?.requiredApprovals == 2)
    let ruleCalls = await runner.recordedArguments.filter { $0.contains("repos/bsv-blockchain/teranode/rules/branches/main") }
    #expect(ruleCalls.count == 1, "the second PR on the same base must reuse the cached rules")
    // The snapshot itself still lands, and now carries the blocking detail.
    #expect(model.prStatuses[sampleReviewID]?.approvalCount == 1)
    #expect(model.prStatuses[sampleReviewID]?.unresolvedThreads == 1)
    #expect(model.prStatuses[secondReviewID]?.mergeState == .blocked)
}

@Test @MainActor func staleMergeRulesAreReadAgainAfterTheTTL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: blockedSnapshotJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: twoApprovalsRuleJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: blockedSnapshotJSON, standardError: ""),
        CommandResult(
            exitCode: 0,
            standardOutput: """
            [{"type":"pull_request","parameters":{"required_approving_review_count":3},"ruleset_id":1}]
            """,
            standardError: ""
        ),
    ])
    let model = modelWith(runner, store: store)
    await model.load()

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await model.refreshReviewState(for: sampleReviewID, now: start)
    await model.refreshReviewState(for: sampleReviewID, now: start.addingTimeInterval(7 * 3600))

    let key = MergeRules.key(owner: "bsv-blockchain", repo: "teranode", branch: "main")
    #expect(model.mergeRules[key]?.requiredApprovals == 3)
}

@Test @MainActor func mergeRulesWithinTheTTLAreNotReadAgain() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: blockedSnapshotJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: twoApprovalsRuleJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: blockedSnapshotJSON, standardError: ""),
    ])
    let model = modelWith(runner, store: store)
    await model.load()

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await model.refreshReviewState(for: sampleReviewID, now: start)
    await model.refreshReviewState(for: sampleReviewID, now: start.addingTimeInterval(600))

    let ruleCalls = await runner.recordedArguments.filter { $0.contains("repos/bsv-blockchain/teranode/rules/branches/main") }
    #expect(ruleCalls.count == 1)
}

@Test @MainActor func aFailedMergeRulesReadIsNotRetriedWithinTheTTL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: blockedSnapshotJSON, standardError: ""),
        CommandResult(exitCode: 1, standardOutput: "", standardError: "HTTP 403"),
        CommandResult(exitCode: 0, standardOutput: blockedSnapshotJSON, standardError: ""),
    ])
    let model = modelWith(runner, store: store)
    await model.load()

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await model.refreshReviewState(for: sampleReviewID, now: start)
    await model.refreshReviewState(for: sampleReviewID, now: start.addingTimeInterval(600))

    let key = MergeRules.key(owner: "bsv-blockchain", repo: "teranode", branch: "main")
    // The failure is remembered as "requirement unknown", so the row falls back to a plain
    // count instead of asking again on every poll.
    #expect(model.mergeRules[key] == MergeRules(requiredApprovals: nil))
    let ruleCalls = await runner.recordedArguments.filter { $0.contains("repos/bsv-blockchain/teranode/rules/branches/main") }
    #expect(ruleCalls.count == 1)
}

// MARK: - Worktree lifecycle
//
// A merged PR used to leave its checkout behind for good: the work item went, and nothing was
// left to say which directory had belonged to it. The managed root then grew by one checkout
// per merge, and only a manual menu command could reclaim the space.

private func managedRootFixture() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("managed-\(UUID().uuidString)", isDirectory: true).path
}

@Test @MainActor func pruningAMergedDiscoveredItemGivesBackItsWorktree() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.managedRoot = managedRootFixture()
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    var merged = sampleReview()
    merged.origin = .discovered
    merged.prState = .merged
    merged.worktreePath = WorktreeLayout.directory(managedRoot: seed.managedRoot) + "/bsv-blockchain-teranode-pr944"
    try await store.upsertItem(merged)
    let ops = StubWorktreeOps()
    await ops.set(isCleanResult: true)
    // Every query answers empty, so the merged PR falls out of the results and gets pruned.
    let client = GitHubClient(
        runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: "")),
        ghPath: "gh"
    )
    let model = AppModel(
        store: store, client: client, diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(),
        worktreeOps: ops, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.isEmpty)
    #expect(await ops.removedOrphanPaths == [merged.worktreePath!])
}

@Test @MainActor func pruningAMergedItemKeepsADirtyWorktree() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.managedRoot = managedRootFixture()
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    var merged = sampleReview()
    merged.origin = .discovered
    merged.prState = .merged
    merged.worktreePath = WorktreeLayout.directory(managedRoot: seed.managedRoot) + "/bsv-blockchain-teranode-pr944"
    try await store.upsertItem(merged)
    let ops = StubWorktreeOps()
    // Unpushed work outweighs the disk. The orphan prune, which warns first, still reaches it.
    await ops.set(isCleanResult: false)
    // Every query answers empty, so the merged PR falls out of the results and gets pruned.
    let client = GitHubClient(
        runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: "")),
        ghPath: "gh"
    )
    let model = AppModel(
        store: store, client: client, diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(),
        worktreeOps: ops, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.isEmpty)
    #expect(await ops.removedOrphanPaths.isEmpty)
}

// MARK: - Open PRs that leave the discovery results
//
// Submitting a review clears the request, so the PR drops out of `review-requested:@me`. The
// item used to stay until the PR merged, which kept every reviewed PR on the list.

private func searchHitJSON(numbers: [Int]) -> String {
    let rows = numbers.map { n in
        """
        {"number": \(n), "title": "pr \(n)", "url": "https://github.com/bsv-blockchain/teranode/pull/\(n)", \
        "state": "open", "isDraft": false, "author": {"login": "icellan"}, \
        "repository": {"nameWithOwner": "bsv-blockchain/teranode"}}
        """
    }
    return "[" + rows.joined(separator: ",") + "]"
}

private func searchOK(_ json: String) -> CommandResult {
    CommandResult(exitCode: 0, standardOutput: json, standardError: "")
}

/// Two PR queries (review requests, then my PRs) and no issue query, so each test controls
/// exactly what every search answers.
@MainActor
private func openPruneModel(
    items: [WorkItem],
    searchResults: [CommandResult],
    ops: StubWorktreeOps = StubWorktreeOps()
) async throws -> AppModel {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.managedRoot = managedRootFixture()
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = true
    seed.myPRQueries = [DiscoveryQuery(text: "author:@me is:open")]
    seed.issuesEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    for item in items {
        try await store.upsertItem(item)
    }
    // `load()` asks for the login first; the searches follow in query order.
    let client = GitHubClient(runner: StubRunner(results: [searchOK("icellan")] + searchResults), ghPath: "gh")
    let model = AppModel(
        store: store, client: client, diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(),
        worktreeOps: ops, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster()
    )
    await model.load()
    return model
}

private func discoveredOpenReview() -> WorkItem {
    var item = sampleReview()
    item.origin = .discovered
    item.prState = .open
    return item
}

private func existingWorktreeFixture() throws -> String {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true).path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

@Test @MainActor func anOpenDiscoveredPRLeavesOnceNoQueryReturnsIt() async throws {
    let model = try await openPruneModel(
        items: [discoveredOpenReview()],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)]
    )
    model.selection = sampleReviewID

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.isEmpty)
    #expect(model.selection == nil)
}

@Test @MainActor func anOpenDiscoveredPRStaysWhileAQueryStillReturnsIt() async throws {
    let model = try await openPruneModel(
        items: [discoveredOpenReview()],
        searchResults: [searchOK(searchHitJSON(numbers: [944])), searchOK(emptySearchJSON)]
    )

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.map(\.id) == [sampleReviewID])
}

@Test @MainActor func aFailedQueryKeepsOpenPRsItMayHaveReturned() async throws {
    // The review-request search hits a rate limit. Its PRs are unknown, not gone.
    let model = try await openPruneModel(
        items: [discoveredOpenReview()],
        searchResults: [
            CommandResult(exitCode: 1, standardOutput: "", standardError: "HTTP 403: You have exceeded a secondary rate limit."),
            searchOK(emptySearchJSON),
        ]
    )

    await model.discoverNow()

    #expect(model.discoveryWarnings.count == 1)
    #expect(model.discoveryWarnings.first?.contains("secondary rate limit") == true)
    #expect(model.reviews.map(\.id) == [sampleReviewID])
}

@Test @MainActor func aTooBroadQueryKeepsOpenPRsItMayHaveReturned() async throws {
    // 100+ results are thrown away, so the app never saw whether PR 944 was among them.
    let model = try await openPruneModel(
        items: [discoveredOpenReview()],
        searchResults: [searchOK(searchHitJSON(numbers: Array(2000..<2100))), searchOK(emptySearchJSON)]
    )

    await model.discoverNow()

    #expect(model.discoveryWarnings.count == 1)
    #expect(model.discoveryWarnings.first?.contains("100+") == true)
    #expect(model.reviews.map(\.id) == [sampleReviewID])
}

@Test @MainActor func anUnscopedSkippedQueryKeepsOpenPRs() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.managedRoot = managedRootFixture()
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = true
    seed.myPRQueries = [DiscoveryQuery(text: "is:open")]
    seed.issuesEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(discoveredOpenReview())
    let client = GitHubClient(runner: StubRunner(results: [searchOK("icellan"), searchOK(emptySearchJSON)]), ghPath: "gh")
    let model = AppModel(
        store: store, client: client, diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.discoveryWarnings.count == 1)
    #expect(model.discoveryWarnings.first?.contains("Skipped") == true)
    #expect(model.reviews.map(\.id) == [sampleReviewID])
}

@Test @MainActor func anOpenPRStaysWhileItsAgentWorks() async throws {
    let model = try await openPruneModel(
        items: [discoveredOpenReview()],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)]
    )
    model.setClaudeStatusForTesting(.working, for: sampleReviewID)

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.map(\.id) == [sampleReviewID])
}

@Test @MainActor func anOpenPRStaysWhileItsAgentStarts() async throws {
    let model = try await openPruneModel(
        items: [discoveredOpenReview()],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)]
    )
    model.setClaudeStatusForTesting(.starting, for: sampleReviewID)

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.map(\.id) == [sampleReviewID])
}

@Test @MainActor func anOpenPRLeavesWhenItsAgentIsIdle() async throws {
    let model = try await openPruneModel(
        items: [discoveredOpenReview()],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)]
    )
    model.setClaudeStatusForTesting(.idle(since: Date(), lastVerdictSnippet: "approved"), for: sampleReviewID)

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.isEmpty)
    #expect(model.claudeStatuses[sampleReviewID] == nil)
}

@Test @MainActor func anOpenPRStaysWhileItsWorktreeHasLocalChanges() async throws {
    var item = discoveredOpenReview()
    item.worktreePath = try existingWorktreeFixture()
    let ops = StubWorktreeOps()
    await ops.set(isCleanResult: false)
    let model = try await openPruneModel(
        items: [item],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)],
        ops: ops
    )

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.map(\.id) == [sampleReviewID])
    #expect(await ops.removedOrphanPaths.isEmpty)
}

@Test @MainActor func anOpenPRStaysWhenGitCannotReadItsWorktree() async throws {
    var item = discoveredOpenReview()
    item.worktreePath = try existingWorktreeFixture()
    let ops = StubWorktreeOps()
    await ops.set(isCleanThrows: true)
    let model = try await openPruneModel(
        items: [item],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)],
        ops: ops
    )

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.map(\.id) == [sampleReviewID])
}

@Test @MainActor func anOpenPRWithACleanWorktreeLeavesAndGivesItBack() async throws {
    var item = discoveredOpenReview()
    let path = try existingWorktreeFixture()
    item.worktreePath = path
    let ops = StubWorktreeOps()
    await ops.set(isCleanResult: true)
    let model = try await openPruneModel(
        items: [item],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)],
        ops: ops
    )

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.isEmpty)
    #expect(await ops.removedOrphanPaths == [path])
}

@Test @MainActor func anOpenPRTheUserAddedStaysWhenNoQueryReturnsIt() async throws {
    var added = sampleReview()
    added.origin = .added
    let both = WorkItem(
        id: "both-item",
        title: "second fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/second",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 945,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/945")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .both,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let model = try await openPruneModel(
        items: [added, both],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)]
    )

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(Set(model.reviews.map(\.id)) == [sampleReviewID, "both-item"])
}

@Test @MainActor func aMergedPRTheUserAlsoAddedLeaves() async throws {
    var both = sampleReview()
    both.origin = .both
    both.prState = .merged
    let model = try await openPruneModel(
        items: [both],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)]
    )

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.isEmpty)
}

@Test @MainActor func aMergedPROnlyTheUserAddedStays() async throws {
    var added = sampleReview()
    added.origin = .added
    added.prState = .merged
    let model = try await openPruneModel(
        items: [added],
        searchResults: [searchOK(emptySearchJSON), searchOK(emptySearchJSON)]
    )

    await model.discoverNow()

    #expect(model.discoveryWarnings.isEmpty)
    #expect(model.reviews.map(\.id) == [sampleReviewID])
}

@Test @MainActor func pruneOrphanedWorktreesRemovesThroughGit() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    let managedRoot = managedRootFixture()
    defer { try? FileManager.default.removeItem(atPath: managedRoot) }
    seed.managedRoot = managedRoot
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    var live = sampleReview()
    let worktrees = WorktreeLayout.directory(managedRoot: managedRoot)
    live.worktreePath = worktrees + "/kept"
    try await store.upsertItem(live)
    for name in ["kept", "orphan-a", "orphan-b"] {
        try FileManager.default.createDirectory(atPath: worktrees + "/" + name, withIntermediateDirectories: true)
    }
    let ops = StubWorktreeOps()
    let model = AppModel(
        store: store, client: stubClient(), diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(),
        worktreeOps: ops, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster()
    )
    await model.load()

    #expect(model.orphanedWorktreePaths() == [worktrees + "/orphan-a", worktrees + "/orphan-b"])
    let removed = await model.pruneOrphanedWorktrees()

    #expect(removed == 2)
    // Through git, so the clone's administrative entry and the branch go with the directory.
    #expect(await ops.removedOrphanPaths == [worktrees + "/orphan-a", worktrees + "/orphan-b"])
}

@Test @MainActor func pruneOrphanedWorktreesReportsAFailureAndCountsOnlyWhatWent() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    let managedRoot = managedRootFixture()
    defer { try? FileManager.default.removeItem(atPath: managedRoot) }
    seed.managedRoot = managedRoot
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let worktrees = WorktreeLayout.directory(managedRoot: managedRoot)
    try FileManager.default.createDirectory(atPath: worktrees + "/orphan-a", withIntermediateDirectories: true)
    let ops = StubWorktreeOps()
    await ops.set(orphanRemovalError: .refusedNonManagedWorktree(path: worktrees + "/orphan-a"))
    let model = AppModel(
        store: store, client: stubClient(), diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(),
        worktreeOps: ops, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster()
    )
    await model.load()

    let removed = await model.pruneOrphanedWorktrees()

    #expect(removed == 0)
    #expect(model.errorMessage?.contains("orphan-a") == true)
}

@Test @MainActor func startupExcludesTheManagedTreesFromBackups() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    let managedRoot = managedRootFixture()
    defer { try? FileManager.default.removeItem(atPath: managedRoot) }
    seed.managedRoot = managedRoot
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store, client: stubClient(), diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster()
    )
    await model.load()

    // The directory does not exist yet on a first launch, so the call has to create it.
    model.excludeManagedTreesFromBackups()

    let worktrees = WorktreeLayout.directory(managedRoot: managedRoot)
    let excluded = try URL(fileURLWithPath: worktrees).resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(excluded.isExcludedFromBackup == true)

    // The clone root must stay in the backup. It can hold a branch that exists nowhere else,
    // and excluding it would leave no copy of that work anywhere.
    let repos = managedRoot + "/repos"
    try FileManager.default.createDirectory(atPath: repos, withIntermediateDirectories: true)
    model.excludeManagedTreesFromBackups()
    let clones = try URL(fileURLWithPath: repos).resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(clones.isExcludedFromBackup != true, "clones must not be excluded from backups")
}

// MARK: - Gateway backend conformance

@MainActor
private func gatewayModel(_ store: ReviewStore) -> AppModel {
    AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
}

@Test @MainActor func theGatewaySnapshotProjectsAStoredPullRequest() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()

    let snapshot = model.snapshot()
    let projected = snapshot.sections.flatMap(\.items)

    #expect(projected.count == 1)
    #expect(projected.first?.number == 944)
    #expect(projected.first?.kind == .pr)
    #expect(projected.first?.author == "icellan")
    #expect(projected.first?.baseBranch == "main")
    #expect(snapshot.gatewayVersion == GatewayVersion.current)
}

@Test @MainActor func anEmptyQueueStillSendsEveryMacSection() throws {
    let model = gatewayModel(try ReviewStore(fileURL: tempStoreURL()))
    let sections = model.snapshot().sections

    #expect(sections.map(\.kind) == [.myWork, .reviewRequests, .issues])
    #expect(sections.allSatisfy { $0.items.isEmpty })
}

@Test @MainActor func somebodyElsesPullRequestLandsInReviewRequests() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()

    let sections = model.snapshot().sections

    #expect(sections.map { $0.items.map(\.id) } == [[], [sampleReviewID], []])
}

@Test @MainActor func myOwnPullRequestLandsInMyWork() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()
    model.setCurrentLoginForTesting("icellan")

    let sections = model.snapshot().sections

    #expect(sections.map { $0.items.map(\.id) } == [[sampleReviewID], [], []])
}

// The phone showed nearly every item under "Needs you": any item the agent had ever
// reviewed counted, because `claudeReviewedAt` never clears. Once you answer the agent's
// turn with your own review, the item asks for nothing and reads as parked.
@Test @MainActor func aReviewYouAnsweredAsksForNothingAndIsParked() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var reviewed = sampleReview()
    reviewed.claudeReviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
    reviewed.claudeLastCompletedAt = Date(timeIntervalSince1970: 1_800_000_000)
    reviewed.myLastReviewAt = Date(timeIntervalSince1970: 1_800_000_600)
    reviewed.myReviewState = .approved
    try await store.upsertItem(reviewed)
    let model = gatewayModel(store)
    await model.load()

    let projected = try #require(model.snapshot().sections.flatMap(\.items).first)

    #expect(projected.attentionReason == nil)
    #expect(projected.primaryCommand == nil)
    #expect(projected.isParked)
    #expect(!projected.signals.contains("agent"))
}

@Test @MainActor func aTurnYouHaveNotAnsweredStillAsksForYou() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var waiting = sampleReview()
    waiting.claudeReviewedAt = Date(timeIntervalSince1970: 1_800_000_000)
    waiting.claudeLastCompletedAt = Date(timeIntervalSince1970: 1_800_000_900)
    waiting.myLastReviewAt = Date(timeIntervalSince1970: 1_800_000_600)
    try await store.upsertItem(waiting)
    let model = gatewayModel(store)
    await model.load()

    let projected = try #require(model.snapshot().sections.flatMap(\.items).first)

    #expect(projected.attentionReason == "Agent is waiting for you")
    #expect(projected.signals.contains("agent"))
    #expect(!projected.isParked)
}

@Test @MainActor func theItemCarriesTheSameSignalsAndResourcesAsTheMacRow() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seeded = sampleReview()
    seeded.worktreePath = "/tmp/wt-944"
    try await store.upsertItem(seeded)
    let model = gatewayModel(store)
    await model.load()
    model.setClaudeStatusForTesting(.awaitingInput(since: Date(), lastVerdictSnippet: nil), for: sampleReviewID)
    model.webViewIsLive = { $0 == sampleReviewID }

    let projected = try #require(model.snapshot().sections.flatMap(\.items).first)
    let macFacts = model.sidebarFacts(for: seeded)

    #expect(projected.signals == ["needsInput"])
    #expect(projected.resources == ["worktree", "web"])
    #expect(macFacts.needsInput)
    #expect(macFacts.hasWorktree)
    #expect(macFacts.hasWebView)
    #expect(!macFacts.hasSession)
}

@Test @MainActor func aWorkingAgentShowsAsTheWorkingSignal() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()
    model.setClaudeStatusForTesting(.working, for: sampleReviewID)

    let projected = try #require(model.snapshot().sections.flatMap(\.items).first)

    #expect(projected.signals == ["working"])
}

@Test @MainActor func theListingCarriesTheMacSortHideParkedAndEveryPill() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.sidebarSort = .byAuthor
    seed.hideParked = true
    try await seedStore.updateSettings(seed)
    let model = gatewayModel(try ReviewStore(fileURL: url))
    await model.load()

    let listing = model.snapshot().listing

    #expect(listing.sort == "byAuthor")
    #expect(listing.hideParked)
    #expect(listing.signalFilters.map(\.key) == SignalFilter.ordered.map(\.key))
    #expect(listing.signalFilters.map(\.label) == SignalFilter.ordered.map(\.displayName))
    #expect(listing.resourceFilters.map(\.key) == ["worktree", "session", "web"])
    #expect(listing.sorts.map(\.key) == ["recent", "byStatus", "byAuthor", "byNumber"])
}

@Test @MainActor func aDisabledItemStaysIdleAndSaysSoOnTheWire() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seeded = sampleReview()
    seeded.disabled = true
    try await store.upsertItem(seeded)
    let model = gatewayModel(store)
    await model.load()

    let projected = try #require(model.snapshot().sections.flatMap(\.items).first)

    #expect(projected.isDisabled)
    #expect(projected.attentionReason == nil)
}

@Test @MainActor func aLimitedItemCarriesItsReasonAndPrimaryCommand() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seeded = sampleReview()
    seeded.agentLimitMessage = "5-hour limit reached"
    try await store.upsertItem(seeded)
    let model = gatewayModel(store)
    await model.load()

    let snapshot = model.snapshot()
    let projected = try #require(snapshot.sections.flatMap(\.items).first)

    #expect(projected.attentionReason == "Agent hit its usage limit")
    #expect(projected.primaryCommand == .clearAgentLimit(id: sampleReviewID))
    #expect(projected.badges.contains { $0.text == "Limit" && $0.tone == .red })
}

@Test @MainActor func aCommandForAnUnknownItemIsRejectedRatherThanIgnored() async throws {
    let model = gatewayModel(try ReviewStore(fileURL: tempStoreURL()))

    let result = await model.perform(.startSession(id: "nope#1", forceFresh: false))

    #expect(result.status == .rejected)
    #expect(result.message == "no such item")
}

@Test @MainActor func anUnknownPaneIsRejected() async throws {
    let model = gatewayModel(try ReviewStore(fileURL: tempStoreURL()))

    let result = await model.perform(.setPane(id: sampleReviewID, pane: "diff"))

    #expect(result.status == .rejected)
}

@Test @MainActor func anUnknownIssueStatusIsRejected() async throws {
    let model = gatewayModel(try ReviewStore(fileURL: tempStoreURL()))

    let result = await model.perform(.setIssueStatus(id: sampleReviewID, status: "banana"))

    #expect(result.status == .rejected)
}

@Test @MainActor func setLabelTravelsThroughTheGatewayOntoTheStoredItem() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()

    let result = await model.perform(.setLabel(id: sampleReviewID, label: "perf"))

    #expect(result.status == .accepted)
    #expect(model.reviews.first?.label == "perf")
    #expect(result.snapshot.sections.flatMap(\.items).first?.label == "perf")
}

@Test @MainActor func setDisabledTravelsThroughTheGatewayOntoTheStoredItem() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()

    let result = await model.perform(.setDisabled(id: sampleReviewID, disabled: true))

    #expect(result.status == .accepted)
    #expect(model.reviews.first?.disabled == true)
}

// MARK: - Transcript and prompt sending

@Test @MainActor func promptingIsRefusedUnlessTheUserTurnedItOn() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()

    let result = await model.perform(.sendPrompt(id: sampleReviewID, text: "carry on"))

    #expect(result.status == .rejected)
    #expect(result.message?.contains("off") == true)
}

@Test @MainActor func promptingWithNoLiveSessionIsRefusedEvenWhenAllowed() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()
    var settings = model.settings
    settings.gatewayAllowPrompts = true
    await model.updateSettings(settings)

    let result = await model.perform(.sendPrompt(id: sampleReviewID, text: "carry on"))

    #expect(result.status == .rejected)
    #expect(result.message?.contains("no live session") == true)
}

@Test @MainActor func anEmptyPromptIsRefusedRatherThanSubmittingABareReturn() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()
    var settings = model.settings
    settings.gatewayAllowPrompts = true
    await model.updateSettings(settings)

    let result = await model.perform(.sendPrompt(id: sampleReviewID, text: "   \n  "))

    #expect(result.status == .rejected)
    #expect(result.message == "nothing to send")
}

@Test @MainActor func aTranscriptForAnUnknownItemIsUnavailableRatherThanEmpty() async throws {
    let model = gatewayModel(try ReviewStore(fileURL: tempStoreURL()))

    let transcript = model.transcript(for: "nope#1", limit: 50)

    #expect(transcript.available == false)
    #expect(transcript.note == "no such item")
    #expect(transcript.turns.isEmpty)
}

@Test @MainActor func anItemWithNoWorktreeSaysSoRatherThanShowingNothing() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()

    let transcript = model.transcript(for: sampleReviewID, limit: 50)

    #expect(transcript.available == false)
    #expect(transcript.note?.contains("no worktree") == true)
}

@Test @MainActor func handingOverToTheSameAgentExplainsWhyItCannot() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()
    var settings = model.settings
    // Default agent and failover agent the same: an account cannot rescue itself.
    settings.failoverAgent = settings.defaultAgent
    await model.updateSettings(settings)

    let result = await model.perform(.handOver(id: sampleReviewID))

    #expect(result.status == .rejected)
    #expect(result.message?.contains("already runs on") == true)
    #expect(result.message?.contains("Settings") == true)
}

@Test @MainActor func handingOverAnItemWithNoWorktreeSaysSo() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = gatewayModel(store)
    await model.load()
    var settings = model.settings
    settings.defaultAgent = .claudeCode
    settings.failoverAgent = .codex
    await model.updateSettings(settings)

    let result = await model.perform(.handOver(id: sampleReviewID))

    #expect(result.status == .rejected)
    #expect(result.message?.contains("no worktree") == true)
}

@Test @MainActor func handingOverAnUnknownItemIsRejected() async throws {
    let model = gatewayModel(try ReviewStore(fileURL: tempStoreURL()))

    let result = await model.perform(.handOver(id: "nope#1"))

    #expect(result.status == .rejected)
    #expect(result.message == "no such item")
}

@Test @MainActor func aNewerUpdateStampBumpsTheItemsChangeTickOnce() async throws {
    func hit(_ stamp: String) -> String {
        sampleSearchHitJSON.replacingOccurrences(
            of: "\"isDraft\": false,",
            with: "\"isDraft\": false,\n    \"updatedAt\": \"\(stamp)\","
        )
    }
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    seed.issuesEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: hit("2026-10-28T09:00:00Z"), standardError: ""),
        CommandResult(exitCode: 0, standardOutput: hit("2026-10-28T09:00:00Z"), standardError: ""),
        CommandResult(exitCode: 0, standardOutput: hit("2026-10-28T10:00:00Z"), standardError: ""),
        CommandResult(exitCode: 0, standardOutput: hit("2026-10-28T10:00:00Z"), standardError: "")
    ])
    let model = AppModel(
        store: store,
        client: GitHubClient(runner: runner, ghPath: "gh"),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    let id = try #require(model.reviews.first?.id)

    await model.discoverNow()
    #expect(model.remoteChangeTicks[id] == nil)

    await model.discoverNow()
    #expect(model.remoteChangeTicks[id] == nil)

    await model.discoverNow()
    #expect(model.remoteChangeTicks[id] == 1)

    await model.discoverNow()
    #expect(model.remoteChangeTicks[id] == 1)
}

private func askedQuestion(_ text: String) -> AskedQuestion {
    AskedQuestion(
        question: text,
        header: "Q",
        multiSelect: false,
        options: [.init(label: "Skip", detail: "")]
    )
}

@Test @MainActor func interruptedQuestionsAppearAndSettleOnTypedPrompt() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureAgentSession(for: review)
    let question = askedQuestion("How to post?")

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, interruptedQuestions: [question])
    #expect(model.unansweredQuestions[review.id] == [question])

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: "No response requested.")
    #expect(model.unansweredQuestions[review.id] == [question])

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, questionsSettled: true)
    #expect(model.unansweredQuestions[review.id] == nil)
}

@Test @MainActor func dismissingOneQuestionKeepsTheOthers() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureAgentSession(for: review)
    let first = askedQuestion("First?")
    let second = askedQuestion("Second?")
    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, interruptedQuestions: [first, second])

    model.removeUnansweredQuestion(first, for: review.id)
    #expect(model.unansweredQuestions[review.id] == [second])

    model.removeUnansweredQuestion(second, for: review.id)
    #expect(model.unansweredQuestions[review.id] == nil)
}

@Test @MainActor func terminatingTheSessionDropsItsQuestions() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureAgentSession(for: review)
    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: nil, interruptedQuestions: [askedQuestion("Q?")])

    model.terminateAgentSession(for: review.id)

    #expect(model.unansweredQuestions[review.id] == nil)
}

private func trailItem(_ number: Int) -> WorkItem {
    WorkItem(
        title: "trail \(number)",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        headBranch: "trail-\(number)",
        prRef: PRRef(
            owner: "o", repo: "r", number: number,
            url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            authorLogin: "a"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@MainActor private func trailModel(at url: URL, seed: [WorkItem] = []) async throws -> AppModel {
    let store = try ReviewStore(fileURL: url)
    for item in seed { try await store.upsertItem(item) }
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    return model
}

@Test @MainActor func openedTicketsEnterTheTrailNewestFirst() async throws {
    let a = trailItem(1), b = trailItem(2)
    let model = try await trailModel(at: tempStoreURL(), seed: [a, b])
    let t1 = Date(timeIntervalSince1970: 1_800_000_000)
    let t2 = Date(timeIntervalSince1970: 1_800_000_060)

    await model.markReviewOpened(a.id, now: t1)
    await model.markReviewOpened(b.id, now: t2)

    #expect(model.recentItems.map(\.id) == [b.id, a.id])
    #expect(model.recentItems[0].visitedAt == t2)
}

@Test @MainActor func reopenedTicketMovesToTheTopOnce() async throws {
    let a = trailItem(1), b = trailItem(2)
    let model = try await trailModel(at: tempStoreURL(), seed: [a, b])

    await model.markReviewOpened(a.id)
    await model.markReviewOpened(b.id)
    await model.markReviewOpened(a.id)

    #expect(model.recentItems.map(\.id) == [a.id, b.id])
}

@Test @MainActor func unknownTicketRecordsNothing() async throws {
    let model = try await trailModel(at: tempStoreURL())

    await model.markReviewOpened("nope")

    #expect(model.recentTrail.entries.isEmpty)
}

@Test @MainActor func removedTicketLeavesTheTrail() async throws {
    let a = trailItem(1), b = trailItem(2)
    let model = try await trailModel(at: tempStoreURL(), seed: [a, b])
    await model.markReviewOpened(a.id)
    await model.markReviewOpened(b.id)

    await model.removeReview(id: b.id)

    #expect(model.recentItems.map(\.id) == [a.id])

    await model.markReviewOpened(a.id)

    #expect(model.recentTrail.entries.map(\.itemID) == [a.id])
}

@Test @MainActor func trailSurvivesAReload() async throws {
    let url = tempStoreURL()
    let a = trailItem(1), b = trailItem(2)
    let model = try await trailModel(at: url, seed: [a, b])
    await model.markReviewOpened(a.id)
    await model.markReviewOpened(b.id)

    let reloaded = try await trailModel(at: url)

    #expect(reloaded.recentItems.map(\.id) == [b.id, a.id])
}

@Test @MainActor func loadPrunesTicketsThatAreGone() async throws {
    let url = tempStoreURL()
    let a = trailItem(1)
    let seedStore = try ReviewStore(fileURL: url)
    var stored = RecentTrail()
    stored.visit("gone", at: Date(timeIntervalSince1970: 1))
    stored.visit(a.id, at: Date(timeIntervalSince1970: 2))
    try await seedStore.updateRecentTrail(stored)

    let model = try await trailModel(at: url, seed: [a])

    #expect(model.recentTrail.entries.map(\.itemID) == [a.id])
    let persisted = await (try ReviewStore(fileURL: url)).recentTrail()

    #expect(persisted.entries.map(\.itemID) == [a.id])
}

@Test @MainActor func ticketSelectedAtLoadEntersTheTrail() async throws {
    let url = tempStoreURL()
    let a = trailItem(1)
    let model = try await trailModel(at: url, seed: [a])

    #expect(model.selection == a.id)
    #expect(model.recentTrail.entries.map(\.itemID) == [a.id])

    await model.load()

    #expect(model.recentTrail.entries.map(\.itemID) == [a.id])
}

@Test @MainActor func tabChangeShowsInTheTrailLabel() async throws {
    let a = trailItem(1)
    let model = try await trailModel(at: tempStoreURL(), seed: [a])
    await model.markReviewOpened(a.id)

    await model.setPane(.claude, for: a.id)

    #expect(trailTabLabel(for: model.recentItems[0].item, defaultAgent: .claudeCode) == "Claude Code")

    await model.setPane(.github, for: a.id)

    #expect(trailTabLabel(for: model.recentItems[0].item, defaultAgent: .claudeCode) == "GitHub")
}

@Test @MainActor func jumpSelectsALiveTicketAndIgnoresADeadOne() async throws {
    let a = trailItem(1), b = trailItem(2)
    let model = try await trailModel(at: tempStoreURL(), seed: [a, b])

    model.jump(to: b.id)

    #expect(model.selection == b.id)

    model.jump(to: "gone")

    #expect(model.selection == b.id)
}


private func myPR(_ number: Int, id: String = UUID().uuidString) -> WorkItem {
    WorkItem(
        id: id,
        title: "mine \(number)",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        headBranch: "mine-\(number)",
        prRef: PRRef(
            owner: "o", repo: "r", number: number,
            url: URL(string: "https://github.com/o/r/pull/\(number)")!,
            authorLogin: "me"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func redCI(head: String) -> PRStatus {
    PRStatus(ci: .failing, mergeState: .clean, readiness: .reviewRequired, headOID: head, failedChecks: ["build"])
}

@MainActor private func coordinatorModel(
    at url: URL,
    seed: [WorkItem] = [],
    poster: StubNotificationPoster = StubNotificationPoster()
) async throws -> AppModel {
    let store = try ReviewStore(fileURL: url)
    for item in seed { try await store.upsertItem(item) }
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: poster)
    await model.load()
    model.setCurrentLoginForTesting("me")
    return model
}

@Test @MainActor func askPassNotifiesOncePerCauseAndStartsNothing() async throws {
    let poster = StubNotificationPoster()
    let item = myPR(1)
    let model = try await coordinatorModel(at: tempStoreURL(), seed: [item], poster: poster)
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)

    await model.runCoordinatorPass()
    await model.runCoordinatorPass()
    await poster.waitForNeedsYou(atLeast: 1)
    await poster.settle()

    #expect(await poster.needsYou.count == 1)
    #expect(await poster.needsYou[0].reviewID == item.id)
    #expect(await poster.needsYou[0].body.contains("CI red: build"))
    #expect(model.nextUpRows.map(\.itemID) == [item.id])
    #expect(model.claudeSessions.isEmpty)
}

@Test @MainActor func newHeadCommitNotifiesAgain() async throws {
    let poster = StubNotificationPoster()
    let item = myPR(1)
    let model = try await coordinatorModel(at: tempStoreURL(), seed: [item], poster: poster)
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)
    await model.runCoordinatorPass()

    model.setPRStatusForTesting(redCI(head: "h2"), for: item.id)
    await model.runCoordinatorPass()
    await poster.waitForNeedsYou(atLeast: 2)

    #expect(await poster.needsYou.count == 2)
}

@Test @MainActor func disabledNotificationsPostNothingButTheRowStaysAndTheCauseIsSpent() async throws {
    let poster = StubNotificationPoster()
    let item = myPR(1)
    let model = try await coordinatorModel(at: tempStoreURL(), seed: [item], poster: poster)
    var quiet = model.settings
    quiet.notificationsEnabled = false
    await model.updateSettings(quiet)
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)

    await model.runCoordinatorPass()
    await poster.settle()

    #expect(await poster.needsYou.isEmpty)
    #expect(model.nextUpRows.count == 1)

    var loud = model.settings
    loud.notificationsEnabled = true
    await model.updateSettings(loud)
    await model.runCoordinatorPass()
    await poster.settle()

    #expect(await poster.needsYou.isEmpty)
}

@Test @MainActor func handledCausesSurviveAReload() async throws {
    let url = tempStoreURL()
    let item = myPR(1)
    let first = StubNotificationPoster()
    let model = try await coordinatorModel(at: url, seed: [item], poster: first)
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)
    await model.runCoordinatorPass()
    await first.waitForNeedsYou(atLeast: 1)

    let second = StubNotificationPoster()
    let reloaded = try await coordinatorModel(at: url, poster: second)
    reloaded.setPRStatusForTesting(redCI(head: "h1"), for: item.id)
    await reloaded.runCoordinatorPass()
    await second.settle()

    #expect(await first.needsYou.count == 1)
    #expect(await second.needsYou.isEmpty)
}

@Test @MainActor func causesOfRemovedTicketsArePruned() async throws {
    let url = tempStoreURL()
    let item = myPR(1)
    let model = try await coordinatorModel(at: url, seed: [item])
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)
    await model.runCoordinatorPass()
    #expect(model.handledCauses.count == 1)

    await model.removeReview(id: item.id)
    await model.runCoordinatorPass()

    #expect(model.handledCauses.isEmpty)
    #expect(await (try ReviewStore(fileURL: url)).handledCauses().isEmpty)
}

@Test @MainActor func waitingAgentNotifiesAsCaseTwo() async throws {
    let poster = StubNotificationPoster()
    let item = myPR(1)
    let model = try await coordinatorModel(at: tempStoreURL(), seed: [item], poster: poster)
    model.setClaudeStatusForTesting(.awaitingInput(since: Date(timeIntervalSince1970: 1_800_000_000), lastVerdictSnippet: nil), for: item.id)

    await model.runCoordinatorPass()
    await poster.waitForNeedsYou(atLeast: 1)

    #expect(model.nextUpRows.first?.kase == .sessionWaits)
    #expect(await poster.needsYou.first?.body.contains("Agent waits for your answer") == true)
}

@Test @MainActor func issueCoveredByAPRGivesNoRow() async throws {
    var pr = myPR(1)
    pr.closingIssueNumber = 7
    let issue = WorkItem(
        title: "issue 7", repoKey: "github.com/o/r", baseBranch: "main",
        issueRef: IssueRef(owner: "o", repo: "r", number: 7, url: URL(string: "https://github.com/o/r/issues/7")!, authorLogin: "x"),
        prState: .open, origin: .added, addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let model = try await coordinatorModel(at: tempStoreURL(), seed: [pr, issue])
    model.setClaudeStatusForTesting(.awaitingInput(since: Date(timeIntervalSince1970: 1_800_000_000), lastVerdictSnippet: nil), for: issue.id)

    await model.runCoordinatorPass()

    #expect(model.nextUpRows.isEmpty)
}


private func withWorktree(_ item: WorkItem) -> WorkItem {
    var copy = item
    copy.worktreePath = "/tmp/wt"
    return copy
}

private func reviewRequest(_ number: Int) -> WorkItem {
    var item = myPR(number)
    item.prRef?.authorLogin = "alice"
    return item
}

private func rowFor(_ item: WorkItem, _ kase: NextUpCase, step: NextUpStep) -> NextUpRow {
    NextUpRow(itemID: item.id, kase: kase, reason: "r", step: step, since: Date(), trigger: "h1")
}

@MainActor private func stepModel(
    seed: [WorkItem],
    ops: StubWorktreeOps = StubWorktreeOps(),
    worktreePath: String = "/tmp/wt"
) async throws -> AppModel {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for item in seed { try await store.upsertItem(item) }
    let provider = StubWorktreeProvider(result: WorktreeReady(clonePath: "/tmp/clone", worktreePath: worktreePath, remoteName: "origin"))
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: provider, cloneRegistrar: StubRegistrar(), worktreeOps: ops, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    model.setCurrentLoginForTesting("me")
    return model
}

@Test @MainActor func startReviewUsesTheExistingSessionStartWithNoDenyRules() async throws {
    let item = reviewRequest(1)
    let model = try await stepModel(seed: [item])

    let result = await model.performStep(.startReview, row: rowFor(item, .reviewRequested, step: .startReview), auto: true)

    let arguments = model.claudeSessions[item.id]?.spec.arguments ?? []
    #expect(result == .done("Started the review session"))
    #expect(arguments.contains("/review https://github.com/o/r/pull/1"))
    #expect(!arguments.contains("--disallowedTools"))
    #expect(model.hasAutoLimits(item.id) == false)
}

@Test @MainActor func startFixRendersTheTemplateWithChecksAndBase() async throws {
    let item = myPR(2)
    let model = try await stepModel(seed: [item])
    model.setPRStatusForTesting(PRStatus(ci: .failing, mergeState: .clean, readiness: .none, headOID: "h1", failedChecks: ["build", "lint"]), for: item.id)

    let result = await model.performStep(.startFix, row: rowFor(item, .ciRed, step: .startFix), auto: false)

    let arguments = model.claudeSessions[item.id]?.spec.arguments ?? []
    #expect(result == .done("Started a fix session"))
    #expect(arguments.contains { $0.contains("build, lint") && $0.contains("--force-with-lease") })
}

@Test @MainActor func conflictFixPromptNamesTheBaseBranch() async throws {
    let item = myPR(3)
    let model = try await stepModel(seed: [item])

    _ = await model.performStep(.startFix, row: rowFor(item, .conflict, step: .startFix), auto: false)

    #expect((model.claudeSessions[item.id]?.spec.arguments ?? []).contains { $0.contains("conflicts with main") })
}

@Test @MainActor func autoFixLaunchCarriesTheDenyRulesAndTheBadge() async throws {
    let item = myPR(4)
    let model = try await stepModel(seed: [item])

    _ = await model.performStep(.startFix, row: rowFor(item, .ciRed, step: .startFix), auto: true)

    let arguments = model.claudeSessions[item.id]?.spec.arguments ?? []
    #expect(arguments.first == "--disallowedTools")
    #expect(arguments.dropFirst().first == DenyRules.autoFix.joined(separator: ","))
    #expect(model.hasAutoLimits(item.id))
}

@Test @MainActor func userFixClickCarriesNoDenyRules() async throws {
    let item = myPR(5)
    let model = try await stepModel(seed: [item])

    _ = await model.performStep(.startFix, row: rowFor(item, .ciRed, step: .startFix), auto: false)

    let arguments = model.claudeSessions[item.id]?.spec.arguments ?? []
    #expect(!arguments.isEmpty)
    #expect(!arguments.contains("--disallowedTools"))
    #expect(model.hasAutoLimits(item.id) == false)
}

@Test @MainActor func idleLiveSessionRestartsWithResumeAndRulesThenReceivesThePrompt() async throws {
    let item = myPR(6)
    let worktree = "/tmp/wt-\(UUID().uuidString)"
    let model = try await stepModel(seed: [item], worktreePath: worktree)
    await model.ensureAgentSession(for: item)
    let firstSession = model.claudeSessions[item.id]
    let sessionID = model.reviews.first { $0.id == item.id }?.claudeSessionID
    #expect(firstSession != nil)
    #expect(sessionID != nil)

    let transcriptDirectory = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: worktree)
    try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: transcriptDirectory.appendingPathComponent("\(sessionID ?? "").jsonl"))
    defer { try? FileManager.default.removeItem(at: transcriptDirectory) }

    let result = await model.performStep(.startFix, row: rowFor(item, .ciRed, step: .startFix), auto: true)

    let arguments = model.claudeSessions[item.id]?.spec.arguments ?? []
    #expect(result == .done("Restarted the session with limits and sent the fix prompt"))
    #expect(model.claudeSessions[item.id] !== firstSession)
    #expect(arguments.first == "--disallowedTools")
    #expect(arguments.contains("--resume"))
    #expect(model.lastStepPrompt[item.id]?.contains("--force-with-lease") == true)
}

@Test @MainActor func userFixClickSendsToALiveSessionWithoutRestarting() async throws {
    let item = myPR(7)
    let model = try await stepModel(seed: [item])
    await model.ensureAgentSession(for: item)
    let firstSession = model.claudeSessions[item.id]

    let result = await model.performStep(.startFix, row: rowFor(item, .ciRed, step: .startFix), auto: false)

    #expect(result == .done("Sent the fix prompt to the live session"))
    #expect(model.claudeSessions[item.id] === firstSession)
    #expect(model.lastStepPrompt[item.id] != nil)
}

@Test @MainActor func rebaseThenPushesWithForceWhenTheBranchDiverged() async throws {
    let ops = StubWorktreeOps()
    await ops.set(currentBranchResult: "mine-8")
    await ops.set(aheadBehindByUpstream: ["origin/mine-8": (ahead: 3, behind: 2)])
    let item = withWorktree(myPR(8))
    let model = try await stepModel(seed: [item], ops: ops)

    let result = await model.performStep(.rebase, row: rowFor(item, .behind, step: .rebase), auto: true)

    #expect(result == .done("Rebased and pushed"))
    #expect(await ops.recordedPushCalls.count == 1)
    #expect(await ops.recordedPushCalls.first?.force == true)
}

@Test @MainActor func rebaseThatChangesNothingPushesNothing() async throws {
    let ops = StubWorktreeOps()
    await ops.set(currentBranchResult: "mine-9")
    let item = withWorktree(myPR(9))
    let model = try await stepModel(seed: [item], ops: ops)

    let result = await model.performStep(.rebase, row: rowFor(item, .behind, step: .rebase), auto: true)

    #expect(result == .done("Rebased; nothing to push"))
    #expect(await ops.recordedPushCalls.isEmpty)
}

@Test @MainActor func conflictingRebaseAbortsAndBecomesTheConflictCase() async throws {
    let ops = StubWorktreeOps()
    await ops.set(rebaseResult: .conflicts(["a.go", "b.go"]))
    let item = withWorktree(myPR(10))
    let model = try await stepModel(seed: [item], ops: ops)
    model.setPRStatusForTesting(PRStatus(ci: .passing, mergeState: .behind, readiness: .reviewRequired, headOID: "h1"), for: item.id)

    let result = await model.performStep(.rebase, row: rowFor(item, .behind, step: .rebase), auto: true)
    await model.runCoordinatorPass()

    #expect(result == .failed("Rebase stopped on 2 conflicting files and was aborted"))
    #expect(await ops.abortedRebases == 1)
    #expect(await ops.recordedPushCalls.isEmpty)
    #expect(model.rebaseStates[item.id] == nil)
    #expect(model.nextUpRows.first?.kase == .conflict)
}

@Test @MainActor func rebaseWithoutAWorktreeFailsCleanly() async throws {
    let item = myPR(11)
    let model = try await stepModel(seed: [item])

    let result = await model.performStep(.rebase, row: rowFor(item, .behind, step: .rebase), auto: true)

    #expect(result == .failed("No worktree to rebase"))
}

@Test @MainActor func continueSelectsTheTicketAndOpensItsAgentTab() async throws {
    let item = myPR(12)
    let model = try await stepModel(seed: [item])

    let result = await model.performStep(.continueWork, row: rowFor(item, .issueInProgress, step: .continueWork), auto: false)
    await model.waitForPendingItemEdits()

    #expect(result == .done("Opened the agent tab"))
    #expect(model.selection == item.id)
    #expect(model.reviews.first { $0.id == item.id }?.lastPane == .claude)
}

@Test @MainActor func openOnReadyToMergeSelectsTheGitHubTabAndOtherOpensKeepTheTab() async throws {
    let ready = myPR(13)
    let waiting = myPR(14)
    let model = try await stepModel(seed: [ready, waiting])

    _ = await model.performStep(.open, row: rowFor(ready, .readyToMerge, step: .open), auto: false)
    _ = await model.performStep(.open, row: rowFor(waiting, .sessionWaits, step: .open), auto: false)
    await model.waitForPendingItemEdits()

    #expect(model.reviews.first { $0.id == ready.id }?.lastPane == .github)
    #expect(model.reviews.first { $0.id == waiting.id }?.lastPane == nil)
    #expect(model.selection == waiting.id)
}

@Test @MainActor func ciFixPromptSaysHowToFindChecksWhenNoneAreListed() async throws {
    let item = myPR(15)
    let model = try await stepModel(seed: [item])

    _ = await model.performStep(.startFix, row: rowFor(item, .ciRed, step: .startFix), auto: false)

    let arguments = model.claudeSessions[item.id]?.spec.arguments ?? []
    #expect(arguments.contains { $0.contains("gh pr checks") })
    #expect(!arguments.contains { $0.contains("checks are: .") })
}

@MainActor private func autoModel(
    seed: [WorkItem],
    ops: StubWorktreeOps = StubWorktreeOps(),
    cap: Int = 5,
    url: URL = tempStoreURL(),
    poster: StubNotificationPoster = StubNotificationPoster()
) async throws -> AppModel {
    let store = try ReviewStore(fileURL: url)
    for item in seed { try await store.upsertItem(item) }
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: ops, claudePath: "/usr/bin/true", notificationPoster: poster)
    await model.load()
    model.setCurrentLoginForTesting("me")
    var settings = model.settings
    settings.coordinatorAuto = true
    settings.maxLiveAgentSessions = cap
    await model.updateSettings(settings)
    return model
}

@Test @MainActor func autoPassStartsTheStepAndLogsIt() async throws {
    let poster = StubNotificationPoster()
    let item = withWorktree(myPR(20))
    let model = try await autoModel(seed: [item], poster: poster)
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)

    await model.runCoordinatorPass()
    await poster.settle()

    let arguments = model.claudeSessions[item.id]?.spec.arguments ?? []
    #expect(arguments.first == "--disallowedTools")
    #expect(model.autoLog.count == 1)
    #expect(model.autoLog[0].action == "Start fix")
    #expect(model.autoLog[0].result == "Started a fix session")
    #expect(model.autoLog[0].kase == .ciRed)
    #expect(model.handledCauses.values.contains(.acted))
    #expect(await poster.needsYou.isEmpty)
}

@Test @MainActor func autoWaitsWhenTheSessionCapIsFullAndNeverEvicts() async throws {
    let busy = withWorktree(myPR(21))
    let waiting = withWorktree(myPR(22))
    let model = try await autoModel(seed: [busy, waiting], cap: 1)
    await model.ensureAgentSession(for: busy)
    let liveSession = model.claudeSessions[busy.id]
    model.setPRStatusForTesting(redCI(head: "h1"), for: waiting.id)

    await model.runCoordinatorPass()

    #expect(model.claudeSessions[waiting.id] == nil)
    #expect(model.claudeSessions[busy.id] === liveSession)
    #expect(model.handledCauses.isEmpty)
    #expect(model.autoLog.isEmpty)
}

@Test @MainActor func twoRowsOneSlotTheLowerRankWinsAndTheOtherStaysUnhandled() async throws {
    let review = withWorktree(reviewRequest(23))
    let red = withWorktree(myPR(24))
    let model = try await autoModel(seed: [review, red], cap: 1)
    model.setPRStatusForTesting(redCI(head: "h1"), for: red.id)

    await model.runCoordinatorPass()

    #expect(model.claudeSessions[review.id] != nil)
    #expect(model.claudeSessions[red.id] == nil)
    #expect(model.handledCauses.count == 1)
    #expect(model.autoLog.map(\.kase) == [.reviewRequested])
}

@Test @MainActor func autoSkipsATicketWithUncommittedChangesAndSaysWhy() async throws {
    let ops = StubWorktreeOps()
    await ops.set(localChangesResult: ["a.go"])
    let item = withWorktree(myPR(25))
    let model = try await autoModel(seed: [item], ops: ops)
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)

    await model.runCoordinatorPass()
    await model.runCoordinatorPass()

    #expect(model.claudeSessions[item.id] == nil)
    #expect(model.handledCauses.isEmpty)
    #expect(model.autoLog.count == 1)
    #expect(model.autoLog[0].result == "Skipped: uncommitted changes in the worktree")
}

@Test @MainActor func autoSkipsATicketWithNoWorktreeOrCloneAndSaysWhyOnce() async throws {
    let item = myPR(26)
    let model = try await autoModel(seed: [item])
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)

    await model.runCoordinatorPass()
    await model.runCoordinatorPass()

    #expect(model.claudeSessions[item.id] == nil)
    #expect(model.autoLog.count == 1)
    #expect(model.autoLog[0].result == "Skipped: no worktree and no registered clone")
}

@Test @MainActor func aWorkingAgentGivesNoRowSoAutoLoadAndAutoDoNotDoubleStart() async throws {
    let item = withWorktree(myPR(27))
    let model = try await autoModel(seed: [item])
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)
    model.setClaudeStatusForTesting(.working, for: item.id)

    await model.runCoordinatorPass()

    #expect(model.nextUpRows.isEmpty)
    #expect(model.autoLog.isEmpty)
}

@Test @MainActor func fixThatDoesNotClearNotifiesOnceThenStops() async throws {
    let poster = StubNotificationPoster()
    let item = withWorktree(myPR(28))
    let model = try await autoModel(seed: [item], poster: poster)
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)
    await model.runCoordinatorPass()
    let session = model.claudeSessions[item.id]
    #expect(session != nil)

    model.setClaudeStatusForTesting(.awaitingInput(since: Date(timeIntervalSince1970: 1_800_000_000), lastVerdictSnippet: nil), for: item.id)
    await model.runCoordinatorPass()
    await model.runCoordinatorPass()
    await poster.settle()

    let bodies = await poster.needsYou.map(\.body)
    #expect(bodies.filter { $0.contains("AUTO fix did not clear") }.count == 1)
    #expect(model.handledCauses.values.contains(.failureNotified))
    #expect(model.claudeSessions[item.id] === session)
    #expect(model.autoLog.count == 1)
}

@Test @MainActor func autoOnlyNotifiesForReadyToMergeAndNeverPushesOrMerges() async throws {
    let poster = StubNotificationPoster()
    let ops = StubWorktreeOps()
    let item = withWorktree(myPR(29))
    let model = try await autoModel(seed: [item], ops: ops, poster: poster)
    model.setPRStatusForTesting(PRStatus(ci: .passing, mergeState: .clean, readiness: .approved, headOID: "h1"), for: item.id)

    await model.runCoordinatorPass()
    await poster.waitForNeedsYou(atLeast: 1)

    #expect(model.nextUpRows.first?.kase == .readyToMerge)
    #expect(await poster.needsYou.first?.body.contains("ready to merge") == true)
    #expect(model.claudeSessions.isEmpty)
    #expect(await ops.recordedPushCalls.isEmpty)
    #expect(model.autoLog.isEmpty)
}

@Test @MainActor func autoRebasesABehindPRAndPushes() async throws {
    let ops = StubWorktreeOps()
    await ops.set(currentBranchResult: "mine-30")
    await ops.set(aheadBehindByUpstream: ["origin/mine-30": (ahead: 2, behind: 2)])
    let item = withWorktree(myPR(30))
    let model = try await autoModel(seed: [item], ops: ops)
    model.setPRStatusForTesting(PRStatus(ci: .passing, mergeState: .behind, readiness: .reviewRequired, headOID: "h1"), for: item.id)

    await model.runCoordinatorPass()

    #expect(await ops.recordedPushCalls.count == 1)
    #expect(model.autoLog.first?.action == "Rebase and push")
    #expect(model.autoLog.first?.result == "Rebased and pushed")
}

@Test @MainActor func autoLogAndCausesSurviveAReload() async throws {
    let url = tempStoreURL()
    let item = withWorktree(myPR(31))
    let model = try await autoModel(seed: [item], url: url)
    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)
    await model.runCoordinatorPass()

    let reloaded = try await autoModel(seed: [], url: url)

    #expect(reloaded.autoLog.count == 1)
    #expect(reloaded.handledCauses.count == 1)
}

@MainActor private func stateObject(_ model: AppModel) throws -> [String: Any] {
    let data = try model.coordinatorState(now: Date(timeIntervalSince1970: 1_800_000_000)).jsonData()

    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private func tickets(_ object: [String: Any]) -> [[String: Any]] {
    object["tickets"] as! [[String: Any]]
}

@Test @MainActor func stateJSONHoldsEveryFieldForAPR() async throws {
    let item = withWorktree(myPR(40))
    let model = try await stepModel(seed: [item])
    model.setPRStatusForTesting(
        PRStatus(
            ci: .failing, mergeState: .behind, readiness: .changesRequested, unresolvedThreads: 2,
            threadsAwaitingMe: 1, changeRequests: ChangeRequestTally(current: 1, outdated: 0),
            headOID: "h1", failedChecks: ["build", "lint"]
        ),
        for: item.id
    )

    let ticket = tickets(try stateObject(model))[0]

    #expect(ticket["id"] as? String == item.id)
    #expect(ticket["number"] as? Int == 40)
    #expect(ticket["title"] as? String == "mine 40")
    #expect(ticket["url"] as? String == "https://github.com/o/r/pull/40")
    #expect(ticket["repo"] as? String == "o/r")
    #expect(ticket["kind"] as? String == "pr")
    #expect(ticket["author"] as? String == "me")
    #expect(ticket["headBranch"] as? String == "mine-40")
    #expect(ticket["baseBranch"] as? String == "main")
    #expect(ticket["boardColumn"] as? String == "inProgress")
    #expect((ticket["nextUp"] as? [String: Any])?["case"] as? String == "ciRed")
    #expect((ticket["nextUp"] as? [String: Any])?["reason"] as? String == "CI red: build, lint")
    #expect(ticket["ci"] as? String == "failing")
    #expect(ticket["failedChecks"] as? [String] == ["build", "lint"])
    #expect(ticket["mergeState"] as? String == "behind")
    #expect(ticket["reviewReadiness"] as? String == "changesRequested")
    #expect(ticket["readyToMerge"] as? Bool == false)
    #expect(ticket["unresolvedThreads"] as? Int == 2)
    #expect(ticket["threadsAwaitingMe"] as? Int == 1)
    #expect(ticket["changeRequestsCurrent"] as? Int == 1)
    #expect(ticket["agentStatus"] as? String == "none")
    #expect(ticket["worktreePath"] as? String == "/tmp/wt")
    #expect(ticket["disabled"] as? Bool == false)
}

@Test @MainActor func stateJSONHoldsTheFieldsForAnIssue() async throws {
    let issue = WorkItem(
        title: "bug", repoKey: "github.com/o/r", baseBranch: "main",
        issueRef: IssueRef(owner: "o", repo: "r", number: 7, url: URL(string: "https://github.com/o/r/issues/7")!, authorLogin: "x"),
        prState: .open, origin: .added, addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let model = try await stepModel(seed: [issue])
    model.setClaudeStatusForTesting(.idle(since: Date(timeIntervalSince1970: 1_799_990_000), lastVerdictSnippet: "tests pass"), for: issue.id)

    let ticket = tickets(try stateObject(model))[0]

    #expect(ticket["kind"] as? String == "issue")
    #expect(ticket["number"] as? Int == 7)
    #expect(ticket["author"] as? String == "x")
    #expect(ticket["url"] as? String == "https://github.com/o/r/issues/7")
    #expect(ticket["agentStatus"] as? String == "idle")
    #expect(ticket["lastVerdict"] as? String == "tests pass")
    #expect(ticket["ci"] == nil)
}

@Test @MainActor func stateJSONHoldsTheFieldsForATask() async throws {
    var task = WorkItem(
        title: "spike", repoKey: "github.com/o/r", baseBranch: "main", headBranch: "spike",
        origin: .added, addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    task.worktreePath = "/tmp/wt"
    let model = try await stepModel(seed: [task])

    let ticket = tickets(try stateObject(model))[0]

    #expect(ticket["kind"] as? String == "task")
    #expect(ticket["number"] == nil)
    #expect(ticket["headBranch"] as? String == "spike")
    #expect(ticket["worktreePath"] as? String == "/tmp/wt")
    #expect(ticket["boardColumn"] as? String == "inProgress")
}

@Test @MainActor func stateJSONLeavesOutMergedAndClosedTicketsAndCarriesTheAutoLog() async throws {
    var merged = myPR(41)
    merged.prState = .merged
    let live = withWorktree(myPR(42))
    let model = try await autoModel(seed: [merged, live])
    model.setPRStatusForTesting(redCI(head: "h1"), for: live.id)
    await model.runCoordinatorPass()

    let object = try stateObject(model)
    let log = object["autoLog"] as! [[String: Any]]

    #expect(tickets(object).map { $0["number"] as? Int } == [42])
    #expect(log.count == 1)
    #expect(log[0]["action"] as? String == "Start fix")
    #expect(object["generatedAt"] as? String == "2027-01-15T08:00:00Z")
}

@MainActor private func coordinatorAgentModel(
    seed: [WorkItem] = [],
    cap: Int = 5,
    agent: AgentKind = .claudeCode,
    root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("prpilot-coord-\(UUID().uuidString)", isDirectory: true),
    url: URL = tempStoreURL()
) async throws -> (AppModel, URL) {
    let store = try ReviewStore(fileURL: url)
    for item in seed { try await store.upsertItem(item) }
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    model.setCurrentLoginForTesting("me")
    var settings = model.settings
    settings.managedRoot = root.path
    settings.maxLiveAgentSessions = cap
    settings.defaultAgent = agent
    settings.piPath = "/usr/bin/true"
    await model.updateSettings(settings)
    return (model, root.appendingPathComponent("coordinator", isDirectory: true))
}

private func stateFile(_ directory: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("state.json"))) as! [String: Any]
}

@Test @MainActor func startWritesStateJsonAndLaunchesInTheCoordinatorDirectoryWithDenyRules() async throws {
    let item = withWorktree(myPR(50))
    let (model, directory) = try await coordinatorAgentModel(seed: [item])
    defer { model.terminateAllAgentSessions() }

    await model.startCoordinator()

    let spec = model.coordinatorSession?.spec
    #expect(spec?.cwd == directory.path)
    #expect(spec?.arguments.first == "--disallowedTools")
    #expect(spec?.arguments.dropFirst().first == DenyRules.coordinator.joined(separator: ","))
    #expect(spec?.arguments.last?.contains("state.json") == true)
    #expect((try stateFile(directory)["tickets"] as! [[String: Any]]).count == 1)
}

@Test @MainActor func coordinatorDoesNotCountAgainstTheSessionCapAndIsNotEvicted() async throws {
    let item = withWorktree(myPR(51))
    let (model, _) = try await coordinatorAgentModel(seed: [item], cap: 1)
    defer { model.terminateAllAgentSessions() }
    await model.startCoordinator()
    let coordinator = model.coordinatorSession

    await model.ensureAgentSession(for: item)
    model.enforceSessionBudget()

    #expect(model.claudeSessions.count == 1)
    #expect(model.claudeSessions[item.id] != nil)
    #expect(model.coordinatorSession === coordinator)
}

@Test @MainActor func coordinatorStopsAfterTenIdleMinutes() async throws {
    let (model, _) = try await coordinatorAgentModel()
    defer { model.terminateAllAgentSessions() }
    await model.startCoordinator()

    model.stopCoordinatorIfIdle(now: Date().addingTimeInterval(599))
    #expect(model.coordinatorSession != nil)

    model.stopCoordinatorIfIdle(now: Date().addingTimeInterval(601))
    #expect(model.coordinatorSession == nil)
}

@Test @MainActor func nextQuestionResumesTheSameConversation() async throws {
    let (model, directory) = try await coordinatorAgentModel()
    defer {
        model.terminateAllAgentSessions()
        try? FileManager.default.removeItem(at: AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: directory.path))
    }
    await model.startCoordinator()
    let firstArguments = model.coordinatorSession?.spec.arguments ?? []
    let sessionID = firstArguments.drop { $0 != "--session-id" }.dropFirst().first
    #expect(sessionID != nil)

    let transcripts = AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: directory.path)
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try Data("{}\n".utf8).write(to: transcripts.appendingPathComponent("\(sessionID ?? "").jsonl"))
    model.stopCoordinatorIfIdle(now: Date().addingTimeInterval(601))
    #expect(model.coordinatorSession == nil)

    await model.startCoordinator()

    let resumed = model.coordinatorSession?.spec.arguments ?? []
    #expect(resumed.contains("--resume"))
    #expect(resumed.contains(sessionID ?? "missing"))
    #expect(!resumed.contains { $0.contains("state.json") })
}

@Test @MainActor func refreshRewritesTheStateWhileTheSessionLives() async throws {
    let item = withWorktree(myPR(52))
    let (model, directory) = try await coordinatorAgentModel(seed: [item])
    defer { model.terminateAllAgentSessions() }
    await model.startCoordinator()
    #expect(((try stateFile(directory)["tickets"] as! [[String: Any]])[0]["ci"]) == nil)

    model.setPRStatusForTesting(redCI(head: "h1"), for: item.id)
    await model.runCoordinatorPass()

    #expect(((try stateFile(directory)["tickets"] as! [[String: Any]])[0]["ci"] as? String) == "failing")
}

@Test @MainActor func piCoordinatorLaunchCarriesTheRulesInThePromptOnly() async throws {
    let (model, _) = try await coordinatorAgentModel(agent: .pi)
    defer { model.terminateAllAgentSessions() }

    await model.startCoordinator()

    let arguments = model.coordinatorSession?.spec.arguments ?? []
    #expect(model.coordinatorSession != nil)
    #expect(!arguments.contains("--disallowedTools"))
    #expect(arguments.last?.contains("Never merge") == true)
}

@Test @MainActor func coordinatorSessionIDSurvivesAReload() async throws {
    let url = tempStoreURL()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("prpilot-coord-\(UUID().uuidString)", isDirectory: true)
    let (model, directory) = try await coordinatorAgentModel(root: root, url: url)
    defer {
        model.terminateAllAgentSessions()
        try? FileManager.default.removeItem(at: AgentTranscriptPath.directoryURL(for: .claudeCode, worktreePath: directory.path))
    }
    await model.startCoordinator()
    let sessionID = (model.coordinatorSession?.spec.arguments ?? []).drop { $0 != "--session-id" }.dropFirst().first

    #expect(await (try ReviewStore(fileURL: url)).coordinatorSessionIDs()["claudeCode"] == sessionID)
}

@Test @MainActor func firstFullRefreshBaselinesExistingRowsWithoutNotifying() async throws {
    let poster = StubNotificationPoster()
    let old = withWorktree(myPR(60))
    let fresh = withWorktree(myPR(61))
    let model = try await coordinatorModel(at: tempStoreURL(), seed: [old, fresh], poster: poster)
    model.setPRStatusForTesting(redCI(head: "h1"), for: old.id)

    await model.refreshReviewStates()
    await poster.settle()

    #expect(await poster.needsYou.isEmpty)
    #expect(model.nextUpRows.map(\.itemID) == [old.id])
    #expect(model.handledCauses.count == 1)

    model.setPRStatusForTesting(redCI(head: "h2"), for: fresh.id)
    await model.refreshReviewStates()
    await poster.waitForNeedsYou(atLeast: 1)

    #expect(await poster.needsYou.map(\.reviewID) == [fresh.id])
}

@Test @MainActor func baselineHappensOnlyOnceAcrossReloads() async throws {
    let url = tempStoreURL()
    let item = withWorktree(myPR(62))
    let first = try await coordinatorModel(at: url, seed: [item])
    first.setPRStatusForTesting(redCI(head: "h1"), for: item.id)
    await first.refreshReviewStates()

    let poster = StubNotificationPoster()
    let reloaded = try await coordinatorModel(at: url, poster: poster)
    reloaded.setPRStatusForTesting(redCI(head: "h2"), for: item.id)
    await reloaded.refreshReviewStates()
    await poster.waitForNeedsYou(atLeast: 1)

    #expect(await poster.needsYou.count == 1)
}
