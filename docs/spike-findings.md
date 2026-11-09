# Platform spike findings

Spike plan: `docs/superpowers/plans/2026-11-10-platform-spike.md`. Code: `spike/` (throwaway).
Answers the open questions in spec §12.1. Times are UTC, with Adelaide local time in brackets.

## Environment

- macOS 27.2 (Darwin 27.2.0), Xcode 27.2 (27B52), XcodeGen 2.46.0, Apple silicon.
- restic 0.19.1 upstream `restic_0.19.1_darwin_arm64.bz2`, SHA-256 `7be0a144…ac143` matching the release `SHA256SUMS`. It's re-signed with the app identity and hardened runtime, with identifier `com.jaydenkerr.restorey.spike.restic`.
- Team `X72LEXP4DY`. Phase A signing uses the automatic "Apple Development: Jayden Kerr (8F7K4LGEQH)" identity, and Xcode supplies "Mac Team Provisioning Profile: \*" to both the app and the agent.
- Bundle layout:
  - `RestoreySpike.app/Contents/Helpers/RestoreySpikeAgent.app` (LSUIElement helper app, the LaunchAgent)
  - `RestoreySpike.app/Contents/Helpers/restic`
  - `RestoreySpike.app/Contents/Library/LaunchAgents/com.jaydenkerr.restorey.spike.agent.plist`, with `BundleProgram`, `MachServices`, `KeepAlive`, `RunAtLoad` and `ProcessType=Adaptive`
- Entitlements, identical on the app and the agent apart from `application-identifier`: `keychain-access-groups = [X72LEXP4DY.com.jaydenkerr.restorey.spike]`.

### Designated requirements (phase A, Apple Development)

```
app:    identifier "com.jaydenkerr.restorey.spike" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Jayden Kerr (8F7K4LGEQH)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
agent:  identifier "com.jaydenkerr.restorey.spike.agent" and … (same certificate clause)
restic: identifier "com.jaydenkerr.restorey.spike.restic" and … (same certificate clause)
```

**First finding (Task 1).** The Apple Development requirement pins the leaf certificate's common name, which names one person's development certificate. TCC stores grants against the designated requirement. So grants to a development build should be lost whenever that certificate is renewed or replaced, and they won't carry over to Developer ID builds. Developer ID requirements pin the team (`leaf[subject.OU]`) instead, which is what makes grants survive updates. Phase B checks this.

## H1 — One Full Disk Access grant covers the agent and restic

### Negative control (no grant), 9 Nov 2026 22:35 UTC (10 Nov 09:05)

- Triggered over XPC from the app, so the agent runs under launchd. The terminal used for inspection has no FDA itself: it can't open `~/Library/Application Support/com.apple.TCC/TCC.db`.
- In the agent: `~/Library/Safari`, `~/Library/Mail` and `~/Library/Messages` were all `denied: NSCocoaErrorDomain 257`.
- restic as the agent's child: **exit code 3**, with 6 "operation not permitted" errors (scan and archival for each folder), **and it still wrote a snapshot** of 3 empty directories (`dirs_new: 3`).
- **Consequence for v0.1 (anti-goal 3):** without FDA, a backup produces a snapshot and exit code 3, which looks like "partly worked". The agent has to recognise "operation not permitted" errors on source paths as **missing Full Disk Access**, an error state with a fix action, not the ordinary "some files skipped" warning.

## H2 — Keychain password helper from launchd, no prompt

_Pending (Task 4)._

## H3 — Agent process shape: registration, lifecycle, notifications

### H3a — Registration and lifecycle (Task 2, 9 Nov 2026 22:28–22:36 UTC (10 Nov 08:58–09:06))

- **Registration needed no approval.** `SMAppService.agent(plistName:).status` read `notFound` before the first `register()`, not `notRegistered`. The app has to treat `notFound` as "not registered yet" on first launch, not as a broken bundle. `register()` went straight to `enabled` and launchd started the agent within about 1 s. Nothing had to be approved in Login Items.
- **How Login Items records it** (`sfltool dumpbtm`): one parent item `RestoreySpike` (type app, Developer Name "Jayden Kerr", team X72LEXP4DY). Under it is a child `RestoreySpikeAgent` (type agent, `Parent Identifier: 2.com.jaydenkerr.restorey.spike`, disposition `enabled, allowed, notified`). The child's name is the agent's **executable/product name**, not its `CFBundleDisplayName`. So the real agent's product name needs to read well, e.g. "Restorey Agent".
- **XPC:** a Mach service declared in the plist's `MachServices` works. The agent sets `setConnectionCodeSigningRequirement` to accept only the app's identifier plus team OU, and the app's connections pass it.
- **KeepAlive:** after `kill -9` of the agent, launchd had a new agent process **0.4 s** later, and the app's heartbeat recovered on its next 10-second ping.
- **Replacing the app bundle while the agent runs** (same build): the old agent process kept running from its now-deleted binary and served the new app fine.
- **Agent killed during a restic run (review focus 3):** restic, a child of the agent, **died with the agent**. Nothing was orphaned and no restic process remained 3 s later. The likely cause is launchd cleaning up the job's process group when the job exits (`AbandonProcessGroup` defaults to false), or SIGPIPE on restic's closed stdout. Either way, crashes don't leave orphans.
- **…but they do leave a stale lock.** The dead restic's lock (non-exclusive, `hostname pepper.home.kerr.host`, pid 33485) stayed in `locks/`.
  - A following exclusive `restic check` **failed at once with exit code 11**: "repository is already locked by PID 33485". So taking an exclusive lock doesn't skip stale locks.
  - A plain `restic unlock` (no `--remove-all`) removed it, and `check` then passed. restic 0.19.1 `internal/restic/lock.go` `Stale()` counts a lock as stale if it is more than 30 min old (`StaleLockTimeout`), or if it was created on **this host** and its pid can't be reached.
  - **Consequence for v0.1:** run a plain `restic unlock` before maintenance commands, and after any agent restart. It only removes locks restic itself judges stale, so another live client's lock is never touched, which meets spec §5.6 and §12.5. Never use `--remove-all`.
  - **Caveat:** restic compares `os.Hostname()`, which on this Mac is the network-dependent `pepper.home.kerr.host`. After a network change, the Mac's own crashed-run locks look foreign until they are 30 minutes old.

## H4 — How backend credentials reach restic

_Pending (Task 6)._

## H6 — Manual N→N+1 update

_Pending (Tasks 7 and 8)._

## Phase B — Developer ID, notarisation, real quarantine

_Pending (Task 8)._
