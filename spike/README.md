# Restorey platform spike (throwaway)

Throwaway code for the spike in `../docs/superpowers/plans/2026-11-10-platform-spike.md`.
Findings live in `../docs/spike-findings.md`. Nothing here ships.

```sh
cp Config/Local.example.xcconfig Config/Local.xcconfig   # set DEVELOPMENT_TEAM
scripts/build.sh --version 0.0.1                          # prints build/RestoreySpike-0.0.1.dmg
```

Install by opening the DMG and dragging the app to /Applications. The app refuses to register
its agent from anywhere else.
