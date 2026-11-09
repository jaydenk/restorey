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

_Pending (Task 3)._

## H2 — Keychain password helper from launchd, no prompt

_Pending (Task 4)._

## H3 — Agent process shape: registration, lifecycle, notifications

_Pending (Tasks 2 and 5)._

## H4 — How backend credentials reach restic

_Pending (Task 6)._

## H6 — Manual N→N+1 update

_Pending (Tasks 7 and 8)._

## Phase B — Developer ID, notarisation, real quarantine

_Pending (Task 8)._
