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

**Verdict: confirmed (phase A, Apple Development signing).** One FDA grant to `RestoreySpike.app` covers the LaunchAgent and the restic it launches. Nothing else appears in the FDA list and nothing else needs granting.

### With the grant, 9 Nov 2026 22:41 UTC (10 Nov 09:11)

- The owner added only `/Applications/RestoreySpike.app` under Privacy & Security → Full Disk Access. It showed as "RestoreySpike" with its icon, and macOS added nothing else.
- **The grant reached the already-running agent** (pid 35286, started before the grant) **with no restart.**
- In the agent: Safari, Mail and Messages all `ok`.
- restic as the agent's child: **exit code 0, 0 permission errors**, 128,922 files and 20.3 GB processed in 84 s.
- TCC log (`log stream`, subsystem `com.apple.TCC`): `Handling access request to kTCCServiceSystemPolicyAllFiles, from Sub:{com.jaydenkerr.restorey.spike}Resp:{TCCDProcess: identifier=com.jaydenkerr.restorey.spike.agent, pid=35286 …}`. The **subject is the app's bundle ID** and the agent is the responsible process. restic produced no separate request. This matches Apple DTS's description: an `SMAppService`-installed agent makes the app the responsible code, and so do its children.
- **Safety note for the probe itself:** a real backup of those folders copied about 10 GB of the owner's mail and messages into the local test repository. The repository and its password file were deleted straight afterwards, and later FDA probes use `restic backup --dry-run`, which still reads every file but writes nothing. The real app's onboarding FDA check should probe the same way, by listing a directory, never by backing up the user's mail.
- **Unverified in phase A:** the fallback path (§12.1 "guided two-item grant") wasn't needed, so it wasn't exercised.

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
- **The user switches the agent off in Login Items (review focus 4)**, 22:37:41–22:38:05 UTC. The owner reports the entry shows as "RestoreySpike" with its icon. Switching it off made launchd **remove the job and stop the agent** ("service inactive … removing service"). The app's heartbeat then failed ("Could not find job with label …"). Switching it on re-submitted the job ("Setting service … to enabled (initiated by smd)") and launchd started a new agent within 0.2 s. **Consequence:** the menu bar app's heartbeat is what catches this (spec §6.2), because nothing else does. Not captured: the exact `SMAppService.Status` value while it was off. `sfltool dumpbtm` hung, and polling it from a script is not usable.
- **Background Task Management stores a SHA-256 of the agent executable** (`BTMConfigSHA256Checksum` in `backgroundtaskmanagementd` logs). Task 7 checks whether a changed binary after an update triggers re-approval.
  - **Caveat:** restic compares `os.Hostname()`, which on this Mac is the network-dependent `pepper.home.kerr.host`. After a network change, the Mac's own crashed-run locks look foreign until they are 30 minutes old.

## H4 — How backend credentials reach restic

_Pending (Task 6)._

## H6 — Manual N→N+1 update

_Pending (Tasks 7 and 8)._

## Phase B — Developer ID, notarisation, real quarantine

_Pending (Task 8)._
