# CI runner diagnosis: why `swift test` fails on the GitHub `xcode-27` runner but passes on a 10-core Mac

18 November 2026, branch `v0.1-ui` at 259d75d. Diagnosis only: no tracked file was changed.

## Summary

There are two separate starvation mechanisms, and the hypothesis is only half right.

1. **Cooperative pool (width = core count).** This is proven. One synchronously blocked pool thread is enough to delay main-actor `Task.sleep` wake-ups and task resumptions until it frees up. That explains `longSynchronousJobDoesNotBlockAnotherKey`, all of the KeyWaiter failures, `aHungServicesReadIsBoundedAndShared`, and the elapsed-time half (line 205) of `theDeadlineWinsOverAStuckQuery`. In all of these the defect is in the **tests**, plus one misleading doc comment. Production code does not block the pool on any long path I could find.
2. **GCD's constrained global queues.** This one is **not** the cooperative pool. `theDeadlineWinsOverAStuckQuery` fails `result == .gaveUp` (line 204) on every CI run. Exhausting the cooperative pool cannot cause that, because neither racer uses the pool. Starving `DispatchQueue.global(qos: .utility)` does cause it. That is a **production defect** at `MarkedNotForBackup.swift:271`, and the same pattern appears at `PlanRunner.swift:562-563`.

The runner always shows the same failures, and the 10-core Mac never does, for two reasons:

- With 3–4 cores, the cooperative pool is 3–4 threads wide.
- Kernel admission to the constrained global queues needs fewer than NCPU threads active at or above that QoS.

All 1,023 tests start in parallel, and individual CI tests take about 40 s of wall time. That saturates both mechanisms in the first few seconds, which is when the KeyWaiter, RepositoryQueues and MarkedNotForBackup suites all finish together (5–9 s in, every log).

## Method

- Load was 17.3 at the start, so I waited until it fell below 15 (it reached 13). No CPU load, stress or loops were used. Each focused run was done once or twice.
- `swift test` passes its environment through to the test runner, so `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --package-path RestoreyCore --skip-build --filter '…'` works. I confirmed this with a positive control: the RepositoryQueues test fails at exactly line 117 with the variable set and passes without it.
- None of the named tests is agent-hosted. `AgentHostedTests` holds only `KeychainSecretStoreTests` and `LaunchRoleTests`, and on GitHub it is skipped anyway because there is no `Config/Local.xcconfig`. So xcodebuild env plumbing was not needed.
- To reproduce without load, I built a scratch package **outside the repo** (`/private/tmp/claude-501/-Users-kerrj-Documents-Development-restorey/50d7f0ea-c10d-4cb6-89d3-1ae860872c86/scratchpad/poolprobe`) that depends on RestoreyCore and AgentCore by path. Each probe reruns a failing test's body next to an *idle* blocker:
  - one cooperative thread in `usleep` (3–4 s), or
  - 80 `DispatchQueue.global(qos: .utility)` blocks waiting on a semaphore (the kernel parks 64 of them: `kern.wq_max_constrained_threads = 64`).

## Results

Focused run of the three always-failing tests in the real suite:

| Test | Pool default (10) | Pool strict (1) |
|---|---|---|
| `longSynchronousJobDoesNotBlockAnotherKey` | passed, 0.356 s | **failed at RepositoryQueuesTests.swift:117** (same as CI) |
| `theDeadlineWinsOverAStuckQuery` | passed, 0.103 s | passed, but took 0.372 s (held up by the usleep) |
| `theWaitEndsWhenTheWindowBecomesKey` | passed, 0.025 s | passed, but took 0.373 s (held up by the usleep) |

Scratch probes (same bodies and bounds as the real tests):

| Probe | Pool default | Pool strict (1) |
|---|---|---|
| KeyWaiter wait + 20 ms `becameKey`, one pool thread blocked 3 s | 25 ms | **3,029 ms** (bound 2,000) |
| LocationAccess two `current()` with hung read, 100 ms bound, one pool thread blocked 4 s | 205 ms | **4,215 ms** (bound 3,000) |
| `offPool` with 2 s stuck query, 0.1 s deadline, one pool thread blocked 3 s | gaveUp, 106 ms | **gaveUp**, 3,106 ms. Fails line 205 only, not line 204 |
| `offPool`, 64 constrained global utility threads parked, cooperative pool idle | **found([]), 2,078 ms**. Fails lines 204 *and* 205, exactly as on CI | same: found([]), 2,074 ms |
| …in that same starved state, a 0.1 s `asyncAfter` on a **private serial** queue | fired at 103 ms | fired at 100 ms |
| …and a 0.1 s `asyncAfter` on `DispatchQueue.global(qos: .utility)` | still not fired after 2 s | still not fired after 2 s |

## Per test

### `longSynchronousJobDoesNotBlockAnotherKey` (RepositoryQueuesTests.swift:117): defect in the test, plus a wrong doc comment

- The test blocks a cooperative thread itself: `usleep` ×30 inside the job (RepositoryQueuesTests.swift:109).
- `RepositoryQueues.enqueue` runs work on `Task.detached` (RepositoryQueues.swift:60), and that is the same cooperative pool. Job B therefore needs a *second* pool thread to be free within 300 ms.
- On a 3–4-thread pool that is shared with 1,023 parallel tests, there never is one. With strict = 1 it fails deterministically.
- **Production:** no defect today. Restic jobs are fully async: `ResticProcess` drains its pipes on private serial queues (`ResticProcess.swift:239`) and waits through `terminationHandler`. However, the doc comment at RepositoryQueues.swift:10-11 ("a long synchronous job cannot block … a job for another key") is false once the pool is full.
- **Fix:**
  - Rewrite the test so it checks what the code actually guarantees, which is that the work runs off the actor. Have A *suspend* on a gate and check that B enqueues and runs while A is suspended. The existing `differentRepositoriesOverlap` already does most of this, so the test can be dropped or merged into it.
  - Correct the doc comment to say that work must not block a cooperative thread.
  - If synchronous jobs ever need supporting, run them on a dedicated thread or queue and resume through a continuation.

### `theWaitEndsWhenTheWindowBecomesKey` (KeyWaiterTests.swift:27), plus intermittent `cancelResumesEveryWaiterOnceWithFalse` (:63) and `closingDuringTheWaitFetchesNothing` (:258): victims; defect in the tests' wall-clock bounds and the suite's pool hygiene

- The suite is `@MainActor`. The 20 ms `Task.sleep` before `becameKey()`, and `KeyWaiter`'s own timeout (`KeyWaiter.swift:72`), are main-actor `Task.sleep`s. The probe shows their wake-up and resumption wait for a cooperative thread: 25 ms → 3,029 ms with one pool thread blocked. So when the pool is busy, the "< 2 s" and "< 5 s" bounds fail.
- **Production:** `KeyWaiter` itself doesn't block anything. In the app, the timeout fires late only if something else in the app holds the pool. No such blocker was found, so there is no user-visible defect from `KeyWaiter`.
- **Fix:**
  - Stop asserting wall-clock bounds on code that depends on the scheduler. Inject the time source: `KeyWaiter` and `RevealOrder` take an `any Clock<Duration>` (default `ContinuousClock`), and the tests drive a manual or test clock. The tests then check *order* (resumed by `becameKey` or `cancel`, not by the timeout) rather than elapsed time.
  - Separately, remove the suite's own pool blockers (see "Suite-wide blockers").
  - Widening the bounds would only be a patch.

### `aHungServicesReadIsBoundedAndShared` (LocationAccessTests.swift:116): victim; defect in the test's wall-clock bound

- This is the same mechanism. The suite is `@MainActor`, and `LocationAccess.readServices`'s bound is an inheriting main-actor `Task { try? await Task.sleep(for: servicesBound) }` (LocationAccess.swift:128-131). The probe went from 205 ms to 4,215 ms against a 3 s bound.
- **Production:** the blocking `servicesEnabled()` read is correctly off-pool on a private serial queue (LocationAccess.swift:57, 140). There is no production defect, beyond the bound inheriting any pool starvation in the agent.
- **Fix:** inject a clock for `requestBound`/`servicesBound` as above, and assert "returned via the bound, one read in flight" without a wall-clock limit.

### `theDeadlineWinsOverAStuckQuery` (MarkedNotForBackupTests.swift:204-205): **production defect**

- On CI, `result == .gaveUp` is false. In other words, the 2 s `Thread.sleep` on the scan's own `Thread` beat a 0.1 s deadline.
- The deadline is `DispatchQueue.global(qos: .utility).asyncAfter` (**MarkedNotForBackup.swift:271**). Global queues are *constrained* (non-overcommit) queues. The kernel runs a constrained work item only when:
  - fewer than NCPU workqueue threads at that QoS or higher are active, and
  - fewer than 64 constrained threads exist in the process.
- Utility is below the test tasks' QoS, so on a 3–4-core runner with every core busy, the deadline item simply isn't admitted.
- The probe reproduces both CI assertions exactly by exhausting the constrained pool with idle threads. Under the same starvation, a timer on a private serial queue (overcommit) fired on time at 100–103 ms. Blocking the *cooperative* pool reproduces only line 205, and the result stays `.gaveUp`.
- On the runner the starvation is most likely the active-thread (NCPU) half, not the 64-thread half. I did not reproduce that half, because doing so requires CPU load.
- **User-visible consequence on a low-core Mac:**
  - When the agent or app process is busy, the Spotlight "marked not for backup" look is not bounded by `MarkedNotForBackup.timeLimit`. A slow or hung `mds` holds the backup's pre-scan, or the Folders tab's count, for as long as the query takes.
  - Under starvation the gate's "stuck" detection also slips, because the deadline that turns a look into `.gaveUp` arrives late.
- `aStuckLookIsNotJoinedByAnother` doesn't catch this because its first call has no time bound.
- **Fix:** don't put deadline timers on global queues. Use one of these:
  - a `DispatchSourceTimer` or `asyncAfter` on a private serial queue created with the caller's QoS (serial queues created with `DispatchQueue(label:)` target the overcommit root queue);
  - the dedicated thread waiting on a semaphore with a timeout;
  - a `Task.sleep` in a racing child task. Note this depends on the cooperative pool, so it is not suitable here.
- Keep the deadline at least at the caller's QoS, not `.utility`.

### `aStuckWalkIsAbandonedAtTheDeadlineAndItsLateResultDiscarded` (CloudOnlyWalkerTests.swift, `!finished.value`): defect in the test; same production pattern nearby

- Only `#expect(!finished.value)` failed. `cloudOnlySkipped == nil` and the "Gave up" log passed, so the 0.3 s deadline *did* win on that run.
- The test assumes `runBackup` returns within the walk's 15 s `Thread.sleep`, but on the runner the test took 57.6 s. That is a wall-clock assumption, not a code fault.
- **Fix (test):** have the fake walk wait on a semaphore that the test signals *after* asserting `!finished`, instead of sleeping 15 s.
- **Production, same defect class as above:**
  - `PlanRunner.swift:563` puts the cloud-only deadline on `DispatchQueue.global(qos: .utility).asyncAfter`, so it can fire late under starvation.
  - `PlanRunner.swift:562` runs the *blocking* walk on a constrained global thread. A stuck walk pins one of the process's 64 constrained threads for as long as it hangs, and adds to the starvation that delays every other global-queue deadline.
  - Consequence on a low-core Mac: a backup can sit after restic has finished for longer than `cloudOnlyDeadline` before it records and returns.
- **Fix (production):**
  - Run the walk on a dedicated `Thread`, as `offPool` already does for MDQuery.
  - Put the deadline on a private serial queue or timer at the caller's QoS.
  - Consider a one-outstanding-walk gate like `MarkedItemsLookGate`, so repeated stuck walks can't accumulate.

### `aLockHeldElsewhereRemovesNothing` (EarlierSnapshotsRunnerTests.swift:232): not explained by either mechanism; needs its own look

- It failed once in 12 runs (c9e73ab) with `<not evaluated>`. That means `previewEarlierSnapshots` threw or returned no `beforeAdoption` group *while the other client's lock was held*.
- The preview is `forget --dry-run --no-lock` (ResticInvocation.swift:218-226), so it should not meet the lock. The likely suspects are the restic call or the fixture under load (a slow restic, or `LockHolder`'s process). I did not run it: it needs real restic and is not pool-related.
- **Next step:** record the thrown error in the test (`do/catch` with `Issue.record(error)`) so the next CI failure says why.

## Suite-wide blockers of the cooperative pool (why the pool is full on the runner)

`Tool.swift` (both copies) and `ResticProcess` already do this correctly, on private serial queues. Places in the tests that still block a pool thread synchronously:

- `RepositoryQueuesTests.swift:109`: 300 ms `usleep`.
- `StubHTTPServer.swift:51,68`: `DispatchSemaphore.wait(timeout: 5 s)` in `init`, called from async tests in `CheckInServiceTests`.
- `HelperAuthorisationTests.swift:123`: `process.waitUntilExit()` in a synchronous test, which runs on the pool.

Beyond those, a 3–4-thread pool is held by *runnable* CPU-bound test bodies on a contended VM. So removing the blockers alone will not make wall-clock bounds of 1.5–5 s reliable there. The durable fix is the injected clock for the scheduler-sensitive tests.

## Proposed fixes, in order

1. Production: move the deadline timers off the global queues (`MarkedNotForBackup.swift:271`, `PlanRunner.swift:563`), and move the cloud-only walk onto its own thread (`PlanRunner.swift:562`).
2. Tests: inject a clock into `KeyWaiter`/`RevealOrder` and `LocationAccess`, and replace the elapsed-time assertions with ordering assertions.
3. Tests: rewrite `longSynchronousJobDoesNotBlockAnotherKey` without `usleep`, and correct the RepositoryQueues doc comment.
4. Tests: gate the CloudOnlyWalker fake walk on a semaphore. Make `StubHTTPServer` readiness async (continuation) rather than a semaphore wait. Move `waitUntilExit` off the pool.
5. Instrument `aLockHeldElsewhereRemovesNothing` to record the thrown error.
6. Optional guard: a CI step that runs the timing-sensitive suites with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` would catch new pool blockers on any Mac. It doesn't cover the global-queue mechanism.
