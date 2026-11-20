# O1 diagnosis: Restorey's windows open behind the active app (15 Nov 2026)

Diagnosis only: no product code changed, nothing committed. Evidence comes from diagnostic builds 813 and 814 (a detached scratchpad worktree at 4dd1ec2, with the temporary `ActivationLog`) and the owner's three runs on 15 Nov 2026 (times ACDT):

- **A:** both switches off.
- **B:** `diagActivateInMenuAction` on, so `activate()` is called synchronously inside the menu action.
- **C:** B plus `diagRegularWhileWindowOpen`, so the app is `.regular` while one of its windows is open.

Sources:
- Restorey's own `activation` log: `scratchpad/part{A,B,C}-act.log`.
- The system's front-process decisions, re-queried for 15:54–16:06: WindowServer `SkyLight.processes:Focus`, `OrderWindowGroupFrontConditionally`, and launchservicesd `processmanager` `SETFRONT`. Saved as `scratchpad/sysall.log`.
- The merged timelines (`scratchpad/tl.py`) and the timing table (`scratchpad/gap.py`).

The scratchpad is `/private/tmp/claude-501/-Users-kerrj-Documents-Development-restorey/50d7f0ea-c10d-4cb6-89d3-1ae860872c86/scratchpad`.

Identifiers in the logs:

| | pid | WindowServer connection | ASN | launchservicesd `foreground` |
|---|---|---|---|---|
| Restorey | 37650 | `1f1633` | `0x34ad4aa` | 0 (accessory) |
| cmux | 2204 | `14bd3` (its key window is 168) | `0xd10d1` | 1 |
| LocalAuthentication UI agent | 84934 | `4294e3` | | |

## How "in front" and "behind" show in the logs

Every opening goes through the same path: menu action → `WindowRouter.show` → `WindowActivation.bringForward` → `makeKeyAndOrderFront` → `NSApplication.activate()`. Whether the window ends up in front is decided entirely by whether launchservicesd grants the activation request:

- **Granted:** `SETFRONT: pid=37650 … foreground=0 oldFrontPid=2204` and WindowServer `Making … 0x0-0x34ad4aa the front process … via SetFrontProcessWithInfo`. The window is then ordered front: `1f1633[OrderWindowGroupFrontConditionally]: order window: … op: 1 relative: 0`.
- **Refused:** no `SETFRONT` and no `didBecomeActive`. WindowServer orders the window **below cmux's key window**, for example at 15:58:48.796: `order window: 5f72 op: -1 relative: 168`.

Neither the system nor AppKit logs a reason for a refusal. Apple documents this: `activate()` "doesn't guarantee app activation" ([NSApplication.activate()](https://developer.apple.com/documentation/appkit/nsapplication/activate())). `activate(from:options:)` returns true only "if the request is allowed by the system" ([NSRunningApplication.activate(from:options:)](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(from:options:))).

Every Settings… opening across the three runs:

| Time | Run | Outcome | Last input seen during menu tracking | Last input → menu action |
|---|---|---|---|---|
| 15:56:52 | A | granted | mouse moved | 271 ms |
| 15:57:23 | A | granted | mouse moved | 263 ms |
| 15:58:23 | A (after kit Cancel) | granted | mouse moved | 254 ms |
| 15:58:48 | A | **refused** | mouse moved | 274 ms |
| 15:59:04 | A | **refused** | mouse up | 354 ms |
| 16:00:33 | B (first) | **refused** | mouse up | 353 ms |
| 16:00:44 to 16:01:41 (7 openings) | B | granted | mouse moved | 262–299 ms |
| 16:02:17 | B (after kit Cancel) | **refused** | mouse up | 349 ms |
| 16:02:31 | B | granted | mouse moved | 294 ms |
| 16:02:39 | B | **refused** | mouse up | 356 ms |
| 16:03:21 | C | granted | mouse up | 349 ms |
| 16:03:47 | C | granted | mouse up | 346 ms |
| 16:04:07 | C | granted | mouse moved | 249 ms |
| 16:04:25 | C | granted | mouse moved | 265 ms |
| 16:04:32 | C (after the close while inactive) | **refused** | mouse up | 348 ms |

The outcomes match the owner's front/behind report one for one.

How to read the last two columns:
- The input column is the event AppKit held when the menu window resigned key, about 240 ms after the click.
- "Mouse up" means the pointer stayed still after the click.
- "Mouse moved" means the pointer moved during the menu's selection blink.

## (1) What the Touch ID prompt leaves behind

**Proven: when the prompt closes, WindowServer brings the next regular app forward, never an accessory app.**

1. `evaluatePolicy` makes the LocalAuthentication UI agent front:
   ```
   15:57:29.923 SETFRONT pid=84934 … oldFrontPid=37650
   ```
2. On Cancel, the agent's connection hands the front to the next process:
   ```
   15:57:32.880 WS  FRONT 0x0-0xd10d1 by 4294e3 via BringNextToFront
   15:57:32.880 LS  SETFRONT pid=2204 fg=1 old=84934
   ```
   Run B is identical at 16:01:45.857.

   Restorey was the active app immediately before the prompt (15:57:29.508, `isActive=true`). Even so, cmux (`foreground=1`) was chosen and Restorey (`foreground=0`) was skipped.
3. Restorey's post-prompt `bringForward` then calls `activate()` (15:57:32.881 and 16:01:45.857). No user input is behind that call, and it is refused: no `SETFRONT`.
4. With `.regular` (run C), the same moment picks Restorey, both for Cancel and for approve:
   ```
   16:03:27.295 SETFRONT pid=37650 fg=1 old=84934   FRONT 0x0-0x34ad4aa by 4294e3 via BringNextToFront   (Cancel)
   16:03:50.835 SETFRONT pid=37650 fg=1 old=84934   FRONT 0x0-0x34ad4aa by 4294e3 via BringNextToFront   (approve)
   ```

**Nothing found that outlives the prompt.** The openings after a Cancel went granted, refused, refused (run A) and refused, granted, refused (run B). Each refusal there fits the same pattern as the refusals with no prompt before them (16:00:33, run B's first opening):
- the pointer was still after the click;
- the menu action came about 350 ms after the last input.

The one exception is 15:58:48 (274 ms, pointer moving). Between the prompt and those openings, the owner clicked the kit window (`DoDeferredOrdering` at 15:57:41 and 16:02:07) and then clicked cmux, so activation state was rebuilt by ordinary clicks.

So the prompt's lasting effect is only that it hands the front to cmux at dismissal, and Restorey can't take it back without user input. Synchronous `activate()` in the menu action can't help here: that is about a later, separate request.

## (2) Why B's first opening and C's last opening went behind

Both are ordinary refused requests (no `SETFRONT`; ordered `op: -1 relative: 168`). They match every other refusal:

- **16:00:33 (B, first):** the synchronous `activate()` at 16:00:33.180 came 3 ms after the menu action and was still refused. The pointer stayed still after the click (mouse up 353 ms earlier).
- **16:04:32 (C, last):**
  - The owner closed Settings with the red button while cmux was active. The policy went back to `.accessory` at 16:04:30.220 while Restorey was inactive.
  - The next opening switched to `.regular` and called `activate()` inside the menu action. That was refused, again with the pointer still (mouse up 348 ms earlier).
  - C's 16:03:47 opening made the same accessory-to-regular switch at the menu action, at the same 346 ms, and was granted. So the switch can't explain the refusal on its own.

**Strongest pattern, a hypothesis:** in accessory mode (runs A and B):
- 4 of 4 requests made with the pointer still after the click were refused;
- 10 of 11 made with the pointer moving were granted.

The menu action fires only after the menu's selection blink, about 350 ms after the mouse up. Pointer movement during the blink is input to Restorey, roughly 250–300 ms before the action. So the system appears to grant activation only when the requesting app received user input very recently. The window sits somewhere between about 300 and 350 ms, and the 15:58:48 refusal at 274 ms says the rule isn't purely time-based.

Apple documents no such window, and I couldn't see launchservicesd's reasoning: its decision logging is private and would need admin rights to enable. Treat this as the most likely reading, not a proven rule.

In run C, two "pointer still" requests were granted (16:03:21, 16:03:47) and one refused (16:04:32). Being `.regular` may loosen the rule, but three samples don't show it.

## (3) Is `.regular` while a window is open the fix, or only a mask?

**It is the fix for the drop after the Touch ID prompt, at the root.** The root cause is that WindowServer's `BringNextToFront` passes over accessory (`foreground=0`) processes. After that, an `activate()` without user input is refused, and nothing an accessory app does can bring it back. A `.regular` app is an ordinary front-app candidate, and the system itself made Restorey front again when the prompt closed (point 1, item 4).

**It also fixes the owner's "no menu to select Quit from".** Apple's `.accessory` documentation: "The application doesn't appear in the Dock and doesn't have a menu bar" ([ActivationPolicy.accessory](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory)). While a Restorey window is in use, the menu bar still belongs to the previous app. A `.regular` app "is an ordinary app that appears in the Dock and may have a user interface" ([ActivationPolicy.regular](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/regular)), so Restorey's own menu bar, with Quit and ⌘Q, shows while its window is active.

**It doesn't remove refusals when a window opens from the status-item menu.** Those are the system's user-intent decision at request time (C's 16:04:32). They need their own handling (point 4).

**Minimal correct policy transition:**
- **Go `.regular`** synchronously when a Restorey window is about to be shown and the policy isn't already `.regular`. That means in `WindowRouter.show`, before `makeKeyAndOrderFront` and before `activate()`. Use `setActivationPolicy(_:)` ([docs](https://developer.apple.com/documentation/appkit/nsapplication/setactivationpolicy(_:))), which returns whether the switch succeeded.
  - Run C shows launchservicesd treating Restorey as foreground immediately: `SETFRONT pid=37650 fg=1` within 3–6 ms of the switch (16:03:21.594, 16:03:47.239).
  - This covers every route into a window: menu items, the "Add…" route, reopen, "Show recovery kit…" from Settings, and the quit sheet's `bringForward`.
- **Go back to `.accessory`** in `windowWillClose` when no other Restorey window (`AppWindowKind`) stays visible. Sheets and alerts belong to their window and don't count separately.
  - When Restorey is active at that moment, the switch hands the front to the previous app by itself: `16:03:36.060 FRONT 0x0-0xd10d1 by 1f1633 via SetFrontProcess`, then `16:03:55.813` and `16:04:14.997`. That is the behaviour the owner expects.
- **Red-button close while inactive** (16:04:30): switching to `.accessory` then is correct and harmless. The Dock icon goes, focus stays with cmux, and no front change happens (none is logged). Nothing special is needed. The next opening is a normal request and may be refused like any other (point 2), which the fallback in point 4 covers.
- **Not needed:** switching at `menuWillOpen`, or keeping `.regular` while no window is open.

## (4) Recommended fix and its cost

1. **`.regular` while any Restorey window is open, `.accessory` otherwise**, as described in point 3.
   - **Cost:** a Dock icon and a ⌘-Tab entry while a Restorey window is open, and Restorey's menu bar while that window is active. Both go when the last window closes. This is the usual arrangement for menu bar apps with real windows.
   - **Gain:** the kit window and Restore Files stay in front after Touch ID, whether it is approved or cancelled. Settings stays behind the kit window but in front of other apps. ⌘Q and the app menu work.
2. **Ask for activation once, synchronously, in the menu action, and drop the deferred `RunLoop.main.perform` re-request.**
   - The deferral (fix round 1) moved the request about 110–180 ms later (`menu action` → `deferred fired`). The data gives it no benefit.
   - The menu has already closed when its action runs: `menuDidClose` is logged in the same millisecond as the action, before it (15:56:52.782), and the key-thief is released 3–10 ms earlier. So the original reason for the deferral doesn't hold.
3. **Fallback when the request is refused:** keep the window visible in front even though the app isn't active.
   - After `activate()`, if Restorey hasn't become active by the next turn (no `didBecomeActive`; `NSApp.isActive` false), call `orderFrontRegardless()` on the window. Apple: it "moves the window to the front of its level, even if its application isn't active, without changing either the key window or the main window" ([NSWindow.orderFrontRegardless()](https://developer.apple.com/documentation/appkit/nswindow/orderfrontregardless())).
   - The owner's first click in the window then activates Restorey. User clicks are always honoured (`DoDeferredOrdering`, for example at 16:00:49.393 and 16:02:07.004).
   - **Cost:** after a refused activation the window is in front but not key, so typing goes nowhere until that click.
   - **Caveat:** Apple says the method is "rarely" needed and is meant for cooperating apps. This is the honest fallback for a refusal, not something to use routinely.
4. **Remove the post-prompt `activate()` from `OwnerAuthentication.confirm`.** It is always refused (point 1, item 3). With `.regular`, the system already returns the front to Restorey when the prompt closes. Keep the `makeKeyAndOrderFront`, which restores key status to the window that asked.

Expected result:
- The prompt and Quit symptoms go deterministically.
- Openings from the status menu are either granted, or visible in front waiting for a click. The window is never hidden behind another app.

The live checks for the fix round:
- the owner's three runs again;
- a "pointer still after the click" opening;
- the red-button close while inactive, then reopening;
- ⌘Q and the menu bar while Settings is active;
- confirming the Dock icon appears and disappears with the windows.

## Clean-up after the fix round

- `defaults delete com.jaydenkerr.restorey.dev diagActivateInMenuAction` and `diagRegularWhileWindowOpen` (already done by the coordinator).
- Install the fix, or 4dd1ec2, from the main checkout with `BUILD_NUMBER=815` or higher, so the agent restarts on the version handshake.
- `git worktree remove --force` the scratchpad `o1-diag` worktree. Nothing from it was committed.
