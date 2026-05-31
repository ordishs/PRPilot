import Foundation
import PRPilotModels
import ReviewStore
import GitHubKit
import CommandSupport
import WorktreeKit
import DiffKit

public enum AppModelFactory {
    @MainActor
    public static func makeDefault() throws -> AppModel {
        let settings = Settings.default
        let storeURL = URL(fileURLWithPath: settings.managedRoot).appendingPathComponent("store.json")
        let store = try ReviewStore(fileURL: storeURL)

        let ghPath = settings.ghPath ?? ToolResolver.resolve("gh") ?? "/opt/homebrew/bin/gh"
        let gitPath = settings.gitPath ?? ToolResolver.resolve("git") ?? "/opt/homebrew/bin/git"
        let claudePath = settings.claudePath ?? ""

        let client = GitHubClient(runner: ProcessCommandRunner(), ghPath: ghPath)
        let worktreeManager = WorktreeManager(runner: ProcessCommandRunner(), gitPath: gitPath, managedRoot: settings.managedRoot)
        let worktreeProvider = WorktreeProvider(worktreeManager: worktreeManager)
        let diffService = DiffService(runner: ProcessCommandRunner(), gitPath: gitPath)
        let diffLoader = WorktreeDiffLoader(worktreeProvider: worktreeProvider, worktreeManager: worktreeManager, diffService: diffService)
        let cloneRegistrar = GitCloneRegistrar(runner: ProcessCommandRunner(), gitPath: gitPath)
        let notificationPoster = UserNotificationsPoster()

        return AppModel(
            store: store,
            client: client,
            diffLoader: diffLoader,
            worktreeProvider: worktreeProvider,
            cloneRegistrar: cloneRegistrar,
            claudePath: claudePath,
            notificationPoster: notificationPoster
        )
    }
}
