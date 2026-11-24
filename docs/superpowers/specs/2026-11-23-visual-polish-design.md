# Visual polish pass

**Status:** draft for the owner's approval (23 Nov 2026). Decided by the owner in conversation on 23 Nov 2026. It
builds on the v0.1 UI design (`2026-11-12-restorey-v0.1-ui-design.md`, especially §5–§8) and the polish audit
(`docs/build-records/2026-11-12-v0.1-ui/polish-audit.md`; its current status is in this document's appendix).

## Intent

The owner set "a visual polish pass across the app before 1.0 is considered finished" on 16 Nov 2026. Most of the
17 Nov audit is done. What is left is what the owner notices in daily use: places where Restorey doesn't behave like
a well-made Mac app. The worst are the window structure (⌘, opens the backup plans, not preferences), lists, and
having to type a path where a picker belongs. The owner also asked for optional status notifications.

Success: the owner uses Restorey for a while and nothing reads as "not quite Mac".

## Goals

1. **Two windows.** A main **Restorey** window for the plans and their history, and a standard **Settings** window
   for app-wide preferences.
2. **Lists** use the Mac's standard + and − buttons attached to the list.
3. **Pickers**, not typed paths, wherever the user names a folder or drive: a plan's folders, and a local repository.
4. **Status notifications** the user can choose: backup started, backup finished, errors.
5. **The audit's leftovers** are fixed (listed under "Leftovers").

## Non-goals

- The menu bar menu's text weights and layout. The owner's concern came from a stuck warning, caused by the DeviceFS
  bug (fixed separately on 23 Nov 2026, branch `fix-devicefs-mounts`). The menu already uses only standard AppKit
  items and stays as it is, apart from the shorter banner lines below.
- The polish batch: the small deferred minors from task reviews (TODO "Minor polish list"). It is the next item in
  the owner's order and is planned separately.
- The audit's Touch items the owner didn't pick (T5 Dock menu, T6 Quick Look, T7 animated icon, T10 ⌃Tab).
- New features beyond notifications.

## Anti-goals

- **Losing a failure.** Error notifications can be turned off, but a failure must still show somewhere: the menu
  bar icon and menu, and any check-in URL. The README's aim, "alert loudly when backups fail or stop", stands.
- **Settings that save themselves half-checked.** Moving Settings to apply-as-you-go must never write a value the
  agent would refuse, or leave the app and the agent disagreeing about what is saved.
- **Breaking routes into the app.** Every way in today must still land somewhere sensible: the menu bar (a plan's
  status item, Settings…), ⌘,, the Dock icon, reopen, Shortcuts, notifications, the setup flow's end and the
  Developer window.

## Constraints

- AppKit owns the windows. `WindowRouter`, `MainMenu` and `AppShell` (`SettingsSection`, `SettingsRoute`) decide which
  window shows. SwiftUI draws the content inside `NSHostingView`. The app's life cycle is AppKit (`AppDelegate`), so
  a SwiftUI `Settings` scene is not an option without replacing that.
- HIG Settings: an app-wide preferences window opened by Settings… (⌘,) in the app menu, with a toolbar of panes, a
  fixed width, the pane's name as the window title, changes applied immediately, and no OK, Cancel or Save. Its
  name is "Settings", not "Preferences" (macOS 13 and later).
- The agent owns config and validates every save (`NetworkSettingsError`, `Plan.validationErrors`). The app never
  writes config itself.
- Australian English in all text. No straight quotes in UI text.
- Config is versioned (`VersionedStore`, schema 5). New Mac-wide fields follow the existing rule: an additive field
  with a default when absent needs no schema bump (as `adoptedAt` and `skipsItemsMarkedNotForBackup` did); a
  changed shape needs a migration and the `.v<n>.bak` copy.

## Approaches

1. **Keep AppKit-owned windows, split into two (chosen).** `WindowRouter` gains a second window kind. The existing
   pane views move into one window or the other. Routing, frame autosave and the Window menu stay in one place.
2. **SwiftUI `Window` and `Settings` scenes (rejected).** That would replace the AppKit life cycle, `WindowRouter`,
   `MainMenu` and the remembered window frames for no visible gain. The audit (F1–F3) already made the AppKit
   window behave like a Mac window.
3. **One window, reordered (rejected by the owner).** Plans, History, Network, General in one window. It is the
   smallest change, but ⌘, would still open the plans, and the HIG reserves Settings for app-wide preferences.

## The design

### 1. Two windows

**The main window**, titled with the current section ("Plans" or "History", as today):

- Two sections, **Plans** (first, where it opens) and **History**, switched the way the Settings window switches
  sections today (toolbar items). The Plans section keeps its current layout: the bordered plan list on the left,
  the selected plan's tabs and page on the right. History keeps its table.
- It is resizable, remembers its frame and last section (P1, as today), and is listed in the Window menu.
- Opened by:
  - a plan's status item in the menu bar menu (opens that plan, as today);
  - a new menu bar item, **Open Restorey** (no shortcut; above Settings…);
  - the Dock icon and reopen (`applicationShouldHandleReopen`), except when the menu bar item is hidden: then
    reopen keeps today's rule (`shellOpeningOnReopen`) and opens Settings ▸ General, where the control to show it
    again is (my call: a hidden menu bar item must stay recoverable);
  - (Shortcuts run in the background and the setup flow's end opens no window, so neither needs a route.)
- Each window has its own frame-autosave name and Window menu entry. A remembered section from before the split
  that now belongs to the other window falls back to that window's default (Plans; General), with no migration.
- The plan editor is unchanged: its tabs keep their Save and Revert bar, and the unsaved-edits question
  (`SaveQuestion`) is asked when switching plans or closing the window. Switching to History asks nothing: the
  edits stay in the window's editor and are there on going back to Plans, as today (ruling, 23 Nov 2026).
  Apply-as-you-go is for the Settings window only.
- Whether Restorey shows a Dock icon while this window is open follows today's rule for the Settings window,
  unchanged.

**The Settings window**:

- Opened by Restorey ▸ Settings… (⌘,) in the app menu, and by **Settings…** in the menu bar menu. Both open Settings
  only, never the plans.
- Toolbar panes, in order: **General**, **Notifications**, **Network**. Fixed width; height follows the pane, as
  System Settings-style preference windows do. Title is the pane's name. Last pane remembered.
- **Changes apply as they are made.** This concerns Network and the notification switches; General's rows are
  already actions or system state that take effect at once (Open at login, Full Disk Access, Logs). A toggle or
  picker applies at once. A text or number field (an upload limit,
  a window time) applies when editing ends (Return, Tab or leaving the field), not on every keystroke. A value the
  agent refuses is never kept: the field shows the agent's sentence beside it, and the setting stays as saved. The
  Save and Revert bar goes. Network's "Now:" line drops ". Updates when you save.", since there is nothing unsaved.
  Network is validated as a whole, as today (`NetworkEditModel`): a change is sent only when the whole set is valid.
  While a rule across fields fails (for example a window whose start equals its end), the problem shows beside the
  field and nothing is sent; edits still invalid when the window closes are dropped, and the pane shows what is
  saved when reopened (my call).
- While the agent isn't connected, the panes' controls are disabled with the existing "Waiting for Restorey's
  background process…" state, as the Network pane does today; nothing queues (my call).
- General keeps everything it has today: Open at login, Full Disk Access, notifications permission, Backups in the
  background, Logs. The notifications permission row moves to the Notifications pane.

**Routing (`AppShell`):** `SettingsSection` splits into the main window's sections (plans, history) and the Settings
window's panes (general, notifications, network). Every route that names a section today (`SettingsRoute`, menu
commands, banners such as "Allow Full Disk Access…" and "Turn On Notifications…", Shortcuts, the Developer window, `AppWindowKind`)
maps to the right window. A banner's fix opens the Settings pane it names; anything about a plan opens the main
window.

```
Menu bar menu                      App menu
  B2 · restorey-full-test          Restorey
  ✓ Backed up at 9:19 am  ──┐        About Restorey
  …                         │        Settings…        ⌘,  ──┐
  Back Up Now               │        …                      │
  Restore Files…            │                               │
  ────────────              ▼                               ▼
  Open Restorey      ──▶ [ Main window: Plans | History ]  [ Settings: General | Notifications | Network ]
  Settings…          ─────────────────────────────────────▶
  Quit Restorey
```

### 2. Lists: + and −

Every list that adds and removes items gets the Mac's standard control: small square + and − buttons joined to the
list's bottom edge, inside its border, with no gap (as in System Settings, Finder's sidebar settings and Mail's
accounts). The plan list already has + and − (`ListAddRemoveBar`, audit P9), but as a separate row under the list's
border; the shared control becomes one bordered unit, list and buttons together. − is disabled when nothing removable is selected. This covers the plan list, a plan's folders, the
exclusions sheet, its file types, and the skipped Wi-Fi networks list (today a plain column of rows, each with its own
Remove button). Setup's environment-variable rows for an Other location keep their own controls (rarely used, set
once). The buttons keep their accessibility labels ("Add Plan",
"Remove Plan", and so on) and their existing actions.

### 3. Pickers

- **A plan's folders** (setup and the Folders tab, `SourcesEditor`): the + button opens the existing `NSOpenPanel`
  for folders and drives (multiple selection). Drag and drop onto the list stays. The separate "Add Folder or
  Drive…" and "Remove" buttons go, replaced by + and −. The add rule (`FolderDrop`) is unchanged.
- **A local repository** (setup's storage step; a plan's repository can't be changed after setup, as today): a new
  storage choice, **A folder or drive on this Mac**, separate from **Other**. It shows the chosen folder (name and
  icon, the full path under it) and a **Choose…** button that opens an `NSOpenPanel` for one folder, with
  New Folder allowed. The existing rules still apply: the folder must be empty or hold a restic repository, and a
  plan's own repository can't be inside its sources in a way the add rule refuses. **Other** stays for any location
  restic understands (sftp, rest, and so on), as a typed string.
- The chosen folder is stored as a path, as today (no security-scoped bookmark: the agent isn't sandboxed). Editing
  an existing plan whose repository is a local path (a resumed setup) shows this form with that path. Whether the
  folder exists, is empty or holds a repository is reported by the agent's check after Check, as today (my call;
  there is no separate "can't be found" text for a repository).
- The + of a list that adds by typing or choosing (exclusion patterns, skipped Wi-Fi names) opens that list's
  existing add flow; only the buttons' look and place change (my call).

### 4. Notifications

A new Mac-wide setting (in config with the network settings; the builder picks the field's name and shape), shown
in Settings ▸ Notifications:

```
Notifications
  [ ] Backup started
  [ ] Backup finished
  [x] Problems with backups
      When this is off, the menu bar icon still shows a problem, and so does a check-in URL if you've set one.
  Notifications are allowed for Restorey.          (or: Notifications are off for Restorey. [Open System Settings…])
```

- **Backup started**: off by default. Posted when a backup's restic step starts, for a scheduled backup and for Back
  Up Now. Not for maintenance (forget, prune, check), and not for a backup that is skipped before it starts.
- **Backup finished**: off by default. Posted when a backup ends having saved its data: success, unchanged, or a
  warning (files couldn't be read, worded as the menu words it). A cancelled, paused or stopped-by-the-system
  backup posts nothing here. A failure is a problem, below, not "finished".
- **Problems with backups**: on by default. Gates the alerts the agent posts today (`AlertCondition`: backup failed,
  check failed, no recent success, check-in rejected, configuration error, Full Disk Access missing). Their rules
  (when raised, edge-triggered, repeats rate-limited) are unchanged. Turning it off stops posting them as
  notifications only: the alerts are still raised, so the menu bar icon, the menu's banners and check-in pings
  behave exactly as today.
- Each notification names the plan. The agent posts them, as it posts alerts today, through `AlertNotifying` with
  a new kind of content for events (my call: the builder adds it beside `AlertContent`).
- **Identifiers (my call):** started and finished share one identifier per plan, so each replaces the last and hourly
  backups leave one notification per plan. Problem notifications keep their own per-plan, per-condition
  identifiers and sit alongside. When a backup fails, the plan's started notification is removed, so a stale
  "started" never sits next to the failure.
- **Clicking a notification** does what macOS does by default today; it doesn't open the plan (my call, not
  requested: the agent posts the notifications and has no click handling, so routing a click to the app's window
  is its own piece of work for later).
- Turning on any notification asks for notification permission if it hasn't been asked yet, through the existing
  path (`requestNotificationPermission`). The `notificationsOff` alert ("Restorey can't alert you…") is raised
  only when Problems with backups is on, since it exists to protect that.

### 5. Leftovers

From the audit's status check and TODO (each was folded into this pass by the owner):

- **No Save bar where there's nothing to edit** (P15): a plan's Overview and History pages don't show the dimmed
  Revert and Save row, unless a sheet opened from them (such as Files that couldn't be read) has left unsaved edits
  or a save is running.
- **Shorter menu banner lines** (P5): each banner's subtitle is one short line; the full explanation stays in its
  tooltip. Today only one is long: "Restorey's background process hasn't answered for 30 minutes".
- **Help buttons** (T8): the round "?" help button (`NSButton` help style) on the Network pane and the Keep
  (retention) tab, opening the README's matching section on GitHub until there is Help Book content. The README
  gains a heading for each (its Network and Retention text are run-in paragraphs today, with no anchor).
- **The tab row overhang** (17c minor): at the main window's minimum width, the plan tab row no longer overhangs the
  form by about 10 pt.
- **Diagnostics version lines** (17d minor): readable, not disabled grey.
- **The progress bar's inset** (17d minor): NSMenu publishes no metric for where a standard item's title starts, so
  the 14 pt stays a named constant matched to macOS 27's menus, checked in the live look (my call; the alternative,
  guessing from a font metric, is no more right).
- **The owner's live look** (TODO L134): the owner checks the main window, Settings, the lists, the pickers and the
  notifications on a Dev build, as the last task.

## Left to the builder

- The exact layout of the main window's Plans and History switch, if toolbar items don't fit the split well (the
  owner may revisit in the live look).
- How apply-as-you-go is wired between the Settings panes and the agent (one save per change, or the existing save
  path called on each commit), so long as the anti-goal holds.
- The notifications setting's name and shape in config, and whether it needs a schema bump.
- Notification titles and bodies, in the style of the existing alerts, and the identifiers used to replace them.
- Test names, file splits, and README and UI design updates (§5–§8 of the UI design gain a pointer here).

## Review focus

1. Every route into the app lands in the right window after the split, including banners, Shortcuts, the setup
   flow's end, reopen with no window open (with the menu bar item shown and hidden), and a window closed and
   reopened.
2. Apply-as-you-go with a value the agent refuses, a field left mid-edit when the window closes, and two quick changes
   in a row.
3. Notifications with permission denied, with Problems off while a failure happens (the icon must still show it),
   and with started and finished both on for several plans backing up at once.
4. The local-repository picker with a folder inside a plan's sources, an existing restic repository, a non-empty
   folder, and a drive that is later disconnected.
5. The + and − controls with nothing selected, with several selected, and with keyboard only (VoiceOver labels).

## Appendix: the audit's status (23 Nov 2026)

Of 38 findings, 31 are done. Partly done: P5, P15 and T8 (all in "Leftovers"). Not built, by the owner's choice on
17 Nov: T5, T6, T7 and T10. The full table was written for this design in the session's scratch file and is not
kept.
