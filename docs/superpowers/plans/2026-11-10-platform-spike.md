# Platform spike implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer the five open platform questions in spec §12.1 with evidence from a signed build running from launchd. The questions are Full Disk Access attribution, Keychain helper access, agent process shape and notifications, backend credential passing, and the manual N→N+1 update. Record the answers in `docs/spike-findings.md`.

**Architecture:** This is throwaway code. `RestoreySpike.app` is a minimal menu bar app with one window of probe buttons. It embeds three things. The first is `RestoreySpikeAgent.app`, a background-only (`LSUIElement`) helper app registered as a LaunchAgent through `SMAppService.agent(plistName:)`. The second is a re-signed upstream restic 0.19.1. The third is the agent's launchd plist. The app only sends commands, over one XPC Mach service. The agent runs every probe, so every result comes from launchd context. Each task is an experiment. Its "test" is an observable result with a negative control, written into the findings doc. It is not a unit test, because spec §13 makes this throwaway code.

**Tech Stack:** Swift 6.4 language mode, macOS 27 deployment target, Xcode 27.0, XcodeGen, SwiftUI plus `NSStatusItem`, `NSXPCConnection`, ServiceManagement, Security (data protection keychain), UserNotifications, restic 0.19.1 (upstream darwin_arm64 release), Docker Compose (MinIO, Task 6 only).

**Spec:** `docs/superpowers/specs/2026-11-09-restorey-design.md`. Read §5.7 (FDA), §6.2 (agent liveness), §7 (secrets), §8 (architecture), §10 (keychain test constraint), §12.1 and §12.7.

## Research done while writing this plan (10 Nov 2026)

These facts shape the tasks. Check them again only if a probe contradicts them.

- **TCC responsibility.** Apple DTS ([forum 756510](https://developer.apple.com/forums/thread/756510)) says this about agents: "If the daemon or agent was installed by `SMAppService`, that makes the app the responsible code." For child processes it says: "Spawned as a child process … by an app — The system treats the app as the responsible code." DTS adds that the algorithm "is not documented, has changed in the past". Hypothesis H1 is therefore that one FDA grant to `RestoreySpike.app` covers the agent and restic. This has to be proven from launchd context. A probe run from Terminal inherits Terminal's own grant and proves nothing. Restic Station's docs note the same confound.
- **Plist location.** Apple's ["Updating helper executables"](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos) says agent plists go in `Contents/Library/LaunchAgents/`. `BundleProgram` is a path relative to the bundle, and "LaunchAgents … in the app bundle automatically associate with that app in the Login Items panel". So `AssociatedBundleIdentifiers` is not needed.
- **Keychain access groups need a provisioning profile on macOS.** Apple DTS forum threads and TN3125 say every claim in `keychain-access-groups` must be backed by an embedded provisioning profile. Without one, calls fail with `-34018`. A February 2026 third-party report adds that each nested helper needs its own profile. So the "password helper" has to be a bundle that can embed a profile. A bare tool can't. This plan uses the agent app's own executable with a `print-password` argument as `RESTIC_PASSWORD_COMMAND`, rather than a third binary. Restic Station uses `/usr/bin/security` with `-T /usr/bin/security` ACLs instead. Under that scheme any same-user process can read every secret silently, which is a further reason not to copy it.
- **Signing identities available today:** only "Apple Development: Jayden Kerr", on both this Mac and birdseye. There is no "Developer ID Application" identity and no `notarytool` profile. Tasks 1–7 (phase A) run with Apple Development signing plus a macOS development provisioning profile. Task 8 (phase B) needs Developer ID and notarisation, and it is the only way to test a real quarantined DMG through Gatekeeper. Phase B is blocked until the owner has those.

## Global constraints

- Deployment target macOS 27.0, Xcode 27.0, Swift 6.4 language mode with strict concurrency (spec §8).
- Bundle IDs: app `com.jaydenkerr.restorey.spike`; agent `com.jaydenkerr.restorey.spike.agent`; launchd label and XPC Mach service `com.jaydenkerr.restorey.spike.agent`. These are spike-only IDs, so TCC and keychain entries never collide with the real app.
- Keychain access group: `$(TeamIdentifierPrefix)com.jaydenkerr.restorey.spike`, used by both targets. Every item is created with `kSecUseDataProtectionKeychain: true` and `kSecAttrAccessibleAfterFirstUnlock`. Never drop `kSecUseDataProtectionKeychain` to make something work (spec §10).
- restic is pinned to 0.19.1, downloaded from the upstream GitHub release, checked against the release's `SHA256SUMS`, and re-signed with the app's identity and hardened runtime. Never use the Homebrew binary.
- The agent plist sets `KeepAlive` true, `ProcessType` `Adaptive` and never `Background` (spec §8), plus `MachServices` {`com.jaydenkerr.restorey.spike.agent`: true}.
- Every probe runs in the agent and is triggered over XPC. None runs from Terminal.
- Builds come from birdseye via `remote-ci`. Probes run on this Mac, the owner's, because they need a logged-in GUI session and a person to click TCC grants.
- Australian English in all UI text and docs. Timestamps in the findings doc are UTC with the local time in brackets.
- Never write secrets to logs, the findings doc or the repo. The spike repo password is a random value generated at test time.

## Review focus

1. **The Terminal confound.** An FDA probe that "passes" because it was launched from a terminal that has its own grant. Task 3 runs probes only via XPC and checks the responsible process in the unified log.
2. **Keychain locked at login.** After a reboot the agent starts before the login keychain unlocks, and the first scheduled run fails or prompts. Task 4 includes a reboot run.
3. **Agent killed during a restic run.** An orphaned restic keeps running and holds the repository lock, or the lock is left stale. Task 2 kills the agent mid-run and records what happens to the child and the lock.
4. **The user turns the agent off in Login Items.** Status becomes `.requiresApproval` or `.notRegistered` and backups stop silently (anti-goal 1). Task 2 checks the app detects it.
5. **Grants that don't survive a signing change.** A grant made to the Apple Development build may not carry over to the Developer ID build, and an update with a changed designated requirement silently drops FDA. Tasks 7 and 8 compare `codesign -d -r-` output and recheck every grant.

---

### Task 1: Scaffold, signed build and DMG

**Files:**
- Create: `spike/project.yml`, `spike/README.md` (states "throwaway; see docs/spike-findings.md")
- Create: `spike/App/` (`RestoreySpikeApp.swift`, `ProbeWindow.swift`, `Info.plist`, `App.entitlements`)
- Create: `spike/Agent/` (`main.swift`, `Info.plist`, `Agent.entitlements`)
- Create: `spike/Shared/AgentProtocol.swift`
- Create: `spike/LaunchAgents/com.jaydenkerr.restorey.spike.agent.plist`
- Create: `spike/scripts/fetch-restic.sh`, `spike/scripts/make-dmg.sh`, `scripts/ci.sh`, `scripts/fetch-dmg.sh`
- Create: `docs/spike-findings.md` (one heading per hypothesis H1–H6, plus an environment section)
- Modify: `.gitignore` (add `spike/vendor/`, `spike/*.xcodeproj`)

**Interfaces:**
- Produces: `@objc protocol AgentXPC` in `Shared/AgentProtocol.swift`. Later tasks add methods. Every method replies with a `String` (JSON) through a `withReply` closure, so the protocol never needs `NSSecureCoding` classes.
- Produces the bundle layout that later tasks rely on:
  - `RestoreySpike.app/Contents/Helpers/RestoreySpikeAgent.app`
  - `RestoreySpike.app/Contents/Helpers/restic`
  - `RestoreySpike.app/Contents/Library/LaunchAgents/com.jaydenkerr.restorey.spike.agent.plist`, with `BundleProgram` = `Contents/Helpers/RestoreySpikeAgent.app/Contents/MacOS/RestoreySpikeAgent`
- Produces `scripts/ci.sh [--version X.Y.Z]`. It builds, signs, verifies and writes `build/RestoreySpike-<version>.dmg`.

- [ ] **Step 1:** Write `fetch-restic.sh`. It downloads `restic_0.19.1_darwin_arm64.bz2` and `SHA256SUMS` into `spike/vendor/`, exits non-zero on a checksum mismatch, and decompresses to `spike/vendor/restic`.
- [ ] **Step 2:** Write `project.yml`. Both targets use automatic signing with `DEVELOPMENT_TEAM` read from the environment (never committed) and hardened runtime on. The app has `LSUIElement` true. A post-build script copies the agent app and `vendor/restic` into `Contents/Helpers/` and the plist into `Contents/Library/LaunchAgents/`. It then re-signs `restic` with `codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY"`. Both entitlements files hold only `keychain-access-groups` with the group above.
- [ ] **Step 3:** Write `make-dmg.sh` (`hdiutil create -format UDZO` containing the app and an `/Applications` symlink) and `scripts/ci.sh`. `ci.sh` runs `xcodegen generate`, `xcodebuild -allowProvisioningUpdates build`, then `codesign --verify --deep --strict --verbose=2`, then `make-dmg.sh`. Write `scripts/fetch-dmg.sh`, which copies `build/*.dmg` back from the directory that `remote-sync` prints.
- [ ] **Step 4:** Run `remote-ci` in the background. Expected: exit 0 and a DMG present after `fetch-dmg.sh`.
- [ ] **Step 5:** Verify locally:
  - `codesign -d --entitlements - --xml` on the app and the agent shows the access group.
  - `codesign -dv` shows the same TeamIdentifier on the app, the agent and restic.
  - `Contents/embedded.provisionprofile` exists in both the app and the agent.

  Record `codesign -d -r-` (the designated requirement) for all three in the findings environment section. If birdseye can't create a development profile because no account is signed in or this Mac isn't registered as a device, stop and tell the owner.
- [ ] **Step 6:** Commit (`spike: scaffold signed app, agent and bundled restic`).

### Task 2: Agent registration, XPC heartbeat and lifecycle

**Files:** Modify `spike/Agent/main.swift`, `spike/App/ProbeWindow.swift`, `spike/Shared/AgentProtocol.swift`

**Interfaces:**
- Produces `AgentXPC.ping(withReply: (String) -> Void)` → `{"version","build","pid","startedAt"}`.
- Produces `AgentXPC.runBackup(paths: [String], withReply:)` → `{"exitCode","stderrTail","durationSeconds"}`. The agent spawns `Contents/Helpers/restic backup --json` with `--repo ~/Library/Caches/com.jaydenkerr.restorey.spike/repo` and `--cache-dir ~/Library/Caches/com.jaydenkerr.restorey.spike/restic`. It never sets `responsibility_spawnattrs_setdisclaim`. The password source is a parameter: Tasks 2 and 3 use `RESTIC_PASSWORD` set only in the child environment, and Task 4 switches to the keychain.
- Produces `AgentXPC.initRepo(passwordSource: String, withReply:)`, a one-time `restic init` for that local repo. `passwordSource` is `"env"` here; Task 4 adds `"keychain"`.

- [ ] **Step 1:** In the app, add Register, Unregister, Status (showing the `SMAppService.Status` value) and Ping buttons, plus a 10-second auto-ping that shows the last reply and time.
- [ ] **Step 2:** Build. Then install by mounting the DMG, setting quarantine on the copy (`xattr -w com.apple.quarantine "0081;$(printf %x $(date +%s));Safari;" <app>`), and copying the app to `/Applications`. Launch it from `/Applications`.
- [ ] **Step 3:** Register. Expected: `.requiresApproval` or `.enabled`. Approve in System Settings > General > Login Items if asked. Record exactly how the item is named there. Ping should return a pid that matches `launchctl print gui/$(id -u)/com.jaydenkerr.restorey.spike.agent`.
- [ ] **Step 4 (KeepAlive):** `kill -9 <agent pid>`. Expected: a new pid within 10 s, and the app's ping recovers. Record the gap.
- [ ] **Step 5 (review focus 3):** Start `runBackup` on a large folder (e.g. `~/Library/Developer`), then `kill -9` the agent. Record:
  - whether restic keeps running (`pgrep -fl Helpers/restic`)
  - whether `restic list locks` shows a lock afterwards
  - how old that lock is when the next run starts
- [ ] **Step 6 (review focus 4):** Turn the item off in Login Items. Record the `SMAppService.Status` the app sees, and whether the agent process is stopped. Turn it back on.
- [ ] **Step 7:** Write up H3a (registration and lifecycle) in the findings doc. Commit.

### Task 3: Full Disk Access attribution (H1)

**Files:** Modify `spike/Agent/main.swift`, `spike/Shared/AgentProtocol.swift`, `spike/App/ProbeWindow.swift`

**Interfaces:**
- Produces `AgentXPC.probeFDA(withReply:)` → `{"inAgent": {"~/Library/Safari": "ok|denied|absent", "~/Library/Mail": …}, "restic": {"exitCode", "permissionErrors": Int}}`.
  - The in-agent part uses `FileManager.contentsOfDirectory`.
  - The restic part runs `runBackup(paths: ["~/Library/Safari", "~/Library/Mail"])` and counts `error` messages whose `error.message` contains "operation not permitted".

- [ ] **Step 1 (negative control):** With no FDA grant for the app, run the probe. Expected: `denied` in the agent, and restic exit code 3 with permission errors above 0. If the result is `ok`, the probe isn't measuring TCC. Stop and investigate before going on.
- [ ] **Step 2:** Grant FDA to `/Applications/RestoreySpike.app` only. Restart the agent (Unregister, then Register, or `kill`). Run the probe. Expected under H1: `ok` everywhere, and restic exit code 0. Record which items appear in the FDA list, and whether macOS added the agent on its own.
- [ ] **Step 3:** While the probe runs, capture `log stream --predicate 'subsystem == "com.apple.TCC"' --info` and record the responsible process TCC names for each access.
- [ ] **Step 4 (fallback, only if Step 2 failed for the agent or for restic):**
  - Find which part was denied.
  - Try granting FDA to the agent app as well, and record whether that fixes it.
  - Record whether a deep link (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`) opens the right pane on macOS 27.

  Under spec §12.1 the fallback is the "guided two-item grant".
- [ ] **Step 5:** Write up H1. Commit.

### Task 4: Keychain password helper from launchd (H2)

**Files:** Modify `spike/Agent/main.swift`, `spike/App/ProbeWindow.swift`, `spike/Shared/AgentProtocol.swift`

**Interfaces:**
- Produces an agent command-line mode: `RestoreySpikeAgent print-password --account <id>`. It writes the item's value to stdout and exits 0. On failure it writes the `OSStatus` to stderr and exits 1. It never prompts. `main.swift` dispatches on `CommandLine.arguments` before starting the XPC listener.
- Produces app actions that write `account "spike-repo"` and delete it, both through `SecItemAdd` and `SecItemDelete` with the constraints above.
- `runBackup` gains `passwordSource: "keychain"`, which sets `RESTIC_PASSWORD_COMMAND` to the agent's own resolved executable path (`Bundle.main.executableURL`, never `argv[0]`) followed by `print-password --account spike-repo`.

- [ ] **Step 1:** In the app, generate a random password and store it. Re-initialise the spike repository with it, by deleting the old repo and calling `initRepo` with the keychain source.
- [ ] **Step 2:** Run `runBackup` with the keychain source via XPC. Expected: exit code 0 and no dialog on screen.
- [ ] **Step 3 (negative controls):**
  - In Terminal, `security find-generic-password -s spike-repo` should fail. A failure shows the item is in the data protection keychain, not the file-based one.
  - Copy the agent executable out and run `codesign --force -s - <copy>`. Running `<copy> print-password --account spike-repo` should fail with `-34018` or `-25300`. A failure shows that only the signed identity can read the item.
- [ ] **Step 4 (review focus 2):**
  - Add `scheduleBackup(afterSeconds:)` to the agent.
  - Schedule a run 120 s ahead, then lock the screen (⌃⌘Q) and wait. Record the result.
  - Schedule a run for 60 s after the agent starts, then reboot and don't log in for 2 minutes. Record whether the run fails, waits, or prompts, and the `OSStatus`.
- [ ] **Step 5:** Write up H2, including whether the agent needed its own provisioning profile. Check by temporarily removing it from the agent and recording the error. Commit.

### Task 5: Notifications from the agent (H3b)

**Files:** Modify `spike/Agent/main.swift`, `spike/Agent/Info.plist` (`CFBundleDisplayName` "Restorey Spike", app icon), `spike/App/ProbeWindow.swift`

**Interfaces:**
- Produces `AgentXPC.requestNotificationAuth(withReply:)` and `AgentXPC.postTestNotification(withReply:)`, both through `UNUserNotificationCenter.current()` inside the agent.

- [ ] **Step 1 (negative control):** Request notification permission from the main app only. Then call `postTestNotification` in the agent. Record whether it is delivered, and the agent's `getNotificationSettings` authorisation status.
- [ ] **Step 2:** Request permission from the agent. Record:
  - who the prompt says is asking, and with which name and icon
  - the entry it creates in System Settings > Notifications
  - whether a posted notification shows the Restorey name and icon
- [ ] **Step 3:** Repeat Step 2 after `kill -9` of the agent, to confirm the grant persists across agent restarts.
- [ ] **Step 4:** Write up H3b. It must answer two questions: does onboarding need a separate permission request from the agent, and what does the user see? Commit.

### Task 6: Backend credential passing (H4)

**Files:**
- Create: `spike/minio/docker-compose.yml` (MinIO with a pinned current release tag, port 9000 on localhost only, `/etc/localtime:/etc/localtime:ro`)
- Create: `spike/minio/env.example`
- Modify: `spike/Agent/main.swift`

**Interfaces:**
- `runBackup` gains `repo: String` and `backendEnv: [String: String]` for the child environment only. A new `credentialMode` takes the values `"env"`, `"sharedFile"` or `"credentialProcess"`.

- [ ] **Step 1 (source reading):** Read restic 0.19.1's `internal/backend/s3/s3.go` and `internal/backend/b2/b2.go`. Record every credential source each backend accepts, with file and line, and specifically whether S3 honours `AWS_PROFILE` / `AWS_SHARED_CREDENTIALS_FILE` and `credential_process`. Look up the current MinIO release tag before writing the compose file.
- [ ] **Step 2 (exposure check):** While a `runBackup` with `backendEnv` is running, use `ps -E -ww -p <restic pid>` and a small `sysctl(KERN_PROCARGS2)` reader, both as the same user from Terminal. Record whether the secret is visible. Also record whether the agent's own environment, which should not contain it, shows it.
- [ ] **Step 3:** Against MinIO (`docker compose up -d`), run backups in each credential mode that Step 1 found supported. For `credentialProcess`, the process is the agent's `print-password`-style mode extended to print the `credential_process` JSON. Expected: exit code 0 for the modes that are supported.
- [ ] **Step 4:** Write up H4 with a recommendation per backend and the exact sentence the README should use to say how backend secrets are passed (spec §7). `docker compose down -v`. Commit.

### Task 7: Manual N→N+1 update (H6, phase A)

**Files:** Modify `spike/Agent/main.swift`, `spike/App/RestoreySpikeApp.swift`, `spike/Shared/AgentProtocol.swift`

**Interfaces:**
- Produces `AgentXPC.prepareForRestart(withReply:)`. The agent stops accepting new runs, waits for any running restic to exit, replies, then calls `exit(0)`, after which `KeepAlive` relaunches it.
- On launch, the app compares its `CFBundleVersion` with `ping().build`. If they differ it calls `prepareForRestart`, then polls `ping` until the build matches, with a 60-second timeout, and shows the result.

- [ ] **Step 1:** Build two DMGs with `remote-ci -- --version 0.0.1` and `remote-ci -- --version 0.0.2`. They must differ only in version.
- [ ] **Step 2:** Install 0.0.1, register, grant FDA, store the keychain password, and run Task 3's probe and Task 4's keychain backup. Both should pass.
- [ ] **Step 3:** Start a long `runBackup`. While it runs, quit the app and drag 0.0.2 over it from the quarantined DMG. Record:
  - that the old agent pid is still alive and running the old binary (`lsof -p <pid> | grep txt`)
  - what happens to the in-flight run
- [ ] **Step 4:** Launch 0.0.2. Expected: the app detects the mismatch and waits for the run to finish. A new agent pid then reports build 0.0.2.
- [ ] **Step 5:** Run the FDA and keychain probes again with no new grants. Compare `codesign -d -r-` between versions. Expected: identical requirements, and both probes pass with no prompts.
- [ ] **Step 6:** Write up H6 phase A. Commit.

### Task 8: Developer ID, notarisation and a real quarantined DMG (phase B — blocked on the owner)

**Prerequisites (owner):** a paid Apple Developer Program membership; a "Developer ID Application" certificate in birdseye's keychain; a `notarytool` keychain profile on birdseye (`xcrun notarytool store-credentials`); a Developer ID provisioning profile for both bundle IDs with the keychain group.

**Files:** Modify `scripts/ci.sh` (a `--release` flag: Developer ID signing, `xcrun notarytool submit --wait`, `xcrun stapler staple` on the DMG), `spike/App/RestoreySpikeApp.swift`

**Interfaces:**
- Produces a launch-time check in the app: `isTranslocated` (the bundle path contains `/AppTranslocation/`) and `isInApplications` (`/Applications/` prefix). Either failing means the app shows "Move to Applications" and registers nothing (spec §8).

- [ ] **Step 1:** Upload the stapled DMG as an asset on a **draft** GitHub release. Draft releases aren't public. Download it in Safari so the quarantine flag is genuine.
- [ ] **Step 2:** Open the app straight from the mounted DMG. Expected: `isTranslocated` is true and nothing is registered.
- [ ] **Step 3:** Copy the app to `/Applications` and open it. Record whether the FDA and keychain grants from the phase A Apple Development build carry over. Expected: they don't, because the requirement changed. Then repeat Tasks 2.3, 3.2, 4.2, 5.2 and 7.3–7.5 with Developer ID 0.0.1 → 0.0.2 builds.
- [ ] **Step 4:** Delete the draft release. Write up phase B. Commit.

### Task 9: Findings, spec and docs

**Files:** Modify `docs/spike-findings.md`, the spec (§7, §8, §12.1 status lines), `README.md` (Status and Documents sections), `TODO.md` (not committed)

- [ ] **Step 1:** Finish the findings doc. For each hypothesis, record the verdict (confirmed, refuted, or confirmed with conditions), the evidence and the consequence for v0.1.
- [ ] **Step 2:** Update the spec wherever a finding changes a decision. Mark each change "(spike)" and flag it to the owner, rather than changing it silently.
- [ ] **Step 3:** Commit on `spike`. Then ask the owner whether to merge `spike` into `main` or keep only the findings doc and the spec changes.
