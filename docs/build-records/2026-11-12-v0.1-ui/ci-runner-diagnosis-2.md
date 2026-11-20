# CI runner diagnosis 2: the three failures at 34959f9 (pull_request run 44401716713)

Written 19 November 2026. These are diagnoses only: no tracked file was changed.

Sources: the failing log `ci-gh-34959f9-pr.log`, the 12 older `ci-gh-<sha>.log` files, the local `ci-*.log` files, `git diff 259d75d..34959f9`, and the code cited below. I ran two focused local runs of #3, with the 1-minute load at about 14 (below the limit of 30).

## Summary

| # | Test | Verdict | Made likelier by 259d75d..34959f9? |
|---|------|---------|------------------------------------|
| 1 | `aLiveLookIsWaitedForThenRunAgain` | (c) test-only wall-clock assumption | **Yes.** 6d4a7ec made the deadline punctual. Before that, the late GCD deadline hid the assumption. |
| 2 | `theScanFinishingReachesTheProgress` | (c) test-only race against the stub's `/bin/sleep` | No |
| 3 | `aHungNotifierHoldsNothingUp` | (c) a 1-minute `.timeLimit` on real-restic work that takes 29–64 s on the runner. **No deadlock.** | No, apart from slightly more agent-phase load |

None of the three failed in any earlier GitHub or local log. I checked all 12 `ci-gh-*.log` files and all 15 local logs; durations are in the evidence sections below. None of the three is a production defect.

## 1. `aLiveLookIsWaitedForThenRunAgain` (MarkedNotForBackupTests.swift:237-249)

**What happened.** `asked == 1`, and neither look returned `.found`. Swift Testing shows `<not evaluated>` for the two `await` expressions, so their values aren't printed. `asked == 1` together with both looks failing has only one explanation: the first look's 5 s deadline (`end`, MarkedNotForBackup.swift:205) passed before the test released the query. Two outcomes are possible, and both give exactly this result:

- The first look returned `.gaveUp`.
- The second look got `.stuck`, then `.busy` (`OneOutstandingGate.enter`, ResumeOnce.swift:107-116), or ran out its own wait. It never queried.

Everything that must happen inside those 5 s needs scheduling. That includes:

- the `async let` child task reaching `offPool`;
- the utility-QoS scan thread reaching `query`;
- the test's 10 ms poll loop resuming;
- the second child task;
- the 200 ms sleep;
- the two `signal()` calls.

The main phase runs 1,089 tests on a 3–4-thread cooperative pool. The test took 7.5 s in all.

**Why it started failing now: mechanism (a), commit 6d4a7ec.**

- Before 6d4a7ec, the deadline was `DispatchQueue.global(qos: .utility).asyncAfter(...)`. The diff removed it from MarkedNotForBackup.swift, at the old line 271.
- On the runner that deadline was always late. The old `theDeadlineWinsOverAStuckQuery` failed in all 12 earlier GitHub logs: `result → .found([])`, with elapsed time of 2.6–2.8 s against a 0.1 s deadline and a 2 s stuck query. So the deadline was at least 1.9 s late, every run.
- That lateness hid this test's assumption. It passed on GitHub with durations of 3.6–8.9 s (8.904 s on 4c16693), even though the deadline was only 5 s.
- `OwnThread.run(..., deadline:)` (ResumeOnce.swift:49-63) now times out on a dedicated thread. That thread runs at `max(caller QoS, utility)` (`deadlineQualityOfService`, :79-82), the same as or above the utility-QoS work thread. So the deadline is now honoured while the work and the test's own steps still queue for CPU and the pool.
- The production change is correct. It exposed a wall-clock assumption that was already in the test.

**Not a production defect.**

- In production, two plans backing up together each get `timeLimit = 10` s (MarkedNotForBackup.swift:24).
- A look that can't get CPU within its bound gives up. That is the intended behaviour (`.gaveUp` and `.busy` skip nothing extra).

**Root-cause fix (test).** The deadline isn't what this test is about, so the test shouldn't be able to reach it. Pass a deadline it can't reach, for example `3600` for both looks. The suite's time limit, or the test run itself, still catches a wait that never ends. What the test claims is unchanged:

- "never two queries at once";
- "the second waits, then runs again";
- `asked == 2`.

Its sibling `aStuckLookIsNotJoinedByAnother` has the same issue at line 231. Its final look, with `deadline: 5`, expects `.found` after the release, so it needs the same change.

## 2. `theScanFinishingReachesTheProgress` (PlanRunnerTests.swift:1352-1387, failing at 1381)

**What happened.**

- The restic stub prints `status(0.1)`, sleeps 1.5 s, prints `scan_finished`, sleeps 1.5 s, and so on.
- The test calls `waitForPhase { percentDone == 0.1 }` (RunnerFixture.swift:386-395, polling every 20 ms). It then reads `status()` again and expects `scanFinished == false`.
- The predicate `percentDone == 0.1` stays true from the first status line until `status(0.5)`, which is about 3 s later. That window includes the 1.5 s after `scan_finished` arrives.
- So the poll can first see 0.1 after the scan line has arrived. Or the gap before the second `status()` read can exceed what is left of the 1.5 s. Either way the read sees `scanFinished == true`.
- The agent phase was very contended. The test took 27.5 s, against 11–27 s on earlier GitHub runs and about 6 s locally, so a gap of more than 1.5 s between two awaits is ordinary there.

**Verdict (c).**

- The commits didn't touch the progress path. The PlanRunner.swift diff covers only the cloud-only walk gate.
- The test races against the stub's `/bin/sleep`. It assumes the test sees each line within 1.5 s.

**Root-cause fix (test).** Replace the sleeps with a handshake, as other stubs in this file already do (PlanRunnerTests.swift:407, 645, 940, 1625: `while [ ! -f '<go-n>' ]; do /bin/sleep 0.05; done`).

- The stub prints `status(0.1)`, then waits for `go-1`.
- It prints `scan_finished`, then waits for `go-2`.
- It prints `status(0.5)`, then waits for `go-3`, then prints the summary.
- The test asserts on each state, then creates the next file.

Each asserted state then lasts until the test moves on, however slow the runner is. The sibling `retryingLineIsShownUntilTheNextStatus` (:1310-1348, stub at :1321-1325) has the same shape and needs the same fix.

## 3. `aHungNotifierHoldsNothingUp` (AgentStateAlertTests.swift:313-339)

**Not a deadlock.** Evidence:

1. **The body finished.** Swift Testing's `withTimeLimit` (swift-testing `Sources/Testing/Traits/TimeLimitTrait.swift`) races the body against a sleep in a `withThrowingTaskGroup`, and calls `group.cancelAll()` in a `defer`. A task group waits for all its children before it returns, so the test is reported only once the body has returned. The test was reported as failed after 64.038 s, 4 s after the limit, and the whole run completed.
   - If the body had been waiting on a `HangingNotifier` continuation, it could never have returned. Those continuations are `withCheckedContinuation`, so they ignore cancellation, and only the body's own later `answer()` resumes them.
   - Only one issue was recorded:
     - no `CancellationError` was thrown from the `try await Task.sleep` loop at :319;
     - the `#require` at :331 didn't fail;
     - `guard case .success` (:332) passed;
     - `deliverAlerts(waitingAtMost: 10 s)` (:338) returned true.
   - So the body ran to completion, late.
2. **No pool blocker.** I ran the test alone twice at 34959f9:
   - normally: passed after 6.36 s;
   - with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (a one-thread pool): passed after 6.31 s. A cooperative-pool wait between tasks would deadlock there; it didn't.
3. **Code read.**
   - Nothing on the save path, the tick or `runsFinished` waits for alert delivery. The only waits on `alertsDelivered`/`alertDelivery` are `deliverAlerts`, which is bounded (AgentState+Alerts.swift:48-56). grep finds no other caller in Sources.
   - Each notifier call runs in `bounded` (AgentState.swift:859-882), inside the unstructured delivery `Task`, which runs on the actor and suspends rather than blocking it.
   - The hung authorisation call stops the round before the write gate is entered (step 1), so it holds no gate.
   - `OwnThread` and `OneOutstandingGate` are on this path only through the backup's cloud-only count and marked-items look. Both fixture fakes return at once, and every gate entry has a matching `leave()` once the work returns.

**Why it timed out: (c).**

- This is the only AgentCore test with a 1-minute limit that does real restic work: `RunnerFixture.make()` creates a repository, then the tick runs a backup and its maintenance. The two RunLogPruning fixture tests use `createRepository: false` and take 1–5 s.
- Every other real-restic fixture suite has a 3-minute limit: PlanRunnerTests, SystemStop, AgentReplacement, CloudOnlyWalker and EarlierSnapshots.
- Its GitHub durations on earlier commits were 29.1, 34.3, 36.4, 38.6, 39.3, 44.3, 46.8, 47.1, 49.7, 50.8, 51.0 and 55.2 s. That already crowded the limit. Locally it takes 11–29 s.
- In this run the agent phase was slower than usual (agent-phase tests, of 317):

  | Run | Tests over 50 s | Tests over 58 s | Slowest |
  |-----|-----------------|-----------------|---------|
  | 259d75d | 0 | 0 | 48.9 s |
  | b05188e | 45 | 8 | 61.9 s |
  | this run | 62 | 44 | 71.3 s |

  Its own suite-mate `aRunWithoutFullDiskAccessIsPostedAndTheTickRepeatsIt` took 60.9 s, against 7–45 s before.
- The only thing the commits added to the agent phase's load is one more real-restic test, `aStuckWalkIsNotJoinedByAnother`: four backups, 63.3 s. The phase's total, 365 s, is within the earlier range of 352–392 s. I can't attribute the slower tail to the commits; it fits runner variance.

**Root-cause fix (test).** The limit is a backstop against hangs, not a performance bound. Here it was sized for a local Mac.

- Use the suite's convention for real-restic fixtures: `.timeLimit(.minutes(3))`. A real hang still fails at 3 minutes.
- Optionally, take restic out of the test's cost with a stub executable, as the progress tests do (`[ "$1" = backup ] || exit 0`). The test's claim is about the notifier, not restic.

## Is there a class to fix systematically? Yes

I found these by grep over `RestoreyCore/Tests`:

- `.timeLimit`
- `ContinuousClock.now -` and `- started`
- `/bin/sleep` in stubs
- `deadline:` and `Deadline:` arguments
- `waitingAtMost`
- `timeout: .seconds`

I then cross-checked durations across all 12 GitHub logs.

The rule that splits them:

- A deadline or limit in a test is either **the subject** (tiny, and the work is held by a semaphore or file until after the result, so the order holds under any load), or **unreachable**.
- It is never a mid-sized number that some sequence of scheduling steps must beat.

The remaining members of the class:

**A. Deadlines that aren't the subject but can be reached (made likelier by 6d4a7ec, because the deadlines are now punctual):**

- MarkedNotForBackupTests.swift:231 (`deadline: 5`), :239/:241 (#1, `deadline: 5`), and :253 (`deadline: 10`, expects `.found`).
- RunnerFixture.swift:165/167: default `cloudOnlyDeadline: 10` and `markedItemsDeadline: 10`.
  - Every runner test that asserts a cloud-only or marked count depends on a fake running on a utility thread within 10 s. Examples: `theCountIsRecordedAfterABackupWithASnapshotWithoutChangingTheOutcome`, `aWarningBackupIsCounted`, `anUnchangedBackupIsCounted`, `markedItemsAreSkippedCountedAndTheirListRemoved`.
  - Before 6d4a7ec, the work and the deadline queued together on the same global queue. Now only the work can be late.
  - Fix: default these to unreachable values, for example 3600. Tests about the deadline already pass 0.2 or 0.3 explicitly.
- AgentStateAlertTests.swift:338 `deliverAlerts(waitingAtMost: .seconds(10))` expected true. It's at risk on the same basis.

**B. Stubs whose intermediate state must be seen within a `/bin/sleep`:**

- PlanRunnerTests.swift:1321-1325 (`retryingLineIsShownUntilTheNextStatus`).
- PlanRunnerTests.swift:1365-1369 (#2).
- Fix: file handshakes, as in PlanRunnerTests.swift:407/645/940/1625 and AgentReplacementTests.swift:35.

**C. Elapsed-time upper bounds on scheduler-dependent code:**

- PlanRunnerTests.swift:1285 (`< 5 s`)
- AgentStateTests.swift:1210 (`< 1 s`)
- ResticProcessTests.swift:148 (`< 5 s`) and :318 (`< 1 s`)
- SystemStopTests.swift:118/120/148
- ResticUnhappyPathTests.swift:280 (`< 120 s`)
- MarkedNotForBackupTests.swift:224 (`< 30 s`, generous)

AgentStateTests.swift:1234 is a lower bound (`>= 30 s`) and is safe. For "it returned via the bound, not by waiting", use injected clocks: `ManualClock` is already in `Tests/TestSupport`, and `KeyWaiter`/`LocationAccess` already take one. Otherwise assert ordering (which event came first), not elapsed time.

**D. 1-minute `.timeLimit` on real-restic work:**

- `aHungNotifierHoldsNothingUp` (#3) is the only one in AgentCore.
- The RestoreyCore 1-minute restic suites (ResticProcessTests, ResticUnhappyPathTests, ScanFinishedTests) peak at 5–12 s on GitHub, because they run in the short main phase. They're safe for now, but they are the same shape. Sizing them to 3 minutes, like the agent-side convention, would close the class.

Searches that can find new members:

- `grep -rnE "deadline: [0-9]|Deadline: [0-9]|waitingAtMost|timeout: \.seconds"`
- `grep -rn "/bin/sleep [0-9.]*$"` in stubs that aren't `exec`'d
- `grep -rn "ContinuousClock.now - "`
- `.timeLimit(.minutes(1))` combined with `RunnerFixture.make(` where `createRepository` isn't false

A CI lint step could run these greps and fail on any new match.
