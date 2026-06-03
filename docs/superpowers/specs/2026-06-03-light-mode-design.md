# Light Mode — Design

**Date:** 2026-06-03
**Status:** Approved

## Problem

PRPilot effectively only works in dark appearance. It does not *force* dark mode
anywhere — there is no `.preferredColorScheme(.dark)` and no
`NSRequiresAquaSystemAppearance` in the build settings — but the app looks wrong
under macOS Light appearance because one set of colors is hardcoded for dark
backgrounds. We want the app to look correct in light appearance and to give the
user explicit control over which appearance is used.

## Scope of the color problem

Audit of `App/` found that nearly all colors are semantic SwiftUI colors
(`.red`, `.green`, `.blue`, `.orange`, `.purple`, `.gray`, `.secondary`,
`.tertiary`) applied directly or with opacity. These already adapt to the active
color scheme. The GitHub `WebPane` renders web content controlled by GitHub, not
by us.

The **only** colors hardcoded for dark mode are the four `SectionStyle` band /
border / text definitions in `App/ContentView.swift` (lines 147–154), used by the
"My Work" and "Review Requests" sidebar section headers. One secondary issue: the
`StateBadge` view applies `.brightness(0.12)`, which washes out colored badge text
on a white background.

## Design

### 1. Appearance preference (data)

Add an `appearance: Appearance` field to `Settings` in
`Core/Sources/PRPilotModels/Settings.swift`, where `Appearance` is a new `Codable`
enum with cases `.system`, `.light`, `.dark`. The default is `.system`.

Decoding a settings file that lacks the field must fall back to `.system`, so
existing users are unaffected. This mirrors how `DiffMode` and `SidebarSort` are
already modeled, defaulted, and persisted.

`Appearance` exposes a computed property mapping to an optional `ColorScheme`:
`.system → nil`, `.light → .light`, `.dark → .dark`.

### 2. Applying the appearance (behavior)

Apply `.preferredColorScheme(settings.appearance.colorScheme)` at the app's root
view (`ContentView`) and to the `Settings` scene content. A `nil` value means
"follow the macOS system setting." Because this drives the SwiftUI environment,
every adaptive (semantic) color updates automatically, and the section-band colors
below recompute via `@Environment(\.colorScheme)`.

### 3. Settings UI

Add an **Appearance** tab to `SettingsView` containing a segmented `Picker` with
System / Light / Dark. The selection is written through the existing
`model.updateSettings(...)` flow used by all other settings, so persistence and
propagation are unchanged.

### 4. Section bands — tinted treatment (Option A)

Convert the `SectionStyle` static constants into values resolved from the current
`@Environment(\.colorScheme)`. The dark values are unchanged from today. The light
values use a soft tinted band, a colored left accent bar, and darker colored text,
mirroring the dark design's structure:

| Section          | Scheme | Band                | Accent / border     | Text                |
|------------------|--------|---------------------|---------------------|---------------------|
| My Work          | dark   | `rgb(42,53,80)`     | `rgb(108,140,255)`  | `rgb(157,180,255)`  |
| My Work          | light  | `rgb(232,238,255)`  | `rgb(70,110,240)`   | `rgb(40,70,170)`    |
| Review Requests  | dark   | `rgb(58,42,80)`     | `rgb(176,108,255)`  | `rgb(212,160,255)`  |
| Review Requests  | light  | `rgb(244,236,255)`  | `rgb(150,80,230)`   | `rgb(110,45,170)`   |

(Dark RGB values above are the existing `Color(red:green:blue:)` constants
expressed in 0–255.)

### 5. Badge legibility fix

Make the `StateBadge` `.brightness(0.12)` boost dark-mode-only (conditional on
`@Environment(\.colorScheme)`): keep `0.12` in dark, use `0` in light. This keeps
badges vivid in dark mode and legible on white in light mode.

## Out of scope

- The GitHub `WebPane` (web content controlled by GitHub).
- Any restyling of semantic colors that already adapt correctly.
- Unrelated refactoring.

## Testing

- Unit test in the `PRPilotModels` test target: `Settings` round-trips the
  `appearance` field, and decoding a JSON payload without the field defaults to
  `.system` (backward compatibility).
- Manual visual verification of the app under both Light and Dark appearance, and
  of the System / Light / Dark picker switching live.
