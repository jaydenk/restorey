## Global Constraints

- Swift 6 language mode; deployment target macOS 27; Xcode 27; XcodeGen `project.yml` is the project source.
- Australian English in all UI text, docs and comments; curly quotes (“ ” ’) in UI strings; menu titles in title case
  with "…" only where more input follows.
- No secrets cross XPC except `recoveryKit`'s reply; nothing new logs a secret.
- Never run restic against a real repository, read the Keychain, or touch `~/Library/Application Support/com.jaydenkerr.restorey*`
  or TCC; don't launch the installed app; no on-screen windows or menus popped on the owner's Mac.
- No CPU-load, stress, repeated or looping test runs. Focused tests while working; `scripts/ci.sh` once at the end of
  each task, only when no `RestoreyDev.app/Contents/Helpers/restic` is running and the 1-minute load is below 15
  (wait up to 60 minutes, else report). GitHub CI (3–4 core runner) is the real gate: the controller checks it after
  every push.
- Tests follow README's rule (Task 18b): a deadline in a test is the subject (tiny, work held past it) or unreachable;
  wait for events with handshakes, never fixed sleeps; inject `ManualClock` (TestSupport) for time.
- Commits: no Co-Authored-By or session trailers; docs (README, specs) updated in the same commit as the behaviour.

## Review Focus

1. **Symlinked and differently spelled paths.** A folder added through a symlink, with a trailing slash, or with `..`
   in it is compared by the place it leads to: `~/Downloads` via a symlink is still "already included" under `~`.
   (Task 1: `aFolderReachedThroughASymlinkIsStillCovered`.)
2. **Name-prefix false positives.** `/Users/me/Doc` must not count as containing `/Users/me/Documents`, nor
   `/Volumes/Backup` contain `/Volumes/Backups`. (Task 1: `aSiblingWhoseNameStartsTheSameIsNotCovered`.)
3. **The clock going backwards during a long pause.** A stored `pausedUntil` can never hold a plan more than 24 hours
   after `now`. (Task 3: `aPauseIsNeverLongerThanADayEvenIfTheClockWentBack`.)
4. **Cancel racing a run's end or a pause.** Cancel after the run ended, or while a pause is already stopping it,
   changes nothing and keeps the pause. (Task 4: `cancelAfterTheRunEndedDoesNothing`,
   `cancelWhileAPauseIsStoppingTheRunKeepsThePause`.)
5. **An unknown pause length over XPC** (an app and agent from different builds during an update, or a malformed
   request) is refused with a clear sentence and pauses nothing. (Task 3: `anUnknownPauseLengthIsRefused`.)
