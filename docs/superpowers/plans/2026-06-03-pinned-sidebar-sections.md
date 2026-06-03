# Pinned Sidebar Sections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make My Work / Review Requests permanent, collapsible, strongly-styled sidebar sections instead of one optional grouping mode, and demote Date/Author/Status to a within-section sort.

**Architecture:** Move the partition-and-sort logic into a pure, unit-tested function in `PRPilotModels` (`sidebarSections(items:myLogin:sort:)`). `Settings` swaps its `sidebarGrouping: SidebarGrouping` field for `sidebarSort: SidebarSort` plus two collapse flags, with a decode-time migration from the old value. `ContentView` renders two fixed collapsible `Section`s driven by that helper.

**Tech Stack:** Swift, SwiftUI (macOS 14+), Swift Testing (`import Testing`, `@Test`, `#expect`). Core tests run via `swift test --package-path Core`. The app builds via `xcodegen generate` + `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-06-03-pinned-sidebar-sections-design.md`

**Sequencing note:** Tasks 1–3 keep the `Core` package compiling and its tests green throughout. The **App (Xcode) target does not compile between Task 3 and Task 4** because `ContentView` still references the removed `sidebarGrouping` until Task 4 rewrites it. This matches the repo's split (Core tested via `swift test`; app built manually). Do not run an Xcode build until Task 4 is complete.

## File Structure

- Create: `Core/Sources/PRPilotModels/SidebarSort.swift` — the new sort enum + legacy mapping.
- Create: `Core/Sources/PRPilotModels/SidebarSections.swift` — pure partition + sort helper.
- Create: `Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift` — tests for the helper.
- Modify: `Core/Sources/PRPilotModels/Settings.swift` — replace `sidebarGrouping` with `sidebarSort` + `myWorkCollapsed`/`reviewsCollapsed`; migrate on decode.
- Modify: `Core/Tests/PRPilotModelsTests/SchemaTests.swift` — update 3 existing tests + add migration/collapse tests.
- Delete: `Core/Sources/PRPilotModels/SidebarGrouping.swift` (in Task 4, once `ContentView` no longer uses it).
- Modify: `App/ContentView.swift` — two fixed collapsible sections, Sort menu, remove dead grouping code.

---

### Task 1: Add `SidebarSort` enum

**Files:**
- Create: `Core/Sources/PRPilotModels/SidebarSort.swift`
- Test: `Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift` (created here, extended in Task 3)

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift`:

```swift
import Testing
import Foundation
@testable import PRPilotModels

@Test func sidebarSortDisplayNames() {
    #expect(SidebarSort.recent.displayName == "Recent")
    #expect(SidebarSort.byStatus.displayName == "By status")
    #expect(SidebarSort.byAuthor.displayName == "By author")
}

@Test func sidebarSortMapsLegacyGrouping() {
    #expect(SidebarSort(legacyGrouping: "byStatus") == .byStatus)
    #expect(SidebarSort(legacyGrouping: "byAuthor") == .byAuthor)
    #expect(SidebarSort(legacyGrouping: "byCategory") == .recent)
    #expect(SidebarSort(legacyGrouping: "none") == .recent)
    #expect(SidebarSort(legacyGrouping: "byDate") == .recent)
    #expect(SidebarSort(legacyGrouping: "garbage") == .recent)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path Core --filter sidebarSort`
Expected: FAIL — `cannot find 'SidebarSort' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Core/Sources/PRPilotModels/SidebarSort.swift`:

```swift
public enum SidebarSort: String, Codable, Sendable, CaseIterable, Equatable {
    case recent
    case byStatus
    case byAuthor

    public var displayName: String {
        switch self {
        case .recent: return "Recent"
        case .byStatus: return "By status"
        case .byAuthor: return "By author"
        }
    }

    public init(legacyGrouping: String) {
        switch legacyGrouping {
        case "byStatus": self = .byStatus
        case "byAuthor": self = .byAuthor
        default: self = .recent
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path Core --filter sidebarSort`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PRPilotModels/SidebarSort.swift Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift
git commit --no-verify -m "feat(sidebar): add SidebarSort enum with legacy grouping migration"
```

---

### Task 2: Pure `sidebarSections` partition + sort helper

**Files:**
- Create: `Core/Sources/PRPilotModels/SidebarSections.swift`
- Test: `Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift`:

```swift
private func makeItem(
    id: String,
    repoKey: String = "github.com/acme/app",
    authorLogin: String? = nil,
    number: Int? = nil,
    state: PRState? = nil,
    addedAt: Date
) -> WorkItem {
    let prRef: PRRef? = number.map {
        PRRef(owner: "acme", repo: "app", number: $0,
              url: URL(string: "https://github.com/acme/app/pull/\($0)")!,
              authorLogin: authorLogin ?? "someone")
    }
    return WorkItem(
        id: id, title: id, repoKey: repoKey, baseBranch: "main",
        headBranch: number == nil ? "feature/\(id)" : nil,
        prRef: prRef, prState: state, origin: .added, addedAt: addedAt
    )
}

@Test func sidebarSectionsPartitionsByCategory() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let items = [
        makeItem(id: "task1", addedAt: base),                                  // task -> My Work
        makeItem(id: "mine", authorLogin: "me", number: 10, state: .open,
                 addedAt: base),                                               // myPR -> My Work
        makeItem(id: "review", authorLogin: "other", number: 20, state: .open,
                 addedAt: base),                                               // reviewRequest
    ]
    let s = sidebarSections(items: items, myLogin: "me", sort: .recent)
    #expect(s.myWork.map(\.id).sorted() == ["mine", "task1"])
    #expect(s.reviewRequests.map(\.id) == ["review"])
}

@Test func sidebarSectionsRecentSortsNewestFirst() {
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let new = Date(timeIntervalSince1970: 1_700_001_000)
    let items = [
        makeItem(id: "old", addedAt: old),
        makeItem(id: "new", addedAt: new),
    ]
    let s = sidebarSections(items: items, myLogin: "me", sort: .recent)
    #expect(s.myWork.map(\.id) == ["new", "old"])
}

@Test func sidebarSectionsByStatusOrdersOpenDraftMergedClosed() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let items = [
        makeItem(id: "closed", authorLogin: "me", number: 1, state: .closed, addedAt: base),
        makeItem(id: "open", authorLogin: "me", number: 2, state: .open, addedAt: base),
        makeItem(id: "merged", authorLogin: "me", number: 3, state: .merged, addedAt: base),
        makeItem(id: "draft", authorLogin: "me", number: 4, state: .draft, addedAt: base),
        makeItem(id: "task", addedAt: base),   // nil state ranks with open
    ]
    let s = sidebarSections(items: items, myLogin: "me", sort: .byStatus)
    let ids = s.myWork.map(\.id)
    #expect(ids.prefix(2).sorted() == ["open", "task"])  // both rank 0
    #expect(ids[2] == "draft")
    #expect(ids[3] == "merged")
    #expect(ids[4] == "closed")
}

@Test func sidebarSectionsByAuthorIsCaseInsensitiveAlphabetical() {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let items = [
        makeItem(id: "z", authorLogin: "Zoe", number: 1, state: .open, addedAt: base),
        makeItem(id: "a", authorLogin: "alice", number: 2, state: .open, addedAt: base),
    ]
    let s = sidebarSections(items: items, myLogin: "nobody", sort: .byAuthor)
    #expect(s.reviewRequests.map(\.id) == ["a", "z"])
}

@Test func sidebarSectionsEmptyWhenNoItems() {
    let s = sidebarSections(items: [], myLogin: "me", sort: .recent)
    #expect(s.myWork.isEmpty)
    #expect(s.reviewRequests.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core --filter sidebarSections`
Expected: FAIL — `cannot find 'sidebarSections' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Core/Sources/PRPilotModels/SidebarSections.swift`:

```swift
import Foundation

public struct SidebarSections: Sendable, Equatable {
    public let myWork: [WorkItem]
    public let reviewRequests: [WorkItem]

    public init(myWork: [WorkItem], reviewRequests: [WorkItem]) {
        self.myWork = myWork
        self.reviewRequests = reviewRequests
    }
}

public func sidebarSections(items: [WorkItem], myLogin: String?, sort: SidebarSort) -> SidebarSections {
    var myWork: [WorkItem] = []
    var reviews: [WorkItem] = []
    for item in items {
        switch item.category(myLogin: myLogin) {
        case .task, .myPR:
            myWork.append(item)
        case .reviewRequest:
            reviews.append(item)
        }
    }
    return SidebarSections(
        myWork: sortWorkItems(myWork, by: sort),
        reviewRequests: sortWorkItems(reviews, by: sort)
    )
}

func sortWorkItems(_ items: [WorkItem], by sort: SidebarSort) -> [WorkItem] {
    switch sort {
    case .recent:
        return items.sorted { $0.addedAt > $1.addedAt }
    case .byStatus:
        return items.sorted {
            let a = statusRank($0.prState)
            let b = statusRank($1.prState)
            if a != b { return a < b }
            return $0.addedAt > $1.addedAt
        }
    case .byAuthor:
        return items.sorted {
            let a = $0.author ?? ""
            let b = $1.author ?? ""
            let cmp = a.localizedCaseInsensitiveCompare(b)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.addedAt > $1.addedAt
        }
    }
}

func statusRank(_ state: PRState?) -> Int {
    switch state {
    case .open, .none: return 0
    case .draft: return 1
    case .merged: return 2
    case .closed: return 3
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Core --filter sidebarSections`
Expected: PASS (all five `sidebarSections*` tests, plus the Task 1 tests).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PRPilotModels/SidebarSections.swift Core/Tests/PRPilotModelsTests/SidebarSectionsTests.swift
git commit --no-verify -m "feat(sidebar): add pure sidebarSections partition + sort helper"
```

---

### Task 3: Migrate `Settings` to `sidebarSort` + collapse flags

**Files:**
- Modify: `Core/Sources/PRPilotModels/Settings.swift`
- Modify: `Core/Tests/PRPilotModelsTests/SchemaTests.swift:70-89`

- [ ] **Step 1: Write/adjust the failing tests**

In `Core/Tests/PRPilotModelsTests/SchemaTests.swift`, replace the two tests at lines 70-89:

```swift
@Test func settingsDefaultSidebarSortIsRecent() throws {
    let s = Settings.default
    #expect(s.sidebarSort == .recent)
    #expect(s.myWorkCollapsed == false)
    #expect(s.reviewsCollapsed == false)
}

@Test func settingsDecodesWithoutSidebarSortDefaultsRecent() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "discoveryQueries": ["review-requested:@me is:open"],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": [],
      "notificationsEnabled": true,
      "diffMode": "unified",
      "diffIgnoreWhitespace": false
    }
    """
    let decoded = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(decoded.sidebarSort == .recent)
    #expect(decoded.myWorkCollapsed == false)
    #expect(decoded.reviewsCollapsed == false)
}

@Test func settingsMigratesLegacySidebarGroupingByStatus() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [],
      "myPRQueries": [],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarGrouping": "byStatus"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.sidebarSort == .byStatus)
}

@Test func settingsMigratesLegacyByCategoryToRecent() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [],
      "myPRQueries": [],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarGrouping": "byCategory"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.sidebarSort == .recent)
}

@Test func settingsCollapseFlagsRoundTrip() throws {
    var s = Settings.default
    s.myWorkCollapsed = true
    s.reviewsCollapsed = false
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.myWorkCollapsed == true)
    #expect(decoded.reviewsCollapsed == false)
    #expect(decoded.sidebarSort == s.sidebarSort)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path Core --filter settings`
Expected: FAIL — `value of type 'Settings' has no member 'sidebarSort'` (compile error).

- [ ] **Step 3: Implement the Settings changes**

In `Core/Sources/PRPilotModels/Settings.swift`:

(a) Replace the property declaration at line 19:

```swift
    public var sidebarSort: SidebarSort
    public var myWorkCollapsed: Bool
    public var reviewsCollapsed: Bool
```

(b) Extend `LegacyKeys` (lines 21-23) to read the old key:

```swift
    private enum LegacyKeys: String, CodingKey {
        case discoveryQueries
        case sidebarGrouping
    }
```

(c) In `init(...)`, replace the `sidebarGrouping` parameter (line 41) with:

```swift
        sidebarSort: SidebarSort = .recent,
        myWorkCollapsed: Bool = false,
        reviewsCollapsed: Bool = false
```

(d) In `init(...)`, replace the assignment (line 58):

```swift
        self.sidebarSort = sidebarSort
        self.myWorkCollapsed = myWorkCollapsed
        self.reviewsCollapsed = reviewsCollapsed
```

(e) In `init(from decoder:)`, replace line 84 (`sidebarGrouping = ...`) with:

```swift
        if let sort = try c.decodeIfPresent(SidebarSort.self, forKey: .sidebarSort) {
            sidebarSort = sort
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let legacyGrouping = (try? legacy.decodeIfPresent(String.self, forKey: .sidebarGrouping)) ?? nil {
            sidebarSort = SidebarSort(legacyGrouping: legacyGrouping)
        } else {
            sidebarSort = .recent
        }
        myWorkCollapsed = try c.decodeIfPresent(Bool.self, forKey: .myWorkCollapsed) ?? false
        reviewsCollapsed = try c.decodeIfPresent(Bool.self, forKey: .reviewsCollapsed) ?? false
```

(f) In the `static let default` (line 117), replace `sidebarGrouping: .byCategory` with:

```swift
        sidebarSort: .recent
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path Core --filter settings`
Expected: PASS — all `settings*` tests including the new migration/collapse tests.

- [ ] **Step 5: Run the whole Core suite to catch fallout**

Run: `swift test --package-path Core`
Expected: PASS. The legacy-discovery test (`settingsMigratesLegacyDiscoveryQueries`, contains `"sidebarGrouping": "byCategory"`) and `ReviewStoreTests` (contains `"sidebarGrouping": "byDate"`) must still decode without error. If either references `sidebarGrouping` on the decoded value, change that assertion to `sidebarSort`. (As written, neither asserts on it, so they should pass unchanged.)

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/PRPilotModels/Settings.swift Core/Tests/PRPilotModelsTests/SchemaTests.swift
git commit --no-verify -m "feat(sidebar): replace sidebarGrouping with sidebarSort + collapse flags"
```

---

### Task 4: Rewrite the sidebar — two pinned collapsible sections

**Files:**
- Modify: `App/ContentView.swift`
- Delete: `Core/Sources/PRPilotModels/SidebarGrouping.swift`

No unit test (SwiftUI view); verified by build + launch in Task 5. The pure logic it relies on is already covered by Tasks 1–3.

- [ ] **Step 1: Delete the obsolete enum**

```bash
git rm Core/Sources/PRPilotModels/SidebarGrouping.swift
```

- [ ] **Step 2: Replace the sidebar list body**

In `App/ContentView.swift`, replace the entire `Group { ... }` block (lines 15-32, the `if model.settings.sidebarGrouping == .none { ... } else { ... }`) with:

```swift
            List(selection: $model.selection) {
                let sections = sidebarSections(
                    items: model.reviews,
                    myLogin: model.currentLogin,
                    sort: model.settings.sidebarSort
                )
                Section(isExpanded: sectionExpanded(\.myWorkCollapsed)) {
                    sectionBody(sections.myWork)
                } header: {
                    sectionHeader(title: "My Work", count: sections.myWork.count, accent: .blue)
                }
                Section(isExpanded: sectionExpanded(\.reviewsCollapsed)) {
                    sectionBody(sections.reviewRequests)
                } header: {
                    sectionHeader(title: "Review Requests", count: sections.reviewRequests.count, accent: .purple)
                }
            }
```

- [ ] **Step 3: Replace the toolbar "Group" menu with a "Sort" menu**

In `App/ContentView.swift`, replace the first `ToolbarItem` (lines 41-52, the `Picker("Group by", ...)` over `SidebarGrouping.allCases`) with:

```swift
                ToolbarItem {
                    Menu {
                        Picker("Sort", selection: sortBinding) {
                            ForEach(SidebarSort.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort items within each section by recency, status, or author")
                }
```

- [ ] **Step 4: Replace `groupingBinding` and add the new helpers**

In `App/ContentView.swift`, replace `groupingBinding` (lines 175-184) with `sortBinding`, and add `sectionExpanded`, `sectionBody`, and `sectionHeader`:

```swift
    private var sortBinding: Binding<SidebarSort> {
        Binding(
            get: { model.settings.sidebarSort },
            set: { newValue in
                var updated = model.settings
                updated.sidebarSort = newValue
                Task { await model.updateSettings(updated) }
            }
        )
    }

    private func sectionExpanded(_ keyPath: WritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(
            get: { !model.settings[keyPath: keyPath] },
            set: { expanded in
                var updated = model.settings
                updated[keyPath: keyPath] = !expanded
                Task { await model.updateSettings(updated) }
            }
        )
    }

    @ViewBuilder
    private func sectionBody(_ items: [WorkItem]) -> some View {
        if items.isEmpty {
            Text("Nothing here yet")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(items) { review in
                sidebarRow(for: review)
                    .tag(review.id as String?)
            }
        }
    }

    private func sectionHeader(title: String, count: Int, accent: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3, height: 14)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
```

- [ ] **Step 5: Delete the now-dead grouping code**

In `App/ContentView.swift`, delete these now-unused members:
- `groupedReviews()` (was ~186-199)
- `groupByCategory()` (was ~201-221)
- `groupByDate()` (was ~223-241)
- `groupByAuthor()` (was ~243-248)
- `groupByStatus()` (was ~250-257)
- `daysAgo(_:)` (was ~259-261)
- the `ReviewGroup` struct (was ~169-173)
- the `partitioned(by:)` array extension at the bottom (was ~376) — only `groupByDate` used it. Confirm with `grep -n "partitioned" App/*.swift` returning nothing before deleting.

- [ ] **Step 6: Build the app**

Run:
```bash
cd /Users/ordishs/dev/masa.gi/code-reviewer && xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Fix any compile errors (e.g. a missed `sidebarGrouping` reference) before proceeding.

- [ ] **Step 7: Commit**

```bash
git add App/ContentView.swift Core/Sources/PRPilotModels/SidebarGrouping.swift
git commit --no-verify -m "feat(sidebar): pin My Work / Review Requests as collapsible sections"
```

---

### Task 5: Manual verification + full suite

**Files:** none (verification only).

- [ ] **Step 1: Run the full Core test suite**

Run: `swift test --package-path Core`
Expected: PASS, count ≥ the prior 249 (new SidebarSort/SidebarSections/Settings tests added).

- [ ] **Step 2: Launch the app fresh**

```bash
osascript -e 'quit app "PR Pilot"' 2>/dev/null; pkill -x "PR Pilot" 2>/dev/null
open "$(xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR =/{print $2}')/PR Pilot.app"
```

- [ ] **Step 2: Verify against the spec (visual checklist)**

Confirm by observation:
- Two sections always present: **My Work** (blue accent) on top, **Review Requests** (purple accent) below, each with an item count.
- Collapsing a section (click its disclosure chevron) hides its rows; the other section stays put.
- Quit and relaunch — the collapse state persisted.
- The toolbar **Sort** menu offers Recent / By status / By author and reorders rows *within* each section without merging the two.
- A section with no items shows "Nothing here yet" rather than disappearing.
- Selecting a row still opens its detail (Claude / GitHub / Diff); status dots, CI chips, and the right-click context menu (Rebase/Push/Copy Session ID/Clear/Disable/Remove) are unchanged.

- [ ] **Step 3: Confirm completion**

If all checks pass, the feature is done. If the user requested it, play the completion sound:
```bash
afplay /System/Library/Sounds/Submarine.aiff
```

---

## Self-Review (completed during planning)

- **Spec coverage:** permanent split (Tasks 4) ✓; strong header w/ accent+count+chevron (Task 4 §4) ✓; collapsible + persisted (Settings Task 3 + bindings Task 4) ✓; within-section sort = demoted Date/Author/Status (Tasks 1-2, menu Task 4) ✓; `byCategory` removed (Tasks 3-4) ✓; empty sections render (Task 4 `sectionBody`) ✓; migration (Task 3 + tests) ✓; Core tests for partition/sort/migration (Tasks 1-3) ✓.
- **Placeholder scan:** none — every code step has complete code.
- **Type consistency:** `SidebarSort` (cases recent/byStatus/byAuthor) used identically across Tasks 1-4; `sidebarSections(items:myLogin:sort:)` and `SidebarSections.myWork/.reviewRequests` consistent; `Settings.sidebarSort/myWorkCollapsed/reviewsCollapsed` consistent; `WorkItem.category(myLogin:)`, `.author`, `.prState`, `.addedAt` match the existing model.
