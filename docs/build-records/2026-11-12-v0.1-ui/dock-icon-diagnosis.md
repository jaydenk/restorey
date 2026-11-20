# Dock tile shows the blank placeholder icon: diagnosis

Date: 2026-11-18. Installed app: `/Applications/RestoreyDev.app`, build 831, `com.jaydenkerr.restorey.dev`.
Method: `superpowers:systematic-debugging`. I changed nothing in the repo or the installed app, and cleared no
system caches.

## Root cause

The Dock is showing an icon it cached itself before Restorey had one, and it has never had a reason to replace it.

- The icon arrived today (`e8cdfbc`, 2026-11-18 11:30). Every Restorey Dev build before then had no icon, so
  each `.regular` switch showed the generic app icon, and the Dock cached that for `/Applications/RestoreyDev.app`.
- The Dock process has been running since **Tue 17 Nov 21:16** (`ps -o lstart= -p $(pgrep -x Dock)`), which is
  before the icon existed. Its on-disk cache (`$DARWIN_USER_CACHE_DIR/com.apple.dock.iconcache`) was last written
  at 11:06 today, also before the icon.
- The Dock validates a cached tile icon against the bundle's **modification date** (the Dock binary carries
  `modDate`, `parentModDate`, `_contentModDate`, `updateIconCache:`, `removeFromIconCache` and
  `convertFileTileToProcessTile:openIconCache:`). Restorey's bundle date never changes:
  - `stat /Applications/RestoreyDev.app` gives **Nov 10 18:38:57**, and Launch Services records the same
    (`mod date: 2026-11-10 18:38`), even though `Info.plist`, `Resources/` and `Assets.car` are dated today.
  - The build product, `build/DerivedData-signed/.../RestoreyDev.app`, is also dated Nov 10 18:38:57. Xcode
    created that directory once. Incremental builds rewrite what is inside it but never the directory itself, and
    `install-dev.log` has no Touch step for it.
  - `scripts/install-dev.sh` runs `rm -rf "$DEST"` and then `ditto "$BUILT" "$DEST"`. `ditto` keeps the source's
    timestamps, so the Nov 10 date carries over to `/Applications`.
  - `CFBundleVersion` is also unchanged. It was 831 on both sides of the icon commit (`BUILD_NUMBER` is the
    override), so the version gives the Dock no signal either.

  The (path, modification date, version) the Dock sees is the same as on Nov 10, so it keeps serving the
  placeholder it rendered while the bundle had no icon. Quitting and relaunching Restorey doesn't touch the Dock's
  cache. Neither did the Launch Services clean-up, because the Dock's cache isn't Launch Services.

### Evidence that everything except the Dock gives the right icon

A throwaway test app (`com.example.dockicon-test.<variant>`, run from the scratchpad with Restorey's compiled
`Assets.car` and `AppIcon.icns`) wrote `NSApp.applicationIconImage`, `NSImage(named: NSImage.applicationIconName)`
and `NSWorkspace.icon(forFile:)` to PNG at launch, and again 1 s after `setActivationPolicy(.regular)`.

| Variant | LSUIElement → `.regular` | Keys | Resources | `applicationIconImage` after `.regular` |
|---|---|---|---|---|
| a (shaped like Restorey) | yes | IconName + IconFile | car + icns | **teal icon** (NSCGImageSnapshotRep 256²) |
| b | no (plain regular) | both | car + icns | teal icon |
| c | yes | `CFBundleIconName` only | car + icns | teal icon (same bytes as a) |
| d | yes | `CFBundleIconFile` only | car + icns | teal icon (icns rendering) |
| e | no | `CFBundleIconName` only | car + icns | teal icon |

None of the variants produced the blank icon. `NSImage(named: .applicationIconName)` and the workspace icon were
the full IconServices image every time (32 `NSISIconImageRep`s, up to 2048²). The PNGs are in
`/private/tmp/claude-501/-Users-kerrj-Documents-Development-restorey/50d7f0ea-c10d-4cb6-89d3-1ae860872c86/scratchpad/dockicon/out/`.
That folder is session scratch, so it may be cleared later.

I also queried the running Restorey (pid 19710, policy `.regular` at the time) read-only, from a separate process:
`NSRunningApplication.icon` and `NSWorkspace.urlForApplication(withBundleIdentifier:)` → `icon(forFile:)` both
return the correct teal icon (`out/q-runningApp-19710.png`, `out/q-byBundleID.png`). The bundle-ID lookup resolves
to `/Applications/RestoreyDev.app`. Launch Services, IconServices and AppKit all give the right icon for this
process. Only the Dock's own cache gives the wrong one.

## Ruled out

- **(a) AppKit doesn't fill `applicationIconImage` from an Icon Composer icon for an accessory app that switches
  to regular.** Refuted by variant a: the image is the correct icon before and after the switch. Apple's docs
  describe `applicationIconImage` as an override you assign "when you want to temporarily change the app icon in
  the dock app tile… To restore your app's original icon, set this property to nil"
  ([NSApplication.applicationIconImage](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage)).
  Restorey never assigns it (`rg` finds no use), so the Dock uses the bundle icon.
- **(c) `CFBundleIconName` vs `CFBundleIconFile` precedence.** Refuted by variants c, d and e. Each key works on
  its own, under both policies. Docs: [CFBundleIconName](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconname)
  ("The name of the asset that represents the app icon") and
  [CFBundleIconFile](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile).
- **(d) A helper is the process behind the tile.** Refuted by `lsappinfo`. The agent
  (`com.jaydenkerr.restorey.dev.agent`, pid 10081) is `type="BackgroundOnly"` (it sets `.prohibited`). The tile
  belongs to the main app (pid 19710, `type="Foreground"`). The agent bundle carries the same icon in any case.
- **The activation-policy switch itself.** It works as documented: `.accessory` "corresponds to … LSUIElement …
  being 1" and `.regular` "appears in the Dock"
  ([.accessory](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory),
  [.regular](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/regular)).
- **The compiled icon.** `Assets.car` holds an `AppIcon` IconImageStack (Aqua, DarkAqua and Tintable), IconGroups
  and sized Icon Images. `AppIcon.icns` unpacks to the correct teal artwork.
- **Duplicate Launch Services registrations.** Removing them didn't help, and the bundle-ID lookup already
  resolves to `/Applications`. One new registration has appeared since the clean-up:
  `~/Library/Caches/com.apple.SwiftUI.Drag-ED749F2B-…/RestoreyDev.app`, flagged `launch-disabled` and registered
  at 13:59. It is probably the copy System Settings made when the app was dragged into Full Disk Access. It doesn't
  affect the icon lookup above, but it is another record for the bundle ID.

## What I could not observe

I was not permitted to capture the screen or the Dock, and the Dock's accessibility items expose no image
(attributes: AXTitle, AXURL, AXIsApplicationRunning, etc.). That means I couldn't watch the Dock re-render. The
cause above rests on elimination (every other layer gives the correct image for this exact process), the
timeline, the frozen bundle date and the Dock's modification-date-keyed cache. It is not a direct observation of
the tile.

The owner can settle it in under a minute:

1. `touch /Applications/RestoreyDev.app`, quit Restorey Dev, relaunch it and open a window. If the tile is now
   correct, the stale modification date is proven to be the cause.
2. If it is still blank, run `killall Dock`. The Dock restarts and reloads its icon cache. If the tile is then
   correct, the cache is proven to be the cause, and it also ignores the modification date until it restarts.
   This is the owner's call; I haven't run it.

## Proper fix

1. **Give every install a modification date that reflects its content.** In `scripts/install-dev.sh`, run
   `touch "$DEST"` straight after `ditto "$BUILT" "$DEST"`, before `lsregister -f`. Or, better, make the build
   product carry the right date: a final post-build step on the Restorey target that runs
   `touch "$TARGET_BUILD_DIR/$WRAPPER_NAME"` (Xcode's usual product Touch step is missing from this build), so the
   date propagates through `ditto`. This is the root fix, not a workaround: the Dock, Finder and IconServices all
   use the bundle's modification date to tell whether a bundle changed. Today every Restorey Dev build claims to be
   the Nov 10 bundle, so any icon or Info.plist change can be ignored the same way.
2. **Bump `CFBundleVersion` on every install**, for example from the commit count. Don't reuse 831. This gives
   version-keyed caches the same signal.
3. **One time:** after the first install with the touch fix, do a Dock restart (`killall Dock`, owner's decision)
   if relaunching alone doesn't refresh the tile. That flushes the placeholder cached while the bundle had no icon.
   No code change is needed for the icon itself, `applicationIconImage`, the plist keys or the activation policy.

Also: the comment in `install-dev.sh` blames the build product's registration for the "old generic icon". That
turned out not to be the cause. Correct the comment when the touch fix lands.

## Clean-up done

Test apps were unregistered (`lsregister -u`, `dump` shows 0 `com.example.dockicon-test` records), bundles,
binaries and per-app cache folders were deleted, and no test process is running. Only the PNG evidence and the two
small Swift sources remain in the scratchpad.
