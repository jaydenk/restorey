# Handoff — v0.1 UI (plan 2), written 2026-11-16T00:58Z before the owner's restart test

Read this first after the Mac restarts. The authoritative record is `progress.md` in this folder (ledger,
every "Ruling:" line); `git log` on branch `v0.1-ui` is the code record.

## Where we are
- Branch `v0.1-ui`, HEAD **56db946**, working tree clean (TODO.md is gitignored). Nothing pushed; pushing,
  PR and merge still need the owner's approval.
- Tasks 1–14, 14b and 14c: **complete** (ledger lines). Task 15 Steps 1, 2, 4 (Network pane, History pane,
  Release without the Developer window, README usage): **complete and reviewed** (acfcb24, 56db946),
  controller live-checked on build 823.
- Installed: `/Applications/RestoreyDev.app` **build 823** (56db946), dev identity
  `com.jaydenkerr.restorey.dev`. Login item state: whatever the owner chose in setup (never enable it ourselves).

## Task 15 Step 3 — owner's live checks (in progress)
Recorded so far (to be written into `docs/v0.1-measurements.md`, placeholder section exists, then committed):
1. **Fresh setup with nothing but the app — PASS** (2026-11-16 ~00:55Z). Owner had no existing repository:
   new **B2 bucket**, **whole home folder**, new repository. "Smooth enough." Owner asked for a **visual polish
   pass before 1.0** (added to TODO.md; carry into the final list).
2. During the first backup: progress on Done screen, Overview progress bar/status, menu bar icon and menu
   (light + dark) — **all look good** (owner). This closes the owed checks "Done's progress during a long first
   backup", "Overview progress bar on a larger backup", "menu icons and highlighting in light and dark".
3. **NEXT — restart during the first backup (R67/R78):** owner restarts normally (Apple menu) with the first
   backup running and Restorey Dev not quit. After login, without opening anything, ask the owner:
   - did the menu bar icon come back on its own?
   - what did the menu and Overview say right after login?
   - did the backup resume (or what instead)?
   Evidence to collect (read-only): `~/Library/Logs/Restorey-Dev/agent.log` and `app.log` around the restart
   (UTC timestamps), `~/Library/Logs/Restorey-Dev/runs/`, `state.json` in
   `~/Library/Application Support/com.jaydenkerr.restorey.dev/`, and `/usr/bin/log show` (zsh) for the agent.
   Never run restic against the owner's B2 repository and never print its secrets.
4. Then: **logout during a later backup**, **wake catch-up after real sleep** (no caffeinate), **a day of
   hourly runs** with no attention needed. Location Services off Mac-wide is optional (never observed).

## After Step 3
- Record results in `docs/v0.1-measurements.md`, update README if needed, commit (no Co-Authored-By or
  session trailers; docs in the same commit), ledger "Task 15: complete".
- Final whole-branch review on the most capable model, then ONE fix dispatch + scoped re-review. Carry every
  "Parked for final review" item in progress.md (Tasks 9–15, N1–N4, 14c minor 6, Task 14b M1–M3/M7 etc.,
  Task 15 R1 minors) plus the owner's polish-pass request.
- finishing-a-development-branch (push/PR only with approval). At the end, list every ledger "Ruling:" line
  for the owner.

## Standing constraints (short)
Australian English; UTC timestamps (run `date`); builds/tests local, team X72LEXP4DY; install with
`BUILD_NUMBER=N scripts/install-dev.sh` then `open -g /Applications/RestoreyDev.app`; never touch
`com.jaydenkerr.restorey` in tests; no Touch ID/admin/password/Location prompts or probes by us; screen
captures of Restorey's own windows only (never a full display, never the Open panel — it shows personal
files); never touch the owner's B2 bucket or real repository; never enable the login item; never relax the
helper's code-signing requirements; look before deleting; send keystrokes only to Restorey windows, never
globally while another app is frontmost.
