# Menu Bar Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the "Layers" menu bar glyph with the system drive symbol and a bottom-right status badge, with a tick
only when every plan really is backed up.

**Architecture:** `RestoreyCore` decides the icon state (`MenuPresentation`); a new lowest state, `.idle`, splits "nothing
to report yet" from "up to date" (`.ok`). The app (`App/StatusIcon.swift`) draws each state from SF Symbols at run
time: `externaldrive` plus a filled circle badge composited in the bottom-right corner. The SVG assets go.

**Tech Stack:** Swift 6.4, AppKit (`NSImage`, SF Symbols), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-20-menu-bar-icon-design.md`

## Global Constraints

- Monochrome menu bar: every icon is a template image (`isTemplate = true`) (owner, 12 Nov 2026).
- Symbols, exactly: `externaldrive`; badges `checkmark.circle.fill` (up to date), `arrow.up.circle.fill` (backing up),
  `pause.circle.fill` (paused), `exclamationmark.circle.fill` (needs attention), `xmark.circle.fill` (a problem stops
  backups); `.idle` has no badge. The drive is the outline `externaldrive` in every state, error included.
- One canvas size for every state; the drive at the same place in all six.
- Accessibility descriptions and tooltips keep today's wording; `.idle` reads like `.ok` ("Restorey").
- Australian English in docs and comments. Docs updated in the same commit as the code.
- Builds and tests on this Mac. `scripts/ci.sh` once, at the end. No CPU-load loops.
- Commits: no Co-Authored-By or session lines.

## Review Focus

1. Restorey connecting or updating its background process (no status yet): must not show the tick → `.idle`.
2. A brand-new plan before its first backup, beside a plan that is backed up: no tick (every plan must have a backup).
3. No plans at all: no tick.
4. A plan whose only backups failed or were skipped (`lastBackup` nil) with no alert yet: no tick.
5. Any warning, error, running or paused plan still wins over both `.ok` and `.idle`.

Each has a test in Task 1.

---

### Task 1: The `.idle` icon state

**Files:**
- Modify: `RestoreyCore/Sources/RestoreyCore/App/AgentPresentation.swift:27-35` (`StatusIconState`)
- Modify: `RestoreyCore/Sources/RestoreyCore/App/MenuPresentation.swift` (`icon(banners:plans:lines:)` ~line 331; the
  `MenuContent(icon: .ok, …)` literals for connecting, updating and no status ~lines 240, 242, 272; `toolTip` ~line 322)
- Test: `RestoreyCore/Tests/RestoreyCoreTests/App/MenuPresentationTests.swift`

**Interfaces:**
- Produces: `StatusIconState` cases, least to most severe: `idle, ok, backingUp, paused, warning, error`.
  `.ok` = every plan has a backup that saved data (`PlanStatus.lastBackup != nil`), at least one plan, nothing higher.
  `.idle` = otherwise, with nothing higher (including connecting, updating, no plans).

- [ ] **Step 1: Write the failing tests** in `MenuPresentationTests` (use the file's `line(_:backedUpAt:…)` helper;
  `backedUpAt: nil` gives no backup):

```swift
@Test func theTickNeedsEveryPlanBackedUp() {
    let home = Self.plan("Home"), photos = Self.plan("Photos")
    #expect(Self.make(Self.status([Self.line(home), Self.line(photos)])).icon == .ok)
    #expect(Self.make(Self.status([Self.line(home), Self.line(photos, backedUpAt: nil)])).icon == .idle)
    #expect(Self.make(Self.status([Self.line(home, backedUpAt: nil)])).icon == .idle)
    #expect(Self.make(Self.status([])).icon == .idle)
}

@Test func problemsRunsAndPausesBeatTheTickAndIdle() {
    let fresh = Self.plan("Fresh"), done = Self.plan("Done")
    #expect(Self.make(Self.status([Self.line(fresh, backedUpAt: nil), Self.line(done, phase: .running(nil, retrying: nil))])).icon == .backingUp)
    #expect(Self.make(Self.status([Self.line(fresh, backedUpAt: nil), Self.line(done, phase: .paused(until: Self.at(15, 0)))])).icon == .paused)
    #expect(Self.make(Self.status([Self.line(done, alerts: [.backupFailed])])).icon > .ok)
}

@Test func connectingOrUpdatingIsNeverTheTick() {
    // health .checking and .waitingForUpdate, and .healthy with no status yet: icon == .idle
}
```

  Fill the last test with the file's existing `make(health:status:)` calls for the "Connecting…" and "Updating…"
  messages (the same inputs the existing connecting/updating tests use), each asserting `.icon == .idle`.

- [ ] **Step 2: Run** `swift test --package-path RestoreyCore --filter MenuPresentationTests`.
  Expected: build failure (`.idle` doesn't exist).

- [ ] **Step 3: Implement.** Add `case idle` first in `StatusIconState` and update its doc comment (`.idle` nothing to
  report yet; `.ok` up to date). In `icon(banners:plans:lines:)` start from
  `!plans.isEmpty && plans.allSatisfy { $0.lastBackup != nil } ? .ok : .idle`, then take the existing `max`es. The
  connecting, updating and no-status `MenuContent` literals use `.idle`. In `toolTip`, `.idle` shares the `.ok` branch.

- [ ] **Step 4: Run** the filtered tests, then the whole suite: `swift test --package-path RestoreyCore --filter
  RestoreyCoreTests`. Fix existing tests that assert `.ok` for a state with no backup (they now expect `.idle`); change
  no assertion whose plan has a backup.
  Expected: all pass.

- [ ] **Step 5: Commit** "Menu bar icon state: up to date only when every plan is backed up".

### Task 2: Drive with a corner badge

**Files:**
- Modify: `App/StatusIcon.swift` (whole file)
- Delete: `App/Assets.xcassets/Status{Idle,BackingUp,Paused,Attention,Error}.imageset/`
- Modify: `scripts/verify-bundle.sh:86-103` (the glyph block)
- Modify docs: `docs/superpowers/specs/2026-11-12-restorey-v0.1-ui-design.md` (Icon bullet ~line 137),
  `README.md` ("The menu bar" icon paragraph), `docs/superpowers/specs/2026-11-09-restorey-design.md` (icon states,
  line 110)

**Interfaces:**
- Consumes: `StatusIconState` from Task 1 (six cases).
- Keeps: `StatusIcon.image(for:) -> NSImage` and `StatusIcon.accessibilityDescription(for:) -> String` (callers in
  `StatusItemController` unchanged). Removes `assetName(for:)`.

- [ ] **Step 1: Render check first.** Write a throwaway script in the session scratchpad that draws all six states
  with the exact drawing code planned for `StatusIcon` on a light and a dark bar beside `wifi` and `battery.100percent`
  at menu bar size, and look at it. Tune point size, badge size (about 60 % of the icon's height) and the cut-out gap
  until the drive matches the system icons' weight and every badge reads. Record the chosen numbers.

- [ ] **Step 2: Implement `StatusIcon`.** `badge(for: StatusIconState) -> String?` gives the symbol names in Global
  Constraints (`nil` for `.idle`). `make(_:)` draws `externaldrive` and, when there is a badge, clears a circle slightly
  larger than the badge (destination-out) in the bottom-right corner and draws the badge in it; one canvas size for all
  states, from the drive plus badge room; `isTemplate = true`; images cached per state as today. A symbol that fails to
  load logs a fault (as today) and falls back to the plain drive. Doc comment: describes the drive and badges, cites the
  spec. `.idle` accessibility description: "Restorey".

- [ ] **Step 3: Remove the assets and the bundle check.** Delete the five image sets (keep `Assets.xcassets/Contents.json`
  and anything else in the catalog). In `verify-bundle.sh`, remove the glyph loop and its comment; keep the app-icon
  checks.

- [ ] **Step 4: Docs.** Replace the Layers descriptions with the drive and badges table (six states, the tick only when
  every plan has a backup, plain drive otherwise, one canvas, template image, owner 20 Nov 2026), in the UI spec, the
  README and the product spec's icon-states line.

- [ ] **Step 5: Verify.** `scripts/ci.sh` → "All CI checks passed". Then `BUILD_NUMBER=834 scripts/install-dev.sh`,
  and look at the live icon in the menu bar (the owner's plan currently has "3 files couldn't be read", a warning:
  expect the "!" badge; the tick appears once a backup reads every file).

- [ ] **Step 6: Commit** "Menu bar icon: the system drive with a status badge in the corner".
