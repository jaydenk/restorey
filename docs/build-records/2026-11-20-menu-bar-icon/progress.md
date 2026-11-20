# SDD ledger — plan: docs/superpowers/plans/2026-11-20-menu-bar-icon.md
Spec: docs/superpowers/specs/2026-11-20-menu-bar-icon-design.md
Pre-flight: Task 2 consumes StatusIconState (six cases, .idle lowest) from Task 1 — consistent.
Task 1: Ruling: plan test asserted no plans → .idle, but no plans already raises the "No backup plan yet" warning banner, so the icon is .warning — kept the existing behaviour and asserted .warning (still never the tick, Review Focus 3) — cost if wrong: none, the banner predates this change.
Task 1: Ruling: App/StatusIcon.swift maps .idle to the current idle glyph so the app still builds between tasks — Task 2 replaces the file — cost if wrong: none.
Task 1: complete (commits 1e08484..e7a887f, tests: swift test --package-path RestoreyCore --filter RestoreyCoreTests → 􁁛  Test run with 1149 tests in 88 suites passed after 18.537 seconds.)
Task 2: Ruling: badge 72% of the drive height, not the spec's "about 60%" — at 62% the marks inside the badge were too small beside wifi/battery in the render; the spec leaves the exact size to tuning — cost if wrong: one constant.
Task 2: Ruling: no unit test for the drawing — the app has no test target; the state→badge mapping is a switch the compiler checks, and the drawing is verified by the side-by-side render (scratchpad bar.png) and the live icon — cost if wrong: a drawing regression found only by eye.
Task 2: Ruling: removed the now-empty App/Assets.xcassets as well as the five image sets — nothing else used it; the app icon lives in Resources/AppIcon.icon — cost if wrong: none.
Task 2: complete (commits e7a887f..7e6f44f, tests: swift test --package-path RestoreyCore --filter RestoreyCoreTests → 􁁛  Test run with 1149 tests in 88 suites passed after 24.603 seconds.)
Final review: opus reviewer — no Critical, no Important; Review Focus 1–5 all confirmed against the code.
Final: Ruling: Minor 3 (the .idle doc comment and the spec table said "no plans" gives the plain drive; it gives "!") re-graded Important under the plan's docs-match-code constraint — fixed in the comment and the spec (and "all five" → six); doc text, so no test — cost if wrong: none.
Final: Ruling: Minor 1's comment half (StatusIcon said a missing symbol leaves the plain drive; a missing drive leaves an empty image) — comment corrected; the fallback code itself deferred, below — cost if wrong: none.
Final: minor (deferred): a missing `externaldrive` symbol gives a 0×0 image, so the status item would vanish — unreachable on the macOS 27 target, where the symbol exists.
Final: minor (deferred): the badge's destination-out cut-out isn't wrapped in a transparency layer, so drawing the image straight into a view (not as the status button's template) would cut through that view too — not how it's used today.
Final: minor (deferred): tests don't pin Review Focus 4 with a failed/skipped latest record, and `problemsRunsAndPausesBeatTheTickAndIdle` checks `> .ok` rather than the exact state.
Final: declined by reviewer, ruled: a plan with an older good backup whose latest run failed before any alert fires still shows the tick — existing alert policy, unchanged by this branch; the tooltip with one plan backed up and another not still says "Last backup …" — the spec keeps tooltips as they are.
