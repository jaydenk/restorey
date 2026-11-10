# Restorey

A free, open-source macOS menu bar app that puts an Arq/Backblaze-style front end on
[restic](https://restic.net).

> **Status: design stage.** There is no app to download yet. The design is approved and the
> platform spike is done ([findings](docs/spike-findings.md)); v0.1 engine work has begun with the project scaffold.
> Nothing here is ready to protect your data.

## What it will do

- Show backup status in the menu bar, with live progress, Back Up Now and Pause.
- Run backups from a background agent, so they keep running with the app closed and catch up after sleep.
- Support several independent backup plans, each with its own repository, sources, schedule and retention.
- Adopt existing restic repositories without losing their history.
- Restore files through a Time Machine-style window: Finder columns plus a timeline of snapshots.
- Alert loudly when backups fail or stop, through macOS notifications, a Healthchecks-style check-in URL, ntfy, Pushover or a webhook.
- Verify repositories regularly with `restic check` and test restores.
- Support cold storage plans on S3 Glacier Deep Archive, with a guided thaw before restoring.

Restorey is a thin wrapper. restic does the deduplication, encryption, storage and retention.

It is aimed at people who already know restic. It targets macOS 27 and will not be on the Mac App Store,
because the App Store sandbox rules out the Full Disk Access a backup tool needs.

## Documents

- [Design](docs/superpowers/specs/2026-11-09-restorey-design.md)
- [Menu bar and restore window mockup](docs/mockups/menubar-and-restore.html)
- [Platform spike plan](docs/superpowers/plans/2026-11-10-platform-spike.md)
- [Platform spike findings](docs/spike-findings.md) (throwaway spike code in [`spike/`](spike/))

## Building from source

Prerequisites: macOS 27, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

1. Fetch the pinned upstream binaries (restic 0.19.1 and rest-server 0.14.0, checked against each release's
   `SHA256SUMS`) into the gitignored `vendor/` folder:

   ```sh
   scripts/fetch-binaries.sh
   ```

2. Run the CI checks: the `RestoreyCore` tests, an unsigned Debug build and the bundle checks. If
   `Config/Local.xcconfig` exists, it also does a signed Debug build and the full signature checks.

   ```sh
   scripts/ci.sh
   ```

3. For a signed local install, copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` (gitignored) and
   set `DEVELOPMENT_TEAM`. Then build, sign and install `RestoreyDev.app` into `/Applications`:

   ```sh
   scripts/install-dev.sh
   ```

Debug builds use a separate identity (`com.jaydenkerr.restorey.dev`, `RestoreyDev`), so they can sit beside a
Release install without sharing a launchd label, keychain group or on-disk state. GitHub Actions runs the
unsigned path of `scripts/ci.sh` on every push and pull request.

### Checking the agent by hand (Debug only, temporary)

Until the app shell can register and talk to the agent itself, a Debug build takes two launch arguments:

```sh
/Applications/RestoreyDev.app/Contents/MacOS/RestoreyDev --register   # SMAppService register(), prints the status
/Applications/RestoreyDev.app/Contents/MacOS/RestoreyDev --hello      # one hello and one status over XPC
launchctl print gui/$(id -u)/com.jaydenkerr.restorey.dev.agent        # spawn type = daemon (3), both Mach services
```

The agent serves its XPC interface only to the signed app: the listener requires the app's bundle ID and the
team in `Config/Local.xcconfig`, so any other process is refused. It is the only writer of `config.json`,
`state.json` and the plans' keychain items, all under `~/Library/Application Support/<root ID>` (mode 0700).
If either file is corrupt or was written by a newer Restorey, the agent reports it in `status`, refuses every
change and leaves the file as it is. Its log is `~/Library/Logs/Restorey-Dev/agent.log`, and MetricKit
diagnostics go to `diagnostics/` beside it.

## How secrets reach restic

Repository passwords, and keys for S3 (including Backblaze B2 through its S3 endpoint), are read from your
Keychain by Restorey's background agent and handed to restic through a pipe. They are never written to disk
or put in environment variables. Credentials for other backends, including repositories that use restic's
native `b2:` backend, are passed to restic as environment variables while it runs. Other programs running as
you can read those.

How it works (design spec §7; [spike findings](docs/spike-findings.md) H2 and H4):

- restic runs the agent's own executable as `RESTIC_PASSWORD_COMMAND`
  (`RestoreyAgent print-password --plan <id>`) and, for S3 and B2, as the `credential_process` in a per-plan
  shared-credentials file (`RestoreyAgent s3-credentials --plan <id>`). That file holds only the command line,
  never a key. The route itself was verified against a real B2 bucket through its S3 endpoint with a test
  helper: restic ran it once per command. Restorey's own helper is checked end to end in the v0.1 alpha.
- The helper holds no secrets. It asks the running agent over XPC. The agent accepts the connection only
  from its own executable, signed by the same team (checked against the caller's audit token). It then
  checks that the caller's parent process is a restic that the agent itself started and is still
  supervising, for the plan named in the request. Only then does it read the Keychain and reply.
- Run by hand, from Terminal or any other program, the helper gets nothing: it exits 1 and prints nothing.
- For S3 the helper prints `Version`, both keys and an `Expiration` 12 hours ahead, so restic asks once per
  run rather than once per request. The helper refuses to run (exit 2) if its own path contains a space,
  because the `credential_process` line can't be quoted. Its errors go to the unified log (subsystem
  `com.jaydenkerr.restorey`, or `com.jaydenkerr.restorey.dev` for Debug builds, category `helper`), not
  stderr, which restic's S3 library discards.
- The agent trusts a restic by its process ID and start time together, and stops trusting it the moment it
  exits, so a later process that reuses the same ID is never mistaken for it.

What this doesn't protect against: an attacker who can hijack a restic process Restorey is supervising could
obtain that plan's secrets; any program running as you can already do a great deal.

## Why the keychain tests need a signed host

Restorey keeps every repository password, backend key and check-in URL in the data protection keychain
(design spec §7 and §10), never the legacy file keychain that `/usr/bin/security` can read. The data
protection keychain only works for code that carries the `keychain-access-groups` entitlement, which needs a
signed app with a provisioning profile. Under bare `swift test` there is no such app, so `SecItemAdd` and
`SecItemCopyMatching` fail with `-34018` (`errSecMissingEntitlement`). Dropping `kSecUseDataProtectionKeychain`
in tests would pass but test the wrong keychain, so the keychain tests are not in `RestoreyCore`'s package suite.

They live in the `AgentHostedTests` bundle, which runs inside the signed Debug agent
(`xcodebuild test -scheme AgentHostedTests -configuration Debug`). `scripts/ci.sh` runs them only when
`Config/Local.xcconfig` exists. On GitHub Actions it doesn't, and the script prints
`hosted keychain tests skipped: no signing` instead. The bundle also runs the installed helper by hand
and checks the agent refuses it (`HelperEndToEndTests`), so it needs `RestoreyDev.app` installed with
`scripts/install-dev.sh`, registered with `--register`, and the agent restarted after each install
(`launchctl kickstart -k gui/$(id -u)/com.jaydenkerr.restorey.dev.agent`). Without that it fails rather than
skips. The tests use a random plan ID each and delete what they
create, so they never touch real Restorey items. The hosted build goes in `~/Library/Caches/restorey-ci`
(override with `RESTOREY_HOSTED_DERIVED_DATA`), not `build/`, because macOS blocks launching an app from
`~/Documents` on a privacy prompt that nobody is there to answer.

## Restoring without Restorey

Your backups will always be plain restic repositories. If Restorey ever disappears, you can restore with
the restic command-line tool and the details from your recovery kit. Full instructions will be added here
before the first release.

## Licence

MIT. See [LICENSE](LICENSE).
