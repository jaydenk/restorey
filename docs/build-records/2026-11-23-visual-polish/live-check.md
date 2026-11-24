# Visual polish: owner's live check

Builds 841 (e210639) and 842 (2857b9e), Dev install on the owner's Mac, 23–24 Nov 2026. The owner did each check;
the app's and agent's logs (`~/Library/Logs/Restorey-Dev`) confirmed each save and run.

| # | Check | Result |
|---|-------|--------|
| 1 | Settings ▸ Network times apply on Tab and on Return, with no Save button | Pass: three saves logged, the setting put back afterwards |
| 2a | Open Restorey opens the main window | Pass |
| 2b | Settings… opens the Settings window | Pass |
| 2c | Opening the app again with no windows open shows the main window | Pass. Restorey has a Dock icon only while a window is open (as designed), so this is a reopen from Applications or Spotlight |
| 2d | Each window reopens on the section it was left on | Pass |
| 2e | Menu bar icon hidden: opening the app again shows Settings ▸ General with the note | Not verifiable on this Mac (below) |
| 3a | "Skip on a hotspot or in Low Data Mode" applies at once | Pass: off and on saved a second apart |
| 3b | A window whose start and end are the same is refused with its reason | Pass |
| 3c | The Wi-Fi list's + opens the name pop-up | Pass. The field starts empty, as built; the owner suggests offering the current network (TODO) |
| 4 | Backup started and Backup finished notifications, no sound, the second replacing the first | Pass (run f469cef8, Succeeded) |
| 5a | Lists' + and − | Failed on 841: bevelled square buttons, and the inset list's alternating rows drew rounded stripes down the empty part of the Plans list. Fixed in 2857b9e (borderless glyphs on a shaded bar, no alternating rows). Pass on 842 |
| 5b | Esc closes the Exclusions sheet without saving | Pass |
| 5c | Setup's four storage choices, and Folder or Drive | Failed on 841: the segmented control stopped short of the fields and its segments were uneven; the Folder or Drive page's bare line and far-off Choose… lined up with nothing. Fixed in 2857b9e (`FillingSegmentedControl`, equal segments across the step; a labelled read-only field with Choose… beside it). Pass on 842 |
| 6a | The plan tab row at the main window's narrowest width | Pass |
| 6b | Help buttons open the README at their section | Opens the repository page at the top: the `#### Network` and `#### Retention` headings exist only on this branch (GitHub's main has neither). Works once the branch is pushed; to check again then |
| 6c | Diagnostics lines (Option-click) readable | Pass |
| 6d | The menu's progress bar | Pass |

## Not verifiable here: the hidden menu bar icon (2e)

macOS keeps one Menu Bar entry for `com.jaydenkerr.restorey.dev` in Control Center's settings
(`group.com.apple.controlcenter`, `trackedApplications`), and it is tied to a deleted ad hoc copy,
`~/Downloads/RestoreyDev 2.app`. Turning RestoreyDev off in System Settings ▸ Menu Bar saved `isAllowed: false` on
that entry, but the icon of `/Applications/RestoreyDev.app` stayed, `NSStatusItem.isVisible` never changed, and so the
note never showed. A leftover of earlier testing on this Mac, not something a release install meets. To try on a clean
Mac or another user account.

## Raised for elsewhere

- A backup about two hours after the last one spent close to 30 minutes before uploading (run started 04:25 UTC,
  24 Nov). Engine speed, not polish: passed to the `backup-robustness` branch, whose speed commit removes restic's
  counting walk.
- Not changed by the owner's choice: no New Plan… item in the menu bar menu.
