# UI polish audit: Settings window and menu bar (read-only)

Audit of branch `v0.1-ui` at `364317b`, plus the working tree (Task 16f in progress). Date: 17 Nov 2026. Nothing in the
repo was changed; no builds, tests or git writes.

**About the captures.** None could be taken. The Mac's session was locked for the whole audit
(`ioreg` reports `CGSSessionScreenIsLocked = Yes`). The cmux-cua window grab of Restorey Settings (window 618) came back
pure white, and `screencapture -l618` failed with "could not create image from window". Task 8 found the same thing
(`rulings-for-owner.md` line 13). The `polish/` folder is therefore empty. I deleted the one blank PNG.

The accessibility tree of Restorey's own menus could still be read. Where a finding rests on it, it is cited as **AX**.
It showed two things:
- the status menu's plan item reads "B2 · restorey-full-test / Backed up at 21:20 / 3 files couldn't be read /
  B2 · restorey-full-test";
- while Settings is open, the Window menu offers Show Tab Bar, Merge All Windows, Enter Full Screen and Minimise.

Everything else here comes from reading the code against the HIG. The owner should do one visual pass in both
appearances to confirm the layout findings (F5–F7, P9–P11).

---

## 1. What "Mac-assed" means for Restorey

The phrase comes from Brent Simmons (he credits his friend Collin Donnell). In a March 2020 post he said such apps "are
platform-specific" and are "not trying to wow us with all their custom not-Mac-like UI". He also noted that custom UI
"often isn't very accessible". John Gruber picked the phrase up and preferred it to the vaguer "native".
- Simmons, [Proxyman](https://inessential.com/2020/03/19/proxyman)
- Gruber, [Mac-assed Mac apps](https://daringfireball.net/linked/2020/03/20/mac-assed-mac-apps)

In September 2026 Simmons argued that stock Mac UI isn't automatically right either, and Gruber agreed:
- Simmons, [That about wraps it up for…](https://inessential.com/2026/09/22/that-about-wraps-it-up-for.html)
- Gruber, [Brent Simmons on stock Mac UI](https://daringfireball.net/linked/2026/09/25/brent-simmons-stock-mac-ui)

So the bar isn't "use every stock control". It is "behave the way a Mac user's hands and eyes already expect".

For a menu-bar backup utility, that comes down to:

- **The menu bar extra behaves like Apple's own.** A template symbol. A real menu, not a popover. Standard text styles.
  Titles in title case. Ellipses only where more input follows. Option reveals extra items, as the Wi-Fi, Bluetooth and
  Time Machine extras do.
- **Settings behaves like a Mac settings window.** ⌘, opens it from the app menu. A fixed toolbar of panes, with the
  window titled after the pane. It reopens on the last pane. Minimise and Zoom are dimmed.
  ([HIG: Settings](https://developer.apple.com/design/human-interface-guidelines/settings))
- **Complete standard menus while it is a regular app.** App, Edit and Window menus with their usual items, plus Help.
  ([HIG: The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar))
- **System text styles, used for their purpose.** Semantic colours, readable contrast, and colour never as the only
  signal. ([HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography),
  [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility))
- **Direct manipulation where it is natural.** Drag folders from Finder. Delete removes the selected row. Context menus
  on rows. Quick Look a log.
- **Reachable from the system.** Shortcuts and Spotlight actions (App Intents), and a Dock menu while it is in the Dock.
  The HIG suggests offering an extra's functions in other ways too, since people can hide the extra
  ([HIG: Menu bar extras](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar#Menu-bar-extras)).

HIG pages used: [Settings](https://developer.apple.com/design/human-interface-guidelines/settings),
[The menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar),
[Menus](https://developer.apple.com/design/human-interface-guidelines/menus),
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography) (macOS built-in text styles
table), [Color](https://developer.apple.com/design/human-interface-guidelines/color),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons),
[Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets).

API availability was checked against Apple's documentation JSON:
- `NSMenuItem.subtitle` (macOS 14.4)
- `NSMenuItem.sectionHeader(title:)` (macOS 14.0)
- `NSMenuItem.badge` (macOS 14.0)
- `NSMenuItem.isAlternate`
- `NSWindow.tabbingMode`
- `NSWindow.setFrameAutosaveName(_:)`
- `NSApplicationDelegate.applicationDockMenu(_:)`
- `AppShortcutsProvider` (macOS 13)

---

## 2. Findings

Priorities:
- **Fix**: visibly wrong or inconsistent.
- **Polish**: noticeably nicer.
- **Touch**: a little Mac-assed extra.

Effort is S, M or L. Paths are relative to the repo root. `MP` = `RestoreyCore/Sources/RestoreyCore/App/MenuPresentation.swift`.

### Fix

**F1 · Menu bar / app menu: no Settings… item, so ⌘, works only while the status menu is open (S)**
- **What's wrong.** `App/MainMenu.swift:30-41`: the app menu has About, Hide and Quit only. ⌘, is set on the status
  menu's item (`App/MenuBuilder.swift:117-123`). A status menu's key equivalents fire only while that menu is open. So
  with Settings or Setup frontmost, ⌘, does nothing.
- **Why.** HIG Settings: "Include a settings item in the App menu… the standard Command–Comma (,) keyboard command".
- **Fix.** Add "Settings…" ⌘, after About and its separator, targeting `WindowRouter.showSettings()`.

**F2 · Menu bar / main menu: incomplete app and Window menus, no Help menu (S)**
- **What's wrong.** `App/MainMenu.swift:30-64`.
  - The app menu lacks Hide Others (⌥⌘H), Show All and Services.
  - The Window menu lacks Zoom and Bring All to Front.
  - There is no Help menu.
- **Why.**
  - HIG The menu bar, Window menu: "Include the Minimize and Zoom menu items so people using Full Keyboard Access can use
    the keyboard". The app menu's standard order includes Services and Hide Others.
  - A Help menu is expected, and it gives macOS's menu search somewhere to live.
- **Fix.**
  - Add the standard items and set `NSApp.servicesMenu`.
  - Add a Help menu with "Restorey Help" opening the README or a help page (see T8).
  - If F3 removes Zoom from Settings, Zoom stays valid for Setup and Restore Files.

**F3 · Settings window: Minimise and full screen enabled, and window tabbing offered (S)**
- **What's wrong.**
  - `App/WindowRouter.swift:222` gives every window `.miniaturizable`, and `:125` adds `.resizable` to Settings, which
    enables Zoom and full screen.
  - AX: with Settings open, the Window menu offers Show Tab Bar, Merge All Windows, Move Tab to New Window and Enter Full
    Screen, because `tabbingMode` is left at automatic.
- **Why.** HIG Settings: "Dim a settings window's minimize and maximize buttons… there's no need to keep the window in
  the Dock". Tabbing a Settings window into another window makes no sense.
- **Fix.**
  - For Settings, drop `.miniaturizable`.
  - Set `window.tabbingMode = .disallowed` for every Restorey window.
  - Add `collectionBehavior.insert(.fullScreenNone)` to Settings, Recovery Kit and Restore Files.
  - Keep resizable: Plans and History need it, which is a fair exception. Zoom should still be dimmed (disable the zoom
    button, or keep `.resizable` but set `window.standardWindowButton(.zoomButton)?.isEnabled = false`).

**F4 · Settings window: title is "Restorey Settings — Plans", not "Plans" (S)**
- **What's wrong.** `App/Settings/SettingsWindow.swift:158`, confirmed in AX (Window menu item "Restorey Settings — Plans").
- **Why.** HIG Settings: "Update the window's title to reflect the currently visible pane". Apple's apps show just the
  pane name ("General"). "App Name Settings" is for single-pane windows only.
- **Fix.** `window.title = section.title`. The Window menu then lists "Plans", as Mail and Safari do.

**F5 · Settings › all panes, sheets: plan name and Overview headline share one style (S)**
- **What's wrong.** `App/Settings/PlansPane.swift:217` sets the plan name in `.title3.weight(.semibold)`.
  `App/Settings/PlanOverviewTab.swift:40-42` sets the headline ("Up to date") in the same style, directly below the
  segmented control. Two equal-weight titles compete, and the status reads as a second name.
- **Why.** HIG Typography: use the styles to build a clear hierarchy, so the plan name should outrank the status line.
- **Fix.** Either make the plan name the only title (`.title3.weight(.semibold)`) and put the headline in `.headline`
  (13 pt bold), or keep the headline large and drop the separate name header on Overview. The coloured-headline rule is
  unaffected.

**F6 · Settings, sheets: heading weights and capitalisation are inconsistent (S)**
- **What's wrong.**
  - Sheet titles use `.title3.bold()`:
    - `App/Controls/ExclusionsSheet.swift:19`
    - `App/Controls/BiggestAdditionsSheet.swift:20`
    - `App/Controls/UnreadableFilesSheet.swift:22`
    - `App/Controls/NotForBackupSheet.swift:21`
  - Pages use `.title3.weight(.semibold)` (`PlansPane.swift:217`, `PlanPageParts.swift:141`).
  - The titles' capitalisation varies: "Exclusions", "Biggest additions", "Files that couldn't be read",
    "Items Marked Not for Backup".
- **Why.** HIG macOS text styles table: Title 3's emphasised weight is **Semibold**. Bold is Title 1 and 2's emphasis. A
  title style should be used one way throughout.
- **Fix.** Make every sheet and page title `.title3.weight(.semibold)` (or `.headline` for sheets). Choose one case:
  sentence case, to match every other heading in the app ("Earlier snapshots", "No backup plans yet"). That means
  "Items marked not for backup".

**F7 · Copy: button and item capitalisation and wording are inconsistent (S)**
- **What's wrong.** These break title case:

  | Where | Now | Should be |
  |---|---|---|
  | `App/Settings/PlansPane.swift:90` | "+ Add plan…" | "Add Plan…" (see P9) |
  | `App/Settings/PlanStorageTab.swift:50` | "Show recovery kit…" | "Show Recovery Kit…" |
  | `App/Controls/UnreadableFilesSheet.swift:76` | "Don't back this up" | "Don't Back Up" |
  | `App/Settings/HistoryList.swift:62` | "All plans" | "All Plans" (the status menu says "All Plans") |

  The same System Settings action also has three labels:
  - "Open Settings…" (`App/Controls/FullDiskAccessBlock.swift:35`), which is ambiguous with Restorey's own Settings
  - "Open System Settings" (`App/Settings/NetworkPane.swift:156`)
  - "Fix…" in the menu (`MP:26`)

  And "Show recovery kit…" in Storage opens a window that unlocks with Touch ID, while the menu says "Save Recovery Kit…".
- **Why.** HIG Buttons and Menus: "use title-style capitalization". Use an ellipsis only when more input follows.
- **Fix.** Title-case all button and menu labels. Use "Open System Settings" (no ellipsis: nothing more is asked in
  Restorey) for every jump to System Settings. Keep "Fix…" only if the menu row gets a subtitle saying where it goes
  (see P4).

**F8 · Settings › Plans: delete confirmation uses straight quotes (S)**
- **What's wrong.** `App/Settings/PlanPageParts.swift:112`: `"Delete the plan \"\(planName)\"?"`. Every other prompt
  uses curly quotes, for example `SettingsWindow.swift:63` and `PlansPane.swift:61`.
- **Fix.** `Delete the plan “\(planName)”?`

**F9 · About panel: no copyright, and no restic licence notice (S)**
- **What's wrong.**
  - `/Applications/RestoreyDev.app/Contents/Info.plist` has no `NSHumanReadableCopyright`.
  - The bundle has no Credits.rtf, although restic is shipped at `Contents/Helpers/restic`.
- **Why.** restic is BSD-2-Clause, which requires reproducing its copyright notice with binary redistributions. The
  standard About panel shows `Credits.rtf` or `.html` automatically, which is the Mac way to do it.
- **Fix.** Add `NSHumanReadableCopyright` and a `Credits.rtf` holding restic's licence (and any other bundled code).
  No code is needed: `orderFrontStandardAboutPanel` picks the file up.

**F10 · Whole app: no app icon (M, needs design)**
- **What's wrong.** The bundle has no `Assets.car` or `.icns`, and Info.plist has no icon key. The generic icon shows in:
  - the Dock and ⌘-Tab while a window is open (since the O1 fix makes Restorey a regular app);
  - the About panel;
  - the FDA drag tile (`App/Controls/FullDiskAccessBlock.swift:47`);
  - System Settings' Full Disk Access and Login Items lists;
  - notifications, which the agent posts, so the agent needs one too.
- **Why.** On macOS this is the most visible sign of an unfinished app, and in the permissions lists it makes Restorey
  harder to recognise and trust.
- **Fix.** An Icon Composer `.icon` for the app and agent. Mind the XcodeGen recursion trap with `.icon` folders (see the
  `xcodegen-gotchas` skill).

**F11 · Settings, sheets: 10-pt Caption for explanatory paragraphs, 52 times (M)**
- **What's wrong.** `.font(.caption)` is used 52 times across `App/`, mostly for multi-sentence explanations. Examples:
  - `App/Settings/PlanKeepTab.swift:28,33,40,43`
  - `App/Settings/PlanStorageTab.swift:31,38`
  - `App/Settings/NetworkPane.swift:73,99`
  - `App/Controls/NotForBackupSheet.swift:23`

  Similar notes elsewhere use `.callout` (12 pt), for example `EarlierSnapshotsSection.swift:46,49` and
  `PlanOverviewTab.swift:66,75`. Errors also use red Caption (for example `PlanScheduleTab.swift:32`).
- **Why.** HIG macOS text styles: Caption 1 is 10 pt, the smallest style. It suits labels such as "Restorey's own", not
  three-line explanations. Grouped-form footers use 11 pt (Subheadline). Long 10-pt grey text is hard to read and
  quickly turns into noise.
- **Fix.**
  - Explanatory notes: `.subheadline` (11 pt) or the form footer.
  - Validation errors: `.callout` (12 pt) with an icon.
  - Keep `.caption` for short tags only.
  - Better still, cut the explanations. Several restate each other: Keep has four separate grey paragraphs before
    "Earlier snapshots".

**F12 · Settings, menu: orange and red text fails contrast, and colour carries meaning (M)**
- **What's wrong.** Status text is coloured `.orange` or `.red` in several places:
  - `App/MenuBuilder.swift:156-162`: the menu status line;
  - `App/Settings/GeneralPane.swift:128`: the General lines;
  - `App/Settings/PlansPane.swift:81`: the sidebar notes;
  - `App/Settings/PlanOverviewTab.swift:105-111`: the Overview headline;
  - `App/Settings/NetworkPane.swift:152`.

  systemOrange (#FF9500) on a light background is about **2.2:1**, and systemRed (#FF3B30) about **3.5:1**. Both are
  below 4.5:1, so the text is hard to read at 10–13 pt.
  - In the sidebar the orange caption sits on the accent-coloured selection highlight.
  - History's outcome dots are colour only (`App/Settings/HistoryList.swift:149-152,185-191`), red against green.
- **Why.**
  - HIG Accessibility: sufficient contrast, and don't convey information by colour alone.
  - HIG Color: use system colours for their meaning, but text should stay legible. Apple pairs a tinted symbol with
    label-coloured text.
- **Fix.**
  - Keep text in `labelColor` or `secondaryLabelColor` and carry severity with a tinted SF Symbol, as `StopBanner` and
    `NewKitBanner` already do (`exclamationmark.triangle.fill` orange, `xmark.octagon.fill` red).
  - Give History rows a symbol per outcome (`checkmark.circle.fill`, `exclamationmark.triangle.fill`,
    `xmark.octagon.fill`, `minus.circle`).
  - Check in Increase Contrast mode too.

**F13 · Settings › Plans: three layout systems in one window (L)**
- **What's wrong.**
  - General and Network use a grouped `Form`: labels on the left, controls on the trailing edge, inset sections.
  - What, Storage and Alerts use `SetupField` (a label above each control) in a bare `VStack` (`PlanWhatTab.swift:21-53`,
    `PlanStorageTab.swift:13-52`, `PlanAlertsTab.swift:11-21`).
  - Schedule and Keep use a `Grid` with leading labels (`PlanScheduleTab.swift:12-38`, `PlanKeepTab.swift:16-21`).
    Keep also has a lone `Toggle` and `Picker` outside the grid, with a different label alignment (`:31-39`).

  Moving between tabs shifts the label column, control alignment, insets and background (grouped versus plain). The page
  reads as setup screens pasted into Settings.
- **Why.** HIG Layout: align controls consistently, and use the system's grouped form style on macOS, which System
  Settings itself uses. Consistent alignment is what makes a settings window scannable.
- **Fix.** Put every plan tab into `Form { Section { … } footer: { … } }.formStyle(.grouped)` with `LabeledContent` rows,
  as General and Network do:
  - Folders, Exclusions and Marked items become rows with trailing buttons.
  - Storage's secrets become `LabeledContent` with `SecretField`.
  - The Keep counts sit in one row.
  - The notes become footers, which also fixes F11 for free.

  It is the biggest single visual improvement available, and the menu and Overview wording don't change.

### Polish

**P1 · Settings window: last pane and window frame not remembered across launches (S)**
- **What's wrong.**
  - `ShellState.settingsSection` lives in memory only.
  - `App/WindowRouter.swift:214` centres every new window, and no window calls `setFrameAutosaveName`.
- **Why.** HIG Settings: "Restore the most recently viewed pane".
- **Fix.**
  - Persist the section (not the plan or its tab) in `UserDefaults`.
  - Call `window.setFrameAutosaveName("Settings")` and centre only when there is no saved frame. (`isRestorable = false`
    is still correct: this is about frame and pane, not reopening at launch.)

**P2 · Menu bar: dead submenu and indented items (S)**
- **What's wrong.**
  - With several plans, "Back Up Now" becomes a submenu that is disabled when nothing can back up
    (`RestoreyCore/.../MenuLayout.swift:70-71`, the enabled flag on `.submenu` at `:99`).
  - "Show Details…", "Don't Show This Again" and other actions are indented under their row (`MenuLayout.swift:46,58`,
    `App/MenuBuilder.swift:107`).
- **Why.** HIG Menus:
  - "Make sure a submenu remains available even when its nested menu items are unavailable."
  - "Prefer using a submenu to indenting menu items. Using indentation is inconsistent with the system."
- **Fix.**
  - Keep the submenu enabled and disable its children.
  - Replace the indented items with a section per plan (see P4), or attach the secondary action as an Option-alternate
    (`isAlternate`) of the row it belongs to.

**P3 · Menu bar: destination line repeats the plan name (S)**
- **What's wrong.** AX: "B2 · restorey-full-test … B2 · restorey-full-test". Setup names a new plan after its repository
  (`App/Setup/SetupModel+Storage.swift:31`, `StorageForm.planName`), and the menu adds the destination below it
  (`MP:436-449`). For most users the first and last lines will therefore match until the size has been measured.
- **Fix.** Omit the destination when it equals the plan name, or show only its new part (", 486 GB, 3 days ago").

**P4 · Menu bar: hand-drawn rows instead of sections and subtitles (M)**
- **What's wrong.** `App/MenuBuilder.swift:127-185` builds each banner and plan row as a multi-line attributed title:
  - the bold name is a font trait conversion of the menu font;
  - a second line holds the status;
  - small secondary lines follow;
  - for banners, the fix is accent-coloured text inside the same row.

  Because AppKit doesn't recolour attributed text on highlight, `willHighlight` redraws rows by hand (`:29-42`).
  In the result:
  - the bold names look like nothing else in macOS menus;
  - the accent "Fix…" reads as a link but isn't a separate target;
  - the row is one long VoiceOver string.
- **Why.**
  - HIG Menus asks for groups with separators and standard item styles.
  - Apple's own extras (Wi-Fi, Bluetooth, Battery, Focus) use small section headers, and plain items with a secondary
    line.
  - The APIs exist on the deployment target: `NSMenuItem.sectionHeader(title:)` (14.0), `subtitle` (14.4) and `badge`
    (14.0).
- **Fix.**
  - Plans:
    - each plan gets a `sectionHeader(title: plan name)`;
    - one item shows the status as its title, with detail and destination as its `subtitle`;
    - a tinted symbol image marks severity.
  - Banners: a title, the detail as a subtitle, and the fix named in the title or as its own item ("Open Full Disk
    Access Settings").

  AppKit then handles highlight colours, so `willHighlight` and the `Palette` code go. Keep the progress view row.

**P5 · Menu bar: long sentences make the whole menu wide (S)**
- **What's wrong.** Menu items don't wrap, so the menu is as wide as its longest line. Examples:
  - `MP:421`: "The first backup was interrupted. It carries on at 14:16, keeping what's already uploaded."
  - `MP:213`: "Restorey can't read its settings: …", which ends in a raw error of any length.
  - `MP:476`: "Finishing the current backup before updating the agent".
  - `MP:269`: "Notifications are off — Restorey can't alert you".
- **Why.** HIG Menus: keep labels succinct. Apple's extras keep lines short and put detail in their settings.
- **Fix.**
  - Give menu strings a length budget (about 45 characters).
  - Move the explanation to the Overview or a tooltip (`NSMenuItem.toolTip`).
  - Never interpolate a raw error into a menu line: say "Restorey can't read its settings" and open General or the
    Overview for the detail.

**P6 · Settings › General: Full Disk Access block crammed into the value column (S)**
- **What's wrong.** `App/Settings/GeneralPane.swift:28-32` puts a paragraph, a 48-pt drag tile, a caption and a button
  inside `LabeledContent`'s trailing column. In a grouped form that column is meant for a short value or control, so the
  block wraps narrowly and sits against the right edge.
  - The `LineView` values beside it are right-aligned multi-line text (`:129`).
- **Fix.**
  - Make Full Disk Access its own `Section("Full Disk Access")`: tile and text in a full-width row while missing, a
    one-line "On ✓" `LabeledContent` row when granted.
  - Same for the Notifications and agent lines: a short value, with the explanation in the section footer.

**P7 · Settings: no "edited" indicator on the window (S)**
- **What's wrong.** Unsaved edits are guarded on close and quit (`App/WindowRouter.swift:229-300`; good), but nothing
  shows them before then. `isDocumentEdited` is never set.
- **Why.** On the Mac, the dot in the close button is the standard signal that something is unsaved, and it matches the
  Save, Don't Save or Cancel alert the app already uses.
- **Fix.** Set `window.isDocumentEdited` from `planEditorSlot.unsavedPlanID != nil || network.isDirty`.

**P8 · Sheets: Esc and Cancel not provided (S, verify first)**
- **What's wrong.** These sheets each offer only "Done" with `.defaultAction` and no `.cancelAction`:
  - `ExclusionsSheet.swift:55`
  - `BiggestAdditionsSheet.swift:45`
  - `UnreadableFilesSheet.swift:42`
  - `NotForBackupSheet.swift:34`

  I couldn't test whether Esc closes them on macOS 27 (the screen was locked).
- **Why.** HIG Sheets: people expect Esc to dismiss a sheet, and in AppKit Esc maps to the cancel button. The
  information-only sheets (Biggest additions, Files that couldn't be read) need no Cancel, but Esc should still work.
- **Fix.**
  - If Esc doesn't dismiss, add `.onExitCommand { dismiss() }`, or a hidden `.keyboardShortcut(.cancelAction)` on Done.
  - The editing sheets apply straight into the plan's unsaved fields, so Done is correct there. Their Revert is the
    page's, which should be noted in the sheet's footer.

**P9 · Settings › Plans: the sidebar doesn't look like a Mac settings list (M)**
- **What's wrong.**
  - `App/Settings/PlansPane.swift:74-97`: the sidebar is a `.sidebar` list (translucent sidebar material) inside a
    preferences window.
  - Adding is a borderless text button, "+ Add plan…".
  - Deleting is "Delete Plan…" at the far left of the Save bar (`App/Settings/PlanPageParts.swift:64`), right beside
    Revert and Save. That is an odd place, and a risky one.
- **Why.** Apple's settings windows with a list of things use a bordered list with small + and − buttons beneath it:
  Mail › Accounts, Users & Groups, Network's service list. The control-bar idiom is what Mac users look for.
- **Fix.**
  - `.listStyle(.bordered)` (or `.inset` with alternating rows).
  - Below it, + (add plan) and − (Delete Plan…, confirmation unchanged) buttons in the standard small square bezel.
  - Rename and actions via a context menu (T4).
  - Take Delete out of the Save bar.

**P10 · Settings › Plans: seven segmented tabs (M)**
- **What's wrong.** `PlanTabPicker` (`App/Settings/PlansPane.swift:187-205`) has seven segments: Overview, What,
  Schedule, Storage, Keep, Alerts, History.
  - The control's natural width sets the window's minimum width (`SettingsWindow.swift:31-33`).
  - "What" and "Keep" are terse to the point of guessing.
  - The plan's History duplicates the toolbar's History pane, filtered.
- **Why.** HIG (Tab views and Segmented controls) suggests keeping the count low and labels clear. A segmented control
  used as tabs should be a `TabView`, which on macOS draws the system tab style and handles keyboard switching.
- **Fix.**
  - Use a `TabView`.
  - Rename What → "Folders", and Keep → "Snapshots" or "Retention".
  - Drop the per-plan History tab in favour of a "Show History" button on the Overview that opens History filtered to
    the plan (the route already exists: `showSettings(section: .history, planID:)`). Six tabs then fit comfortably.
  - Alerts could fold into Schedule ("When to warn").

**P11 · Settings › History: list with fake columns (M)**
- **What's wrong.** `App/Settings/HistoryList.swift:139-183` is a `List` of `HStack`s with `minWidth` "columns".
  - There are no headers, sorting or column resizing.
  - Actions are link-style buttons on every row: "Show…", "Show…" and "Show Log".
  - It doesn't respond to double-click, a context menu or the space bar.
- **Why.** A table of runs is a textbook `Table` (`NSTableView`). Mac users expect sortable headers, selectable rows, ⌘C,
  and a context menu.
- **Fix.**
  - SwiftUI `Table` with Time, Plan, Step, Outcome, Added and Duration columns.
  - Outcome with a symbol (F12).
  - Selection, with the actions in a context menu: Show Log, Show Log in Finder, Show Files That Couldn't Be Read…,
    Show Biggest Additions….
  - Double-click opens the log, and the space bar Quick Looks it (T6).
  - The two filter pop-ups move into the window's toolbar area or stay above the table.

**P12 · Menu bar: the OK icon is the Time Machine glyph (S, design call)**
- **What's wrong.** `App/StatusIcon.swift:35` uses `externaldrive.badge.timemachine`.
- **Why.** People who also run Time Machine have Apple's extra right beside it, and the clock badge invites confusion
  about which tool is backing up and which is complaining. The HIG asks for a symbol that represents *your* app.
- **Fix.** Keep the drive, and swap the badge for a neutral or brand mark (for example `externaldrive.badge.checkmark`,
  or a custom symbol built from it in the SF Symbols app, exported as a template).

**P13 · Copy: "agent" jargon in user-facing text (S)**
- **What's wrong.**
  - "Restart Agent" (`MP:27`).
  - "The background agent isn't running" (`MP:192`).
  - "Background agent" (General), and "Updating the background agent…".
- **Why.** "Agent" is an implementation word. Apple says "background item" (Login Items & Extensions) and otherwise
  names the function.
- **Fix.** Use "Restart Backups" (or "Restart Restorey's Background Process"), "Backups aren't running", and a General
  row titled "Backups in the background".

**P14 · Settings › Schedule and Keep: bare number fields (S)**
- **What's wrong.** `App/Controls/ScheduleControls.swift:53-62`: retention counts are 46-pt text fields with no stepper.
  The upload limit is a 70-pt field whose placeholder is "None".
- **Fix.**
  - Pair each count field with a `Stepper` (`NSStepper`), as Alerts' day count already does.
  - Use `.monospacedDigit()`, and right-align numbers in the fields.

**P15 · Settings › Overview: actions are an undifferentiated row (S)**
- **What's wrong.** `App/Settings/PlanOverviewTab.swift:78-83`: Back Up Now, Pause and Restore Files… are equal plain
  buttons at the bottom of a page that already ends in the Save bar's Revert and Save. This makes two rows of buttons
  with different meanings.
- **Fix.**
  - Put the Overview actions in the header beside the headline, as Time Machine settings puts "Back Up Now" by its status.
  - Hide the Save bar on Overview: nothing there is editable.

### Touch

**T1 · Menu bar: Option reveals more**
- Apple's Wi-Fi, Bluetooth and Time Machine extras show extra detail and actions when Option-clicked. Use an
  `isAlternate` item, or check `NSEvent.modifierFlags` in `menuNeedsUpdate`, to add:
  - the agent version;
  - "Show Logs in Finder";
  - "Restart Background Process";
  - "Copy Diagnostics";
  - "Check Repository Now" (later).
- This also gives the P2 secondary actions somewhere to live.
- Effort: S–M.

**T2 · System: App Intents**
- Add an `AppShortcutsProvider` with:
  - "Back Up Now" (all plans or one);
  - "Pause Backups" and "Resume Backups";
  - "Get Last Backup", which returns the time and outcome.
- They appear in Shortcuts, Spotlight and Siri with no extra UI, and let people back up before closing the lid from a
  Focus automation.
- Effort: M.

**T3 · Settings › What, Exclusions: drag and drop, and the Delete key**
- Accept folders dragged from Finder into the Folders list and the Exclusions list (`.dropDestination(for: URL.self)`).
- Make Delete and ⌘⌫ remove the selected rows (`.onDeleteCommand`).
- Files: `App/Controls/SourcesEditor.swift`, `App/Controls/ExclusionsSheet.swift`.
- Effort: S.

**T4 · Settings: context menus**
- Plan in the sidebar: Back Up Now, Pause, Restore Files…, Show History, Rename, Delete Plan….
- Folder rows: Show in Finder, Remove.
- History rows: see P11.
- Effort: S–M.

**T5 · Dock: a Dock menu while Restorey is a regular app**
- `applicationDockMenu(_:)` with Back Up Now, Pause and Settings…. The HIG suggests a Dock menu because people can hide
  the menu-bar extra.
- Effort: S.

**T6 · Settings › History: Quick Look a run log**
- Space bar on a selected row opens the log in a Quick Look panel (`QLPreviewPanel`). Option turns Show Log into
  "Show Log in Finder".
- Effort: S.

**T7 · Menu bar: a subtly animated icon while backing up**
- Time Machine animates its extra during a backup. A slow symbol effect, or rotating the badge, says "working" without a
  progress bar. Respect Reduce Motion.
- Effort: M.

**T8 · Help: a Help menu and help buttons**
- A Help menu (F2) that opens a help page or the README.
- The round "?" help button (`NSButton` help bezel) at the bottom-right of Network and Keep, linking to the relevant
  section. This is cheaper than paragraphs of 10-pt text (F11).
- Effort: S–M.

**T9 · Menu bar: tooltip on the status item**
- `item.button?.toolTip = "Restorey — backed up at 21:20"` (or the worst problem), updated with the icon. Today only the
  refused copy has one (`App/StatusItemController.swift:85`). It gives the state at a glance without opening the menu.
- Effort: S.

**T10 · Settings › Plans: keyboard between tabs**
- With `TabView` (P10), ⌃Tab and ⌃⇧Tab move between tabs.
- Also make ↑ and ↓ in the sidebar change plan without first clicking in it (initial focus on the list when Plans opens).
- Effort: S.

---

## 3. Already right — leave alone

- **Status icon.** Every state is a template SF Symbol composite, so it tints for light and dark and dims on an inactive
  display. Each state has its own VoiceOver description (`App/StatusIcon.swift`).
- **Real menu, live updates.** It is an `NSMenu`, not a popover. Items update in place while open, so the highlight and
  any open submenu survive progress updates (`MenuLayout.canUpdateInPlace`).
- **Menu wording.** "Back Up Now" (verb form), "Restore Files…" and "Settings…" have correct ellipses. "Quit Restorey"
  has ⌘Q. The order is status, actions, then Settings and Quit, as Apple's extras have it.
- **Semantic colours.** The menu uses `labelColor`, `secondaryLabelColor` and `selectedMenuItemTextColor`. No hex
  colours anywhere in the UI. SwiftUI `.red` and `.orange` are the adaptive system colours, so dark mode works (the
  issue is contrast, F12).
- **Settings toolbar.** An `NSToolbar` with `.preference` style, non-customisable, SF Symbols with labels, selected item
  shown (`SettingsWindow.swift:85-160`). This is exactly the HIG pattern.
- **Unsaved edits.** Save, Don't Save or Cancel on close and on quit. Discard is asked before switching plans. ⌘S saves.
  Save isn't the default button, because Return belongs to the fields.
- **Edit menu.** Wired to the first responder, so ⌘C, ⌘V, ⌘Z and ⌘A work in every field. The per-field undo managers
  can't outlive their fields, and secrets have no undo history.
- **About panel.** The standard About panel, counted as a window.
- **Restoration.** `isRestorable = false`, so Settings doesn't reopen at every login.
- **Full Disk Access drag tile.** It drags a real file URL into System Settings' list, with an accessibility hint. A very
  Mac-assed detail.
- **Accessibility work.** VoiceOver labels on grouped-form toggles and pickers (live finding 4), on the menu progress
  bar, on "Show…" links and on the Copy buttons. Paths use middle truncation with `.help` giving the full path. Times
  use `.monospacedDigit()`.
- **Open panels.** Presented as sheets on the key window (`presentForKeyWindow`), with specific prompts ("Leave Out",
  "Add").
- **One source of truth for words.** The menu, Overview and Settings share `MenuPresentation`, so the states can't drift
  apart.
- **Spelling.** Australian English throughout ("Minimise", "colour", "Centre" from the system). No US spellings found
  in UI strings.
