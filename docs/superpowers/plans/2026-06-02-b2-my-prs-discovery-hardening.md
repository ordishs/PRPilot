# B2 — My PRs Discovery + Discovery Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a second discovery query group (`author:@me`) so the user's own PRs surface (under My Work, already wired in B1.2), and harden discovery so an unscoped query can never again return a global firehose — via a `queryIsScoped` guard enforced at input (Settings warning + per-line "run anyway") and at execution (skip unscoped unless overridden), plus a 100-result circuit-breaker.

**Architecture:** Replace `Settings.discoveryQueries: [String]` with two ordered lists of a new `DiscoveryQuery {text, allowUnscoped}` value type — `reviewRequestQueries` and `myPRQueries` — each with a group-level enabled flag. `DiscoveryQuery.isScoped(_:)` is a pure, tested function in PRPilotModels. `AppModel.discoverNow` iterates both enabled groups, skips unscoped lines (unless `allowUnscoped`) and capped results, and exposes `discoveryWarnings` for the UI. The Settings Discovery tab becomes a structured editor (two groups, per-row text + scope warning + run-anyway toggle, group enable toggles). Categorisation of discovered My PRs into "My Work" already works (B1.1/B1.2 — `category(myLogin:)`).

**Scope (deferred, with reason):** Per the spec, B2 also listed *My-PR worktree-on-branch* and *auto-linking by branch*. Both are deferred: auto-linking has nothing to link until pre-PR **tasks** exist (B3), and worktree-on-branch is only exercised by **rebase/push** (B5). Building them now would be dead/speculative code. They move to B3/B5 respectively. B2 delivers: My PRs appear + discovery can't firehose.

**Tech Stack:** Swift / SwiftUI; Apple Swift Testing; XcodeGen app target.
**Build/test:** `swift test --package-path Core`; `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`.
**Conventions:** No comments unless surrounding code has them; `--no-verify`; no AI attribution.

---

## File Structure

**New:**
- `Core/Sources/PRPilotModels/DiscoveryQuery.swift` — value type + `isScoped`.
- `Core/Tests/PRPilotModelsTests/DiscoveryQueryTests.swift` — scope-check table + codable.

**Modify:**
- `Core/Sources/PRPilotModels/Settings.swift` — two query groups + enabled flags; remove `discoveryQueries`; migration; defaults.
- `Core/Sources/PRPilotModels/Schema.swift` — `schemaVersion` 2 → 3.
- `Core/Sources/AppCore/AppModel.swift` — `discoverNow` rewrite + `discoveryWarnings`.
- `App/SettingsView.swift` — structured DiscoverySettingsTab.
- Tests: `ModelsTests.swift`, `SchemaTests.swift`, `ReviewStoreTests.swift`, `AppModelTests.swift`.

---

## Task 1: `DiscoveryQuery` + `isScoped`

**Files:** Create `Core/Sources/PRPilotModels/DiscoveryQuery.swift`, `Core/Tests/PRPilotModelsTests/DiscoveryQueryTests.swift`.

- [ ] **Step 1: Failing tests** — create `DiscoveryQueryTests.swift`:

```swift
import Testing
import Foundation
@testable import PRPilotModels

@Test func discoveryQueryRoundTripsThroughCodable() throws {
    let q = DiscoveryQuery(text: "author:@me is:open", allowUnscoped: true)
    let data = try JSONEncoder().encode(q)
    #expect(try JSONDecoder().decode(DiscoveryQuery.self, from: data) == q)
}

@Test func scopedQueriesAreRecognised() {
    let scoped = [
        "author:@me is:open",
        "review-requested:@me is:open",
        "assignee:@me",
        "mentions:@me",
        "involves:ordishs",
        "commenter:@me",
        "org:bsv-blockchain is:open",
        "repo:bsv-blockchain/teranode",
        "user:ordishs is:pr",
        "is:open author:someone-else",        // scoped to another person — still bounded
    ]
    for t in scoped { #expect(DiscoveryQuery.isScoped(t), "expected scoped: \(t)") }
}

@Test func unscopedQueriesAreRejected() {
    let unscoped = [
        "is:open",
        "is:pr",
        "is:open is:pr archived:false",
        "draft:false label:bug",
        "is:open language:swift created:>2024-01-01",
        "",
    ]
    for t in unscoped { #expect(!DiscoveryQuery.isScoped(t), "expected unscoped: \(t)") }
}

@Test func isScopedIsCaseInsensitive() {
    #expect(DiscoveryQuery.isScoped("AUTHOR:@me"))
    #expect(DiscoveryQuery(text: "Org:bsv", allowUnscoped: false).isScoped)
}
```

- [ ] **Step 2: Run → FAIL** (`DiscoveryQuery` undefined): `swift test --package-path Core --filter DiscoveryQuery`

- [ ] **Step 3: Implement** — create `DiscoveryQuery.swift`:

```swift
import Foundation

public struct DiscoveryQuery: Codable, Sendable, Equatable {
    public var text: String
    public var allowUnscoped: Bool

    public init(text: String, allowUnscoped: Bool = false) {
        self.text = text
        self.allowUnscoped = allowUnscoped
    }

    /// A query is "scoped" when it contains at least one qualifier that bounds results to a
    /// person or a repo/org. Without one, `gh search prs` returns a global firehose.
    public static func isScoped(_ text: String) -> Bool {
        let qualifiers = [
            "author:", "review-requested:", "assignee:", "mentions:", "involves:",
            "commenter:", "user:", "org:", "repo:",
        ]
        let lower = text.lowercased()
        return qualifiers.contains { lower.contains($0) }
    }

    public var isScoped: Bool { DiscoveryQuery.isScoped(text) }
}
```

- [ ] **Step 4: Run → PASS**: `swift test --package-path Core --filter DiscoveryQuery`

- [ ] **Step 5: Commit**
```bash
git add Core/Sources/PRPilotModels/DiscoveryQuery.swift Core/Tests/PRPilotModelsTests/DiscoveryQueryTests.swift
git commit -m "feat(models): add DiscoveryQuery with scope check" --no-verify
```

---

## Task 2: Settings — two query groups + migration + schema bump

**Files:** `Core/Sources/PRPilotModels/Settings.swift`, `Core/Sources/PRPilotModels/Schema.swift`, and tests `ModelsTests.swift`, `SchemaTests.swift`, `ReviewStoreTests.swift`.

- [ ] **Step 1: Update/By tests first**

In `ModelsTests.swift`, `settingsDefaultHasExpectedValues` currently asserts `settings.discoveryQueries == [...]`. Replace that one assertion with:
```swift
    #expect(settings.reviewRequestQueries.map(\.text) == ["review-requested:@me is:open", "assignee:@me is:open"])
    #expect(settings.myPRQueries.map(\.text) == ["author:@me is:open"])
    #expect(settings.reviewRequestsEnabled == true)
    #expect(settings.myPRsEnabled == true)
```

In `SchemaTests.swift`: rename `schemaVersionIsTwo` → `schemaVersionIsThree`, assert `== 3`. Add a settings-migration test:
```swift
@Test func settingsMigratesLegacyDiscoveryQueries() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "discoveryQueries": ["review-requested:@me is:open", "assignee:@me is:open"],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarGrouping": "byCategory"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.reviewRequestQueries.map(\.text) == ["review-requested:@me is:open", "assignee:@me is:open"])
    #expect(s.reviewRequestQueries.allSatisfy { !$0.allowUnscoped })
    #expect(s.myPRQueries.map(\.text) == ["author:@me is:open"])  // injected default
    #expect(s.reviewRequestsEnabled == true && s.myPRsEnabled == true)
}
```
(The existing `settingsDecodesPersistedSettingsWithoutSidebarGrouping` test feeds legacy JSON with `discoveryQueries` and asserts `sidebarGrouping == .none`; it must keep passing — the legacy branch still applies the `?? .none` fallback. Leave it.)

In `ReviewStoreTests.swift`, the migration test `loadMigratesLegacySchemaV1FileAndRewritesIt` asserts `schemaVersion == 2`. Change it to assert against the current constant: `#expect(rewritten?["schemaVersion"] as? Int == PRPilotModels.schemaVersion)` (add `import PRPilotModels` already present). Its legacy settings block (with `discoveryQueries`) still decodes via the migration.

- [ ] **Step 2: Run → FAIL** (new fields don't exist): `swift test --package-path Core --filter Settings`

- [ ] **Step 3: Bump schema** — `Schema.swift`: `public static let schemaVersion = 3`.

- [ ] **Step 4: Rewrite Settings.swift**

Replace the `discoveryQueries: [String]` stored property with the four new ones, update the memberwise init, add a `LegacyKeys` enum + migration in `init(from:)`, and update `default`. Full file:

```swift
import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var managedRoot: String
    public var reviewRequestQueries: [DiscoveryQuery]
    public var myPRQueries: [DiscoveryQuery]
    public var reviewRequestsEnabled: Bool
    public var myPRsEnabled: Bool
    public var pollIntervalSeconds: Int
    public var ghPath: String?
    public var gitPath: String?
    public var claudePath: String?
    public var claudeLaunchArgs: String
    public var claudeEnv: String
    public var autoLoad: Bool
    public var notificationsEnabled: Bool
    public var diffMode: DiffMode
    public var diffIgnoreWhitespace: Bool
    public var sidebarGrouping: SidebarGrouping

    private enum LegacyKeys: String, CodingKey {
        case discoveryQueries
    }

    public init(
        managedRoot: String,
        reviewRequestQueries: [DiscoveryQuery],
        myPRQueries: [DiscoveryQuery],
        reviewRequestsEnabled: Bool = true,
        myPRsEnabled: Bool = true,
        pollIntervalSeconds: Int,
        ghPath: String? = nil,
        gitPath: String? = nil,
        claudePath: String? = nil,
        claudeLaunchArgs: String = "",
        claudeEnv: String = "",
        autoLoad: Bool = false,
        notificationsEnabled: Bool,
        diffMode: DiffMode,
        diffIgnoreWhitespace: Bool,
        sidebarGrouping: SidebarGrouping = .byCategory
    ) {
        self.managedRoot = managedRoot
        self.reviewRequestQueries = reviewRequestQueries
        self.myPRQueries = myPRQueries
        self.reviewRequestsEnabled = reviewRequestsEnabled
        self.myPRsEnabled = myPRsEnabled
        self.pollIntervalSeconds = pollIntervalSeconds
        self.ghPath = ghPath
        self.gitPath = gitPath
        self.claudePath = claudePath
        self.claudeLaunchArgs = claudeLaunchArgs
        self.claudeEnv = claudeEnv
        self.autoLoad = autoLoad
        self.notificationsEnabled = notificationsEnabled
        self.diffMode = diffMode
        self.diffIgnoreWhitespace = diffIgnoreWhitespace
        self.sidebarGrouping = sidebarGrouping
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managedRoot = try c.decode(String.self, forKey: .managedRoot)
        pollIntervalSeconds = try c.decode(Int.self, forKey: .pollIntervalSeconds)
        ghPath = try c.decodeIfPresent(String.self, forKey: .ghPath)
        gitPath = try c.decodeIfPresent(String.self, forKey: .gitPath)
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        if let argsString = try? c.decodeIfPresent(String.self, forKey: .claudeLaunchArgs) {
            claudeLaunchArgs = argsString
        } else {
            let argsArray = try c.decodeIfPresent([String].self, forKey: .claudeLaunchArgs) ?? []
            claudeLaunchArgs = argsArray.joined(separator: " ")
        }
        if let envString = try? c.decodeIfPresent(String.self, forKey: .claudeEnv) {
            claudeEnv = envString
        } else {
            let envArray = try c.decodeIfPresent([String].self, forKey: .claudeEnv) ?? []
            claudeEnv = envArray.joined(separator: " ")
        }
        autoLoad = try c.decodeIfPresent(Bool.self, forKey: .autoLoad) ?? false
        notificationsEnabled = try c.decode(Bool.self, forKey: .notificationsEnabled)
        diffMode = try c.decode(DiffMode.self, forKey: .diffMode)
        diffIgnoreWhitespace = try c.decode(Bool.self, forKey: .diffIgnoreWhitespace)
        sidebarGrouping = try c.decodeIfPresent(SidebarGrouping.self, forKey: .sidebarGrouping) ?? .none

        if let rrq = try c.decodeIfPresent([DiscoveryQuery].self, forKey: .reviewRequestQueries) {
            reviewRequestQueries = rrq
            myPRQueries = try c.decodeIfPresent([DiscoveryQuery].self, forKey: .myPRQueries) ?? Settings.defaultMyPRQueries
            reviewRequestsEnabled = try c.decodeIfPresent(Bool.self, forKey: .reviewRequestsEnabled) ?? true
            myPRsEnabled = try c.decodeIfPresent(Bool.self, forKey: .myPRsEnabled) ?? true
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let old = try legacy.decodeIfPresent([String].self, forKey: .discoveryQueries) ?? []
            reviewRequestQueries = old.map { DiscoveryQuery(text: $0, allowUnscoped: false) }
            myPRQueries = Settings.defaultMyPRQueries
            reviewRequestsEnabled = true
            myPRsEnabled = true
        }
    }

    public static let defaultReviewRequestQueries: [DiscoveryQuery] = [
        DiscoveryQuery(text: "review-requested:@me is:open"),
        DiscoveryQuery(text: "assignee:@me is:open"),
    ]
    public static let defaultMyPRQueries: [DiscoveryQuery] = [
        DiscoveryQuery(text: "author:@me is:open"),
    ]

    public static let `default` = Settings(
        managedRoot: Settings.defaultManagedRoot(),
        reviewRequestQueries: Settings.defaultReviewRequestQueries,
        myPRQueries: Settings.defaultMyPRQueries,
        pollIntervalSeconds: 120,
        notificationsEnabled: true,
        diffMode: .unified,
        diffIgnoreWhitespace: false,
        sidebarGrouping: .byCategory
    )

    public static func defaultManagedRoot() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PRPilot", isDirectory: true).path
    }
}
```

Note: synthesized `CodingKeys` now includes the four new properties (and NOT `discoveryQueries`), so `Encodable` stays synthesized and writes only the new shape. The legacy `discoveryQueries` is read via the separate `LegacyKeys` container.

- [ ] **Step 5: Find other `discoveryQueries` references**

Grep the whole repo for `discoveryQueries`. Remaining hits are `AppModel.discoverNow` (Task 3) and `SettingsView` (Task 4) — leave those for their tasks. There must be no other `Settings(...)` constructor call passing `discoveryQueries:`. If a test constructs `Settings(...)` directly with `discoveryQueries:`, update it to the new params.

- [ ] **Step 6: Build the model + store targets**
`swift build --package-path Core --target ReviewStore` (compiles PRPilotModels + ReviewStore). AppCore/App won't build until Tasks 3/4 — expected.

- [ ] **Step 7: Commit**
```bash
git add Core/Sources/PRPilotModels/Settings.swift Core/Sources/PRPilotModels/Schema.swift Core/Tests/PRPilotModelsTests/ModelsTests.swift Core/Tests/PRPilotModelsTests/SchemaTests.swift Core/Tests/ReviewStoreTests/ReviewStoreTests.swift
git commit -m "feat(settings): split discovery into review-request + my-PR query groups; schema v3" --no-verify
```

---

## Task 3: `discoverNow` — two groups, scope guard, circuit-breaker

**Files:** `Core/Sources/AppCore/AppModel.swift`, `Core/Tests/AppCoreTests/AppModelTests.swift`.

- [ ] **Step 1: Add the warnings property**

In `AppModel`, alongside the other `public private(set)` observable properties, add:
```swift
    public private(set) var discoveryWarnings: [String] = []
```

- [ ] **Step 2: Rewrite `discoverNow()`**

Replace the current `discoverNow()` with:

```swift
    func discoverNow() async {
        var hitsByID: [String: DiscoveryHit] = [:]
        var anyQuerySucceeded = false
        var warnings: [String] = []

        let groups: [(enabled: Bool, queries: [DiscoveryQuery])] = [
            (settings.reviewRequestsEnabled, settings.reviewRequestQueries),
            (settings.myPRsEnabled, settings.myPRQueries),
        ]
        for group in groups where group.enabled {
            for query in group.queries {
                let text = query.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                guard query.isScoped || query.allowUnscoped else {
                    warnings.append("Skipped “\(text)” — not scoped to you, an org, or a repo. Add a qualifier (author:/org:/repo:/…) or enable “run anyway”.")
                    continue
                }
                guard let results = try? await client.searchPRs(query: text) else { continue }
                anyQuerySucceeded = true
                if results.count >= 100 {
                    warnings.append("“\(text)” returned 100+ results (too broad) — refine it. Those results were not added.")
                    continue
                }
                for hit in results {
                    hitsByID[hit.id] = hit
                }
            }
        }
        discoveryWarnings = warnings
        await mergeDiscoveryHits(Array(hitsByID.values))
        if anyQuerySucceeded {
            await pruneStaleDiscoveredReviews(currentHitIDs: Set(hitsByID.keys))
        }
    }
```

(`mergeDiscoveryHits`/`pruneStaleDiscoveredReviews` are unchanged from B1.1.)

- [ ] **Step 3: Update AppModelTests**

The discovery tests previously seeded `settings.discoveryQueries`. Update them to seed `settings.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]` (and disable the my-PR group where a test asserts an exact hit set, to keep the stub's returned hits deterministic: set `settings.myPRsEnabled = false`, or have the stub client return the same hits for any query). Read how the test's stub `GitHubClient`/search is wired and adapt minimally so existing discovery assertions still hold.

Add these new tests (adapt the stub-client setup to the file's existing pattern for returning canned `DiscoveryHit`s / counts):
```swift
@Test func discoverSkipsUnscopedQueryAndWarns() async {
    // model with reviewRequestQueries = [DiscoveryQuery(text: "is:open")] (unscoped, allowUnscoped: false)
    // after discoverNow(): no reviews added, discoveryWarnings is non-empty and mentions the query
}

@Test func discoverRunsUnscopedQueryWhenAllowed() async {
    // reviewRequestQueries = [DiscoveryQuery(text: "is:open", allowUnscoped: true)]
    // after discoverNow(): the stub's hits ARE merged (query ran)
}

@Test func discoverSkipsCappedResultsAndWarns() async {
    // stub client returns 100 hits for the query
    // after discoverNow(): those hits are NOT merged; discoveryWarnings mentions "100+"
}
```
Implement each using the test file's existing stub mechanism (e.g., a stub client returning a fixed `[DiscoveryHit]`). If the current stub can't vary its result count, extend it minimally (e.g., a configurable `searchResult: [DiscoveryHit]`), following the existing test-double style. Keep all pre-existing discovery tests passing.

- [ ] **Step 4: Build the package**
`swift build --package-path Core` → all sources compile.

- [ ] **Step 5: Commit**
```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(discovery): two query groups with scope guard and 100-result circuit-breaker" --no-verify
```

---

## Task 4: Settings UI — structured two-group editor

**Files:** `App/SettingsView.swift`.

Replace `DiscoverySettingsTab` (currently a `TextEditor` over `discoveryQueries`) with a structured editor: two groups (Review requests, My PRs), each with an enable toggle and an editable list of rows; each row has a query `TextField`, an inline scope warning + "Run anyway" toggle shown only when the text is unscoped and not allowed, and a remove button; plus an "Add query" button per group. Keep the existing Auto-load and Poll-interval sections. Surface `model.discoveryWarnings` in a footer section when non-empty.

- [ ] **Step 1: Replace `DiscoverySettingsTab`** with:

```swift
private struct DiscoverySettingsTab: View {
    let model: AppModel

    @State private var reviewRows: [QueryRow] = []
    @State private var myPRRows: [QueryRow] = []
    @State private var reviewEnabled = true
    @State private var myPRsEnabled = true
    @State private var pollIntervalSeconds = 120
    @State private var autoLoad = false

    private struct QueryRow: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var allowUnscoped: Bool
    }

    var body: some View {
        Form {
            Section("Auto load") {
                Toggle("Automatically start a Claude review for every PR", isOn: $autoLoad)
                Text("Reviews each PR at least once: resumes its session, or starts a fresh review for a new one. Runs at launch and when a PR is added (manually or via discovery). Repos without a local clone are reviewed when first opened.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            querySection(title: "Review requests", rows: $reviewRows, enabled: $reviewEnabled)
            querySection(title: "My PRs", rows: $myPRRows, enabled: $myPRsEnabled)

            if !model.discoveryWarnings.isEmpty {
                Section("Discovery warnings") {
                    ForEach(model.discoveryWarnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            Section("Poll interval") {
                Stepper(value: $pollIntervalSeconds, in: 30...3600, step: 30) {
                    Text("\(pollIntervalSeconds) seconds")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reviewRows = model.settings.reviewRequestQueries.map { QueryRow(text: $0.text, allowUnscoped: $0.allowUnscoped) }
            myPRRows = model.settings.myPRQueries.map { QueryRow(text: $0.text, allowUnscoped: $0.allowUnscoped) }
            reviewEnabled = model.settings.reviewRequestsEnabled
            myPRsEnabled = model.settings.myPRsEnabled
            pollIntervalSeconds = model.settings.pollIntervalSeconds
            autoLoad = model.settings.autoLoad
        }
        .onChange(of: reviewRows) { _, _ in commit() }
        .onChange(of: myPRRows) { _, _ in commit() }
        .onChange(of: reviewEnabled) { _, _ in commit() }
        .onChange(of: myPRsEnabled) { _, _ in commit() }
        .onChange(of: pollIntervalSeconds) { _, _ in commit() }
        .onChange(of: autoLoad) { _, _ in commit() }
    }

    @ViewBuilder
    private func querySection(title: String, rows: Binding<[QueryRow]>, enabled: Binding<Bool>) -> some View {
        Section {
            Toggle("Enabled", isOn: enabled)
            ForEach(rows) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("gh search prs query", text: $row.text)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button(role: .destructive) {
                            rows.wrappedValue.removeAll { $0.id == row.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                    if !DiscoveryQuery.isScoped(row.text) && !row.text.trimmingCharacters(in: .whitespaces).isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Not scoped to you, an org, or a repo — matches PRs across all of GitHub.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Run anyway", isOn: $row.allowUnscoped).toggleStyle(.checkbox)
                        }
                    }
                }
            }
            Button {
                rows.wrappedValue.append(QueryRow(text: "", allowUnscoped: false))
            } label: { Label("Add query", systemImage: "plus") }
        } header: {
            Text(title)
        }
    }

    private func commit() {
        var updated = model.settings
        updated.reviewRequestQueries = reviewRows
            .map { DiscoveryQuery(text: $0.text.trimmingCharacters(in: .whitespaces), allowUnscoped: $0.allowUnscoped) }
            .filter { !$0.text.isEmpty }
        updated.myPRQueries = myPRRows
            .map { DiscoveryQuery(text: $0.text.trimmingCharacters(in: .whitespaces), allowUnscoped: $0.allowUnscoped) }
            .filter { !$0.text.isEmpty }
        updated.reviewRequestsEnabled = reviewEnabled
        updated.myPRsEnabled = myPRsEnabled
        updated.pollIntervalSeconds = pollIntervalSeconds
        updated.autoLoad = autoLoad
        Task { await model.updateSettings(updated) }
    }
}
```

- [ ] **Step 2: Build the app**
`xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build` → BUILD SUCCEEDED. Fix any compile issues (e.g., `ForEach($rows)` binding requires `rows` be a `Binding<[QueryRow]>` over an `Identifiable` element — it is). If the `ForEach(rows) { $row in }` binding form misbehaves, fall back to indexing: `ForEach(rows.indices, id: \.self) { i in ... rows.wrappedValue[i] ... }` with explicit bindings; choose whichever compiles cleanly.

- [ ] **Step 3: Commit**
```bash
git add App/SettingsView.swift
git commit -m "feat(ui): structured discovery settings with scope warnings and run-anyway" --no-verify
```

---

## Task 5: Verify

- [ ] **Step 1:** `swift test --package-path Core` → all pass.
- [ ] **Step 2:** `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build` → BUILD SUCCEEDED.
- [ ] **Step 3 (controller, non-destructive):** Verify the real settings migrate: the user's `store.json` settings still has `discoveryQueries` (legacy). Confirm via a copy that it decodes into `reviewRequestQueries` + injected `myPRQueries`, without touching the real file (controller handles, as in B1.1).

---

## Self-Review

**Spec coverage:** Structured two-group queries ✓ (Task 2); `queryIsScoped` ✓ (Task 1); input warning + run-anyway ✓ (Task 4); execution skip ✓ (Task 3); 100-cap circuit-breaker ✓ (Task 3); My PRs surface via `author:@me` group ✓ (Task 2 default + Task 3 runs it; categorisation already wired). Deferred (documented): worktree-on-branch → B5; auto-linking → B3.

**Placeholder scan:** none. The one UI fallback (`ForEach` binding vs index form) gives a concrete decision rule, not a TBD.

**Type consistency:** `DiscoveryQuery {text, allowUnscoped}` + `isScoped` (static + computed); `Settings.reviewRequestQueries`/`myPRQueries`/`reviewRequestsEnabled`/`myPRsEnabled`; `AppModel.discoveryWarnings`; `schemaVersion = 3`. Used consistently across tasks.

**Migration safety:** Settings keeps synthesized `Encodable` (legacy key isolated in `LegacyKeys`); legacy `discoveryQueries` → `reviewRequestQueries`, my-PR group injected; all other field fallbacks preserved (verified against current `init(from:)`).

---

## Next plan

**B3 — New task:** the minimal eager-Claude creation flow (branch + worktree + session), `WorkItem` with `prRef: nil`, and **auto-linking** a discovered My PR to a task by `repoKey`+`headBranch`.
