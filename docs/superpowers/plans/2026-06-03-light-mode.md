# Light Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PRPilot render correctly under macOS Light appearance and give the user a System / Light / Dark preference.

**Architecture:** Add an `appearance` preference to the `Settings` model (pure data, in `PRPilotModels`). The App target maps it to a SwiftUI `ColorScheme?` and applies `.preferredColorScheme(...)` at the window root, so all adaptive (semantic) colors flip automatically. The only hardcoded dark-only colors — the sidebar section bands — become color-scheme-aware, and the badge brightness boost is made dark-mode-only.

**Tech Stack:** Swift 6, SwiftUI, swift-testing (`import Testing` / `@Test` / `#expect`). Model tests run via `cd Core && swift test`. App builds via `xcodegen generate && xcodebuild`.

---

## File Structure

- **Create** `Core/Sources/PRPilotModels/Appearance.swift` — the `Appearance` enum (pure data, no SwiftUI).
- **Modify** `Core/Sources/PRPilotModels/Settings.swift` — add `appearance` stored property, init param, and backward-compatible decode.
- **Create** `Core/Tests/PRPilotModelsTests/AppearanceSettingsTests.swift` — round-trip + default-when-absent tests.
- **Create** `App/Appearance+ColorScheme.swift` — maps `Appearance` → `ColorScheme?` (SwiftUI lives in the App target only).
- **Modify** `App/PRPilotApp.swift` — apply `.preferredColorScheme(...)` to `ContentView` and `SettingsView`.
- **Modify** `App/ContentView.swift` — make the sidebar section bands color-scheme-aware (tinted light variant) and make the `StateBadge` brightness boost dark-only.
- **Modify** `App/SettingsView.swift` — add an Appearance tab with a System / Light / Dark picker.

Rationale: the model package stays SwiftUI-free (so `swift test` keeps working as a headless logic package); the `ColorScheme` mapping is an App-target concern.

---

## Task 1: `Appearance` enum + `Settings.appearance` (model, TDD)

**Files:**
- Create: `Core/Sources/PRPilotModels/Appearance.swift`
- Modify: `Core/Sources/PRPilotModels/Settings.swift`
- Test: `Core/Tests/PRPilotModelsTests/AppearanceSettingsTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Core/Tests/PRPilotModelsTests/AppearanceSettingsTests.swift`:

```swift
import Testing
import Foundation
@testable import PRPilotModels

@Test func appearanceDefaultsToSystemWhenAbsent() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [{"text": "author:@me is:open", "allowUnscoped": false}],
      "myPRQueries": [{"text": "author:@me is:open", "allowUnscoped": false}],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarSort": "recent"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.appearance == .system)
}

@Test func appearanceRoundTrips() throws {
    var s = Settings.default
    s.appearance = .light
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.appearance == .light)
}

@Test func appearanceDecodesExplicitDark() throws {
    let json = """
    {
      "managedRoot": "/tmp",
      "reviewRequestQueries": [{"text": "author:@me is:open", "allowUnscoped": false}],
      "myPRQueries": [{"text": "author:@me is:open", "allowUnscoped": false}],
      "pollIntervalSeconds": 120,
      "claudeLaunchArgs": "", "claudeEnv": "",
      "notificationsEnabled": true, "diffMode": "unified",
      "diffIgnoreWhitespace": false, "sidebarSort": "recent",
      "appearance": "dark"
    }
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.appearance == .dark)
}

@Test func appearanceCasesHaveDisplayNames() {
    #expect(Appearance.system.displayName == "System")
    #expect(Appearance.light.displayName == "Light")
    #expect(Appearance.dark.displayName == "Dark")
    #expect(Appearance.allCases.count == 3)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter appearance`
Expected: FAIL — `Appearance` type does not exist / `s.appearance` is not a member of `Settings`.

- [ ] **Step 3: Create the `Appearance` enum**

Create `Core/Sources/PRPilotModels/Appearance.swift`:

```swift
public enum Appearance: String, Codable, Sendable, CaseIterable, Equatable {
    case system
    case light
    case dark

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
```

- [ ] **Step 4: Add the `appearance` property to `Settings`**

In `Core/Sources/PRPilotModels/Settings.swift`, add the stored property after `reviewsCollapsed` (after line 21):

```swift
    public var reviewsCollapsed: Bool
    public var appearance: Appearance
```

Add the init parameter — change the end of the `init(...)` signature (the `reviewsCollapsed` param, line 46) to:

```swift
        myWorkCollapsed: Bool = false,
        reviewsCollapsed: Bool = false,
        appearance: Appearance = .system
    ) {
```

Add the assignment at the end of the memberwise init body (after `self.reviewsCollapsed = reviewsCollapsed`, line 65):

```swift
        self.reviewsCollapsed = reviewsCollapsed
        self.appearance = appearance
```

In the custom `init(from decoder:)`, add this line after the `reviewsCollapsed` decode (after line 100):

```swift
        reviewsCollapsed = try c.decodeIfPresent(Bool.self, forKey: .reviewsCollapsed) ?? false
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
```

(No change to `CodingKeys` is needed — it is compiler-synthesized from the stored properties, so `appearance` is included automatically for both encoding and the synthesized key set. `Settings.default` needs no change because the new init param defaults to `.system`.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Core && swift test --filter appearance`
Expected: PASS — all four tests green.

- [ ] **Step 6: Run the full model test suite for regressions**

Run: `cd Core && swift test`
Expected: PASS — no existing test broken by the new field.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/PRPilotModels/Appearance.swift Core/Sources/PRPilotModels/Settings.swift Core/Tests/PRPilotModelsTests/AppearanceSettingsTests.swift
git commit -m "feat(settings): add appearance preference (system/light/dark)" --no-verify
```

---

## Task 2: Map `Appearance` → `ColorScheme` and apply at the window root (App)

**Files:**
- Create: `App/Appearance+ColorScheme.swift`
- Modify: `App/PRPilotApp.swift:16-19`, `App/PRPilotApp.swift:61`

- [ ] **Step 1: Create the ColorScheme mapping**

Create `App/Appearance+ColorScheme.swift`:

```swift
import SwiftUI
import PRPilotModels

extension Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
```

- [ ] **Step 2: Apply `.preferredColorScheme` to `ContentView`**

In `App/PRPilotApp.swift`, change the `ContentView` block (lines 16–19) from:

```swift
                    ContentView(model: model, webViewCache: webViewCache)
                        .sheet(isPresented: $showingManage) {
                            ManageLocalClonesView(model: model, isPresented: $showingManage)
                        }
```

to:

```swift
                    ContentView(model: model, webViewCache: webViewCache)
                        .sheet(isPresented: $showingManage) {
                            ManageLocalClonesView(model: model, isPresented: $showingManage)
                        }
                        .preferredColorScheme(model.settings.appearance.colorScheme)
```

- [ ] **Step 3: Apply `.preferredColorScheme` to the Settings scene**

In `App/PRPilotApp.swift`, change the `SettingsView` line (line 61) from:

```swift
                SettingsView(model: model)
```

to:

```swift
                SettingsView(model: model)
                    .preferredColorScheme(model.settings.appearance.colorScheme)
```

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug -derivedDataPath DerivedData build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add App/Appearance+ColorScheme.swift App/PRPilotApp.swift
git commit -m "feat(app): apply appearance preference via preferredColorScheme" --no-verify
```

---

## Task 3: Color-scheme-aware sidebar section bands (App)

**Files:**
- Modify: `App/ContentView.swift:24`, `App/ContentView.swift:29`, `App/ContentView.swift:141-181`

Goal: the "My Work" / "Review Requests" headers use the existing dark colors in dark mode and the approved tinted light palette in light mode. Because `.preferredColorScheme` is applied to `ContentView` from `PRPilotApp` (Task 2), child views reliably read the forced scheme via `@Environment(\.colorScheme)`. So the header is extracted into a dedicated child `View` struct that reads the environment.

- [ ] **Step 1: Replace the two header call sites**

In `App/ContentView.swift`, change line 24 from:

```swift
                    sectionHeader(title: "My Work", count: sections.myWork.count, style: .myWork)
```

to:

```swift
                    SidebarSectionHeader(title: "My Work", count: sections.myWork.count, kind: .myWork)
```

Change line 29 from:

```swift
                    sectionHeader(title: "Review Requests", count: sections.reviewRequests.count, style: .reviewRequests)
```

to:

```swift
                    SidebarSectionHeader(title: "Review Requests", count: sections.reviewRequests.count, kind: .reviewRequests)
```

- [ ] **Step 2: Delete the old nested `SectionStyle` and `sectionHeader`**

In `App/ContentView.swift`, delete the nested `SectionStyle` struct (lines 141–156) and the `sectionHeader(...)` method (lines 158–181) from inside `ContentView`. They are replaced by file-scope types in the next step.

- [ ] **Step 3: Add file-scope `SidebarSectionKind`, `SectionStyle`, and `SidebarSectionHeader`**

In `App/ContentView.swift`, add these private file-scope declarations (e.g. just below the `ContentView` struct's closing brace, near the other private structs like `StateBadge`):

```swift
private enum SidebarSectionKind {
    case myWork
    case reviewRequests
}

private struct SectionStyle {
    let band: Color
    let border: Color
    let text: Color

    static func myWork(_ scheme: ColorScheme) -> SectionStyle {
        scheme == .dark
            ? SectionStyle(
                band: Color(red: 0.165, green: 0.208, blue: 0.314),
                border: Color(red: 0.424, green: 0.549, blue: 1.0),
                text: Color(red: 0.616, green: 0.706, blue: 1.0)
            )
            : SectionStyle(
                band: Color(red: 0.910, green: 0.933, blue: 1.0),
                border: Color(red: 0.275, green: 0.431, blue: 0.941),
                text: Color(red: 0.157, green: 0.275, blue: 0.667)
            )
    }

    static func reviewRequests(_ scheme: ColorScheme) -> SectionStyle {
        scheme == .dark
            ? SectionStyle(
                band: Color(red: 0.227, green: 0.165, blue: 0.314),
                border: Color(red: 0.690, green: 0.424, blue: 1.0),
                text: Color(red: 0.831, green: 0.627, blue: 1.0)
            )
            : SectionStyle(
                band: Color(red: 0.957, green: 0.925, blue: 1.0),
                border: Color(red: 0.588, green: 0.314, blue: 0.902),
                text: Color(red: 0.431, green: 0.176, blue: 0.667)
            )
    }
}

private struct SidebarSectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let count: Int
    let kind: SidebarSectionKind

    private var style: SectionStyle {
        switch kind {
        case .myWork: return .myWork(colorScheme)
        case .reviewRequests: return .reviewRequests(colorScheme)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(style.text)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.text.opacity(0.75))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.band)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(style.border)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 2, trailing: 8))
        .textCase(nil)
    }
}
```

(This is the exact body of the old `sectionHeader` method, with the style now resolved from `colorScheme`. The dark-mode RGB values are identical to the originals.)

- [ ] **Step 4: Build to verify it compiles**

Run:
```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug -derivedDataPath DerivedData build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add App/ContentView.swift
git commit -m "feat(sidebar): light-mode tinted section bands" --no-verify
```

---

## Task 4: Make the badge brightness boost dark-mode-only (App)

**Files:**
- Modify: `App/ContentView.swift:279-294` (the `StateBadge` struct)

- [ ] **Step 1: Add `colorScheme` to `StateBadge` and gate the brightness**

In `App/ContentView.swift`, change the `StateBadge` struct (lines 279–294) from:

```swift
private struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(color)
            .brightness(0.12)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.30))
            .clipShape(Capsule())
    }
}
```

to:

```swift
private struct StateBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(color)
            .brightness(colorScheme == .dark ? 0.12 : 0)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(colorScheme == .dark ? 0.30 : 0.18))
            .clipShape(Capsule())
    }
}
```

(The background opacity is also reduced in light mode so the capsule tint stays subtle on white; dark mode keeps `0.30`.)

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug -derivedDataPath DerivedData build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/ContentView.swift
git commit -m "fix(badge): keep state badges legible in light mode" --no-verify
```

---

## Task 5: Appearance picker in Settings (App)

**Files:**
- Modify: `App/SettingsView.swift:9-20` (add the tab), append a new `AppearanceSettingsTab` struct

- [ ] **Step 1: Add the Appearance tab to the `TabView`**

In `App/SettingsView.swift`, change the `body` `TabView` (lines 9–18) from:

```swift
        TabView {
            DiscoverySettingsTab(model: model)
                .tabItem { Label("Discovery", systemImage: "magnifyingglass") }

            ToolsSettingsTab(model: model)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            ClaudeSettingsTab(model: model)
                .tabItem { Label("Claude", systemImage: "terminal") }
        }
```

to:

```swift
        TabView {
            AppearanceSettingsTab(model: model)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            DiscoverySettingsTab(model: model)
                .tabItem { Label("Discovery", systemImage: "magnifyingglass") }

            ToolsSettingsTab(model: model)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }

            ClaudeSettingsTab(model: model)
                .tabItem { Label("Claude", systemImage: "terminal") }
        }
```

- [ ] **Step 2: Add the `AppearanceSettingsTab` struct**

In `App/SettingsView.swift`, add this private struct (e.g. immediately after the `SettingsView` struct's closing brace, before `DiscoverySettingsTab`):

```swift
private struct AppearanceSettingsTab: View {
    let model: AppModel

    @State private var appearance: Appearance = .system

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text("\"System\" follows your macOS appearance setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            appearance = model.settings.appearance
        }
        .onChange(of: appearance) { _, _ in commit() }
    }

    private func commit() {
        var updated = model.settings
        updated.appearance = appearance
        Task { await model.updateSettings(updated) }
    }
}
```

(Mirrors the existing tab pattern: local `@State` seeded in `.onAppear`, committed via `model.updateSettings(...)` on change.)

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug -derivedDataPath DerivedData build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App/SettingsView.swift
git commit -m "feat(settings): add appearance picker tab" --no-verify
```

---

## Task 6: Final verification (build + manual visual check)

**Files:** none (verification only)

- [ ] **Step 1: Full model test suite**

Run: `cd Core && swift test`
Expected: PASS — all tests green (including the new `appearance` tests).

- [ ] **Step 2: Clean app build**

Run:
```bash
xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug -derivedDataPath DerivedData build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Launch and visually verify**

Run: `open -n "DerivedData/Build/Products/Debug/PR Pilot.app"`

Verify:
- Settings (⌘,) shows an **Appearance** tab with a System / Light / Dark segmented picker.
- Selecting **Light** flips the whole window live: backgrounds go light, text stays readable, the "My Work" (blue) and "Review Requests" (purple) section bands show the tinted light palette, and status badges (APPROVED / NEW / MERGED / CI) stay vivid and legible on white.
- Selecting **Dark** restores the original dark look exactly (section bands and badges unchanged from before this work).
- Selecting **System** follows the macOS appearance (toggle macOS System Settings → Appearance to confirm it tracks).

- [ ] **Step 4: Confirm no AI attribution in the commit history for this branch**

Run: `git log --oneline main..HEAD`
Expected: clean conventional-commit subjects, no "Claude"/"Anthropic"/"Generated"/"Co-Authored-By" lines.
