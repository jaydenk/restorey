# Restorey

A free, open-source macOS menu bar app that puts an Arq/Backblaze-style front end on
[restic](https://restic.net).

> **Status: design stage.** There is no app to download yet. The design is approved and the
> next step is a technical spike. Nothing here is ready to protect your data.

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

## Restoring without Restorey

Your backups will always be plain restic repositories. If Restorey ever disappears, you can restore with
the restic command-line tool and the details from your recovery kit. Full instructions will be added here
before the first release.

## Licence

MIT. See [LICENSE](LICENSE).
