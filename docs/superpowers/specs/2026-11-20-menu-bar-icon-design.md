# Menu bar icon: drive with a corner badge (design)

Owner, 20 Nov 2026. Replaces the "Layers" glyph signed off on 17 Nov.

## Why

The Layers glyph (three stacked snapshot layers, the top one swapped for the state) doesn't work at menu bar size. In
the warning state it is a barely legible "!" floating over two faded dashes, hard to decipher. The owner liked the idea
but preferred the earlier icon: a drive with the state as an overlay in the bottom-right corner.

## Goals

- The state readable at a glance, in every state, light and dark menu bar.
- Sit with the system's own menu bar icons: same weight, tinted and dimmed by the menu bar like they are.
- Not mistakable for Time Machine (audit P12, the reason the earlier drive icon was retired: its OK state used
  `externaldrive.badge.timemachine`, whose clock badge invites confusion with Apple's own extra).

Non-goals: the app icon ("Snapshots", Icon Composer) stays as it is. The open menu, the tooltip and the accessibility
descriptions are unchanged. Colour in the menu bar stays out (owner, 12 Nov 2026: monochrome).

## Approaches

1. **System drive symbol, badge drawn in code (chosen).** SF Symbols' `externaldrive` with a filled circle badge
   composited in the bottom-right corner, cut out of the drive with a small gap. Matches the system's weight, renders
   crisp at any scale, template-tinted. Generic drive, so it doesn't echo the app icon; acceptable.
2. **The snapshot layers as the base with the same badge.** Matches the app icon, but three bars plus a badge in
   about 16 pt is busy, and hand-drawn art drifts from the system weight. Rejected.
3. **A custom symbol made in the SF Symbols app.** Best weight matching, but much more work for no visible gain in a
   monochrome menu bar. Rejected.

Rendered comparison (owner saw it, 20 Nov 2026): row A of the scratch sheet, the drive with bottom-right filled badges,
read well on light and dark; Apple's built-in `externaldrive.badge.*` symbols put the badge bottom-left and have no
upload or pause badge, so they don't fit.

## Design

| State | Image |
|---|---|
| Up to date: every plan has a backup and nothing is wrong | `externaldrive` + `checkmark.circle.fill` |
| Nothing to report yet: no problem, but a plan has no backup yet, or Restorey is still connecting | `externaldrive`, no badge |
| No plans at all | a warning ("No backup plan yet"): `externaldrive` + "!" |
| Backing up | `externaldrive` + `arrow.up.circle.fill` |
| Paused | `externaldrive` + `pause.circle.fill` |
| Needs attention | `externaldrive` + `exclamationmark.circle.fill` |
| A problem stops backups | `externaldrive` + `xmark.circle.fill` |

- **Badge:** a filled circle symbol in the bottom-right corner, drawn over a slightly larger circle cleared out of the
  drive (destination-out), so the badge reads as separate from the drive outline. All six symbol names exist on macOS
  27.2 (checked with `NSImage(systemSymbolName:)`, 20 Nov 2026).
- **One canvas for every state** (drive plus room for the badge), so the icon doesn't change width or move between
  states. The drive sits at the same place in all six.
- **Size and weight:** the drive at the weight and size of the system's menu bar icons (Wi-Fi, battery); the badge
  about 60 % of the icon's height. Tuned against a real menu bar, not guessed. **Chosen (20 Nov 2026):** the drive at
  SF Symbols' default size (18 × 13 pt, the same as `wifi`), the badge 72 % of the drive's height (62 % made the marks
  too small), a 1.5 pt cleared gap, one 22 × 16 pt canvas.
- **Template image** (`isTemplate = true`): the menu bar tints it for light and dark and dims it on an inactive
  display.
- **Up to date has to say so (owner, 20 Nov 2026: "we need some state to say it's up to date").** Today's `.ok`
  also covers "No backup yet" (just after setup), where a tick would claim backups that don't exist (no plans at all
  is already a warning). So `StatusIconState` gains a case for that: the icon is up to date (tick) only when every plan has a backup
  that saved data (`PlanStatus.lastBackup`, the same record the menu's "Backed up at …" line reads) and nothing ranks
  higher; otherwise, with no problem, running or paused plan, it is the plain drive. A backup that has gone stale is
  already a warning ("No successful backup in N days"), so the tick never sits on an old backup. Its tooltip stays
  as today ("Restorey — Last backup …" / "Restorey — No backup yet").
- **My call:** the error state uses the outline drive like the others; the "×" badge is what sets it apart. A filled
  drive with a cut-out read as broken in the comparison.

## What changes

- `RestoreyCore`: `StatusIconState` gets the new case (ranked lowest), `MenuPresentation.icon` decides it, and
  `MenuPresentationTests` pin both: a fresh plan with no backup is the plain drive, every plan backed up is the tick,
  and any problem, run or pause still wins over both.
- `App/StatusIcon.swift`: draws the images from SF Symbols instead of loading the asset catalog. A missing badge
  symbol falls back to the plain drive and logs a fault, as the asset lookup does today. **Follow-up (v0.1.2, 20 Nov
  2026):** a missing `externaldrive` falls back to the letter "R" in the system menu bar font on the fixed 22 × 16 pt
  canvas, so the item stays clickable (it was an empty image); the drive and its destination-out cut-out are drawn in
  a transparency layer (`CGContext.beginTransparencyLayer`), so the cut-out clears only the drive, never what the
  image is drawn over.
- **Start-up recovery isn't a backup (L168, v0.1.2):** after a restart the icon showed "backing up" for about 6 s
  with no backup in History. The cause was the agent: start-up recovery registered its `restic unlock` as a run of
  the plan (`PlanRunner.begin` → `AgentState.beginRun`), so the plan's phase was `.running` for the unlock (the dev
  agent's 20 Nov 05:42 restart: `unlock` 05:42:50.06–05:42:55.40). It now registers the unlock like the measurement
  after an adopt (`beginMeasurement`): a drain waits for it and the system stop reaches it, but the phase is
  untouched. A pause can't reach it (the state gets the runner only after recovery), and a delete meanwhile is
  refused at once as "still starting up", as Back Up Now is, rather than waiting for restic. The fix is in the agent,
  where the phase is decided, not in the icon.
- `App/Assets.xcassets`: the five `Status*` image sets are removed.
- `scripts/verify-bundle.sh`: drops its check that the five glyphs are template images in `Assets.car`.
- Docs: the menu bar icon passages in the UI spec (§ menu bar, Icon), the README ("The menu bar"), and the product
  spec's icon-states line, so all three describe the drive and badges.

## Checks

- An off-screen render of all six states on a light and a dark bar, compared side by side.
- On the owner's Mac (RestoreyDev): the live icon in its idle state beside the system icons.
- `scripts/ci.sh` once.

## Left to the builder

The exact point size, badge size and gap, chosen by comparing renders with the system icons in the menu bar.
