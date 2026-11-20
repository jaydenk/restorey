# Context for every implementer (plan 2, v0.1 UI)

- Repo: /Users/kerrj/Documents/Development/restorey, branch `v0.1-ui`. Commit to this branch; never push.
- Project: Restorey, a macOS menu bar front end for restic. Plan 1 (merged) built the engine: `RestoreyCore` SPM package (targets `RestoreyCore`, `AgentCore`), the launchd agent (`Agent/`), the app (`App/`), XcodeGen `project.yml`. This plan adds the real UI.
- Binding docs (read only what your brief points to): UI design `docs/superpowers/specs/2026-11-12-restorey-v0.1-ui-design.md`; product spec `docs/superpowers/specs/2026-11-09-restorey-design.md`; plan `docs/superpowers/plans/2026-11-12-v0.1-ui.md` — read only its header sections (Decisions P2-1…P2-16, Global Constraints, Review Focus), not other tasks.
- Commands: `swift test --package-path RestoreyCore [--filter X]` for core tests; `scripts/ci.sh` for the full check (fetches binaries, core tests, xcodegen, unsigned Debug and Release builds, signed Debug build and hosted tests). Builds run on this Mac — never birdseye or remote CI.

## Adding an XPC call (pattern from plan 1)
1. `RestoreyCore/Sources/RestoreyCore/XPC/AgentProtocol.swift` — `@objc` method on `AgentXPC`, reply `@escaping @Sendable (Data?, String?) -> Void`.
2. `XPC/Messages.swift` — Codable request/reply types (`XPCCoding`); tests in `RestoreyCore/Tests/RestoreyCoreTests/XPC/MessagesTests.swift`.
3. `Agent/AgentService.swift` — adapter via `respond(reply, "name") { … }`, `Self.decode`, `Self.planID`.
4. `RestoreyCore/Sources/AgentCore/AgentState.swift` (or `+Runs`, `PlanRunner+Actions.swift`) — logic with `requireMutable()/requireLoaded()/requireRunnable()` and `serialisedWrite`; errors in `AgentError.swift`; tests in `RestoreyCore/Tests/AgentCoreTests/`.
5. `App/AgentConnection.swift` — typed wrapper using `statusCall(timeout:)` or `call(T.self, timeout:)`.

## Rules
- Swift 6.4 language mode, complete strict concurrency, macOS 27. Swift Testing (`import Testing`), no XCTest.
- Tests and `ci.sh` must never touch the real identity's files, keychain or launchd job (Ruling R66). Use temp directories and the existing fakes (`InMemorySecretStore`, `ControlledStore`, `TestClock`, `RunnerFixture`, `RestServer`, `TempRepository`).
- Secrets only in the keychain; never in config, logs or files; redact in descriptions.
- Timestamps stored in UTC. Australian English in UI text, logs for people, and docs.
- Commits: update the README and any relevant docs in the same commit. NO `Co-Authored-By` lines and NO session-link trailers. Never `git add TODO.md` (gitignored).
- No quick fixes: diagnose to the root cause. Don't relax the helper's code-signing requirements.
- Ruling P-1: leave `scripts/ci.sh` green, including the app build; if you change a type the app uses, make the minimal app change so it compiles.
- Ruling P-2 (revised): no hello protocol-version bump is needed — the handshake already restarts an agent whose version, build or binary differs.
- Old payloads must still decode (e.g. a status from build 11 without your new fields): new fields optional or defaulted.
