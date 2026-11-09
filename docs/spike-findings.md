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

**Verdict: confirmed with a condition (phase A).** The agent's own executable, run as `RESTIC_PASSWORD_COMMAND`, reads a data protection keychain item that the app created, from launchd context, with no prompt. **Condition:** as built, any process running as the user can run that helper and get the password. See "Confused deputy" below.

### Results, 9 Nov 2026 22:46–22:52 UTC (10 Nov 09:16–09:22)

- The app stored the item with `SecItemAdd` (`kSecUseDataProtectionKeychain`, access group `X72LEXP4DY.com.jaydenkerr.restorey.spike`, `kSecAttrAccessibleAfterFirstUnlock`). Result: `0 (No error.)`.
- The agent, a different bundle ID in the same group, read it in-process from launchd context: `found: true, status 0`, no dialog.
- `restic init` with `RESTIC_PASSWORD_COMMAND='<agent executable>' print-password --account spike-repo`, run by the agent under launchd: **exit code 0**. A later keychain-backed `backup --dry-run` that opened the repository: **exit code 0**, so the helper returned the same secret both times (a mismatch would be exit 12).
- **Negative controls:**
  - `security find-generic-password -s com.jaydenkerr.restorey.spike -a spike-repo` → "could not be found". The item is in the data protection keychain, which `/usr/bin/security` doesn't search. This confirms spec §7's reason for not copying Restic Station.
  - An ad-hoc re-signed copy of the agent bundle with no entitlements → `-34018 (A required entitlement is not present.)`.
  - A copy re-signed with the real Apple Development identity and the `keychain-access-groups` entitlement but **with `embedded.provisionprofile` removed** → **killed at launch (exit 137, SIGKILL by AMFI)**. So every executable that claims the access group needs its own embedded profile, which means it has to be a bundle. This is why the password helper is the agent app's own executable rather than a bare tool.
  - The FDA dry-run after two in-place binary replacements (same designated requirement, new cdhash): still `ok`, exit code 0. **FDA survives a rebuild that keeps the same requirement.**

### Confused deputy (needs an owner decision before v0.1)

Running the installed, correctly signed helper from Terminal, `…/RestoreySpikeAgent print-password --account spike-repo`, **printed the password (exit 0)**. The keychain's access-group check proves only that the *helper* is allowed to read the item. It says nothing about who launched the helper. So any process running as the user can read every repository password by running our own binary. That's narrower than Restic Station's `-T /usr/bin/security` scheme, but the same kind of hole.

Options for v0.1, from least to most effort:

1. **Accept and document.** Same-user code execution can already do a lot, e.g. read `~/Library` and the restic cache. State it in the README.
2. **Verify the parent chain in `print-password`.** Refuse unless the parent process is the bundled restic (code signature: identifier `…restic` plus the team) and its parent is the agent. Use `proc_pidpath` plus `SecCodeCopyGuestWithAttributes` on the parent's audit token. This raises the bar, but an attacker can still run the bundled restic with our helper as its password command. restic then holds the password and could, for example, `key add` a new key.
3. **One-time token.** The agent puts a random nonce in restic's environment, and `print-password` asks the agent over XPC (the agent verifies the caller's code signature) to exchange the nonce for the secret, once. This stops "run the helper by hand". It doesn't stop an attacker who can read the restic child's environment while it runs (see H4).

Recommendation: option 2 in v0.1, plus the README statement from option 1. Option 3 only if H4 shows child environments are not readable by other same-user processes.

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

### H3b — Notifications from the agent (Task 5), 9 Nov 2026 22:58–23:01 UTC (10 Nov 09:28–09:31)

**Verdict: the agent needs its own notification permission, and the system hides that it doesn't have one.**

1. **App asks first** (the negative control): the system prompt named "Restorey Spike" (the owner's report). Result `granted=true`.
2. **The agent posts before asking for itself:** `UNUserNotificationCenter.add` returned **`posted: true`, but nothing appeared on screen.** The app's permission does **not** cover the agent, and the failure is **silent**: no error and no banner.
3. **The agent asks for itself:** a **second** system prompt appeared, again named "Restorey Spike" with the same icon (`CFBundleDisplayName` "Restorey Spike" and the shared icon). Result `granted=true`.
4. **The agent posts again:** the banner "Test notification from the background agent" appeared, labelled "Restorey Spike".
5. **System Settings → Notifications:** **two entries, both "Restorey Spike"** with the same icon. One has badges, sounds and desktop: that's the agent, which requested `[.alert, .sound, .badge]`. The other has sounds and desktop only: that's the app, which requested `[.alert, .sound]`. This confirms the two entries are the two bundles.

**Consequences for v0.1:**
- Onboarding has to request notification permission **from the agent**, over XPC. The menu bar app has no reason to post notifications itself, so it shouldn't request permission at all. That leaves one entry in Notifications instead of two identical ones, which would confuse people.
- Because `add` succeeds while nothing is delivered, the agent must check `notificationSettings().authorizationStatus` before relying on notifications. If it isn't `authorized`, the menu bar shows a standing warning such as "Notifications are off — Restorey can't alert you". This is anti-goal 1: alerts that silently go nowhere are the serrano failure again.
- Give the agent the same display name and icon as the app, as done here, so the prompt and banners read as Restorey.
- "Background Items Added": the owner saw "maybe 1" during the session, despite 16 BTM generations from repeated rebuilds and registers. That's consistent with BTM notifying once per app, not per update. Not verified exactly.

## Agent priority under `ProcessType=Adaptive` (found during Task 4) — **contradicts spec §8**

- A backup the agent scheduled itself (90 s timer, no XPC request pending) took **more than 4 minutes** for the same dry run that took about 50 s when triggered over XPC. During it, `ps -o pri` showed **priority 4** for both the agent and restic, which is Darwin's throttled background band. restic used about 8% CPU. `launchctl print` showed `spawn type = adaptive (6)`.
- launchd's Adaptive type keeps the job at background priority except while it is serving an XPC request. Every earlier test run was triggered over XPC from the app, so it ran boosted. **The scheduled backups that make up nearly all of Restorey's work would always run throttled.**
- Spec §8 says "Use `ProcessType=Adaptive` or `Standard`". **Adaptive is wrong for this agent.**
- The throttled run was stopped with SIGINT after **954 s**. restic exited **130** and **removed its own lock** (`locks/` empty), which confirms the pause path in spec §5.1. Its keychain pre-read while the screen was locked had returned `0 (No error.)`.

### Fix verified: `ProcessType=Standard` (0.0.3), 9 Nov 2026 23:21–23:23 UTC

- **A plist change in an update is not picked up.** After 0.0.3 (plist `ProcessType` changed to `Standard`) replaced 0.0.2 and launchd relaunched the agent, `launchctl print` **still showed `spawn type = adaptive (6)`**. launchd keeps the job definition submitted at `register()` time. Only **`unregister()` followed by `register()`** applied the new plist: `spawn type = daemon (3)`, with no approval prompt. **Consequence for v0.1:** whenever the embedded plist changes, the update path has to re-register, not just restart the agent. Simplest is for the version handshake to unregister and re-register whenever the plist's hash differs from the one stored at the last registration.
- The agent then scheduled its own run (60 s after start, no XPC pending): the agent was at **priority 20**, restic (`Process.qualityOfService = .utility`) at **priority 46, about 324% CPU**, and the same keychain-backed dry run **finished in 69 s, exit 0** (it had been stopped after 954 s under Adaptive).
- **Consequence for v0.1:** use `ProcessType=Standard`. restic at roughly 3 cores is "noticeable". Whether it's "disruptive" needs the spec §8 measurement on a real first backup, and `GOMAXPROCS` may be the lever if it is. Record that measurement in `docs/` as the spec asks.

## H2 addendum — keychain while the screen is locked (Task 4 step 4), 9 Nov 2026 23:02–23:03 UTC

- The owner locked the screen (⌃⌘Q) at 23:02:06. The scheduled run fired at 23:03:39 with the screen still locked. The agent's in-process `SecItemCopyMatching` worked, restic ran `print-password` at 23:03:40, and restic **opened the repository and went on to read files**, so the password was returned while locked. This is as expected for `kSecAttrAccessibleAfterFirstUnlock`. The run, throttled as described above, was stopped with SIGINT after 954 s (exit code 130). The keychain step had already succeeded.
- **Not done yet:** the reboot test, where the agent starts at login and runs 60 s later. The owner will do it later. The `run-at-start` flag is still set.

## H4 — How backend credentials reach restic

**Verdict: environment variables are readable by other same-user processes (confirmed). A better route exists for S3, and so for B2 through its S3 API (confirmed from source, not run end-to-end).**

### Child environments are not private (10 Nov 2026 UTC 22:58 (09:28))

The bundled, hardened-runtime restic was started with `SPIKE_FAKE_SECRET=…` in its environment. A separate process running as the same user then read that variable two ways: with `ps -E -ww -p <pid>`, and with `sysctl(CTL_KERN, KERN_PROCARGS2, pid)` (rc 0, secret present). `launchctl procinfo` needs root and isn't needed. So **any backend key passed as an environment variable is readable by any same-user process for as long as restic runs**, which matches spec §7's caution. The test's parent was a shell, not the agent. The check is based on uid, so the parent shouldn't matter.

### What restic 0.19.1 accepts (source, with file and line)

- **S3** (`internal/backend/s3/s3.go:103–132`): `credentials.NewChainCredentials` over `Static` (test only), `EnvAWS`, `EnvMinio`, `FileAWSCredentials`, `FileMinioClient` and `IAM`, in that order. `EnvAWS` comes first, so any `AWS_*` variables in the child environment win.
- **`FileAWSCredentials`** (minio-go **v7.1.0**, the version restic pins, `pkg/credentials/file_aws_credentials.go:74–140`) honours `AWS_SHARED_CREDENTIALS_FILE`, `AWS_PROFILE`, and **`credential_process`**. The process is run with `exec.Command` and must print `{"AccessKeyId","SecretAccessKey","SessionToken"?,"Expiration"?}`. Two constraints:
  - the line is split with `strings.Fields`, so **no quoting is possible and the helper's path must not contain spaces**
  - it needs at least two arguments, e.g. `<helper> s3-credentials --plan <id>`
- **B2 native** (`internal/backend/b2/config.go:90–93`, `b2.go:63–78`): `B2_ACCOUNT_ID` and `B2_ACCOUNT_KEY` from the environment only. Nothing else.
- **restic's own docs** (`doc/030_preparing_a_new_repo.rst:458–463`): "the recommended way to utilize Backblaze B2 is by using its S3-compatible API".

### Recommendation for v0.1

- **S3 and B2:** use restic's S3 backend, so B2 goes through its S3-compatible endpoint, as restic recommends. Pass no `AWS_*` variables. Write a per-plan shared-credentials file in Restorey's Application Support (mode 0600) that holds **only** `[restorey-<plan id>] credential_process = <agent executable> s3-credentials --plan <id>`, and set `AWS_SHARED_CREDENTIALS_FILE` and `AWS_PROFILE` in restic's environment. The secret then never appears in an environment variable or a file. It reaches restic through a pipe, from the same keychain-backed helper as the repository password, with the same confused-deputy caveat (H2).
- The real app's bundle path must contain **no spaces**: `/Applications/Restorey.app/Contents/Helpers/RestoreyAgent.app/Contents/MacOS/RestoreyAgent` is fine. The helper should check its own path at startup and refuse to run otherwise.
- **Other backends** (raw repository string plus variables, spec §5.3): child environment only, and the README says plainly that the environment is readable by other processes running as the user while a run is in progress.
- README wording (spec §7): "Repository passwords and S3/B2 keys are read from your Keychain by Restorey's background agent and handed to restic through a pipe. They are never written to disk or put in environment variables. Credentials for other backends are passed to restic as environment variables while it runs; other programs running as you can read those."

### Not done

The end-to-end `credential_process` run against a local S3 server. MinIO's community images are no longer published, and auto mode blocked running `moto` from PyPI. **To do in v0.1:** check it against the owner's real B2 bucket through its S3 endpoint, with an unset `AWS_*` environment as the negative control. Without credentials restic should fail, because `s3.go:146` errors when no credentials are found.

## H6 — Manual N→N+1 update

### Phase A (Apple Development, 0.0.1 → 0.0.2), 9 Nov 2026 22:52–22:56 UTC (10 Nov 09:22–09:26)

**Verdict: confirmed.** The version handshake and the "finish the run, then exit" restart work. The grants survive.

1. 22:52:30: a keychain-backed backup (dry run, about 50 s) was started on 0.0.1 (agent pid 41712, restic pid 45074).
2. 22:52:35: `spike/scripts/install.sh` quit the app and replaced `/Applications/RestoreySpike.app` with 0.0.2, the same as dragging from a DMG. **The old agent kept running the old, now deleted binary** (`lsof` txt entries), and its restic kept running.
3. 22:52:38: 0.0.2 launched. The handshake saw `agent build 0.0.1 ≠ app build 0.0.2` and sent `prepareForRestart`.
4. 22:53:20: the in-flight backup **finished normally (exit 0)**. The agent then replied `exiting: true` and called `exit(0)`.
5. 22:53:22: launchd's `KeepAlive` started the new agent (pid 45266) from the new binary, and the handshake reported `build 0.0.2 — MATCH`. The app-to-agent gap was **under 2 s**.
6. With **no new grants**, on 0.0.2: the FDA probe passed (all `ok`, restic exit 0, 0 permission errors), the keychain-backed backup passed (exit 0, no prompt), and Login Items still showed `enabled, allowed, notified` (generation 16).
- Both builds' designated requirements are identical (identifier plus the same Apple Development certificate clause), which is why the grants carried over. This doesn't yet show what happens when the certificate changes. That's phase B.
- **Consequence for v0.1:** ship this exactly as built. Treat the handshake as part of every app launch, and give the drain a generous timeout: it waited 42 s here for a real run and should allow for a multi-hour first backup. While waiting, the UI must show something like "Finishing the current backup before updating the agent".

## Phase B — Developer ID, notarisation, real quarantine

### Build (Task 8), 9 Nov 2026 23:46–23:48 UTC (10 Nov 10:16–10:18)

- `spike/scripts/release.sh`, adapted from scrap's release script: archive, `-exportArchive` with `method=developer-id` and `destination=upload`, poll `-exportNotarizedApp`. Notarised and stapled. `spctl`: `accepted, source=Notarized Developer ID, origin=Developer ID Application: Jayden Kerr (X72LEXP4DY)`.
- **The export re-signed every piece of nested code with Developer ID and a secure timestamp:** the app, the agent app, and `Contents/Helpers/restic`. restic doesn't need a manual re-sign step. `get-task-allow` is gone. Xcode created explicit profiles, "Mac Team Direct Provisioning Profile: com.jaydenkerr.restorey.spike" and "…spike.agent", which both carry the keychain group.
- **The Developer ID designated requirement pins the team, not a certificate:** `anchor apple generic and identifier "…" and (certificate leaf[field.1.2.840.113635.100.6.1.9] or certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = X72LEXP4DY)`. This is what should let grants survive certificate renewal.

### A copy run from the DMG breaks the installed agent (10 Nov 2026 23:48:52 UTC) — **anti-goal 1**

With development-signed 0.0.3 installed in /Applications and its agent running, the notarised 0.1.0 app was opened **straight from the mounted, quarantined DMG**:

1. It ran **translocated**, from `/private/var/folders/…/AppTranslocation/<uuid>/d/RestoreySpike.app`. The app detected this (`translocated=true`) and **refused to register** as designed.
2. **But Background Task Management re-pointed the existing registration at that copy anyway.** `backgroundtaskmanagementd: _bundleURLForAuditToken: updating item … name=RestoreySpike` fired just from the app launching and reading `SMAppService.status`. No `register()` call was made.
3. The copy's version handshake (0.0.3 ≠ 0.1.0) asked the installed agent to exit. launchd then relaunched the agent **from `/Volumes/Restorey Spike/…/RestoreySpikeAgent`**, the DMG copy, and AMFI killed it: `Launch Constraint Violation (enforcing) … (Constraint not matched)`. smd had stored a launch constraint (an LWCR) at registration that matches the *development* signature.
4. launchd: "removing service since it exited with consistent failure". After that: `state = spawn scheduled`, `last exit code = 78: EX_CONFIG`, `needs LWCR update`. **No agent runs, so no backups run**, until something re-registers.

**Consequences for v0.1:**
- The version handshake, and anything else that can restart or change the agent, must run **only** when the app is non-translocated and in /Applications. That's the same gate as `register()`. A copy run from elsewhere must do nothing except show "Move Restorey to Applications".
- **Merely launching** a copy from elsewhere can re-point the BTM registration. So every launch of the real /Applications copy must check that the registration points at itself and that the agent is actually running (the heartbeat in spec §6.2). If it isn't, re-register: `unregister()` then `register()`. The menu bar app's heartbeat would also catch this, with "Background agent isn't running".
- Moving between signing identities (development to Developer ID) invalidates the launch constraint. Only re-registering fixes that. Phase B still has to show whether Developer ID 0.1.0 → 0.1.1 keeps the constraint satisfied.

### Translocation from /Applications (simulation limits)

- A copy in /Applications that was given `com.apple.quarantine` with `xattr` was **still translocated** when opened.
- So was a copy made by **Finder's AppleScript `duplicate`** from the quarantined DMG: the flag `0081;…` was kept and the app was translocated.
- The real case, the user dragging in Finder, is done by the owner below.

### Real drag install and Developer ID update, 9 Nov 2026 23:53–23:59 UTC (10 Nov 10:23–10:29)

1. **The owner dragged 0.1.0 from the quarantined DMG into /Applications in Finder and opened it.** Gatekeeper showed its usual "downloaded from the Internet" prompt. The app ran from `/Applications/RestoreySpike.app` and was **not translocated** (quarantine flag `01c1`, user-approved). A real Finder drag is the only install path that avoids translocation. Scripted copies, `xattr` and Finder `duplicate` don't.
2. **The agent was still dead** from the DMG-copy incident above (`EX_CONFIG`), yet **`SMAppService.status` reported `enabled`**. The status API doesn't show whether the agent is alive. Only the heartbeat does (spec §6.2). `unregister()` then `register()` fixed it: the agent was running at once, with a new launch constraint and no approval prompt.
3. **What carried over from the Apple Development builds to Developer ID** (same bundle IDs, new designated requirement):

   | Grant | Carried over? | Why |
   |---|---|---|
   | Data protection keychain item created by the development build | **Yes**: `found: true`, status 0, no prompt | Access is by team-prefixed access group, not by signature |
   | Notification permission (agent) | **Yes**: `authorizationStatus 2` | Keyed by bundle ID |
   | Full Disk Access | **No**: agent `denied 257`, restic exit 3 | TCC stores the designated requirement |

   - In System Settings the FDA entry was still listed, but **switched off**. The owner switched it on again, and nothing needed removing or re-adding. The 0.1.0 self-scheduled run that went before that failed (exit 3, 6 permission errors), as expected.
   - **Consequence:** the owner's own development builds should use a separate bundle ID, as scrap's Debug does with `.dev`. That way, switching between development and release builds never invalidates the release app's FDA grant.
4. **Developer ID 0.1.0 → 0.1.1 (H6, phase B)**: the owner dragged 0.1.1 over 0.1.0 (Replace) from a quarantined DMG and opened it, with the Gatekeeper prompt as before.
   - The handshake asked the 0.1.0 agent to drain and exit, and the 0.1.1 agent was running **2 s later** (`last exit code = 0`). The **launch constraint was still satisfied with no re-registration**, because both builds have the team-based requirement.
   - With **no new grants**, the 0.1.1 agent's self-scheduled keychain-backed run over the private folders: **exit code 0, 0 permission errors, 65 s, keychain pre-read status 0, no prompts.**
   - **H1, H2 and H6 hold under Developer ID** across an N→N+1 update. This is spec §12.1's target: "one Full Disk Access grant, made once, that survives updates".
