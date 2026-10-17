# Ice — Project Guidelines

When using these instructions, say "⌘ Using copilot-instructions.md" explicitly.

## Overview

macOS menu bar manager (hide/show menu bar items) — a personal fork of [jordanbaird/Ice](https://github.com/jordanbaird/Ice) with features ported from Thaw. GPL-3.0, Swift/SwiftUI, deployment target macOS 14.

Working branch: `port-base/0.11.12` (based on upstream tag 0.11.12 + fork features). Releases publish to the fork repo (`Caffeine19/Ice`) as `x.y.z-fork.N` tags.

## Architecture

- **`AppState`** (`Ice/Main/AppState.swift`) — single `@MainActor ObservableObject` hub; lazily owns every manager (classic manager-composition pattern)
- **`Ice/MenuBar/`** — core domain: `MenuBarManager` + `MenuBarSection` (visible/hidden/always-hidden sections), item caching, control-item dividers, appearance overlays, search panel, layout bar
- **`Ice/Settings/`** — settings window + panes (General, **Displays**, Menu Bar Layout, Appearance, Hotkeys, Advanced…) backed by `SettingsManagers/` persisting to `Defaults`
- **`Ice/Events/`, `Ice/Hotkeys/`** — CGEvent taps/monitors; global hotkey registry
- **`Ice/UI/`** — IceBar panel, LayoutBar, shared `IceUI` form components
- **`Ice/Bridging/`** — private API shims (SkyLight/CGS) via `@_silgen_name`

Fork-specific additions: **per-display settings** (`DisplaySettingsManager`, keyed by display UUID), **section-reconciliation layer** (`MenuBarItemManager` — persists item→section assignment and restores after macOS repositions items), ⌃N/⌃P search navigation.

## Build & Run

Tasks live in `.vscode/tasks.json` → `scripts/*.sh`:

- After editing code, always run the **"Verify Build"** task to check for compile errors.
- Use `get_errors` tool to verify no lint/compile errors remain in edited files.
- Use the **"Run App"** task to build and launch (quits any running Ice first — same bundle id).
- Use the **"Release App"** task for release zips (`dist/Ice-<tag>.zip`), **"Publish Release"** to build + `gh release create`.

Signing (worked out the hard way — do NOT change without reading this):

- Recipe: `CODE_SIGN_STYLE=Automatic` + `DEVELOPMENT_TEAM=HMNPYJ4S3K` (Xcode "Caffeine Cat" personal team) + `-allowProvisioningUpdates` + `ENABLE_HARDENED_RUNTIME=NO`.
- The `CODE_SIGN_IDENTITY` may display `(BMBKK432MM)` but the cert's **OU is HMNPYJ4S3K** — team lookups must use the OU. Never pass the short name with Manual signing (legacy "Mac Development" lookup fails).
- `ENABLE_HARDENED_RUNTIME=NO` is mandatory: ad-hoc-signed nested Sparkle fails hardened-runtime library validation (app killed at launch).
- This cert-anchored signature makes TCC grants (Accessibility/Screen Recording) survive rebuilds. Verify with `codesign -d -r- <app>` — DR must reference the certificate, not a `cdhash`.

## Key Types

| Type                         | Definition                            | Notes                                                                         |
| ---------------------------- | ------------------------------------- | ----------------------------------------------------------------------------- |
| `AppState`                   | ObservableObject hub                  | Entry to all managers                                                         |
| `MenuBarSection`             | section (visible/hidden/alwaysHidden) | Owns control item + `updateControlItemState`                                  |
| `ControlItem`                | divider NSStatusItem                  | Identifiers "SItem"/"HItem"/"AHItem"; `Lengths.expanded = 10_000` hides items |
| `MenuBarItemInfo`            | namespace + title                     | Stable item identity for caches                                               |
| `DisplayIceBarConfiguration` | Codable struct                        | Per-display: useIceBar / location / alwaysShowHiddenItems                     |

## Conventions

- **Section membership is GEOMETRIC** (item x-coordinates vs divider positions), but the reconciliation layer persists and restores assignments — don't add "smart" reassignment logic that fights it
- **Logging**: `os.Logger` categories — never `print()`
- **Defaults**: homegrown `Defaults` wrapper (`Ice/Utilities/Defaults.swift`), complex values as JSON `Data` blobs
- **pbxproj**: uses `PBXFileSystemSynchronizedRootGroup` — new files under `Ice/` are picked up automatically, no manual registration
- **Commits**: English imperative single-line titles ("Add …", "Fix …"), no emoji; ask before committing
- **Releases**: bump `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in pbxproj first, then publish with tag `x.y.z-fork.N`
