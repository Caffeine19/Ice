---
name: fork-features
description: "Use when: documenting a new fork-specific feature in the Ice README's 'Additional Features in This Fork' section; updating that section after a feature commit; or checking whether a change belongs there. Keywords: additional features, fork features, README section, fork changelog."
argument-hint: "Describe the feature to document (or omit to sync all recent commits)"
---

# Document Fork-Specific Features in the README

Maintain the **Additional Features in This Fork** section of [README.md](../../../README.md) — the list of features this fork (`Caffeine19/Ice`, based on upstream tag `0.11.12`) adds on top of upstream Ice.

## When to Use

- After committing a user-facing fork feature that is not in upstream Ice
- When asked to "update the fork features list" / "document this feature in the README"
- When unsure whether a change belongs in this section (see Qualification)

## Qualification — What Belongs Here

Include only changes that are:

- **User-facing**: a behavior/feature a user can perceive, not pure refactors or build plumbing
- **Fork-specific**: not present in upstream `jordanbaird/Ice` (baseline: tag `0.11.12` = commit `d567f1e`)
- **Committed**: planned-but-unimplemented ideas do not belong (check `git log d567f1e..HEAD`)

Exclude: version bumps, build/signing scripts, code-only polish with no perceivable behavior change. Small visual tweaks may be folded into an existing parent bullet (e.g. under "Search panel") rather than listed alone.

## Section Format (bullet-note style)

- Location: README.md, between `## Features/Roadmap` and `## Why does Ice only support macOS 14 and later?`
- Rules:
  - Only `-` bullets, 2-space indent per nesting level
  - Top-level bullet = feature name (plain text, NO bold `**`)
  - Second level = one description sentence (English, concise, user-benefit oriented)
  - Related sub-tweaks of one feature share a parent bullet with third-level children (see "Search panel")
  - Italics `_..._` for UI pane names (_Displays_, _Menu Bar Layout_); plain text for setting names
- Order: most significant features first (major behavior features → navigation/UX → minor tweaks)

Example shape:

```markdown
- Feature name
  - One-sentence description. Optional second sentence for defaults/migration semantics.
- Feature area
  - Sub-tweak name
    - Description.
  - Sub-tweak name
    - Description.
```

## Procedure

1. Identify the change: `git log d567f1e..HEAD --oneline` and `git show --stat <commit>`; for context, the originating chat session can be located via the search-chat-session workflow
2. Check qualification (above); if it maps to an existing parent bullet, add a child instead of a new top-level entry
3. Edit README.md following the section format; write in the section's existing voice (plain, benefit-first, no emoji)
4. Confirm placement: new bullets go under `## Additional Features in This Fork`, never appended to upstream's `## Features/Roadmap`
5. Show the user the diff; commit separately (suggest message style: `Document fork-specific features in the README` or `Add <feature> to the fork features list`) — never commit without asking

## Current Inventory (as of 2026-10-17)

- Per-display Ice Bar settings (`5eb0cdd`)
- Menu bar layout memory (`0d42cd5` + hardening `be80700`)
- Search panel: Ctrl+N/Ctrl+P navigation (`16af3a7`) + visual refinements (`f6c6c23`, `ca3d5a1`)
- Settings window defaults to Menu Bar Layout (`8bee340`)

Known planned-but-absent (do not document until committed): Ice Bar grid layout, ⌘H move-to-hidden shortcut.
